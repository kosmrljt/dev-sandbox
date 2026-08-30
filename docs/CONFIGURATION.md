# Configuration

All configuration is at the top of `dev-sandbox.sh`. Defaults apply to all profiles — each profile only overrides what differs.

## Priority chain

Settings resolve in this order (first match wins):

```
CLI flag           --ram 8192
Profile            PROFILE_claude_RAM=6144
Environment        DEV_SANDBOX_RAM=8192
Default            DEFAULT_RAM=4096
```

## Profile variables

All variables use the pattern `DEFAULT_<NAME>` / `PROFILE_<profile>_<NAME>`:

| Variable | Type | Description |
|---|---|---|
| `DESCRIPTION` | string | Profile description shown in `profiles` and `info` |
| `AGENTS` | array | Install commands run in Dockerfile during build |
| `DNF` | array | Extra DNF packages on top of base image |
| `TOOLS` | array | External binary tools (curl/wget install commands) |
| `USE_KRUN` | bool | `true` = krun microVM, `false` = standard container |
| `NET_MODE` | string | `open` = full internet, `locked` = no outbound, `filtered` = allow-list |
| `SSH_PORT` | int | SSH server port on host (0 = disabled) |
| `SSH_KEY` | path | Public key for passwordless SSH (e.g. `~/.ssh/id_ed25519.pub`) |
| `RUN_PRIVOXY` | bool | Start Privoxy HTTP→SOCKS5 proxy |
| `PRIVOXY_SOCKS` | host:port | Where Privoxy forwards traffic |
| `RAM` | int | Memory limit in MiB |
| `CPUS` | int | CPU cores limit |
| `COLOR` | int | Prompt color code (0=none, 31=red, 32=green, 33=yellow, 34=blue) |
| `ENV` | array | Extra env variables set in container (`"KEY=VALUE"`) |
| `ENV_PASS` | array | Env variable names passed through from host — values stay out of script |
| `VOLUMES` | array | Home directories to persist as named volumes |
| `PODMAN_ARGS` | array | Extra arguments passed to `podman run` |
| `ROOT_STARTUP` | string | Shell script run as root on every startup |
| `ROOT_WRAPPERS` | array | Commands installed to `/usr/local/bin/` (format: `name\|script`) |
| `DEV_DOTFILES` | array | User config files in `~/.local/etc/` (format: `name\|content`) |

## Environment variable overrides

Override defaults without editing the script:

```bash
DEV_SANDBOX_RAM=8192 dev-sandbox                     # More RAM
DEV_SANDBOX_CPUS=8 dev-sandbox                       # More CPUs
DEV_SANDBOX_STORAGE="/mnt/disk2/podman" dev-sandbox   # Different storage path
```

## What persists between sessions

| What | Persists? | Where |
|---|---|---|
| Project files | ✓ | Bind mount back to host |
| pip packages | ✓ | Volume (~/.local) |
| Agent credentials | ✓ | Volume (~/.claude, ~/.gemini, etc.) |
| SSH host keys | ✓ | Volume (/etc/sandbox) |
| User dotfiles | ✓ | Volume (~/.local/etc/) |
| Privoxy/firewall config | ✓ | Volume (/etc/sandbox) |
| Bash history | ✓ | Volume (~/.local/etc/.bash_history) |
| dnf install packages | ✗ | Add to profile config, rebuild |
| Files outside project and home | ✗ | Lost on exit |

## Adding a new profile

Minimal profile — only description and registration:

```bash
PROFILE_test_DESCRIPTION="My test sandbox"

ALL_PROFILES=(claude research agy vncgui test)
```

Everything else inherits from `DEFAULT_*`. Override as needed:

```bash
PROFILE_test_COLOR="33"                  # Yellow prompt
PROFILE_test_SSH_PORT=2232
PROFILE_test_USE_KRUN=false
PROFILE_test_DNF=(htop strace)
PROFILE_test_AGENTS=('pip install --user aider-chat')
PROFILE_test_ENV=("OLLAMA_HOST=http://host.containers.internal:11434")
PROFILE_test_ENV_PASS=("ANTHROPIC_API_KEY")
```

Build and run:

```bash
dev-sandbox -p test build -f
dev-sandbox -p test
```

## Full rebuild

After changing base packages:

```bash
rm -rf ~/.dev-sandbox
dev-sandbox build -f
```

After changing profile config:

```bash
rm -rf ~/.dev-sandbox/claude
dev-sandbox build -f
```

After changing startup hooks, wrappers, or dotfiles:

```bash
podman volume rm claude-sandbox-rootconf   # regenerate root config
podman volume rm claude-sandbox-pip        # regenerate dotfiles (also removes pip packages)
dev-sandbox                                # regenerates on next run
```

## CLI reference

All flags are available via `dev-sandbox help`. Key commands:

```
dev-sandbox                     Run default profile
dev-sandbox -p <profile>        Run specific profile
dev-sandbox build [-f]          Build images (-f = no cache)
dev-sandbox info                Show resolved profile settings
dev-sandbox status              Show images, volumes, system info
dev-sandbox ls                  List running sandboxes
dev-sandbox profiles            List all profiles
dev-sandbox clean [--purge]     Remove image [and volumes]
dev-sandbox --version           Show version
dev-sandbox help                Show all flags
```
