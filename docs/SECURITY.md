# Security Model

dev-sandbox provides host isolation through krun microVMs and **best-effort network policy** through in-VM nftables. For full egress control, use a host-side proxy ([urllight](https://github.com/kosmrljt/urllight)) which cannot be bypassed from inside the VM.

## What is isolated

- **Filesystem**: Only the project directory is mounted. Agent cannot see `~/.ssh/`, `~/.aws/`, `~/Documents/`, or any other host directory.
- **Credentials**: Each profile has separate volumes. A compromised package in the research profile cannot read Claude API keys.
- **Kernel** (krun): The VM runs its own Linux kernel. Container escape requires a VM escape, not just a namespace escape.
- **Network** (when configured): nftables blocks outbound traffic except explicitly allowed destinations.

## What is NOT isolated

### Project directory is writable

The project directory is bind-mounted read-write. An agent can:

- Write `.git/hooks/pre-commit` → executes **on the host** when you run `git commit`
- Write `.envrc` → executes if you use `direnv`
- Modify `Makefile` → runs on host when you run `make`
- Modify `package.json` scripts → runs on host via `npm run`
- Write `.vscode/tasks.json` → runs in VS Code

**Mitigation**: Review changes in your project directory after sandbox sessions.

```bash
git diff                     # see what changed
git diff --stat              # overview
```

### Persistent volumes contain executable paths

These files persist across sessions and execute on every startup:

| File | Executes as | When |
|---|---|---|
| `~/.local/bin/*` | dev | When called by name |
| `~/.local/etc/bashrc.local` | dev | Every shell start |
| `/etc/sandbox/startup.sh` | root | Every container start |
| `/etc/sandbox/wrappers/*` | dev | When called by name |

A compromised session can plant code that runs on every subsequent start. The "I'll just restart the container" mental model does not fully apply.

**Mitigation**: For a clean start after a suspected compromise:

```bash
podman volume rm claude-sandbox-pip claude-sandbox-rootconf
dev-sandbox    # regenerates defaults from script
```

### sudo password

- Generated on the **host** before the container starts
- Only the hash enters the container via environment variable
- Hash is unset immediately after `usermod`
- No plaintext password inside the container — not in files, scrollback, or environment
- `timestamp_timeout=0` — sudo asks for password every time, no caching
- `~/.local/bin` is at the end of PATH — agent cannot plant a fake `sudo` wrapper that shadows the real one

An agent would need to:
1. Find the password (not in container)
2. Or brute-force the hash (very slow)
3. Or trick the user into typing it where the agent can capture it

### In-VM firewall is best-effort

nftables rules run inside the VM/container. With `sudo` access, they could theoretically be modified. Current mitigations:

- Password required for sudo (not cached, not in container)
- PATH ordered to prevent fake binary shadowing
- Agent cannot read password from scrollback (displayed on host only)

For host-level egress control, use a host-side proxy outside the VM. The `--allow` flag + Privoxy + host SOCKS proxy provides this:

```
Container → Privoxy :8118 → SOCKS5 host:1080 → Internet
         ↓ direct → nftables → DROP
```

Even if the agent bypasses nftables, it still needs a route to the internet. With `--allow host.containers.internal:1080` as the only allowed destination, the only path out is through the monitored proxy.

## Rootless Podman

Podman runs without root privileges. Key implications:

- **Container escape** gives the attacker your **user** permissions, not root
- This is the same for both krun and standard containers
- krun adds VM escape difficulty on top of container escape difficulty
- Neither grants root on the host

```
Docker escape           → root on host (very bad)
Podman rootless escape  → your user (bad, but not root)
krun VM escape          → your user (same result, harder to execute)
```

## Recommendations

| Scenario | Recommended setup |
|---|---|
| Trusted agent (Claude Code) | krun, SSH on, open internet |
| Testing unknown agent | krun, SSH off, `--allow` + Privoxy |
| Running untrusted pip packages | `--no-krun`, `--net locked` |
| Maximum paranoia | `--no-krun`, `--net locked`, review project after |
