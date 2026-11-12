# Security Model

dev-sandbox provides host isolation through Podman containers (optionally with krun microVMs) and best-effort network policy through in-VM nftables. For host-level egress control, use a host-side proxy ([sockLight](https://github.com/kosmrljt/socklight)) outside the VM.

## What is isolated

- **Filesystem**: Only the project directory is mounted. Agent cannot see `~/.ssh/`, `~/.aws/`, `~/Documents/`, or any other host directory.
- **Credentials**: Each profile has separate volumes. A compromised package in one profile cannot read credentials from another.
- **Kernel** (krun): The VM runs its own Linux kernel. Container escape requires a VM escape, not just a namespace escape.
- **Network** (when configured): nftables blocks outbound traffic except allowed destinations.

## Disabled host security modules

The script disables two host-level security mechanisms for compatibility:

- **SELinux** (`--security-opt label=disable`) — disabled to allow bind mounts without relabeling. On Fedora/RHEL systems, this removes SELinux type enforcement on the container.
- **AppArmor** (`--security-opt apparmor=unconfined`) — disabled for Ubuntu compatibility (rootless podman + crun requires it). On Ubuntu systems, this removes AppArmor confinement from the container process.

Both are applied unconditionally to all profiles. The primary isolation boundaries remain: filesystem (bind mount scoping), user namespace (rootless podman), and optionally the VM boundary (krun). These settings trade MAC-level confinement for broad compatibility.

## What is NOT isolated

### Project directory is writable

An agent can write files that execute on the host:

- `.git/hooks/pre-commit` → runs on `git commit`
- `.envrc` → runs with direnv
- `Makefile` targets → runs on `make`
- `package.json` scripts → runs on `npm run`
- `.vscode/tasks.json` → runs in VS Code

**Mitigation**: Review project directory changes after sessions (`git diff`).

**Disable git hooks on the host** to prevent execution of agent-planted hooks:

```bash
# Per-repo — disable hooks in this project
git config core.hooksPath /dev/null

# Global — disable hooks everywhere
git config --global core.hooksPath /dev/null

# Per-command — skip hooks for one operation
git -c core.hooksPath=/dev/null commit -m "message"

# Re-enable
git config --unset core.hooksPath
```

### Persistent volumes contain executable paths

| File | Runs as | When |
|---|---|---|
| `~/.local/bin/*` | dev | Called by name |
| `~/.local/etc/bashrc.local` | dev | Every shell start |
| `/etc/sandbox/startup.sh` | root | Every container start |
| `/etc/sandbox/wrappers/*` | dev | Called by name |

A compromised session can plant persistent code.

**Mitigation**: For a clean start: `podman volume rm <profile>-sandbox-local <profile>-sandbox-rootconf`

### sudo password

- Generated on the host, only hash enters the container
- Hash unset after `usermod` — not in dev environment
- `timestamp_timeout=0` — no credential caching
- `~/.local/bin` at end of PATH — agent cannot shadow system binaries

### In-VM firewall is best-effort

nftables rules run inside the VM/container. With sudo access, they could theoretically be modified. For host-level egress control, route traffic through a host-side proxy:

```
Container → Privoxy :8118 → SOCKS5 host:1080 → Internet
         → direct → nftables → DROP
```

Shortcut: `dev-sandbox --proxy 1080`

## Rootless Podman

Podman runs without root privileges:

```
Docker escape           → root on host
Podman rootless escape  → your user (not root)
krun VM escape          → your user (same result, harder to execute)
```

## Recommendations

| Scenario | Setup |
|---|---|
| Daily work with trusted agent | Default profile, open internet |
| Testing unknown agent | krun, SSH off, `--proxy 1080` |
| Running untrusted packages | `--net locked` |
| Maximum control | `--proxy 1080`, review project after session |
