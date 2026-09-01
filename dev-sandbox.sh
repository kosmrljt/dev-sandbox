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
#    - local volume:     ~/.local (pip packages, scripts, dotfiles, history)
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
#    - Use for: running untrusted code
#
#  KEY PODMAN PARAMETERS USED
#  --------------------------
#  --annotation run.oci.handler=krun   Use krun microVM runtime
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

# Do not run as root — rootless podman requires a regular user
if [[ $(id -u) -eq 0 ]]; then
    echo "✗ Do not run dev-sandbox as root. Use a regular user." >&2
    exit 1
fi

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
VERSION="1.1.0"                         # dev-sandbox version

# Base OS
BASE_OS="fedora:44"

# Podman storage (empty = default ~/.local/share/containers/storage)
# Set for a different disk: PODMAN_STORAGE="/mnt/disk2/podman"
PODMAN_STORAGE="${DEV_SANDBOX_STORAGE:-}"

# ── Base image DNF packages (shared across all profiles) ──
BASE_DNF_PACKAGES=(
    # Core system
    util-linux sudo hostname procps-ng
    findutils which diffutils less man-db

    # Networking
    openssh-server openssh-clients
    curl wget nmap iputils iproute
    bind-utils                          # dig, nslookup, host
    net-tools                           # netstat, ifconfig
    nftables privoxy
    ca-certificates openssl             # TLS/HTTPS support

    # File tools
    git tar zip unzip xz gzip rsync
    vim nano tree mc fzf
    bat                                 # cat with syntax highlighting
    fd-find                             # better find
    ripgrep jq

    # Terminal
    tmux htop

    # Development
    nodejs npm
    python3 python3-pip python3-devel
    gcc gcc-c++ make cmake
    ShellCheck                          # bash script linting

    # Debugging
    strace ltrace

    # Database clients
    sqlite mycli pgcli
    mariadb postgresql

    # Shell
    fish

    # Cloud/sync
    rclone
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
#  PROFILE DEFAULTS
#
#  Default values for all profiles. Each profile only needs to
#  override what differs. Less repetition, easier to add new profiles.
# ═══════════════════════════════════════════════════════════════════════

DEFAULT_USE_KRUN=true                   # krun microVM (false = standard container)
DEFAULT_NET_MODE="open"                 # open, locked, filtered
DEFAULT_SSH_PORT=0                      # 0 = no SSH server
DEFAULT_SSH_KEY=""                      # Path to public key
DEFAULT_RUN_PRIVOXY=false               # Privoxy HTTP proxy
DEFAULT_PRIVOXY_SOCKS="host.containers.internal:1080"
DEFAULT_RAM="${DEV_SANDBOX_RAM:-4096}"   # Override with: DEV_SANDBOX_RAM=8192 dev-sandbox
DEFAULT_CPUS="${DEV_SANDBOX_CPUS:-}"    # Empty = no limit. Override with: DEV_SANDBOX_CPUS=8 dev-sandbox
DEFAULT_COLOR="0"                       # Prompt color (0=default, 32=green, 31=red, 33=yellow, 34=blue)
DEFAULT_ENV=()                          # Extra env vars set in container (KEY=VALUE)
DEFAULT_ENV_PASS=()                     # Env vars passed through from host (KEY only, no values in script)
DEFAULT_VOLUMES=(.cache)
DEFAULT_PODMAN_ARGS=(
    --tmpfs /var/log:rw,size=50m,mode=1777
    --tmpfs /tmp:rw,size=200m,mode=1777
)
DEFAULT_ROOT_STARTUP=''
DEFAULT_ROOT_WRAPPERS=()
DEFAULT_DEV_DOTFILES=(
    'bashrc.local|# Override PATH — Fedora /etc/profile prepends ~/.local/bin on login
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin:$HOME/.claude/bin"

# Persistent history (stored in local volume)
export HISTFILE="$HOME/.local/etc/.bash_history"
export HISTSIZE=10000
export HISTFILESIZE=20000

# Aliases
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


# ═══════════════════════════════════════════════════════════════════════
#  PROFILES
#
#  Each profile only defines what differs from defaults above.
#  New profile: add overrides and the name to ALL_PROFILES.
#
#  All DEFAULT_* variables can be overridden per profile with
#  PROFILE_<name>_<variable>. CLI flags override both.
# ═══════════════════════════════════════════════════════════════════════


# ─── Claude (default) ─────────────────────────────────────────────────

PROFILE_claude_DESCRIPTION="Claude Code — production agent"
PROFILE_claude_COLOR="32"               # Green prompt — trusted agent
#PROFILE_claude_SSH_PORT=2228
PROFILE_claude_AGENTS=(
    'curl -fsSL https://claude.ai/install.sh | bash'
)
PROFILE_claude_VOLUMES=(
    .claude       # Claude credentials and settings
    .cache        # npm/pip cache
)

# Claude-specific startup: restore config from backup
PROFILE_claude_ROOT_STARTUP='
cfg="${CLAUDE_CONFIG_DIR}/.claude.json"
backupdir="${CLAUDE_CONFIG_DIR}/backups"
rootbackup="/etc/sandbox/claude-config-backup.json"

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
if [ -f "$cfg" ]; then
    cp "$cfg" "$rootbackup" 2>/dev/null || true
fi
'

# Claude wrapper — checks config before starting
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
# Check both possible install locations
if [ -x "${HOME}/.local/bin/claude" ]; then
    exec "${HOME}/.local/bin/claude" "$@"
elif [ -x "${HOME}/.claude/bin/claude" ]; then
    exec "${HOME}/.claude/bin/claude" "$@"
else
    echo "✗ Claude not found. Run: curl -fsSL https://claude.ai/install.sh | bash"
    exit 1
fi'
)



# ─── Agy (Antigravity only) ───────────────────────────────────────────

PROFILE_agy_DESCRIPTION="Antigravity sandbox — Google AI agent"
PROFILE_agy_COLOR="33"                  # Yellow prompt
PROFILE_agy_SSH_PORT=2230
PROFILE_agy_AGENTS=(
    'curl -fsSL https://antigravity.google/cli/install.sh | bash'
)
PROFILE_agy_VOLUMES=(
    .gemini       # Antigravity credentials
    .cache
    .config       # XDG config
)


# ─── Research (experimentation) ───────────────────────────────────────

PROFILE_research_DESCRIPTION="Research sandbox — untrusted agents"
PROFILE_research_COLOR="31"             # Red prompt — untrusted
PROFILE_research_USE_KRUN=true          # VM isolation (SSH off → passt → firewall works)
PROFILE_research_SSH_PORT=0             # No SSH (enables passt for firewall)
PROFILE_research_RUN_PRIVOXY=true
PROFILE_research_AGENTS=(
    # Uncomment or add as needed
    # 'pip install --user aider-chat'
    # 'curl -fsSL https://antigravity.google/cli/install.sh | bash'
    # 'pip install --user open-interpreter'
)
PROFILE_research_DNF=(
)
PROFILE_research_VOLUMES=(
    .cache        # Shared cache
    .config       # XDG config
)
PROFILE_research_PODMAN_ARGS=(
    --shm-size 2g
    --tmpfs /var/log:rw,size=50m,mode=1777
    --tmpfs /tmp:rw,size=200m,mode=1777
)


# ─── VNC GUI (graphical applications) ─────────────────────────────────

PROFILE_vncgui_DESCRIPTION="GUI sandbox — VNC + XFCE for graphical apps"
PROFILE_vncgui_COLOR="35"               # Purple prompt
PROFILE_vncgui_USE_KRUN=false           # Standard container (device access)
PROFILE_vncgui_SSH_PORT=2231
PROFILE_vncgui_DNF=(
    tigervnc-server
    xfdesktop xfconf xfce4-settings
    xfce4-session xfce4-panel xfwm4 xfce4-terminal thunar mousepad
    dejavu-sans-fonts dejavu-serif-fonts
    dbus-x11 xorg-x11-xinit
    java-latest-openjdk
    firefox
)
PROFILE_vncgui_VOLUMES=(
    .cache
    .config       # XFCE settings persist
    .vnc          # VNC password and config
)
PROFILE_vncgui_PODMAN_ARGS=(
    --shm-size 2g
    -p 5901:5901
    --tmpfs /var/log:rw,size=50m,mode=1777
    --tmpfs /tmp:rw,size=200m,mode=1777
)
PROFILE_vncgui_AGENTS=()
PROFILE_vncgui_ENV=(
    "DISPLAY=:1"
)
PROFILE_vncgui_ROOT_STARTUP='
# Set VNC password on first run
if [ ! -f "/home/${U}/.vnc/passwd" ]; then
    mkdir -p "/home/${U}/.vnc"
    echo "${SANDBOX_VNC_PASS:-sandbox}" | vncpasswd -f > "/home/${U}/.vnc/passwd"
    chmod 600 "/home/${U}/.vnc/passwd"
    echo "▶ VNC password set (default: sandbox)"
fi

# Create xstartup for XFCE (without systemd)
if [ ! -f "/home/${U}/.vnc/xstartup" ]; then
    {
        echo "#!/bin/bash"
        echo "unset SESSION_MANAGER"
        echo "unset DBUS_SESSION_BUS_ADDRESS"
        echo "export XDG_SESSION_TYPE=x11"
        echo "eval \$(dbus-launch --sh-syntax)"
        echo "xfwm4 &"
        echo "xfdesktop &"
        echo "xfce4-panel &"
        echo "thunar --daemon &"
        echo "wait"
    } > "/home/${U}/.vnc/xstartup"
    chmod +x "/home/${U}/.vnc/xstartup"
fi

chown -R "${U}:${U}" "/home/${U}/.vnc"

# Start VNC server
su - "${U}" -c "vncserver :1 -geometry 1920x1080 -depth 24 -localhost no" 2>/dev/null || true
echo "▶ VNC server started on :5901"
'


# ─── Profile registry ─────────────────────────────────────────────────
ALL_PROFILES=(claude agy research vncgui)


# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Helper functions
#  Color output, profile variable resolution, podman wrapper
# ═══════════════════════════════════════════════════════════════════════

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'
info()  { echo -e "${CYAN}▶${NC} $*"; }
ok()    { echo -e "${GREEN}✓${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC} $*"; }
err()   { echo -e "${RED}✗${NC} $*" >&2; }

# Podman global flags (custom storage path)
PODMAN_GLOBAL_FLAGS=()
if [[ -n "$PODMAN_STORAGE" ]]; then
    PODMAN_GLOBAL_FLAGS=(--root "$PODMAN_STORAGE" --storage-driver overlay)
fi

# Podman wrapper with global flags
pcmd() {
    podman "${PODMAN_GLOBAL_FLAGS[@]}" "$@"
}

# Read profile variable: check PROFILE_<name>_<var> first, then DEFAULT_<var>
get_profile_var() {
    local profile="$1" var="$2"
    local ref="PROFILE_${profile}_${var}"
    if [[ -n "${!ref+x}" ]]; then
        echo "${!ref}"
    else
        local def="DEFAULT_${var}"
        echo "${!def:-}"
    fi
}

# Read profile array: check PROFILE_<name>_<var>[@] first, then DEFAULT_<var>[@]
# Usage: local arr=($(get_profile_array profile VAR))
# NOTE: for arrays with spaces in elements, use get_profile_array_ref instead
get_profile_array_ref() {
    local profile="$1" var="$2" target="$3"
    local ref="PROFILE_${profile}_${var}[@]"
    local def="DEFAULT_${var}[@]"
    if [[ -n "$(declare -p "PROFILE_${profile}_${var}" 2>/dev/null)" ]]; then
        eval "${target}=(\"\${${ref}}\")"
    elif [[ -n "$(declare -p "DEFAULT_${var}" 2>/dev/null)" ]]; then
        eval "${target}=(\"\${${def}}\")"
    else
        eval "${target}=()"
    fi
}

# Derive names from profile
profile_image()      { echo "${1}-sandbox-krun"; }
profile_home()       { echo "${SANDBOX_BASE}/${1}"; }
profile_vol_pip()    { echo "${1}-sandbox-local"; }
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

    # Resolve effective krun setting (CLI > profile > default)
    local effective_krun="$USE_KRUN"
    if [[ -z "${KRUN_CLI_SET:-}" ]]; then
        local profile_krun
        profile_krun=$(get_profile_var "$PROFILE" USE_KRUN)
        if [[ -n "$profile_krun" ]]; then
            effective_krun="$profile_krun"
        fi
    fi

    if [[ "$effective_krun" == "true" ]]; then
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
#  Creates Dockerfile and entrypoint.sh in ~/.dev-sandbox/<profile>/
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
            external_runs="${external_runs}RUN echo \"▶ Installing external tool ...\" && ${clean}
"
        fi
    done

    cat > "${base_home}/Dockerfile" << DEOF
FROM ${BASE_OS}

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN echo "▶ Creating dev user ..." && \\
    groupadd -g \${HOST_GID} dev 2>/dev/null || true && \\
    useradd -u \${HOST_UID} -g \${HOST_GID} -m -s /bin/bash dev 2>/dev/null || true

RUN echo "▶ Installing system packages (this may take a few minutes) ..." && \\
    dnf install -y \\
        ${packages_joined} \\
    && dnf clean all && \\
    echo "✓ System packages installed"

${external_runs}
RUN echo "▶ Configuring sudo and SSH ..." && \\
    printf 'dev ALL=(ALL) ALL\\nDefaults:dev timestamp_timeout=0\\n' > /etc/sudoers.d/dev

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

    local extra_dnf=()
    get_profile_array_ref "$profile" DNF extra_dnf
    local dnf_line=""
    if [[ ${#extra_dnf[@]} -gt 0 ]] && [[ -n "${extra_dnf[0]:-}" ]]; then
        local pkgs
        pkgs=$(printf '%s ' "${extra_dnf[@]}")
        dnf_line="RUN echo \"▶ Installing profile packages ...\" && dnf install -y ${pkgs} && dnf clean all && echo \"✓ Profile packages installed\""
    fi

    local extra_tools=()
    get_profile_array_ref "$profile" TOOLS extra_tools
    local tools_runs=""
    for tool in "${extra_tools[@]}"; do
        local clean
        clean=$(echo "$tool" | sed 's/#.*//g' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
        if [ -n "$clean" ]; then
            tools_runs="${tools_runs}RUN echo \"▶ Installing tool ...\" && ${clean}
"
        fi
    done

    local agents=()
    get_profile_array_ref "$profile" AGENTS agents
    local agent_runs=""
    for agent in "${agents[@]}"; do
        local clean
        clean=$(echo "$agent" | sed 's/#.*//g' | tr '\n' ' ' | sed 's/  */ /g; s/^ //; s/ $//')
        if [ -n "$clean" ]; then
            agent_runs="${agent_runs}RUN echo \"▶ Installing agent ...\" && ${clean}
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

    local wrappers=()
    get_profile_array_ref "$profile" ROOT_WRAPPERS wrappers

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

    local dotfiles=()
    get_profile_array_ref "$profile" DEV_DOTFILES dotfiles

    # Add colored prompt based on profile color
    local pcolor
    pcolor=$(get_profile_var "$profile" COLOR)
    if [[ -n "$pcolor" ]] && [[ "$pcolor" != "0" ]]; then
        # Prepend PS1 to bashrc.local content
        local ps1_line="PS1=\"\\[\\\\e[${pcolor}m\\][${profile}]\\[\\\\e[0m\\] \\w\\$ \""
        local new_dotfiles=()
        for entry in "${dotfiles[@]}"; do
            if [[ "${entry%%|*}" == "bashrc.local" ]]; then
                entry="bashrc.local|${ps1_line}
${entry#*|}"
            fi
            new_dotfiles+=("$entry")
        done
        dotfiles=("${new_dotfiles[@]}")
    fi

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
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:\${H}/.local/bin:\${H}/.claude/bin"
export TERM="\${TERM:-xterm-256color}"
export COLORTERM="\${COLORTERM:-truecolor}"
export CLAUDE_CONFIG_DIR="\${H}/.claude"
export PYTHONUSERBASE="\${H}/.local"
export LANG="en_US.UTF-8"

cleanup() { sync 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if [ "\$(id -un)" = "root" ]; then

    # ── 1. Set sudo password from host-provided hash ──
    if [ -n "\${SANDBOX_SUDO_HASH:-}" ]; then
        usermod -p "\${SANDBOX_SUDO_HASH}" "\${U}"
        unset SANDBOX_SUDO_HASH
    fi

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

    # Startup hook
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

    # Command wrappers
${wrapper_init_block}

    # ── 4. Run startup hook ──
    if [ -f "\${ROOTCONF}/startup.sh" ]; then
        ( set +e; source "\${ROOTCONF}/startup.sh" ) || \
            echo "⚠ startup.sh exited non-zero — continuing"
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
    chown "\${U}:\${U}" "\${H}/.local/etc"
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

        # Enable TCP forwarding (required for VS Code Remote SSH)
        mkdir -p /etc/ssh/sshd_config.d
        echo "AllowTcpForwarding yes" > /etc/ssh/sshd_config.d/99-sandbox.conf

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
            nft add rule inet filter output ct state established,related accept
            nft add rule inet filter output oif lo accept

            IFS=',' read -ra _DESTS <<< "\${SANDBOX_ALLOW:-}"
            for _hostport in "\${_DESTS[@]}"; do
                if [ -z "\$_hostport" ]; then continue; fi

                # Parse host:port, :port, or bare port
                if [[ "\$_hostport" == *:* ]]; then
                    _host="\${_hostport%:*}"
                    _port="\${_hostport#*:}"
                else
                    _host=""
                    _port="\$_hostport"
                fi

                if [ -z "\$_host" ]; then
                    # :port only — allow to any destination
                    nft add rule inet filter output tcp dport "\$_port" accept || {
                        echo "⚠ Firewall: failed to add rule for port \$_port"
                    }
                    echo "▶ Firewall: allowed → *:\$_port"
                else
                    # host:port — allow to specific destination
                    nft add rule inet filter output ip daddr "\$_host" tcp dport "\$_port" accept || {
                        echo "⚠ Firewall: failed to add rule for \$_host:\$_port"
                    }
                    echo "▶ Firewall: allowed → \$_host:\$_port"
                fi
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

            # Allow DNS if --allow-dns was specified
            if [ -n "\${SANDBOX_ALLOW_DNS:-}" ]; then
                if [ "\${SANDBOX_ALLOW_DNS}" = "auto" ]; then
                    _resolvers=\$(awk '/^nameserver/ {print \$2}' /etc/resolv.conf)
                else
                    _resolvers="\${SANDBOX_ALLOW_DNS%:*}"
                fi
                _dnsport="53"
                case "\${SANDBOX_ALLOW_DNS}" in *:*) _dnsport="\${SANDBOX_ALLOW_DNS#*:}" ;; esac

                for _r in \$_resolvers; do
                    case "\$_r" in *:*) continue ;; esac
                    nft add rule inet filter output ip daddr "\$_r" udp dport "\$_dnsport" accept || true
                    nft add rule inet filter output ip daddr "\$_r" tcp dport "\$_dnsport" accept || true
                    echo "▶ Firewall: DNS allowed → \$_r:\$_dnsport"
                done
                [ -z "\$_resolvers" ] && echo "⚠ --allow-dns: no resolver found in /etc/resolv.conf"
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
            nft add rule inet filter output ct state established,related accept
            nft add rule inet filter output oif lo accept
            echo "▶ Firewall: locked — loopback only"
        else
            echo "⚠ nftables not available — firewall not configured"
        fi
    fi

    exec runuser -u "\${U}" --whitelist-environment="\${SANDBOX_EXTRA_ENV:-}" -- env \\
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
#  podman build: base image (shared) → profile image (agent-specific)
# ═══════════════════════════════════════════════════════════════════════

build_base() {
    local force="${1:-}"

    if [[ "$force" != "-f" ]] && pcmd image exists "${BASE_IMAGE_NAME}" 2>/dev/null; then
        ok "Base image exists (use build -f to rebuild)"
        return 0
    fi

    scaffold_base

    echo ""
    info "Building base image ${BASE_IMAGE_NAME} ..."
    info "  This includes: system packages, external tools, SSH, sudo"
    info "  First build takes several minutes (~1.4 GB download)"
    echo ""

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

    echo ""
    ok "Base image ${BASE_IMAGE_NAME} built successfully."
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

    echo ""
    info "Building profile '${profile}' → ${image_name} ..."
    echo ""

    local extra_args=()
    if [[ "${1:-}" == "-f" ]]; then
        extra_args+=(--no-cache)
    fi

    pcmd build \
        "${extra_args[@]}" \
        -t "${image_name}" \
        "${phome}"

    echo ""
    ok "Profile '${profile}' built successfully."
    ok "Run with: dev-sandbox -p ${profile}"
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
#  Assemble podman flags, start container, display startup info
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

    # Extra volumes from profile config (falls back to DEFAULT_VOLUMES)
    local extra_vols=()
    get_profile_array_ref "$profile" VOLUMES extra_vols
    local vol_flags=()
    for vdir in "${extra_vols[@]}"; do
        if [[ -n "$vdir" ]]; then
            local vname="${profile}-sandbox-${vdir#.}"
            vol_flags+=(-v "${vname}:/home/dev/${vdir}")
        fi
    done

    # Resolve per-profile defaults (CLI overrides > profile > global default)
    local use_krun="$USE_KRUN"
    local profile_krun
    profile_krun=$(get_profile_var "$profile" USE_KRUN)
    if [[ -n "$profile_krun" ]] && [[ "$USE_KRUN" == "true" ]] && [[ -z "${KRUN_CLI_SET:-}" ]]; then
        use_krun="$profile_krun"
    fi

    local profile_net
    profile_net=$(get_profile_var "$profile" NET_MODE)
    local effective_net="${NET_MODE:-${profile_net:-open}}"

    local profile_ram
    profile_ram=$(get_profile_var "$profile" RAM)
    local effective_ram="${RAM_OVERRIDE:-${profile_ram:-${DEFAULT_RAM}}}"
    local profile_cpus
    profile_cpus=$(get_profile_var "$profile" CPUS)
    local effective_cpus="${CPUS_OVERRIDE:-${profile_cpus:-${DEFAULT_CPUS}}}"

    # Runtime mode and resource limits
    local krun_flags=()
    local runtime_label

    if [[ "$use_krun" == "true" ]]; then
        krun_flags+=(--annotation "run.oci.handler=krun")
        krun_flags+=(--annotation "krun.ram_mib=${effective_ram}")
        # krun needs a CPU value — default to available cores
        local krun_cpus="${effective_cpus:-$(nproc)}"
        krun_flags+=(--annotation "krun.cpus=${krun_cpus}")
        runtime_label="krun microVM"
    else
        krun_flags+=(--memory "${effective_ram}m")
        # --cpus only when explicitly set (requires cgroup cpu delegation)
        if [[ -n "${effective_cpus}" ]]; then
            krun_flags+=(--cpus "${effective_cpus}")
        fi
        runtime_label="container"
    fi

    # Determine network mode early (needed for passt decision)

    # Enable passt networking for krun when appropriate
    # passt: proper network stack (nftables works) but SSH port mapping broken
    # TSI: socket proxying (SSH port mapping works) but bypasses nftables
    if [[ "$use_krun" == "true" ]] && [[ "$TSI_OVERRIDE" != "true" ]]; then
        if [[ "$ssh_port" == "0" ]] || [[ -z "$ssh_port" ]]; then
            # No SSH — always use passt (better networking)
            krun_flags+=(--annotation "krun.use_passt=1")
            runtime_label="krun microVM (passt)"
        elif [[ "$effective_net" == "filtered" ]] || [[ "$effective_net" == "locked" ]]; then
            # SSH + firewall — passt for firewall, SSH port mapping won't work
            krun_flags+=(--annotation "krun.use_passt=1")
            runtime_label="krun microVM (passt)"
            warn "Firewall requires passt — SSH port mapping disabled"
            warn "Use --no-krun for both SSH and firewall, or connect via VS Code tunnel"
        else
            runtime_label="krun microVM (TSI)"
        fi
    elif [[ "$use_krun" == "true" ]] && [[ "$TSI_OVERRIDE" == "true" ]]; then
        runtime_label="krun microVM (TSI, forced)"
    fi

    # Network and environment flags
    local net_flags=()
    local net_label="open"
    local env_flags=()
    env_flags+=(-e "TERM=xterm-256color")
    env_flags+=(-e "COLORTERM=truecolor")

    # Generate sudo password on host, send only hash to container
    local sudo_pass
    sudo_pass=$(head -c 24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)
    local sudo_hash
    sudo_hash=$(openssl passwd -6 "$sudo_pass")
    env_flags+=(-e "SANDBOX_SUDO_HASH=${sudo_hash}")

    # Extra env vars from profile and CLI
    local profile_env=()
    get_profile_array_ref "$profile" ENV profile_env
    local profile_env_pass=()
    get_profile_array_ref "$profile" ENV_PASS profile_env_pass
    local extra_env_names=()

    # Profile ENV: set values
    for evar in "${profile_env[@]}"; do
        if [[ -n "$evar" ]]; then
            env_flags+=(-e "$evar")
            extra_env_names+=("${evar%%=*}")
        fi
    done

    # Profile ENV_PASS: pass through from host (no values in script)
    for evar in "${profile_env_pass[@]}"; do
        if [[ -n "$evar" ]] && [[ -n "${!evar:-}" ]]; then
            env_flags+=(-e "${evar}=${!evar}")
            extra_env_names+=("$evar")
        elif [[ -n "$evar" ]]; then
            warn "ENV_PASS: ${evar} not set on host — skipping"
        fi
    done

    # CLI --env: auto-detect set (KEY=VALUE) vs passthrough (KEY)
    for evar in "${ENV_OVERRIDES[@]}"; do
        if [[ -n "$evar" ]]; then
            if [[ "$evar" == *=* ]]; then
                # KEY=VALUE → set
                env_flags+=(-e "$evar")
                extra_env_names+=("${evar%%=*}")
            else
                # KEY only → pass through from host
                if [[ -n "${!evar:-}" ]]; then
                    env_flags+=(-e "${evar}=${!evar}")
                    extra_env_names+=("$evar")
                else
                    warn "--env ${evar} not set on host — skipping"
                fi
            fi
        fi
    done

    # Tell entrypoint which extra vars to pass through to dev user
    if [[ ${#extra_env_names[@]} -gt 0 ]]; then
        local env_names_joined
        env_names_joined=$(IFS=','; echo "${extra_env_names[*]}")
        env_flags+=(-e "SANDBOX_EXTRA_ENV=${env_names_joined}")
    fi

    # SSH server
    local ssh_flags=()
    local ssh_label="off"
    if [[ "$ssh_port" != "0" ]] && [[ -n "$ssh_port" ]]; then
        ssh_flags+=(-p "127.0.0.1:${ssh_port}:22")
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

    # Network mode (effective_net already set above for passt decision)
    local cap_flags=()
    if [[ "$effective_net" == "filtered" ]]; then
        local allow_joined
        allow_joined=$(IFS=','; echo "${ALLOW_DESTINATIONS[*]}")
        env_flags+=(-e "SANDBOX_FIREWALL=filtered")
        env_flags+=(-e "SANDBOX_ALLOW=${allow_joined}")
        cap_flags+=(--cap-add NET_ADMIN)
        net_label="filtered (${allow_joined})"

        # DNS override
        if [[ -n "$DNS_OVERRIDE" ]]; then
            env_flags+=(-e "SANDBOX_ALLOW_DNS=${DNS_OVERRIDE}")
            net_label="${net_label}, dns"
            # Warn if Privoxy+DNS both enabled (DNS hole around SOCKS chain)
            if [[ "$privoxy_enabled" == "true" ]]; then
                warn "Both Privoxy and --allow-dns enabled — DNS queries bypass SOCKS proxy"
            fi
        fi
    elif [[ "$effective_net" == "locked" ]]; then
        env_flags+=(-e "SANDBOX_FIREWALL=locked")
        cap_flags+=(--cap-add NET_ADMIN)
        net_label="locked"
    fi

    info "Starting ${runtime_label} ..."
    info "  Profile:  ${profile} — ${desc}"
    info "  Project:  ${project_dir} → ${mount_point}"
    local cpu_label="${effective_cpus:-all}"
    if [[ "$use_krun" == "true" ]]; then
        info "  RAM/CPU:  ${effective_ram} MiB / ${cpu_label} cores"
    else
        info "  RAM/CPU:  ${effective_ram} MiB / ${cpu_label} cores (limits)"
    fi
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
    echo -e "    ✓ Root config — SSH keys, rules (${vol_root})"
    echo -e "    ✓ pip, dotfiles, history (${vol_pip})"
    # Collect extra volume names for compact display
    local vol_names=""
    for vdir in "${extra_vols[@]}"; do
        if [[ -n "$vdir" ]]; then
            if [[ -n "$vol_names" ]]; then
                vol_names="${vol_names}, ${vdir}"
            else
                vol_names="${vdir}"
            fi
        fi
    done
    if [[ -n "$vol_names" ]]; then
        echo -e "    ✓ ${vol_names}"
    fi
    echo -e "    ✗ dnf packages → edit profile and rebuild"
    echo ""
    echo -e "  ${GREEN}sudo:${NC} ${sudo_pass}"
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

    local profile_args=()
    get_profile_array_ref "$profile" PODMAN_ARGS profile_args

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
        "$@" \
    || true

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

    # Validate argument
    if [[ -n "$purge" ]] && [[ "$purge" != "--purge" ]]; then
        err "Unknown option for clean: $purge"
        err "Usage: dev-sandbox clean [--purge]"
        exit 1
    fi
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
        # Extra profile volumes (with default fallback)
        local extra_vols=()
        get_profile_array_ref "$profile" VOLUMES extra_vols
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
        local extra_vols=()
        get_profile_array_ref "$profile" VOLUMES extra_vols
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

        local agents=()
        get_profile_array_ref "$p" AGENTS agents
        if [[ ${#agents[@]} -gt 0 ]] && [[ -n "${agents[0]:-}" ]]; then
            echo "    Agents: ${#agents[@]}"
        fi
        echo ""
    done
}


# ═══════════════════════════════════════════════════════════════════════
#  INTERNAL — Info (show profile settings)
# ═══════════════════════════════════════════════════════════════════════

do_info() {
    local profile="$1"
    local desc
    desc=$(get_profile_var "$profile" DESCRIPTION)

    echo ""
    info "Profile: ${profile}"
    echo "  ${desc}"
    echo ""

    echo "Runtime:"
    echo "  USE_KRUN         $(get_profile_var "$profile" USE_KRUN)"
    echo "  RAM              $(get_profile_var "$profile" RAM) MiB"
    echo "  CPUS             $(get_profile_var "$profile" CPUS)"
    echo ""

    echo "Network:"
    echo "  NET_MODE         $(get_profile_var "$profile" NET_MODE)"
    echo "  RUN_PRIVOXY      $(get_profile_var "$profile" RUN_PRIVOXY)"
    echo "  PRIVOXY_SOCKS    $(get_profile_var "$profile" PRIVOXY_SOCKS)"
    echo ""

    echo "Services:"
    echo "  SSH_PORT          $(get_profile_var "$profile" SSH_PORT)"
    echo "  SSH_KEY           $(get_profile_var "$profile" SSH_KEY)"
    echo "  COLOR             $(get_profile_var "$profile" COLOR)"
    echo ""

    echo "Volumes:"
    local vols=()
    get_profile_array_ref "$profile" VOLUMES vols
    for v in "${vols[@]}"; do
        [[ -n "$v" ]] && echo "  ${v} → ${profile}-sandbox-${v#.}"
    done
    echo ""

    echo "Agents:"
    local agents=()
    get_profile_array_ref "$profile" AGENTS agents
    if [[ ${#agents[@]} -eq 0 ]] || [[ -z "${agents[0]:-}" ]]; then
        echo "  (none)"
    else
        for a in "${agents[@]}"; do
            [[ -n "$a" ]] && echo "  ${a}"
        done
    fi
    echo ""

    echo "Extra DNF:"
    local dnf=()
    get_profile_array_ref "$profile" DNF dnf
    if [[ ${#dnf[@]} -eq 0 ]] || [[ -z "${dnf[0]:-}" ]]; then
        echo "  (none)"
    else
        echo "  ${dnf[*]}"
    fi
    echo ""
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
    echo "  RAM:           ${DEFAULT_RAM} MiB"
    echo "  CPU:           ${DEFAULT_CPUS}"
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
    local extra_vols=()
    get_profile_array_ref "$profile" VOLUMES extra_vols
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
#  Usage text and examples
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
  --allow-dns                           Allow DNS to resolvers in /etc/resolv.conf
  --allow-dns host[:port]               Allow DNS only to this resolver

${GREEN}Runtime:${NC}
  --no-krun                             Standard container (no microVM)
  --krun                                Force microVM (override profile)
  --tsi                                 Force TSI networking (skip passt)
  --ram MiB                             Memory limit (default: ${DEFAULT_RAM})
  --cpus N                              CPU cores limit (default: ${DEFAULT_CPUS})
  --force                               Kill active session and restart

${GREEN}Services:${NC}
  --ssh-port PORT                       SSH server port (0 = disabled)
  --ssh-key ~/.ssh/id_ed25519.pub       SSH public key for passwordless auth
  --run-privoxy                         Enable Privoxy HTTP proxy
  --no-privoxy                          Disable Privoxy (override profile)
  --privoxy-socks host:port             Where Privoxy forwards traffic
  --proxy PORT                          Shortcut: --allow + --run-privoxy + --privoxy-socks
                                        Routes all traffic through SOCKS proxy on host
  --env KEY=VALUE                       Pass env variable to container (repeatable)
  --env KEY                             Pass through from host env (no value in CLI)

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
  RAM:              ${DEFAULT_RAM} MiB  (DEV_SANDBOX_RAM)
  CPU:              ${DEFAULT_CPUS}        (DEV_SANDBOX_CPUS)
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
#  MAIN — Argument parsing, conflict checks, dispatch
#  Supports both --opt value and --opt=value formats
# ═══════════════════════════════════════════════════════════════════════

PROFILE="${DEFAULT_PROFILE}"
USE_KRUN=true
KRUN_CLI_SET=""             # Set to "true" when --krun/--no-krun is used
TSI_OVERRIDE=false          # --tsi (force TSI networking, skip passt)
NET_MODE=""                 # open, locked, filtered (empty = profile default → open)
ALLOW_DESTINATIONS=()       # --allow host:port (repeatable)
PRIVOXY_SOCKS_OVERRIDE=""   # --privoxy-socks host:port
SSH_PORT_OVERRIDE=""        # --ssh-port PORT
SSH_KEY_OVERRIDE=""         # --ssh-key /path/to/key.pub
PRIVOXY_OVERRIDE=""         # --run-privoxy / --no-privoxy
RAM_OVERRIDE=""             # --ram MiB
CPUS_OVERRIDE=""            # --cpus N
FORCE_RUN=false             # --force
DNS_OVERRIDE=""             # --allow-dns [resolver]
PROXY_SHORTCUT=""           # --proxy PORT (shortcut for --allow + --run-privoxy + --privoxy-socks)
ENV_OVERRIDES=()            # --env KEY=VALUE (repeatable)

# Helper: extract value from --opt=value or --opt value
parse_opt_value() {
    local opt="$1"
    if [[ "$opt" == *=* ]]; then
        echo "${opt#*=}"
        return 0
    fi
    return 1
}

while [[ "${1:-}" == -* ]]; do
    case "${1:-}" in
        --no-krun)
            USE_KRUN=false
            KRUN_CLI_SET=true
            shift
            ;;
        --krun)
            USE_KRUN=true
            KRUN_CLI_SET=true
            shift
            ;;
        --tsi)
            TSI_OVERRIDE=true
            shift
            ;;
        --net|--net=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing mode. Usage: --net open|locked"; exit 1; fi
            case "$val" in
                open|locked) NET_MODE="$val" ;;
                *) err "Unknown mode: $val (use: open, locked)"; exit 1 ;;
            esac
            ;;
        --allow|--allow=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing address. Usage: --allow host:port"; exit 1; fi
            ALLOW_DESTINATIONS+=("$val")
            ;;
        --privoxy-socks|--privoxy-socks=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing address. Usage: --privoxy-socks host:port"; exit 1; fi
            PRIVOXY_SOCKS_OVERRIDE="$val"
            ;;
        --ssh-port|--ssh-port=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing port. Usage: --ssh-port PORT"; exit 1; fi
            SSH_PORT_OVERRIDE="$val"
            ;;
        --ssh-key|--ssh-key=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing path. Usage: --ssh-key ~/.ssh/id_ed25519.pub"; exit 1; fi
            SSH_KEY_OVERRIDE="$val"
            ;;
        --run-privoxy)
            PRIVOXY_OVERRIDE="true"
            shift
            ;;
        --no-privoxy)
            PRIVOXY_OVERRIDE="false"
            shift
            ;;
        --ram|--ram=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing value. Usage: --ram 8192"; exit 1; fi
            RAM_OVERRIDE="$val"
            ;;
        --cpus|--cpus=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing value. Usage: --cpus 8"; exit 1; fi
            CPUS_OVERRIDE="$val"
            ;;
        --force)
            FORCE_RUN=true
            shift
            ;;
        --allow-dns|--allow-dns=*)
            val=""
            if val=$(parse_opt_value "$1"); then
                DNS_OVERRIDE="$val"; shift
            elif [[ -n "${2:-}" ]] && [[ "$2" != -* ]]; then
                DNS_OVERRIDE="$2"; shift 2
            else
                DNS_OVERRIDE="auto"; shift
            fi
            ;;
        --proxy|--proxy=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing port. Usage: --proxy 1080"; exit 1; fi
            PROXY_SHORTCUT="$val"
            ;;
        --env|--env=*|-e|-e=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing value. Usage: --env KEY=VALUE"; exit 1; fi
            ENV_OVERRIDES+=("$val")
            ;;
        -p|-p=*)
            val=""
            if val=$(parse_opt_value "$1"); then shift
            elif [[ -n "${2:-}" ]]; then val="$2"; shift 2
            else err "Missing profile name. Usage: dev-sandbox -p <profile>"; err "Available: ${ALL_PROFILES[*]}"; exit 1; fi
            PROFILE="$val"

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
        --)
            shift
            break
            ;;
        -h|-help|--help)
            usage
            exit 0
            ;;
        --version)
            echo "dev-sandbox v${VERSION}"
            exit 0
            ;;
        -*)
            err "Unknown option: $1"
            err "Run 'dev-sandbox help' for usage"
            exit 1
            ;;
    esac
done

# Expand --proxy shortcut (before auto-filter)
if [[ -n "$PROXY_SHORTCUT" ]]; then
    ALLOW_DESTINATIONS+=("host.containers.internal:${PROXY_SHORTCUT}")
    PRIVOXY_OVERRIDE="true"
    PRIVOXY_SOCKS_OVERRIDE="host.containers.internal:${PROXY_SHORTCUT}"
fi

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
if [[ "$NET_MODE" == "locked" ]] && [[ -n "$DNS_OVERRIDE" ]]; then
    err "--net locked and --allow-dns are mutually exclusive"
    exit 1
fi
if [[ "$NET_MODE" == "locked" ]] && [[ "$PRIVOXY_OVERRIDE" == "true" ]]; then
    err "--net locked and --run-privoxy are mutually exclusive"
    err "--net locked blocks all traffic, including Privoxy"
    err "Use --proxy PORT to route traffic through proxy with firewall"
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
    info)       do_info "$PROFILE" ;;
    ls|list)    do_list ;;
    profiles)   do_profiles ;;
    help|--help|-h) usage ;;
    version)  echo "dev-sandbox v${VERSION}" ;;
    *)
        # Check if argument is a profile name (common mistake: forgetting -p)
        if [[ -n "${1:-}" ]]; then
            for p in "${ALL_PROFILES[@]}"; do
                if [[ "$p" == "$1" ]]; then
                    err "Did you mean: dev-sandbox -p $1"
                    exit 1
                fi
            done
            # Unknown command — not a profile, not a known subcommand
            err "Unknown command: $1"
            err "Run 'dev-sandbox help' for usage"
            exit 1
        fi
        check_prereqs; do_run "$PROFILE" "$@"
        ;;
esac
