# dev-sandbox — Testing Guide

This document covers all features with step-by-step commands.
It serves both as a test plan and as a practical tutorial for new users.

---

## Prerequisites

Before testing, ensure you have Podman and crun-krun installed:

```bash
sudo dnf install podman crun-krun

# Verify installation
podman --version
crun --version | grep -i libkrun
```

## 1. First Run — Build and Start

The first run builds the base image (~1.6 GB download, takes several minutes)
and the profile image. Subsequent runs start in seconds.

```bash
# Start from a clean state
rm -rf ~/.dev-sandbox
podman volume ls | grep sandbox | awk '{print $2}' | xargs -r podman volume rm

# Navigate to any project directory
cd ~/my-project

# Run with default profile (claude)
dev-sandbox
```

**What to expect:**
- Base image builds (dnf install, external tools)
- Profile image builds (agent install)
- SSH host keys generated
- Dotfiles generated (bashrc.local, tmux.conf)
- Startup.sh generated
- Wrappers generated (claude)
- sudo password displayed on HOST terminal
- Shell opens inside container

**Verify inside the container:**

```bash
# Check you're inside
hostname                        # claude-sandbox

# Check user
whoami                          # dev

# Check project is mounted
ls                              # your project files

# Check PATH order (local/bin should be at the END for security)
echo $PATH
# /usr/local/sbin:/usr/local/bin:...:/home/dev/.local/bin:/home/dev/.claude/bin

# Exit
exit
```

## 2. Second Run — Cached Start

```bash
dev-sandbox
```

**What to expect:**
- No "Generating..." messages (everything cached in volumes)
- SSH server started
- Shell opens immediately

**Verify persistence:**

```bash
# Install a pip package
pip install --user httpie

# Exit and restart
exit
dev-sandbox

# Package still available
http --version                  # installed from previous session
```

## 3. Profiles

### List available profiles

```bash
dev-sandbox profiles
```

Shows all profiles with description, image status, and which is default.

### Run a different profile

```bash
# Build research profile first
dev-sandbox -p research build -f

# Run it
dev-sandbox -p research
```

**Verify isolation:**

```bash
# Inside research container
hostname                        # research-sandbox
ls ~/.claude                    # No such file (claude credentials isolated)
ls ~/.gemini                    # Research credentials here
```

### Profile status

```bash
dev-sandbox status              # Default profile
dev-sandbox -p research status  # Specific profile
```

Shows images, volumes, build files, and system info.

## 4. SSH Server

### Basic SSH

```bash
# Start sandbox with SSH
dev-sandbox --ssh-port 2228

# From another terminal on host
ssh -p 2228 dev@localhost
# Enter the sudo password shown at startup
```

### SSH with key auth (no password needed)

```bash
# Make sure you have a key
ls ~/.ssh/id_ed25519.pub

# Start with key
dev-sandbox --ssh-port 2228 --ssh-key ~/.ssh/id_ed25519.pub

# From another terminal — connects without password
ssh -p 2228 dev@localhost
```

### VS Code Remote SSH

VS Code Remote SSH requires `--no-krun` and an SSH config entry for passwordless connection.

**1. Add SSH config on host** (`~/.ssh/config`):

```
Host sandbox
    HostName localhost
    Port 2228
    User dev
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

`StrictHostKeyChecking no` and `UserKnownHostsFile /dev/null` prevent host key warnings (keys regenerate between rebuilds).

**2. Start sandbox:**

```bash
dev-sandbox --no-krun --ssh-port 2228 --ssh-key ~/.ssh/id_ed25519.pub
```

**3. Connect in VS Code:**
- `Ctrl+Shift+P` → `Remote-SSH: Connect to Host`
- Select `sandbox`
- VS Code opens inside the container

**4. Verify:**
- Terminal in VS Code shows `[claude] /app/...`
- File explorer shows project files

## 5. Network Modes

### Open (default) — full internet

```bash
dev-sandbox

# Inside container
curl -s https://api.github.com | head -5      # works
```

### Locked — no outbound traffic

```bash
dev-sandbox --no-krun --net locked

# Inside container
curl -s --connect-timeout 3 https://google.com    # fails

# Localhost still works
ss -tlnp                                           # shows listening services

# Verify firewall rules
sudo nft list ruleset
# table inet filter {
#   chain output {
#     policy drop;
#     ct state established,related accept
#     oif "lo" accept
#   }
# }
```

### Filtered — allow specific destinations only

```bash
dev-sandbox --no-krun --allow host.containers.internal:1080

# Inside container
curl -s --connect-timeout 3 https://google.com    # fails (not allowed)

# Only allowed destination works
# (if you have something listening on host:1080)
```

### Filtered with multiple destinations

```bash
dev-sandbox --no-krun \
    --allow host.containers.internal:1080 \
    --allow host.containers.internal:22

# Both destinations allowed, everything else blocked
```

### Filtered with DNS

By default, filtered mode blocks DNS too (all traffic goes through SOCKS proxy).
Use `--allow-dns` for direct DNS:

```bash
# Auto-discover resolvers from /etc/resolv.conf
dev-sandbox --no-krun --allow host.containers.internal:443 --allow-dns

# Inside container
dig google.com                              # works (DNS allowed)
curl -s --connect-timeout 3 https://google.com   # still fails (only DNS allowed, not HTTPS)

# Or allow DNS to a specific resolver only
dev-sandbox --no-krun --allow host.containers.internal:443 --allow-dns 8.8.8.8

# Inside container
dig @8.8.8.8 google.com                    # works
dig @1.1.1.1 google.com                    # fails (only 8.8.8.8 allowed)
```

## 6. Privoxy Proxy Chain

Privoxy runs inside the container and forwards HTTP traffic through a SOCKS5
proxy on the host. DNS queries go through SOCKS too (`forward-socks5t`).

### Setup

```bash
# Terminal 1: Start a SOCKS5 proxy on host (e.g. microsocks)
microsocks -p 1080

# Terminal 2: Start sandbox with Privoxy
dev-sandbox --no-krun \
    --run-privoxy \
    --privoxy-socks host.containers.internal:1080

# Inside container
echo $HTTP_PROXY                # http://127.0.0.1:8118
echo $HTTPS_PROXY               # http://127.0.0.1:8118

# Test through proxy
curl -s https://api.github.com | head -5    # works through proxy chain
```

### Full lockdown with proxy

Force ALL traffic through the proxy — nothing bypasses:

```bash
dev-sandbox --no-krun \
    --allow host.containers.internal:1080 \
    --run-privoxy \
    --privoxy-socks host.containers.internal:1080

# Inside container
# With proxy → works (goes through SOCKS)
curl -s https://api.github.com | head -5

# Without proxy → blocked by firewall
curl -s --noproxy '*' --connect-timeout 3 https://google.com    # fails
```

Every connection visible on the host SOCKS proxy. DNS queries visible too
(forward-socks5t sends domain names through SOCKS, not raw IPs).

### Warning: Privoxy + --allow-dns

```bash
dev-sandbox --no-krun \
    --allow host:1080 \
    --run-privoxy --privoxy-socks host:1080 \
    --allow-dns

# ⚠ Both Privoxy and --allow-dns enabled — DNS queries bypass SOCKS proxy
```

This is intentional — warning reminds you that `--allow-dns` punches a hole
around the SOCKS chain that Privoxy was set up to enforce.

## 7. Conflict Detection

```bash
# --net locked + --allow → error
dev-sandbox --net locked --allow host:1080
# ✗ --net locked and --allow are mutually exclusive

# --net locked + --allow-dns → error
dev-sandbox --net locked --allow-dns
# ✗ --net locked and --allow-dns are mutually exclusive
```

## 8. Environment Variables

### Set a value

```bash
dev-sandbox --env OLLAMA_HOST=http://host.containers.internal:11434

# Inside container
echo $OLLAMA_HOST               # http://host.containers.internal:11434
```

### Pass through from host (no value in CLI)

```bash
# On host
export ANTHROPIC_API_KEY=sk-ant-your-key

# Pass through — key never appears in CLI or script
dev-sandbox --env ANTHROPIC_API_KEY

# Inside container
echo $ANTHROPIC_API_KEY          # sk-ant-your-key
```

### Multiple env vars

```bash
dev-sandbox \
    --env OLLAMA_HOST=http://host.containers.internal:11434 \
    --env ANTHROPIC_API_KEY \
    --env MY_CUSTOM_VAR=hello
```

### Missing host variable

```bash
dev-sandbox --env NONEXISTENT_VAR
# ⚠ --env NONEXISTENT_VAR not set on host — skipping
```

## 9. Resource Limits

```bash
# Custom RAM and CPU
dev-sandbox --ram 8192 --cpus 8

# Verify in startup output
# ▶ RAM/CPU: 8192 MiB / 8 cores

# Works for both krun and standard containers
dev-sandbox --no-krun --ram 2048 --cpus 2
```

## 10. krun vs Standard Container

### krun microVM (default)

```bash
dev-sandbox

# Inside container
uname -r                        # krun kernel (e.g. 6.12.91)
# Different from host kernel!
```

### Standard container

```bash
dev-sandbox --no-krun

# Inside container
uname -r                        # Same as host kernel
```

### krun + passt (automatic)

passt networking is enabled automatically when:
- SSH is **off** (no port mapping needed)
- Firewall is active (`--allow` or `--net locked`)

```bash
# SSH off → passt
dev-sandbox --ssh-port 0
# ▶ Starting krun microVM (passt)

# SSH on, open net → TSI (no passt)
dev-sandbox --ssh-port 2228
# ▶ Starting krun microVM

# SSH on + firewall → passt + warning
dev-sandbox --ssh-port 2228 --net locked
# ⚠ Firewall requires passt — SSH port mapping disabled
```

## 11. Active Session Detection

```bash
# Terminal 1: Start a sandbox
cd ~/my-project && dev-sandbox

# Terminal 2: Try to start another on the same directory
cd ~/my-project && dev-sandbox
# ✗ Session already active: claude-my-project-5a6f3f
# ✗ Use --force to kill and restart, or dev-sandbox ls to see all sessions

# Force restart
dev-sandbox --force
# ⚠ Killing active session: claude-my-project-5a6f3f
# ▶ Starting krun microVM ...
```

## 12. List Running Sandboxes

```bash
dev-sandbox ls
# ▶ Running sandboxes:
#   claude-my-project-5a6f3f  Up 2 hours  ssh:2228->22
```

## 13. Port Conflict Detection

```bash
# If another process uses the SSH port
dev-sandbox --ssh-port 22
# ✗ Port 22 already in use
# ✗ Another sandbox running? Check: dev-sandbox ls
```

## 14. Sudo Password Security

The sudo password is generated on the host and only the hash enters the container.

```bash
dev-sandbox
```

**On HOST terminal (before container starts):**
```
✓ sudo: aB3kM9xPqR2wYh7n         ← visible only here
```

**Inside container — verify password is NOT accessible:**
```bash
# No plaintext file
ls /tmp/.s-token                  # No such file

# No password in environment
env | grep -i pass                # nothing
env | grep -i sudo                # nothing
env | grep -i hash                # nothing (hash is in PID 1 env, not dev's)

# sudo works with the password you saw on host
sudo ls /                         # asks for password, type from memory

# sudo asks EVERY time (no caching)
sudo ls /                         # asks again immediately
```

## 15. Prompt Colors

Profiles have color-coded prompts so you always know which sandbox you're in:

```bash
dev-sandbox                      # [claude] ~/project$     ← green
dev-sandbox -p research          # [research] ~/project$   ← red
```

Colors reset automatically when you exit — your host prompt returns to normal.

## 16. Cleanup

### Remove profile image only (keep data)

```bash
dev-sandbox clean
# ✓ Image claude-sandbox-krun removed
# ⚠ Volumes not removed (contain data):
#   podman volume rm claude-sandbox-local claude-sandbox-rootconf
#   ...
```

### Full purge (remove everything)

```bash
dev-sandbox clean --purge
# ✓ Image claude-sandbox-krun removed
# ✓ Volume claude-sandbox-local removed
# ✓ Volume claude-sandbox-rootconf removed
# ✓ Volume claude-sandbox-claude removed
# ✓ Volume claude-sandbox-cache removed
```

### Manual cleanup with podman

```bash
# See what sandbox created
podman images | grep sandbox
podman volume ls | grep sandbox

# Remove specific volume
podman volume rm claude-sandbox-local

# Remove all sandbox images
podman rmi $(podman images --filter "reference=*sandbox*" -q)

# Nuclear option — remove everything podman
podman system prune --all --volumes
```

## 17. Rebuild After Config Changes

When you change the script configuration:

```bash
# Changed base packages → full rebuild
rm -rf ~/.dev-sandbox
dev-sandbox build -f

# Changed profile config → profile rebuild
rm -rf ~/.dev-sandbox/claude
dev-sandbox build -f

# Changed startup hooks or wrappers → delete rootconf
podman volume rm claude-sandbox-rootconf
dev-sandbox                     # regenerates on next run

# Changed dotfiles → delete pip volume (loses pip packages too)
podman volume rm claude-sandbox-local
dev-sandbox                     # regenerates on next run
```

## 18. Verify Image and Volume State

```bash
# Check images
podman images | grep sandbox
# dev-sandbox-base       latest   abc123   1.6GB
# claude-sandbox-krun    latest   def456   1.8GB

# Check volumes
podman volume ls | grep sandbox
# claude-sandbox-local
# claude-sandbox-rootconf
# claude-sandbox-claude
# claude-sandbox-cache

# Check disk usage
podman system df
```

## 20. Info Command

Shows resolved settings for a profile (after defaults and overrides are applied):

```bash
dev-sandbox info
dev-sandbox -p research info
```

**What to expect:**
- Runtime settings (USE_KRUN, RAM, CPUS)
- Network settings (NET_MODE, RUN_PRIVOXY, PRIVOXY_SOCKS)
- Services (SSH_PORT, SSH_KEY, COLOR)
- Volumes list with volume names
- Agents and extra DNF packages

## 21. Version

```bash
dev-sandbox --version
# dev-sandbox v1.1.0
```

## 22. TSI Override

Force TSI networking even when passt would normally be selected:

```bash
dev-sandbox --tsi --ssh-port 0
```

**What to expect:**
- Shows "Starting krun microVM (TSI, forced)" instead of "(passt)"
- nftables firewall will NOT work (TSI bypasses it)
- Useful for testing TSI-specific behavior

## 23. Port-Only Allow

Allow a port to any destination (no host specified):

```bash
dev-sandbox --no-krun --allow :8000
```

**What to expect:**
- `▶ Firewall: allowed → *:8000`
- Connections to port 8000 on any IP work
- All other ports blocked

Also works without colon:

```bash
dev-sandbox --no-krun --allow 8000
# Same result: ▶ Firewall: allowed → *:8000
```

## 24. Environment Variable Passthrough

Pass a variable from host without putting the value in CLI:

```bash
# Set on host
export TEST_SECRET=mysecretvalue

# Pass through — value never in CLI history
dev-sandbox --env TEST_SECRET
```

**Inside container:**
```bash
echo $TEST_SECRET               # mysecretvalue
```

**Missing variable:**
```bash
dev-sandbox --env NONEXISTENT
# ⚠ --env NONEXISTENT not set on host — skipping
```

## 25. Unknown Command Detection

```bash
dev-sandbox eeee
# ✗ Unknown command: eeee
# ✗ Run 'dev-sandbox help' for usage

dev-sandbox vncgui
# ✗ Did you mean: dev-sandbox -p vncgui

dev-sandbox --typo
# ✗ Unknown option: --typo
# ✗ Run 'dev-sandbox help' for usage
```

## 26. Argument Formats

Both formats work for all options with values:

```bash
dev-sandbox --ssh-port 2228         # space separated
dev-sandbox --ssh-port=2228         # equals sign

dev-sandbox --ram 8192
dev-sandbox --ram=8192

dev-sandbox -p claude
dev-sandbox -p=claude
```

## 27. Podman Management

### List sandbox resources

```bash
# Images
podman images | grep sandbox
# REPOSITORY                    TAG       IMAGE ID      SIZE
# localhost/dev-sandbox-base    latest    abc123def     1.6 GB
# localhost/claude-sandbox-krun latest    def456abc     1.8 GB

# Volumes
podman volume ls | grep sandbox
# local   claude-sandbox-local
# local   claude-sandbox-rootconf
# local   claude-sandbox-claude
# local   claude-sandbox-cache

# Running containers
podman ps | grep sandbox

# Disk usage
podman system df
```

### Remove specific resources

```bash
# Remove profile image (keep volumes)
podman rmi claude-sandbox-krun

# Remove specific volume
podman volume rm claude-sandbox-local

# Remove rootconf (regenerates startup hooks, wrappers on next run)
podman volume rm claude-sandbox-rootconf

# Remove local volume (regenerates dotfiles, loses pip packages and history)
podman volume rm claude-sandbox-local
```

### Remove all sandbox resources

```bash
# All sandbox images
podman rmi $(podman images --filter "reference=*sandbox*" -q) 2>/dev/null

# All sandbox volumes
podman volume ls --format "{{.Name}}" | grep sandbox | xargs -r podman volume rm

# Or use dev-sandbox clean
dev-sandbox clean                    # image + scaffold only
dev-sandbox clean --purge            # image + scaffold + volumes

# Nuclear option — remove everything podman
podman system prune --all --volumes
```

### Inspect volume contents

```bash
# Rootless podman uses user namespaces — need podman unshare to access
podman unshare ls ~/.local/share/containers/storage/volumes/claude-sandbox-local/_data/

# Interactive shell with volume access
podman unshare bash
```

### Rebuild scenarios

```bash
# Changed base packages → full rebuild
rm -rf ~/.dev-sandbox
dev-sandbox build -f

# Changed profile packages/agents → profile rebuild
rm -rf ~/.dev-sandbox/claude
dev-sandbox build -f

# Changed startup hooks or wrappers → delete rootconf
podman volume rm claude-sandbox-rootconf
dev-sandbox                    # regenerates on next run

# Changed dotfiles → delete local volume
podman volume rm claude-sandbox-local
dev-sandbox                    # regenerates on next run

# Fresh start — everything
dev-sandbox clean --purge
rm -rf ~/.dev-sandbox
dev-sandbox build -f
```

## Troubleshooting

### "crun-krun not installed"

```bash
sudo dnf install crun-krun
```

### "Port already in use"

```bash
dev-sandbox ls                   # check running sandboxes
ss -tlnp | grep 2228            # check what uses the port
dev-sandbox --force              # kill and restart
```

### SSH "Connection reset by peer"

Check if krun + passt is active. SSH port mapping doesn't work with passt.
Use `--no-krun` or `--ssh-port 0`:

```bash
dev-sandbox --no-krun --ssh-port 2228    # SSH works
```

### Firewall rules have no effect

krun's TSI networking bypasses nftables. Either:
- Use `--no-krun` for working firewall
- Or use `--allow` which automatically enables passt

### "tty: ttyname error"

Cosmetic warning from krun. Harmless, does not affect functionality.

### Container starts but no prompt

Check for entrypoint errors:

```bash
podman logs $(podman ps -lq)
```

### Lost sudo password

Exit and restart — a new password is generated each time:

```bash
exit
dev-sandbox                      # new password displayed
```
