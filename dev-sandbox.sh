#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  dev-sandbox — Sandboxed AI Coding Agents with Podman & krun microVMs
# ═══════════════════════════════════════════════════════════════════════
#
#  PURPOSE
#  -------
#  Run AI coding agents (Claude Code, Antigravity, etc.) in isolated
#  containers with controlled network access. Each agent gets its own
#  profile with separate credentials, volumes, and firewall rules.
#
#  ARCHITECTURE
#  ------------
#  The script builds a two-layer image:
#
#    Base image (shared)     All common packages, tools, user setup
#         ↓
#    Profile image           Agent-specific packages, entrypoint
#         ↓
#    Runtime                 krun microVM (default) or standard container
#
#  Data persistence uses named Podman volumes:
#    - pip volume:       ~/.local (pip packages, scripts, dotfiles)
#    - rootconf volume:  /etc/sandbox (SSH keys, startup hooks, wrappers)
#    - extra volumes:    per-profile home dirs (.claude, .cache, etc.)
#
#  PODMAN vs PODMAN + KRUN
#  -----------------------
#  Standard container (--no-krun):
#    - Shares host kernel (Linux namespaces isolation)
#    - Full networking support, nftables firewall works
#    - Lower overhead, faster startup
#    - Use for: browser testing, GUI apps, firewall-dependent workflows
#
#  krun microVM (default):
#    - Runs its own Linux kernel inside a lightweight VM
#    - Stronger isolation boundary (VM escape vs container escape)
#    - With passt networking (krun.use_passt=1): nftables works
#    - Without passt (TSI): bypasses netfilter, firewall ineffective
#    - Use for: running untrusted code, production agents
#
#  KEY PODMAN PARAMETERS USED
#  --------------------------
#  --annotation run.oci.handler=krun    Use krun microVM runtime
#  --annotation krun.ram_mib=N         VM memory limit in MiB
#  --annotation krun.cpus=N            VM CPU cores
#  --annotation krun.use_passt=1       Use passt networking (enables nftables)
#  --userns keep-id                    Map host UID to container UID 1:1
#  --security-opt label=disable        Disable SELinux labeling
#  --cap-add NET_ADMIN                 Allow firewall rules (only when needed)
#  --tmpfs /path:opts                  RAM-backed filesystem (cleared on exit)
#  -v name:/path                       Named volume (persists between runs)
#  -v /host/path:/container/path       Bind mount (project directory)
#  -p hostPort:containerPort           Port mapping (SSH server)
#  --hostname name                     Container hostname
#
#  USAGE
#  -----
#    dev-sandbox                          Default profile (claude)
#    dev-sandbox -p research              Different profile
#    dev-sandbox build -f                 Rebuild from scratch
#    dev-sandbox --allow host:1080        Firewall: only allow this destination
#    dev-sandbox --net locked             Firewall: block everything outbound
#    dev-sandbox --no-krun                Use standard container (no microVM)
#    dev-sandbox profiles                 List available profiles
#    dev-sandbox help                     Full help
#
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
#  COMMON CONFIGURATION
#
#  Settings that apply to ALL profiles.
#  Changes here affect the base image (rebuild required).
# ═══════════════════════════════════════════════════════════════════════

# Paths and names
SANDBOX_BASE="${HOME}/.dev-sandbox"     # Build files location
BASE_IMAGE_NAME="dev-sandbox-base"      # Base podman image name
DEFAULT_PROFILE="claude"                # Profile used without -p

# Base OS
BASE_OS="fedora:44"

# Resources (override with env: DEV_SANDBOX_RAM=8192 dev-sandbox)
RAM_MIB="${DEV_SANDBOX_RAM:-4096}"      # krun microVM RAM in MiB
CPUS="${DEV_SANDBOX_CPUS:-4}"           # krun microVM CPU cores

# Podman storage (empty = default ~/.local/share/containers/storage)
# Set for a different disk: PODMAN_STORAGE="/mnt/disk2/podman"
PODMAN_STORAGE="${DEV_SANDBOX_STORAGE:-}"

# ── Base image DNF packages (shared across all profiles) ──
BASE_DNF_PACKAGES=(
    # System
    git vim nano curl unzip tar zip wget
    procps-ng findutils which diffutils
    util-linux sudo nftables
    openssh-server openssh-clients
    privoxy
    iputils nmap iproute

    # Terminal
    tmux tree jq ripgrep
    htop mc fzf

    # Development
    nodejs npm
    python3 python3-pip python3-devel
    gcc gcc-c++ make

    # Tools
    rclone fish xz gzip strace

    # DB clients
    sqlite mycli pgcli
    mariadb postgresql
)

# ── Base image external tools (binary, not from DNF) ──
BASE_EXTERNAL_TOOLS=(
    # DuckDB — SQL analytics on local files
    'curl -L "https://github.com/duckdb/duckdb/releases/latest/download/duckdb_cli-linux-amd64.zip" -o "duckdb.zip"
     && unzip duckdb.zip -d /usr/local/bin && rm duckdb.zip && chmod +x /usr/local/bin/duckdb'

    # Bun — fast JS/TS runtime
    'curl -fsSL https://bun.sh/install | bash
     && mv /root/.bun/bin/bun /usr/local/bin/ && rm -rf /root/.bun'
)


# ═══════════════════════════════════════════════════════════════════════
#  PROFILES
#
#  Each profile defines a sandbox — agents, packages, services.
#  New profile: copy a block, adjust, add the name to ALL_PROFILES.
#
#  Variables by level:
#
#    PROFILE_<name>_DESCRIPTION      Profile description
#    PROFILE_<name>_AGENTS           Agent install commands
#    PROFILE_<name>_DNF              Extra DNF packages (on top of base)
#    PROFILE_<name>_TOOLS            Extra binary tools (on top of base)
#    PROFILE_<name>_VOLUMES          Home dirs to persist (each gets a volume)
#    PROFILE_<name>_PODMAN_ARGS      Extra podman run arguments
#
#    PROFILE_<name>_SSH_PORT         SSH server port (0 = disabled)
#    PROFILE_<name>_RUN_PRIVOXY      Run Privoxy HTTP proxy (true/false)
#    PROFILE_<name>_PRIVOXY_SOCKS    Where Privoxy forwards to (host:port)
#
#    ROOT level (rootconf volume, /etc/sandbox/):
#    PROFILE_<name>_ROOT_STARTUP     Script run at boot (as root, before dev)
#    PROFILE_<name>_ROOT_WRAPPERS    Commands in /usr/local/bin/ (name|script)
#
#    DEV level (.local volume, ~/.local/etc/):
#    PROFILE_<name>_DEV_DOTFILES     Config files (name|content)
# ═══════════════════════════════════════════════════════════════════════


# ─── Claude (default) ─────────────────────────────────────────────────

PROFILE_claude_DESCRIPTION="Claude Code — production agent"

# Agents — install commands run in Dockerfile
PROFILE_claude_AGENTS=(
    'curl -fsSL https://claude.ai/install.sh | bash'
)

# Extra packages (on top of base)
PROFILE_claude_DNF=()
PROFILE_claude_TOOLS=()

# Services
PROFILE_claude_SSH_PORT=2228          # 0 = no SSH server
PROFILE_claude_SSH_KEY=""             # Path to public key (e.g. ~/.ssh/id_ed25519.pub)
PROFILE_claude_RUN_PRIVOXY=false      # true = start Privoxy

# Persistent home directories (each gets its own podman volume)
PROFILE_claude_VOLUMES=(
    .claude       # Claude credentials and settings
    .cache        # npm/pip cache
)

# Extra podman arguments
PROFILE_claude_PODMAN_ARGS=(
    --tmpfs /var/log:rw,size=50m,mode=1777
    --tmpfs /tmp:rw,size=200m,mode=1777
)

# ROOT level — runs as root on every startup
# Location: /etc/sandbox/startup.sh (rootconf volume)
# Generated on first run, then editable in the volume
PROFILE_claude_ROOT_STARTUP='
cfg="${CLAUDE_CONFIG_DIR}/.claude.json"
backupdir="${CLAUDE_CONFIG_DIR}/backups"
rootbackup="/etc/sandbox/claude-config-backup.json"

# Restore from backup if config is missing
if [ ! -f "$cfg" ]; then
    if [ -d "$backupdir" ]; then
        latest=$(ls -t "$backupdir"/.claude.json.backup.* 2>/dev/null | head -1)
        if [ -n "$latest" ]; then
            cp "$latest" "$cfg"
            chown "${U}:${U}" "$cfg" 2>/dev/null || true
            echo "▶ Config restored from Claude backup"
        fi
    fi
    if [ ! -f "$cfg" ] && [ -f "$rootbackup" ]; then
        cp "$rootbackup" "$cfg"
        chown "${U}:${U}" "$cfg" 2>/dev/null || true
        echo "▶ Config restored from rootconf backup"
    fi
fi

# Save a copy to rootconf as secondary backup
if [ -f "$cfg" ]; then
    cp "$cfg" "$rootbackup" 2>/dev/null || true
fi
'

# ROOT level — commands in /usr/local/bin/ (format: name|script)
# Location: /etc/sandbox/wrappers/ (rootconf volume)
PROFILE_claude_ROOT_WRAPPERS=(
    'claude|#!/bin/bash
CFGDIR="${CLAUDE_CONFIG_DIR:-${HOME}/.claude}"
CFG="${CFGDIR}/.claude.json"
BACKUPDIR="${CFGDIR}/backups"
if [ ! -f "$CFG" ] && [ -d "$BACKUPDIR" ]; then
    latest=$(ls -t "$BACKUPDIR"/.claude.json.backup.* 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
        cp "$latest" "$CFG"
        echo "▶ Config restored from backup"
    fi
fi
exec "${HOME}/.claude/bin/claude" "$@"'
)

# DEV level — user dotfiles (format: name|content)
# Location: ~/.local/etc/ (pip volume — persists)
# Generated on first run, then editable in the volume
PROFILE_claude_DEV_DOTFILES=(
    'bashrc.local|# Aliases
alias ll="ls -la"
alias la="ls -A"
alias ..="cd .."
alias ...="cd ../.."

# tmux with custom config
alias tmux="tmux -f ~/.local/etc/tmux.conf"
'
    'tmux.conf|# Minimal status bar
set -g status-style "bg=default,fg=colour8"
set -g status-left "#[fg=colour4]#S "
set -g status-right "#[fg=colour8]%H:%M"
set -g status-left-length 20
setw -g window-status-current-style "fg=colour2"
setw -g window-status-style "fg=colour8"
'
)


# ─── Research (experimentation) ───────────────────────────────────────

PROFILE_research_DESCRIPTION="Research sandbox — untrusted agents"

# Agents
PROFILE_research_AGENTS=(
    # Uncomment or add as needed
    # 'pip install --user aider-chat'
     'curl -fsSL https://antigravity.google/cli/install.sh | bash'
    # 'pip install --user open-interpreter'
)

# Extra packages
PROFILE_research_DNF=(
    chromium
)
PROFILE_research_TOOLS=()

# Services
PROFILE_research_SSH_PORT=2229
PROFILE_research_SSH_KEY=""
PROFILE_research_RUN_PRIVOXY=true
PROFILE_research_PRIVOXY_SOCKS="host.containers.internal:1080"

# Persistent home directories
PROFILE_research_VOLUMES=(
    .gemini       # Antigravity credentials
    .cache        # Shared cache
    .config       # XDG config
)

# Extra podman arguments
PROFILE_research_PODMAN_ARGS=(
    --shm-size 2g
    --tmpfs /var/log:rw,size=50m,mode=1777
    --tmpfs /tmp:rw,size=200m,mode=1777
)

# ROOT level (empty — add as needed)
PROFILE_research_ROOT_STARTUP=''
PROFILE_research_ROOT_WRAPPERS=()

# DEV level
PROFILE_research_DEV_DOTFILES=(
    'bashrc.local|# Aliases
alias ll="ls -la"
alias la="ls -A"
alias ..="cd .."
alias ...="cd ../.."

# tmux with custom config
alias tmux="tmux -f ~/.local/etc/tmux.conf"
'
    'tmux.conf|# Minimal status bar
set -g status-style "bg=default,fg=colour8"
set -g status-left "#[fg=colour4]#S "
set -g status-right "#[fg=colour8]%H:%M"
set -g status-left-length 20
setw -g window-status-current-style "fg=colour2"
setw -g window-status-style "fg=colour8"
'
)


# ─── Profile registry ─────────────────────────────────────────────────
# Add the name here when creating a new profile
ALL_PROFILES=(claude research)


# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Helper functions
# ═══════════════════════════════════════════════════════════════════════

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info()  { echo -e "${CYAN}▶${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# Podman global flags (custom storage path)
podman_global_flags() {
    local flags=()
    if [[ -n "$PODMAN_STORAGE" ]]; then
        flags+=(--root "$PODMAN_STORAGE" --storage-driver overlay)
    fi
    echo "${flags[@]}"
}

# Podman wrapper with global flags
pcmd() {
    local flags
    flags=($(podman_global_flags))
    podman "${flags[@]}" "$@"
}

# Read profile variable via indirect reference
get_profile_var() {
    local profile="$1" var="$2"
    local ref="PROFILE_${profile}_${var}"
    echo "${!ref:-}"
}

# Derive names from profile
profile_image()      { echo "${1}-sandbox-krun"; }
profile_home()       { echo "${SANDBOX_BASE}/${1}"; }
profile_vol_pip()    { echo "${1}-sandbox-pip"; }
profile_vol_root()   { echo "${1}-sandbox-rootconf"; }

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Prerequisites check
# ═══════════════════════════════════════════════════════════════════════

check_prereqs() {
    local missing=0

    if ! command -v podman &>/dev/null; then
        err "podman not installed: sudo dnf install podman"
        missing=1
    fi

    if [[ "$USE_KRUN" == "true" ]]; then
        if crun --version 2>/dev/null | grep -q '+LIBKRUN'; then
            ok "crun + libkrun"
        else
            err "crun-krun not installed: sudo dnf install crun-krun"
            missing=1
        fi

        local ver
        ver=$(rpm -q --qf '%{VERSION}' libkrun 2>/dev/null || echo "0.0")
        local major minor
        major=$(echo "$ver" | cut -d. -f1)
        minor=$(echo "$ver" | cut -d. -f2)
        if [[ "$major" -lt 1 ]] || { [[ "$major" -eq 1 ]] && [[ "$minor" -lt 8 ]]; }; then
            warn "libkrun $ver — recommended >= 1.8: sudo dnf update libkrun"
        fi
    fi

    if [[ $missing -ne 0 ]]; then
        err "Missing prerequisites."
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Scaffold (generate build files from config)
# ═══════════════════════════════════════════════════════════════════════

scaffold_base() {
    local base_home="${SANDBOX_BASE}/base"
    mkdir -p "$base_home"

    info "Generating base Dockerfile ..."

    local packages_joined
    packages_joined=$(printf '%s ' "${BASE_DNF_PACKAGES[@]}")

    local external_runs=""
    for tool in "${BASE_EXTERNAL_TOOLS[@]}"; do
        local clean
        clean=$(echo "$tool" | sed 's/#.*//g' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
        if [ -n "$clean" ]; then
            external_runs="${external_runs}RUN ${clean}
"
        fi
    done

    cat > "${base_home}/Dockerfile" << DEOF
FROM ${BASE_OS}

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN groupadd -g \${HOST_GID} dev 2>/dev/null || true && \\
    useradd -u \${HOST_UID} -g \${HOST_GID} -m -s /bin/bash dev 2>/dev/null || true

RUN dnf install -y \\
        ${packages_joined} \\
    && dnf clean all

${external_runs}
RUN echo 'dev ALL=(ALL) ALL' > /etc/sudoers.d/dev

RUN mkdir -p /var/run/sshd && \\
    sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config && \\
    sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config && \\
    echo 'AllowUsers dev' >> /etc/ssh/sshd_config

RUN echo 'mesg n 2>/dev/null || true' >> /home/dev/.bashrc
RUN echo '[ -f ~/.local/etc/bashrc.local ] && . ~/.local/etc/bashrc.local' >> /home/dev/.bashrc

USER dev
RUN mkdir -p /home/dev/.local/lib /home/dev/.local/bin
USER root

WORKDIR /app
DEOF

    ok "Base Dockerfile: ${base_home}/"
}

scaffold_profile() {
    local profile="$1"
    local phome
    phome=$(profile_home "$profile")
    mkdir -p "$phome"

    info "Generating profile '${profile}' ..."

    generate_profile_dockerfile "$profile"
    generate_entrypoint "$profile"

    ok "Profile '${profile}': ${phome}/"
}

generate_profile_dockerfile() {
    local profile="$1"
    local phome
    phome=$(profile_home "$profile")

    local ref="PROFILE_${profile}_DNF[@]"
    local extra_dnf=("${!ref}")
    local dnf_line=""
    if [[ ${#extra_dnf[@]} -gt 0 ]] && [[ -n "${extra_dnf[0]:-}" ]]; then
        local pkgs
        pkgs=$(printf '%s ' "${extra_dnf[@]}")
        dnf_line="RUN dnf install -y ${pkgs} && dnf clean all"
    fi

    local ref2="PROFILE_${profile}_TOOLS[@]"
    local extra_tools=("${!ref2}")
    local tools_runs=""
    for tool in "${extra_tools[@]}"; do
        local clean
        clean=$(echo "$tool" | sed 's/#.*//g' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
        if [ -n "$clean" ]; then
            tools_runs="${tools_runs}RUN ${clean}
"
        fi
    done

    local ref3="PROFILE_${profile}_AGENTS[@]"
    local agents=("${!ref3}")
    local agent_runs=""
    for agent in "${agents[@]}"; do
        local clean
        clean=$(echo "$agent" | sed 's/#.*//g' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
        if [ -n "$clean" ]; then
            agent_runs="${agent_runs}RUN ${clean}
"
        fi
    done

    cat > "${phome}/Dockerfile" << DEOF
FROM ${BASE_IMAGE_NAME}:latest

${dnf_line}

${tools_runs}
USER dev
${agent_runs}
USER root

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
DEOF
}

generate_entrypoint() {
    local profile="$1"
    local phome
    phome=$(profile_home "$profile")

    local startup_content
    startup_content=$(get_profile_var "$profile" ROOT_STARTUP)

    local wrappers_ref="PROFILE_${profile}_ROOT_WRAPPERS[@]"
    local wrappers=("${!wrappers_ref}")

    local wrapper_init_block=""
    for entry in "${wrappers[@]}"; do
        if [[ -n "$entry" ]]; then
            local wname="${entry%%|*}"
            local wbody="${entry#*|}"
            wrapper_init_block="${wrapper_init_block}
        if [ ! -f \"\${ROOTCONF}/wrappers/${wname}\" ]; then
            cat > \"\${ROOTCONF}/wrappers/${wname}\" << 'WRAPEOF'
${wbody}
WRAPEOF
            echo \"▶ Generated wrapper: ${wname}\"
        fi"
        fi
    done

    local dotfiles_ref="PROFILE_${profile}_DEV_DOTFILES[@]"
    local dotfiles=("${!dotfiles_ref}")

    local dotfiles_init_block=""
    for entry in "${dotfiles[@]}"; do
        if [[ -n "$entry" ]]; then
            local dname="${entry%%|*}"
            local dbody="${entry#*|}"
            dotfiles_init_block="${dotfiles_init_block}
        if [ ! -f \"\${H}/.local/etc/${dname}\" ]; then
            cat > \"\${H}/.local/etc/${dname}\" << 'DOTEOF'
${dbody}
DOTEOF
            chown \"\${U}:\${U}\" \"\${H}/.local/etc/${dname}\"
            echo \"▶ Generated dotfile: ${dname}\"
        fi"
        fi
    done

    cat > "${phome}/entrypoint.sh" << EEOF
#!/bin/bash
set -e

U="dev"
H="/home/\${U}"
ROOTCONF="/etc/sandbox"

export HOME="\${H}"
export PATH="\${H}/.local/bin:\${H}/.claude/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export TERM="\${TERM:-xterm-256color}"
export COLORTERM="\${COLORTERM:-truecolor}"
export CLAUDE_CONFIG_DIR="\${H}/.claude"
export PYTHONUSERBASE="\${H}/.local"
export LANG="en_US.UTF-8"

cleanup() { sync 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if [ "\$(id -un)" = "root" ]; then

    # ── 1. Random sudo password ──
    SUDO_PASS=\$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    echo "\${U}:\${SUDO_PASS}" | chpasswd 2>/dev/null

    # Store in non-obvious location (readable by dev for sudo use)
    echo "\${SUDO_PASS}" > /tmp/.s-token
    chmod 644 /tmp/.s-token

    echo ""
    echo "══════════════════════════════════════════"
    echo "  sudo: \${SUDO_PASS}"
    echo "  hint: cat /tmp/.s-token"
    echo "══════════════════════════════════════════"
    echo ""

    # ── 2. Fix volume ownership ──
    for d in "\${H}"/.*/; do
        dir_name=\$(basename "\$d")
        if [ "\$dir_name" = "." ] || [ "\$dir_name" = ".." ]; then
            continue
        fi
        if [ -d "\$d" ] && [ "\$(stat -c '%U' "\$d" 2>/dev/null)" != "\${U}" ]; then
            echo "▶ Fixing ownership: \$d → \${U}"
            chown "\${U}:\${U}" "\$d" 2>/dev/null || true
        fi
    done

    # ── 3. Root config defaults (first run) ──
    mkdir -p "\${ROOTCONF}/wrappers"

    if [ ! -f "\${ROOTCONF}/startup.sh" ]; then
        cat > "\${ROOTCONF}/startup.sh" << 'STARTUPEOF'
#!/bin/bash
# Root startup hook — runs on every container start
# Edit in rootconf volume for persistent changes
${startup_content}
STARTUPEOF
        chmod +x "\${ROOTCONF}/startup.sh"
        echo "▶ Generated startup.sh"
    fi

${wrapper_init_block}

    # ── 4. Run startup hook ──
    if [ -f "\${ROOTCONF}/startup.sh" ]; then
        source "\${ROOTCONF}/startup.sh"
    fi

    # Install wrappers into PATH
    if [ -d "\${ROOTCONF}/wrappers" ]; then
        for w in "\${ROOTCONF}/wrappers/"*; do
            if [ -f "\$w" ]; then
                cp "\$w" /usr/local/bin/
                chmod +x "/usr/local/bin/\$(basename "\$w")"
            fi
        done
    fi

    # ── 5. Dev dotfiles (from .local volume) ──
    mkdir -p "\${H}/.local/etc"
${dotfiles_init_block}

    # ── 6. SSH server ──
    if [ "\${SANDBOX_SSHD:-}" = "true" ]; then
        mkdir -p "\${ROOTCONF}/sshd"
        if [ ! -f "\${ROOTCONF}/sshd/ssh_host_ed25519_key" ]; then
            echo "▶ Generating SSH host keys ..."
            ssh-keygen -t ed25519 -f "\${ROOTCONF}/sshd/ssh_host_ed25519_key" -N "" -q
            ssh-keygen -t rsa -b 4096 -f "\${ROOTCONF}/sshd/ssh_host_rsa_key" -N "" -q
        fi
        cp "\${ROOTCONF}/sshd/ssh_host_"* /etc/ssh/ 2>/dev/null || true
        chmod 600 /etc/ssh/ssh_host_*_key
        chmod 644 /etc/ssh/ssh_host_*_key.pub

        # Install SSH public key for passwordless auth
        if [ -f "\${SANDBOX_SSH_KEY:-/dev/null}" ]; then
            mkdir -p "\${H}/.ssh"
            cp "\${SANDBOX_SSH_KEY}" "\${H}/.ssh/authorized_keys"
            chmod 700 "\${H}/.ssh"
            chmod 600 "\${H}/.ssh/authorized_keys"
            chown -R "\${U}:\${U}" "\${H}/.ssh"
            echo "▶ SSH key auth configured"
        fi

        /usr/sbin/sshd -e
        echo "▶ SSH server started"
    fi

    # ── 7. Privoxy (HTTP → SOCKS5 proxy) ──
    if [ "\${SANDBOX_PRIVOXY:-}" = "true" ]; then
        PRIVOXY_CONF="\${ROOTCONF}/privoxy"
        mkdir -p "\${PRIVOXY_CONF}"

        if [ ! -f "\${PRIVOXY_CONF}/config" ]; then
            cat > "\${PRIVOXY_CONF}/config" << 'PXYEOF'
# Privoxy config — generated on first run
# Edit in rootconf volume for persistent changes

listen-address  127.0.0.1:8118
toggle  1
enable-remote-toggle  0
enable-remote-http-toggle  0
enable-edit-actions  0

logdir /var/log/privoxy
logfile privoxy.log
debug  4096
PXYEOF
            echo "▶ Generated default Privoxy config"
        fi

        SOCKS_DEST="\${SANDBOX_PRIVOXY_SOCKS:-host.containers.internal:1080}"
        sed -i '/^forward-socks5t/d' "\${PRIVOXY_CONF}/config"
        echo "forward-socks5t / \${SOCKS_DEST} ." >> "\${PRIVOXY_CONF}/config"

        mkdir -p /var/log/privoxy
        chown privoxy:privoxy /var/log/privoxy 2>/dev/null || true
        privoxy --no-daemon "\${PRIVOXY_CONF}/config" &
        echo "▶ Privoxy started (:8118 → SOCKS5 \${SOCKS_DEST})"
    fi

    # ── 8. Firewall (nftables) ──
    if [ "\${SANDBOX_FIREWALL:-}" = "filtered" ]; then
        if command -v nft &>/dev/null; then
            nft add table inet filter 2>/dev/null || true
            nft flush table inet filter 2>/dev/null || true
            nft add chain inet filter output '{ type filter hook output priority 0; policy drop; }'
            nft add rule inet filter output oif lo accept

            IFS=',' read -ra _DESTS <<< "\${SANDBOX_ALLOW:-}"
            for _hostport in "\${_DESTS[@]}"; do
                if [ -z "\$_hostport" ]; then continue; fi
                _host="\${_hostport%:*}"
                _port="\${_hostport#*:}"
                nft add rule inet filter output ip daddr "\$_host" tcp dport "\$_port" accept
                echo "▶ Firewall: allowed → \$_host:\$_port"
            done

            if [ "\${SANDBOX_PRIVOXY:-}" = "true" ]; then
                SOCKS_DEST="\${SANDBOX_PRIVOXY_SOCKS:-host.containers.internal:1080}"
                _socks_host="\${SOCKS_DEST%:*}"
                _socks_port="\${SOCKS_DEST#*:}"
                if [ "\$_socks_host" != "localhost" ] && [ "\$_socks_host" != "127.0.0.1" ]; then
                    nft add rule inet filter output ip daddr "\$_socks_host" tcp dport "\$_socks_port" accept
                    echo "▶ Firewall: SOCKS5 allowed → \$_socks_host:\$_socks_port"
                fi
            fi

            echo "▶ Firewall: everything else blocked"
        else
            echo "⚠ nftables not available — firewall not configured"
        fi
    elif [ "\${SANDBOX_FIREWALL:-}" = "locked" ]; then
        if command -v nft &>/dev/null; then
            nft add table inet filter 2>/dev/null || true
            nft flush table inet filter 2>/dev/null || true
            nft add chain inet filter output '{ type filter hook output priority 0; policy drop; }'
            nft add rule inet filter output oif lo accept
            echo "▶ Firewall: locked — loopback only"
        else
            echo "⚠ nftables not available — firewall not configured"
        fi
    fi

    exec runuser -u "\${U}" -- env \\
        HOME="\${HOME}" \\
        PATH="\${PATH}" \\
        TERM="\${TERM}" \\
        COLORTERM="\${COLORTERM}" \\
        CLAUDE_CONFIG_DIR="\${CLAUDE_CONFIG_DIR}" \\
        PYTHONUSERBASE="\${PYTHONUSERBASE}" \\
        LANG="\${LANG}" \\
        HTTP_PROXY="\${HTTP_PROXY:-}" \\
        HTTPS_PROXY="\${HTTPS_PROXY:-}" \\
        http_proxy="\${http_proxy:-}" \\
        https_proxy="\${https_proxy:-}" \\
        NO_PROXY="\${NO_PROXY:-}" \\
        "\$@"
else
    if [ -f "\${ROOTCONF}/startup.sh" ]; then
        source "\${ROOTCONF}/startup.sh" 2>/dev/null || true
    fi
    exec "\$@"
fi
EEOF
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Build
# ═══════════════════════════════════════════════════════════════════════

build_base() {
    local force="${1:-}"

    if [[ "$force" != "-f" ]] && pcmd image exists "${BASE_IMAGE_NAME}" 2>/dev/null; then
        ok "Base image exists (use build -f to rebuild)"
        return 0
    fi

    scaffold_base

    info "Building base image ${BASE_IMAGE_NAME} ..."

    local extra_args=()
    if [[ "$force" == "-f" ]]; then
        extra_args+=(--no-cache)
    fi

    pcmd build \
        "${extra_args[@]}" \
        --build-arg "HOST_UID=$(id -u)" \
        --build-arg "HOST_GID=$(id -g)" \
        -t "${BASE_IMAGE_NAME}" \
        "${SANDBOX_BASE}/base"

    ok "Base image built."
}

build_profile() {
    local profile="$1"
    shift
    local image_name
    image_name=$(profile_image "$profile")
    local phome
    phome=$(profile_home "$profile")

    if ! pcmd image exists "${BASE_IMAGE_NAME}" 2>/dev/null; then
        warn "Base image missing. Building ..."
        build_base "${1:-}"
    fi

    scaffold_profile "$profile"

    info "Building profile '${profile}' → ${image_name} ..."

    local extra_args=()
    if [[ "${1:-}" == "-f" ]]; then
        extra_args+=(--no-cache)
    fi

    pcmd build \
        "${extra_args[@]}" \
        -t "${image_name}" \
        "${phome}"

    ok "Image ${image_name} built."
}

do_build() {
    local profile="$1"
    shift
    local force="${1:-}"

    build_base "$force"
    build_profile "$profile" "$force"
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Run
# ═══════════════════════════════════════════════════════════════════════

do_run() {
    local profile="$1"
    shift

    local image_name
    image_name=$(profile_image "$profile")
    local vol_pip
    vol_pip=$(profile_vol_pip "$profile")
    local vol_root
    vol_root=$(profile_vol_root "$profile")
    local desc
    desc=$(get_profile_var "$profile" DESCRIPTION)
    local ssh_port
    ssh_port=$(get_profile_var "$profile" SSH_PORT)
    ssh_port="${ssh_port:-0}"
    if [[ -n "$SSH_PORT_OVERRIDE" ]]; then
        ssh_port="$SSH_PORT_OVERRIDE"
    fi

    if ! pcmd image exists "${image_name}" 2>/dev/null; then
        warn "Image not found. Building ..."
        do_build "$profile"
    fi

    local project_dir
    project_dir="$(pwd)"

    local dir_name
    dir_name="$(basename "$project_dir" | tr -cs 'A-Za-z0-9-' '-')"
    local path_hash
    path_hash="$(echo -n "$project_dir" | md5sum | cut -c1-6)"
    local mount_name="${dir_name}-${path_hash}"
    local container_name="${profile}-${mount_name}"
    local mount_point="/app/${mount_name}"

    # Extra volumes from profile config
    local ref="PROFILE_${profile}_VOLUMES[@]"
    local extra_vols=("${!ref}")
    local vol_flags=()
    for vdir in "${extra_vols[@]}"; do
        if [[ -n "$vdir" ]]; then
            local vname="${profile}-sandbox-${vdir#.}"
            vol_flags+=(-v "${vname}:/home/dev/${vdir}")
        fi
    done

    # Runtime mode and resource limits
    local krun_flags=()
    local runtime_label
    local effective_ram="${RAM_OVERRIDE:-${RAM_MIB}}"
    local effective_cpus="${CPUS_OVERRIDE:-${CPUS}}"

    if [[ "$USE_KRUN" == "true" ]]; then
        krun_flags+=(--annotation "run.oci.handler=krun")
        krun_flags+=(--annotation "krun.ram_mib=${effective_ram}")
        krun_flags+=(--annotation "krun.cpus=${effective_cpus}")
        krun_flags+=(--annotation "krun.use_passt=1")
        runtime_label="krun microVM"
    else
        krun_flags+=(--memory "${effective_ram}m")
        krun_flags+=(--cpus "${effective_cpus}")
        runtime_label="container"
    fi

    # Network and environment flags
    local net_flags=()
    local net_label="open"
    local env_flags=()
    env_flags+=(-e "TERM=xterm-256color")
    env_flags+=(-e "COLORTERM=truecolor")

    # SSH server
    local ssh_flags=()
    local ssh_label="off"
    if [[ "$ssh_port" != "0" ]] && [[ -n "$ssh_port" ]]; then
        ssh_flags+=(-p "${ssh_port}:22")
        env_flags+=(-e "SANDBOX_SSHD=true")
        ssh_label="port ${ssh_port}"

        # SSH key auth
        local ssh_key
        ssh_key=$(get_profile_var "$profile" SSH_KEY)
        if [[ -n "$SSH_KEY_OVERRIDE" ]]; then
            ssh_key="$SSH_KEY_OVERRIDE"
        fi
        # Expand ~ in path
        ssh_key="${ssh_key/#\~/$HOME}"
        if [[ -n "$ssh_key" ]] && [[ -f "$ssh_key" ]]; then
            ssh_flags+=(-v "${ssh_key}:/tmp/.ssh-pub-key:ro")
            env_flags+=(-e "SANDBOX_SSH_KEY=/tmp/.ssh-pub-key")
            ssh_label="${ssh_label}, key auth"
        elif [[ -n "$ssh_key" ]]; then
            warn "SSH key not found: ${ssh_key}"
        fi
    fi

    # Privoxy
    local privoxy_enabled
    privoxy_enabled=$(get_profile_var "$profile" RUN_PRIVOXY)
    if [[ -n "$PRIVOXY_OVERRIDE" ]]; then
        privoxy_enabled="$PRIVOXY_OVERRIDE"
    fi
    local privoxy_label="off"
    if [[ "$privoxy_enabled" == "true" ]]; then
        local forward_socks
        forward_socks=$(get_profile_var "$profile" PRIVOXY_SOCKS)
        forward_socks="${forward_socks:-host.containers.internal:1080}"
        if [[ -n "$PRIVOXY_SOCKS_OVERRIDE" ]]; then
            forward_socks="$PRIVOXY_SOCKS_OVERRIDE"
        fi
        env_flags+=(-e "SANDBOX_PRIVOXY=true")
        env_flags+=(-e "SANDBOX_PRIVOXY_SOCKS=${forward_socks}")
        env_flags+=(-e "HTTP_PROXY=http://127.0.0.1:8118")
        env_flags+=(-e "HTTPS_PROXY=http://127.0.0.1:8118")
        env_flags+=(-e "http_proxy=http://127.0.0.1:8118")
        env_flags+=(-e "https_proxy=http://127.0.0.1:8118")
        env_flags+=(-e "NO_PROXY=localhost,127.0.0.1")
        privoxy_label=":8118 → SOCKS5 ${forward_socks}"
    fi

    # Network mode
    local effective_net="${NET_MODE:-open}"
    local cap_flags=()
    if [[ "$effective_net" == "filtered" ]]; then
        local allow_joined
        allow_joined=$(IFS=','; echo "${ALLOW_DESTINATIONS[*]}")
        env_flags+=(-e "SANDBOX_FIREWALL=filtered")
        env_flags+=(-e "SANDBOX_ALLOW=${allow_joined}")
        cap_flags+=(--cap-add NET_ADMIN)
        net_label="filtered (${allow_joined})"
    elif [[ "$effective_net" == "locked" ]]; then
        env_flags+=(-e "SANDBOX_FIREWALL=locked")
        cap_flags+=(--cap-add NET_ADMIN)
        net_label="locked"
    fi

    info "Starting ${runtime_label} ..."
    info "  Profile:  ${profile} — ${desc}"
    info "  Project:  ${project_dir} → ${mount_point}"
    info "  RAM/CPU:  ${effective_ram} MiB / ${effective_cpus} cores"
    info "  Image:    ${image_name}"
    info "  Network:  ${net_label}"
    info "  SSH:      ${ssh_label}"
    info "  Privoxy:  ${privoxy_label}"
    if [[ -n "$PODMAN_STORAGE" ]]; then
        info "  Storage:  ${PODMAN_STORAGE}"
    fi
    echo ""
    echo -e "  ${GREEN}Persisted on exit:${NC}"
    echo -e "    ✓ Project files in ${project_dir}"
    echo -e "    ✓ pip packages (${vol_pip})"
    echo -e "    ✓ Root config — SSH keys, rules (${vol_root})"
    for vdir in "${extra_vols[@]}"; do
        if [[ -n "$vdir" ]]; then
            echo -e "    ✓ ~/${vdir} (${profile}-sandbox-${vdir#.})"
        fi
    done
    echo -e "    ✗ dnf packages → edit profile and rebuild"
    echo ""

    # Check if session is already active on this directory
    if pcmd ps --format "{{.Names}}" 2>/dev/null | grep -q "^${container_name}$"; then
        if [[ "$FORCE_RUN" == "true" ]]; then
            warn "Killing active session: ${container_name}"
            pcmd rm -f "${container_name}" 2>/dev/null || true
        else
            err "Session already active: ${container_name}"
            err "Use --force to kill and restart, or dev-sandbox ls to see all sessions"
            exit 1
        fi
    else
        # Clean up stopped container with same name (if any)
        pcmd rm -f "${container_name}" 2>/dev/null || true
    fi

    # Check for port conflicts
    if [[ "$ssh_port" != "0" ]] && [[ -n "$ssh_port" ]]; then
        if ss -tlnp 2>/dev/null | grep -q ":${ssh_port} "; then
            err "Port ${ssh_port} already in use"
            err "Another sandbox running? Check: dev-sandbox ls"
            exit 1
        fi
    fi

    local extra_args_ref="PROFILE_${profile}_PODMAN_ARGS[@]"
    local profile_args=("${!extra_args_ref}")

    pcmd run --rm -it \
        --name "${container_name}" \
        --hostname "${profile}-sandbox" \
        "${krun_flags[@]}" \
        "${net_flags[@]}" \
        "${ssh_flags[@]}" \
        "${cap_flags[@]}" \
        "${profile_args[@]}" \
        --security-opt label=disable \
        --userns keep-id \
        -v "${project_dir}:${mount_point}" \
        -v "${vol_pip}:/home/dev/.local" \
        -v "${vol_root}:/etc/sandbox" \
        "${vol_flags[@]}" \
        -w "${mount_point}" \
        "${env_flags[@]}" \
        "${image_name}" \
        "$@"

    echo ""
    ok "Shell closed. Changes in ${project_dir} saved."
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — List running sandboxes
# ═══════════════════════════════════════════════════════════════════════

do_list() {
    echo ""
    info "Running sandboxes:"
    echo ""

    local found=false
    for p in "${ALL_PROFILES[@]}"; do
        local containers
        containers=$(pcmd ps --filter "name=${p}-" --format "{{.Names}}|{{.Status}}|{{.Ports}}" 2>/dev/null)
        if [[ -n "$containers" ]]; then
            found=true
            while IFS='|' read -r name status ports; do
                local ssh_info=""
                if [[ -n "$ports" ]]; then
                    ssh_info=$(echo "$ports" | grep -oP '\d+->22' | head -1)
                    if [[ -n "$ssh_info" ]]; then
                        ssh_info=" ssh:${ssh_info}"
                    fi
                fi
                echo -e "  ${CYAN}${name}${NC}  ${status}${ssh_info}"
            done <<< "$containers"
        fi
    done

    if [[ "$found" != "true" ]]; then
        echo "  No running sandboxes"
    fi
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Clean
# ═══════════════════════════════════════════════════════════════════════

do_clean() {
    local profile="$1"
    local purge="${2:-}"
    local image_name
    image_name=$(profile_image "$profile")
    local phome
    phome=$(profile_home "$profile")
    local vol_pip
    vol_pip=$(profile_vol_pip "$profile")
    local vol_root
    vol_root=$(profile_vol_root "$profile")

    info "Cleaning profile '${profile}' ..."
    pcmd rmi "${image_name}" 2>/dev/null && ok "Image ${image_name} removed" || true

    if [[ -d "${phome}" ]]; then
        rm -rf "${phome}"
        ok "Removed: ${phome}/"
    fi

    if [[ "$purge" == "--purge" ]]; then
        info "Purging volumes ..."
        # Core volumes
        for v in "${vol_pip}" "${vol_root}"; do
            pcmd volume rm "$v" 2>/dev/null && ok "Volume $v removed" || true
        done
        # Extra profile volumes
        local ref="PROFILE_${profile}_VOLUMES[@]"
        local extra_vols=("${!ref}")
        for vdir in "${extra_vols[@]}"; do
            if [[ -n "$vdir" ]]; then
                local vname="${profile}-sandbox-${vdir#.}"
                pcmd volume rm "$vname" 2>/dev/null && ok "Volume $vname removed" || true
            fi
        done
        ok "Profile '${profile}' fully purged."
    else
        echo ""
        warn "Volumes not removed (contain data):"
        warn "  podman volume rm ${vol_pip} ${vol_root}"
        local ref="PROFILE_${profile}_VOLUMES[@]"
        local extra_vols=("${!ref}")
        for vdir in "${extra_vols[@]}"; do
            if [[ -n "$vdir" ]]; then
                warn "  podman volume rm ${profile}-sandbox-${vdir#.}"
            fi
        done
        warn "Use: dev-sandbox -p ${profile} clean --purge"
    fi
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Profiles list
# ═══════════════════════════════════════════════════════════════════════

do_profiles() {
    echo ""
    info "Profiles:"
    echo ""
    for p in "${ALL_PROFILES[@]}"; do
        local desc
        desc=$(get_profile_var "$p" DESCRIPTION)
        local image_name
        image_name=$(profile_image "$p")
        local marker=""
        if [[ "$p" == "$DEFAULT_PROFILE" ]]; then
            marker=" ${GREEN}(default)${NC}"
        fi

        local img_status="${RED}not built${NC}"
        if pcmd image exists "${image_name}" 2>/dev/null; then
            local size
            size=$(pcmd images "${image_name}" --format "{{.Size}}" 2>/dev/null)
            img_status="${GREEN}${size}${NC}"
        fi

        echo -e "  ${CYAN}${p}${NC}${marker}"
        echo -e "    ${desc}"
        echo -e "    Image: ${img_status}"

        local ref="PROFILE_${p}_AGENTS[@]"
        local agents=("${!ref}")
        if [[ ${#agents[@]} -gt 0 ]] && [[ -n "${agents[0]:-}" ]]; then
            echo "    Agents: ${#agents[@]}"
        fi
        echo ""
    done
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Status
# ═══════════════════════════════════════════════════════════════════════

do_status() {
    local profile="$1"
    local image_name
    image_name=$(profile_image "$profile")
    local phome
    phome=$(profile_home "$profile")
    local vol_pip
    vol_pip=$(profile_vol_pip "$profile")
    local vol_root
    vol_root=$(profile_vol_root "$profile")
    local desc
    desc=$(get_profile_var "$profile" DESCRIPTION)

    echo ""
    info "=== Profile: ${profile} ==="
    echo "  ${desc}"

    echo ""
    echo "Configuration:"
    echo "  Sandbox base:  ${SANDBOX_BASE}"
    echo "  Profile home:  ${phome}"
    echo "  Base OS:       ${BASE_OS}"
    echo "  RAM:           ${RAM_MIB} MiB"
    echo "  CPU:           ${CPUS}"
    echo "  Vol pip:       ${vol_pip}"
    echo "  Vol rootconf:  ${vol_root}"

    echo ""
    echo "Images:"
    echo -n "  Base:    "
    pcmd images "${BASE_IMAGE_NAME}" --format "{{.Repository}}:{{.Tag}}  {{.Size}}" 2>/dev/null || echo "not built"
    echo -n "  Profile: "
    pcmd images "${image_name}" --format "{{.Repository}}:{{.Tag}}  {{.Size}}" 2>/dev/null || echo "not built"

    echo ""
    echo "Volumes:"
    for v in "${vol_pip}" "${vol_root}"; do
        if pcmd volume exists "$v" 2>/dev/null; then
            echo "  ✓ $v"
        else
            echo "  ✗ $v (missing)"
        fi
    done
    local ref="PROFILE_${profile}_VOLUMES[@]"
    local extra_vols=("${!ref}")
    for vdir in "${extra_vols[@]}"; do
        if [[ -n "$vdir" ]]; then
            local vname="${profile}-sandbox-${vdir#.}"
            if pcmd volume exists "$vname" 2>/dev/null; then
                echo "  ✓ $vname (~/${vdir})"
            else
                echo "  ✗ $vname (missing)"
            fi
        fi
    done

    echo ""
    echo "Build files:"
    if [[ -d "${phome}" ]]; then
        echo "  ✓ ${phome}/"
        ls -1 "${phome}/" | sed 's/^/    /'
    else
        echo "  ✗ ${phome}/ (missing)"
    fi

    echo ""
    echo "System:"
    echo "  libkrun: $(rpm -q libkrun 2>/dev/null || echo 'not installed')"
    echo "  crun:    $(crun --version 2>/dev/null | head -1 || echo 'not installed')"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Help
# ═══════════════════════════════════════════════════════════════════════

usage() {
    cat << EOF

${CYAN}dev-sandbox${NC} — Sandboxed AI Coding Agents

${GREEN}Usage:${NC}
  dev-sandbox                           Default profile (${DEFAULT_PROFILE})
  dev-sandbox -p <profile>              Select profile
  dev-sandbox -p <profile> build        Build profile image
  dev-sandbox -p <profile> build -f     Rebuild without cache
  dev-sandbox profiles                  List profiles
  dev-sandbox ls                        List running sandboxes
  dev-sandbox status                    Status of default profile
  dev-sandbox -p <profile> status       Status of specific profile
  dev-sandbox -p <profile> clean        Remove profile image
  dev-sandbox -p <profile> clean --purge  Remove image AND all volumes
  dev-sandbox help                      This help

${GREEN}Network:${NC}
  (no flag)                             Full internet (default)
  --net open                            Full internet (override profile)
  --net locked                          Locked — no outbound traffic
  --allow host:port                     Allow only this destination (repeatable)
                                        Automatically locks everything else

${GREEN}Services:${NC}
  --no-krun                             Standard container (no microVM)
  --krun                                Force microVM (override profile)
  --ram MiB                             Memory limit (default: ${RAM_MIB})
  --cpus N                              CPU cores limit (default: ${CPUS})
  --force                               Kill active session and restart
  --ssh-port PORT                       SSH server port (0 = disabled)
  --ssh-key ~/.ssh/id_ed25519.pub      SSH public key for passwordless auth
  --run-privoxy                         Enable Privoxy HTTP proxy
  --no-privoxy                          Disable Privoxy (override profile)
  --privoxy-socks host:port             Where Privoxy forwards traffic

${GREEN}Examples:${NC}
  dev-sandbox                           Claude, full internet
  dev-sandbox --allow host:1080         Claude, outbound only to SOCKS proxy
  dev-sandbox -p research --net locked  Research, complete isolation
  dev-sandbox -p research \\
    --allow host:1080 --allow host:22 \\
    --run-privoxy --privoxy-socks host:1080
                                        Research, full proxy chain

${GREEN}Profiles:${NC}
EOF
    for p in "${ALL_PROFILES[@]}"; do
        local desc
        desc=$(get_profile_var "$p" DESCRIPTION)
        local marker=""
        if [[ "$p" == "$DEFAULT_PROFILE" ]]; then marker=" (default)"; fi
        echo "  ${p}${marker} — ${desc}"
    done

    cat << EOF

${GREEN}Configuration:${NC}
  Sandbox base:     ${SANDBOX_BASE}
  Base OS:          ${BASE_OS}
  RAM:              ${RAM_MIB} MiB  (DEV_SANDBOX_RAM)
  CPU:              ${CPUS}        (DEV_SANDBOX_CPUS)
  Storage:          ${PODMAN_STORAGE:-default podman storage}  (DEV_SANDBOX_STORAGE)
  Base packages:    ${#BASE_DNF_PACKAGES[@]}

${GREEN}Architecture:${NC}
  Base image (shared)  ←  DNF packages, external tools, user setup
       ↓
  Profile image        ←  agents, extra packages, entrypoint
       ↓
  krun microVM         ←  own kernel, passt networking (default)
  or container         ←  shared host kernel (--no-krun)

${GREEN}Customization:${NC}
  Base packages:    edit BASE_DNF_PACKAGES[] / BASE_EXTERNAL_TOOLS[]
  New profile:      add PROFILE_<name>_* block and name to ALL_PROFILES
  After changes:    dev-sandbox -p <profile> build -f

${YELLOW}Requirements:${NC}
  sudo dnf install podman crun-krun
  gocryptfs -allow_other (for encrypted directories)

EOF
}

# ═══════════════════════════════════════════════════════════════════════
#  MAIN — Argument parsing
# ═══════════════════════════════════════════════════════════════════════

PROFILE="${DEFAULT_PROFILE}"
USE_KRUN=true
NET_MODE=""                # open, locked, filtered (empty = profile default → open)
ALLOW_DESTINATIONS=()      # --allow host:port (repeatable)
PRIVOXY_SOCKS_OVERRIDE=""  # --privoxy-socks host:port
SSH_PORT_OVERRIDE=""        # --ssh-port PORT
SSH_KEY_OVERRIDE=""         # --ssh-key /path/to/key.pub
PRIVOXY_OVERRIDE=""         # --run-privoxy / --no-privoxy
RAM_OVERRIDE=""             # --ram MiB
CPUS_OVERRIDE=""            # --cpus N
FORCE_RUN=false             # --force

while [[ "${1:-}" == -* ]]; do
    case "${1:-}" in
        --no-krun)
            USE_KRUN=false
            shift
            ;;
        --krun)
            USE_KRUN=true
            shift
            ;;
        --net)
            if [[ -z "${2:-}" ]]; then
                err "Missing mode. Usage: --net open|locked"
                exit 1
            fi
            case "$2" in
                open|locked) NET_MODE="$2" ;;
                *) err "Unknown mode: $2 (use: open, locked)"; exit 1 ;;
            esac
            shift 2
            ;;
        --allow)
            if [[ -z "${2:-}" ]]; then
                err "Missing address. Usage: --allow host:port"
                exit 1
            fi
            ALLOW_DESTINATIONS+=("$2")
            shift 2
            ;;
        --privoxy-socks)
            if [[ -z "${2:-}" ]]; then
                err "Missing address. Usage: --privoxy-socks host:port"
                exit 1
            fi
            PRIVOXY_SOCKS_OVERRIDE="$2"
            shift 2
            ;;
        --ssh-port)
            if [[ -z "${2:-}" ]]; then
                err "Missing port. Usage: --ssh-port PORT"
                exit 1
            fi
            SSH_PORT_OVERRIDE="$2"
            shift 2
            ;;
        --ssh-key)
            if [[ -z "${2:-}" ]]; then
                err "Missing path. Usage: --ssh-key ~/.ssh/id_ed25519.pub"
                exit 1
            fi
            SSH_KEY_OVERRIDE="$2"
            shift 2
            ;;
        --run-privoxy)
            PRIVOXY_OVERRIDE="true"
            shift
            ;;
        --no-privoxy)
            PRIVOXY_OVERRIDE="false"
            shift
            ;;
        --ram)
            if [[ -z "${2:-}" ]]; then
                err "Missing value. Usage: --ram 8192"
                exit 1
            fi
            RAM_OVERRIDE="$2"
            shift 2
            ;;
        --cpus)
            if [[ -z "${2:-}" ]]; then
                err "Missing value. Usage: --cpus 8"
                exit 1
            fi
            CPUS_OVERRIDE="$2"
            shift 2
            ;;
        --force)
            FORCE_RUN=true
            shift
            ;;
        -p)
            if [[ -z "${2:-}" ]]; then
                err "Missing profile name. Usage: dev-sandbox -p <profile>"
                err "Available: ${ALL_PROFILES[*]}"
                exit 1
            fi
            PROFILE="$2"
            shift 2

            local_valid=false
            for p in "${ALL_PROFILES[@]}"; do
                if [[ "$p" == "$PROFILE" ]]; then
                    local_valid=true
                    break
                fi
            done
            if [[ "$local_valid" != "true" ]]; then
                err "Unknown profile: ${PROFILE}"
                err "Available: ${ALL_PROFILES[*]}"
                exit 1
            fi
            ;;
        *)
            break
            ;;
    esac
done

# --allow implicitly sets filtered mode
if [[ ${#ALLOW_DESTINATIONS[@]} -gt 0 ]] && [[ -z "$NET_MODE" ]]; then
    NET_MODE="filtered"
fi

# Conflict detection
if [[ "$NET_MODE" == "locked" ]] && [[ ${#ALLOW_DESTINATIONS[@]} -gt 0 ]]; then
    err "--net locked and --allow are mutually exclusive"
    err "Use --net locked (no exceptions) or --allow (with exceptions)"
    exit 1
fi

case "${1:-}" in
    build)
        shift
        check_prereqs
        do_build "$PROFILE" "${1:-}"
        ;;
    clean)      shift; do_clean "$PROFILE" "${1:-}" ;;
    status)     do_status "$PROFILE" ;;
    ls|list)    do_list ;;
    profiles)   do_profiles ;;
    help|--help|-h) usage ;;
    *)          check_prereqs; do_run "$PROFILE" "$@" ;;
esac
