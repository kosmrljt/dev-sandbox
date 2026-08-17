# dev-sandbox

**Run AI coding agents in isolated Podman containers with krun microVMs.**

One self-contained bash script. No dependencies beyond Podman and crun-krun. Configure profiles, build, run — everything in a single file.

## Why

AI coding agents (Claude Code, Antigravity, Aider, etc.) need shell access and run arbitrary code. Without isolation:

- An agent can read `~/.ssh/`, `~/.aws/`, browser cookies, API keys
- A malicious pip package in `setup.py` can exfiltrate data silently
- Prompt injection in a file can instruct the agent to run destructive commands
- You have no visibility into what network connections the agent makes

dev-sandbox fixes this by running each agent in its own isolated environment with only the current project directory visible.

## What you get

- **Kernel-level isolation** — krun microVM runs its own Linux kernel, not just namespaces
- **Project-only visibility** — only the current directory is mounted, nothing else from your filesystem
- **Separate profiles** — production agent (Claude) and experimental agents (untrusted) have isolated credentials, volumes, and network rules
- **Network control** — nftables firewall via passt networking, Privoxy HTTP→SOCKS5 proxy chain, per-destination allow rules
- **SSH server** — connect from VS Code Remote, additional terminals, or use as SOCKS proxy tunnel
- **Persistent config** — pip packages, credentials, SSH keys, dotfiles survive between sessions in named volumes
- **One file** — everything is configured and runs from a single bash script

## Quick start

### Prerequisites

```bash
sudo dnf install podman crun-krun
```

### Install

```bash
curl -o ~/.local/bin/dev-sandbox https://raw.githubusercontent.com/kosmrljt/dev-sandbox/main/dev-sandbox.sh
chmod +x ~/.local/bin/dev-sandbox

# Ensure ~/.local/bin is in PATH (add to ~/.bashrc if not)
echo $PATH | grep -q "$HOME/.local/bin" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

### First run

```bash
cd ~/my-project
dev-sandbox          # builds image on first run, then opens shell
```

Inside the container:

```bash
claude               # start Claude Code
exit                 # close container, project changes saved
```

## Usage scenarios

### Basic — Claude Code with full internet

```bash
cd ~/my-project
dev-sandbox
```

Agent has internet access, SSH server on port 2228 for VS Code.

### Locked down — no outbound traffic

```bash
dev-sandbox --net locked
```

Container has no internet. Only loopback works. Use for reviewing untrusted code.

### Filtered — outbound only through proxy

```bash
dev-sandbox --allow host.containers.internal:1080 \
            --run-privoxy \
            --privoxy-socks host.containers.internal:1080
```

All traffic forced through Privoxy → SOCKS5 proxy on host. Direct connections blocked. DNS queries go through SOCKS (forward-socks5t). Run a SOCKS5 proxy on the host to monitor all connections.

### Multiple allowed destinations

```bash
dev-sandbox --allow host.containers.internal:1080 \
            --allow host.containers.internal:22
```

Firewall allows only these specific host:port pairs. Everything else dropped.

### Research profile — untrusted agents

```bash
dev-sandbox -p research
```

Separate credentials, separate volumes, separate network rules. A compromised pip package in research cannot read Claude credentials.

### VS Code Remote SSH

```bash
dev-sandbox --ssh-key ~/.ssh/id_ed25519.pub
```

Then in VS Code: `Remote-SSH: Connect to Host` → `ssh -p 2228 dev@localhost`

### Standard container (no microVM)

```bash
dev-sandbox --no-krun
```

Uses host kernel instead of krun microVM. Required for nftables firewall without passt. Faster startup, less isolation.

### Resource limits

```bash
dev-sandbox --ram 8192 --cpus 8
```

Works for both krun (VM memory/CPU) and standard containers (cgroup limits).

### Full proxy chain with monitoring

```bash
# Terminal 1: SOCKS5 proxy on host (monitor connections)
microsocks -p 1080

# Terminal 2: sandbox with everything locked down
dev-sandbox -p research \
    --allow host.containers.internal:1080 \
    --run-privoxy \
    --privoxy-socks host.containers.internal:1080
```

Every HTTP request, every DNS query visible on the host proxy. Nothing bypasses.

## Architecture

```
┌─ Host ───────────────────────────────────────────────────────┐
│                                                              │
│  dev-sandbox.sh                                              │
│  ├── Configuration (profiles, packages, hooks)               │
│  ├── Scaffold (generates Dockerfile, entrypoint.sh)          │
│  ├── Build (podman build → base image → profile image)       │
│  └── Run (podman run → krun microVM or container)            │
│                                                              │
│  ┌─ krun microVM (or container) ──────────────────────────┐  │
│  │                                                        │  │
│  │  entrypoint.sh (PID 1, root)                           │  │
│  │  ├── Generate sudo password                            │  │
│  │  ├── Fix volume ownership                              │  │
│  │  ├── Generate defaults (first run)                     │  │
│  │  │   ├── /etc/sandbox/startup.sh (root hooks)          │  │
│  │  │   ├── /etc/sandbox/wrappers/* (command wrappers)    │  │
│  │  │   └── ~/.local/etc/* (user dotfiles)                │  │
│  │  ├── Run startup hooks                                 │  │
│  │  ├── Start sshd (if configured)                        │  │
│  │  ├── Start Privoxy (if configured)                     │  │
│  │  ├── Configure nftables firewall (if configured)       │  │
│  │  └── Switch to dev user → bash                         │  │
│  │                                                        │  │
│  │  Mounts:                                               │  │
│  │  ├── /app/project-hash ← bind mount (project dir)     │  │
│  │  ├── ~/.local ← volume (pip, scripts, dotfiles)        │  │
│  │  ├── /etc/sandbox ← volume (SSH keys, configs)         │  │
│  │  └── ~/.claude, ~/.cache, etc ← volumes (per profile)  │  │
│  │                                                        │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  Volumes (persist between sessions):                         │
│  ├── claude-sandbox-pip          ~/.local                    │
│  ├── claude-sandbox-rootconf     /etc/sandbox                │
│  ├── claude-sandbox-claude       ~/.claude                   │
│  ├── claude-sandbox-cache        ~/.cache                    │
│  ├── research-sandbox-pip        ~/.local                    │
│  ├── research-sandbox-rootconf   /etc/sandbox                │
│  ├── research-sandbox-gemini     ~/.gemini                   │
│  └── ...                                                     │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Two-layer image build

```
fedora:44                          Base OS
    ↓
dev-sandbox-base                   Common packages, tools, user setup, SSH, Privoxy
    ↓                  ↓
claude-sandbox-krun    research-sandbox-krun
Claude Code agent      Antigravity, untrusted agents
```

Base image is built once and shared. Profile images add only agent-specific packages. Layers are deduplicated — total disk usage is much less than the sum of image sizes.

### Network modes

```
--net open (default)     Full internet access
                         App ──→ Internet

--net locked             No outbound traffic
                         App ──→ ✗ blocked

--allow host:port        Only specified destinations
                         App ──→ Privoxy :8118
                              ──→ SOCKS5 host:1080 ✓
                              ──→ anything else ✗ blocked
```

With `--allow`, nftables drops all outbound traffic except loopback and explicitly allowed destinations. When Privoxy is enabled with `forward-socks5t`, DNS queries also go through the SOCKS proxy — nothing leaks.

### Podman with krun vs without

| | krun microVM | Standard container |
|---|---|---|
| Isolation | Own kernel (VM boundary) | Shared kernel (namespaces) |
| Networking | passt (krun.use_passt=1) | Standard podman networking |
| nftables firewall | Works with passt | Works natively |
| SSH server | Works | Works |
| Overhead | ~200ms startup, fixed RAM | Minimal |
| Container escape | Requires VM escape (hard) | Requires namespace escape (easier) |
| `podman exec` | Not supported | Works |

Default is krun with passt networking, which provides both VM-level isolation and working nftables firewall. Use `--no-krun` when you need `podman exec`, lower overhead, or specific device access.

## Configuration

All configuration is at the top of the script. Edit the profile section to customize:

```bash
# ─── My Custom Profile ─────────────────────────
PROFILE_custom_DESCRIPTION="My custom sandbox"
PROFILE_custom_AGENTS=(
    'pip install --user some-agent'
)
PROFILE_custom_DNF=(extra-package)
PROFILE_custom_SSH_PORT=2230
PROFILE_custom_RUN_PRIVOXY=false
PROFILE_custom_VOLUMES=(.cache .config)
PROFILE_custom_PODMAN_ARGS=(
    --tmpfs /var/log:rw,size=50m,mode=1777
)
PROFILE_custom_ROOT_STARTUP=''
PROFILE_custom_ROOT_WRAPPERS=()
PROFILE_custom_DEV_DOTFILES=(
    'bashrc.local|alias ll="ls -la"'
)

# Add to registry
ALL_PROFILES=(claude research custom)
```

Then build and run:

```bash
dev-sandbox -p custom build -f
dev-sandbox -p custom
```

### Persistence model

| What | Persists? | Where |
|---|---|---|
| Project files | ✓ | Bind mount back to host |
| pip packages | ✓ | Named volume (~/.local) |
| Agent credentials | ✓ | Named volume (~/.claude, ~/.gemini, etc.) |
| SSH host keys | ✓ | Named volume (/etc/sandbox) |
| User dotfiles | ✓ | Named volume (~/.local/etc/) |
| Privoxy/firewall config | ✓ | Named volume (/etc/sandbox) |
| dnf install packages | ✗ | Add to profile config, rebuild |
| Files outside /app and /home/dev | ✗ | Lost on exit |

### CLI reference

```
Network:
  --net open                    Full internet (override profile default)
  --net locked                  No outbound traffic
  --allow host:port             Allow only this destination (repeatable)

Services:
  --krun / --no-krun            Force microVM or standard container
  --ssh-port PORT               SSH server port (0 = disabled)
  --ssh-key path                SSH public key for passwordless auth
  --run-privoxy / --no-privoxy  Enable/disable Privoxy
  --privoxy-socks host:port     Where Privoxy forwards traffic

Resources:
  --ram MiB                     Memory limit
  --cpus N                      CPU cores limit
  --force                       Kill active session and restart

Management:
  dev-sandbox build             Build (uses cache)
  dev-sandbox build -f          Rebuild from scratch
  dev-sandbox ls                List running sandboxes
  dev-sandbox status            Show profile status
  dev-sandbox profiles          List all profiles
  dev-sandbox clean             Remove image and scaffold
  dev-sandbox clean --purge     Remove everything including volumes
```

### Environment variable overrides

```bash
DEV_SANDBOX_RAM=8192 dev-sandbox                    # More RAM
DEV_SANDBOX_CPUS=8 dev-sandbox                      # More CPUs
DEV_SANDBOX_STORAGE="/mnt/disk2/podman" dev-sandbox  # Different storage
```

## Requirements

- **Fedora 40+** (or any distro with Podman 4.x+ and crun-krun)
- **Podman** — `sudo dnf install podman`
- **crun-krun** — `sudo dnf install crun-krun` (for krun microVM mode)
- **passt** — usually installed with crun-krun (for krun networking)

Optional:
- **gocryptfs** — for encrypted project directories (`gocryptfs -allow_other` required)
- **btrfs** — for project directory quotas and instant snapshots


## Known limitations

- **krun without passt**: Default TSI networking bypasses nftables entirely. The script enables `krun.use_passt=1` by default to avoid this.
- **krun TSI TCP limit**: Without passt, concurrent TCP connections are limited to ~3/s ([libkrun #511](https://github.com/libkrun/libkrun/issues/511)). Not an issue with passt enabled.
- **No `podman exec` with krun**: Use SSH or tmux for additional terminals inside the VM.
- **tty warning**: `tty: ttyname error` may appear on krun startup. Cosmetic only, does not affect functionality.
- **gocryptfs directories**: Require `gocryptfs -allow_other` mount flag and `user_allow_other` in `/etc/fuse.conf` for Podman's user namespace to access the FUSE mount.

## Related

- [urllight](https://github.com/kosmrljt/urllight) — SOCKS5 proxy with live terminal dashboard. Run it on the host, route sandbox traffic through it, see every connection and DNS query in real time. Designed to complement dev-sandbox for network analysis and building firewall allowlists from observed traffic.

## Development

Inspired by the [Fedora Magazine article on sandboxing AI agents with microVMs](https://fedoramagazine.org/sandbox-ai-coding-agents-with-microvms-on-fedora-linux/).

The script was developed through iterative pair programming with Claude (Anthropic) — Claude wrote the code, I tested on real hardware and directed the design. Each issue found on the actual system led to a fix, resulting in a single script that encapsulates the non-obvious knowledge needed to run AI agents in properly isolated containers.

## Author

Tomaž Košmrlj

## License

MIT

