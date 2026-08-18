# dev-sandbox

**Run AI coding agents in isolated Podman containers with krun microVMs.**

For Linux distributions with Podman support. Developed and tested on Fedora 44.

One self-contained bash script. No dependencies beyond Podman and crun-krun. Configure profiles, build, run — everything in a single file.

## Why

AI coding agents (Claude Code, Antigravity, Aider, etc.) need shell access and run arbitrary code. Without isolation:

- An agent can read `~/.ssh/`, `~/.aws/`, browser cookies, API keys
- A malicious pip package in `setup.py` can exfiltrate data silently
- Prompt injection in a file can instruct the agent to run destructive commands
- You have no visibility into what network connections the agent makes

dev-sandbox runs each agent in its own isolated environment with only the current project directory visible.

## What you get

- **Kernel-level isolation** — krun microVM runs its own Linux kernel, not just namespaces
- **Project-only visibility** — only the current directory is mounted, nothing else from your filesystem
- **Separate profiles** — production and experimental agents have isolated credentials, volumes, and network rules
- **Network control** — nftables firewall, Privoxy HTTP→SOCKS5 proxy chain, per-destination allow rules
- **SSH server** — connect from VS Code Remote or use as SOCKS proxy tunnel
- **Persistent config** — pip packages, credentials, SSH keys, dotfiles survive between sessions
- **One file** — everything is configured and runs from a single bash script

## Quick start

```bash
# Prerequisites
sudo dnf install podman crun-krun

# Install
curl -o ~/.local/bin/dev-sandbox https://raw.githubusercontent.com/kosmrljt/dev-sandbox/main/dev-sandbox.sh
chmod +x ~/.local/bin/dev-sandbox

# Run (builds image on first run)
cd ~/my-project
dev-sandbox
```

## Usage examples

```bash
# Basic — full internet, SSH for VS Code on port 2228
dev-sandbox

# Locked — no outbound traffic
dev-sandbox --net locked

# Filtered — outbound only through proxy on host
dev-sandbox --allow host.containers.internal:1080 \
            --allow host.containers.internal:22 \
            --run-privoxy --privoxy-socks host.containers.internal:1080

# Research profile — separate credentials and volumes
dev-sandbox -p research

# VS Code Remote SSH with key auth
dev-sandbox --ssh-key ~/.ssh/id_ed25519.pub

# Standard container instead of microVM
dev-sandbox --no-krun

# Resource limits (works for both krun and containers)
dev-sandbox --ram 8192 --cpus 8

# Kill active session and restart
dev-sandbox --force
```

## Architecture

```
┌─ Host ─────────────────────────────────────────────────────┐
│                                                            │
│  dev-sandbox.sh                                            │
│  ├── Configuration (profiles, packages, hooks)             │
│  ├── Scaffold (generates Dockerfile, entrypoint.sh)        │
│  ├── Build (podman build → base image → profile image)     │
│  └── Run (podman run → krun microVM or container)          │
│                                                            │
│  ┌─ krun microVM (or container) ───────────────────────┐   │
│  │                                                     │   │
│  │  entrypoint.sh (PID 1, root)                        │   │
│  │  ├── Generate sudo password                         │   │
│  │  ├── Fix volume ownership                           │   │
│  │  ├── Run startup hooks                              │   │
│  │  ├── Install command wrappers                       │   │
│  │  ├── Generate user dotfiles (first run)             │   │
│  │  ├── Start sshd, Privoxy (if configured)            │   │
│  │  ├── Configure nftables firewall (if configured)    │   │
│  │  └── Switch to dev user → bash                      │   │
│  │                                                     │   │
│  │  Mounts:                                            │   │
│  │  ├── /app/project-hash ← project dir (bind mount)   │   │
│  │  ├── ~/.local ← pip, scripts, dotfiles (volume)     │   │
│  │  ├── /etc/sandbox ← SSH keys, configs (volume)      │   │
│  │  └── ~/.claude, ~/.cache, ... (per-profile volumes) │   │
│  │                                                     │   │
│  └─────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────┘
```

### Image layers

```
fedora:44                          Base OS
    ↓
dev-sandbox-base                   Common: packages, SSH, Privoxy, user setup
    ↓                  ↓
claude-sandbox-krun    research-sandbox-krun
```

Base image is built once and shared. Profile images add only agent-specific packages.

### Network modes

| Mode | Effect |
|---|---|
| `--net open` (default) | Full internet access |
| `--net locked` | No outbound traffic, loopback only |
| `--allow host:port` | Only specified destinations, everything else blocked |

When Privoxy is enabled with `forward-socks5t`, DNS queries go through the SOCKS proxy — nothing leaks.

### krun microVM vs standard container

| | krun microVM | Standard container |
|---|---|---|
| Isolation | Own kernel (VM boundary) | Shared kernel (namespaces) |
| nftables firewall | Works with passt | Works natively |
| Container escape | Requires VM escape | Requires namespace escape |
| `podman exec` | Not supported | Works |
| Overhead | ~200ms startup, fixed RAM | Minimal |

Default is krun with passt networking. Use `--no-krun` when you need `podman exec` or lower overhead.

## Configuration

All configuration is at the top of the script:

```bash
# ─── My Custom Profile ─────────────────────────
PROFILE_custom_DESCRIPTION="My custom sandbox"
PROFILE_custom_AGENTS=('pip install --user some-agent')
PROFILE_custom_DNF=(extra-package)
PROFILE_custom_SSH_PORT=2230
PROFILE_custom_RUN_PRIVOXY=false
PROFILE_custom_VOLUMES=(.cache .config)
PROFILE_custom_PODMAN_ARGS=(--tmpfs /var/log:rw,size=50m,mode=1777)
PROFILE_custom_ROOT_STARTUP=''
PROFILE_custom_ROOT_WRAPPERS=()
PROFILE_custom_DEV_DOTFILES=('bashrc.local|alias ll="ls -la"')

ALL_PROFILES=(claude research custom)
```

```bash
dev-sandbox -p custom build -f
dev-sandbox -p custom
```

Environment variable overrides:

```bash
DEV_SANDBOX_RAM=8192 dev-sandbox
DEV_SANDBOX_CPUS=8 dev-sandbox
DEV_SANDBOX_STORAGE="/mnt/disk2/podman" dev-sandbox
```

### What persists between sessions

| What | Persists? | Where |
|---|---|---|
| Project files | ✓ | Bind mount back to host |
| pip packages | ✓ | Volume (~/.local) |
| Agent credentials | ✓ | Volume (~/.claude, ~/.gemini, etc.) |
| SSH host keys | ✓ | Volume (/etc/sandbox) |
| User dotfiles | ✓ | Volume (~/.local/etc/) |
| dnf install packages | ✗ | Add to profile config, rebuild |

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

## Requirements

- **Podman 4.x+** — `sudo dnf install podman` (Fedora/RHEL) or equivalent
- **crun-krun** — `sudo dnf install crun-krun` (for krun microVM mode)
- **passt** — usually installed with crun-krun

Optional:
- **gocryptfs** — for encrypted project directories (`gocryptfs -allow_other` required)
- **btrfs** — for project directory quotas and instant snapshots

## Security notes

- **`.git/hooks` escape path**: The project directory is bind-mounted read-write. An agent can write git hooks (e.g. `pre-commit`, `post-checkout`) that execute **on the host** next time you run git in that directory. Same applies to `.envrc`, `Makefile` targets, `package.json` scripts, and `.vscode/tasks.json`. Review changes in your project directory after sandbox sessions.
- **Persistent volumes are execution paths**: Files in `~/.local/bin`, `~/.local/etc/bashrc.local`, and `/etc/sandbox/startup.sh` persist across sessions and execute on every startup. A compromised session can plant code that runs on every subsequent start. The mental model "it's a container, I'll just restart it" does not fully apply.

## Known limitations

- **krun without passt**: TSI networking bypasses nftables. The script enables `krun.use_passt=1` by default.
- **No `podman exec` with krun**: Use SSH or tmux for additional terminals.
- **tty warning**: `tty: ttyname error` may appear on krun startup. Cosmetic only.

## Related

[urllight](https://github.com/kosmrljt/urllight) — SOCKS5 proxy with live terminal dashboard. Route sandbox traffic through it to see every connection and DNS query.

## Development

Inspired by the [Fedora Magazine article on sandboxing AI agents with microVMs](https://fedoramagazine.org/sandbox-ai-coding-agents-with-microvms-on-fedora-linux/).

The script was developed through iterative pair programming with Claude (Anthropic) — Claude wrote the code, I tested on real hardware and directed the design. Each issue found on the actual system led to a fix, resulting in a single script that encapsulates the practical knowledge needed to run code in isolated Podman containers with krun microVMs.

## Author

Tomaž Košmrlj

## License

MIT
