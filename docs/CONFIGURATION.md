# Configuration

All configuration lives in `dev-sandbox.sh`. Common settings and sensible defaults
apply to every profile; a profile overrides only what differs. External files loaded
with `--config` can add profiles or layer behavior without touching the script.

- [Priority chain](#priority-chain)
- [Build model](#build-model)
- [Profile variables](#profile-variables)
- [Environment variable overrides](#environment-variable-overrides)
- [What persists between sessions](#what-persists-between-sessions)
- [Adding a new profile](#adding-a-new-profile)
- [External config files](#external-config-files)
- [Rebuilding](#rebuilding)
- [CLI reference](#cli-reference)
- [Connecting to host services](#connecting-to-host-services)

---

## Priority chain

For any setting, the first source that provides a value wins:

```
CLI flag  >  PROFILE_<profile>_<VAR>  >  environment variable  >  DEFAULT_<VAR>
```

Worked example for RAM (each line is the result when that is the highest source set):

```
dev-sandbox --ram 8192        → 8192    (CLI flag wins over everything)
PROFILE_<p>_RAM=6144          → 6144    (profile, when no flag)
DEV_SANDBOX_RAM=16384         → 16384   (environment, feeds DEFAULT_RAM)
(nothing set)                 → 4096    (DEFAULT_RAM)
```

Settings are resolved per run, so changing a runtime one takes effect on the next
`dev-sandbox` with no rebuild. See [Rebuilding](#rebuilding) for the ones that don't.

---

## Build model

`dev-sandbox build` builds two images:

- **Base image** — `dev-sandbox-base`, shared by every profile. Base OS,
  `BASE_DNF_PACKAGES`, `BASE_EXTERNAL_TOOLS`, the `dev` user (same UID as you, via
  `--userns keep-id`), plus sudo and sshd setup.
- **Profile image** — `<profile>-sandbox-image`. `FROM` the base, then the profile's
  `DNF` and `TOOLS` (as **root**), then `AGENTS` (as **dev**), then the generated
  entrypoint.

At container start the entrypoint runs first as **root** — it writes wrappers,
`startup.sh` and dotfiles into the volumes (only if they don't exist yet), and sets up
SSH/Privoxy/firewall — then switches to **dev** for your session. Your project
directory is bind-mounted, and because `dev` shares your host UID, files there are
yours without any `chmod`.

Who applies each variable, and where it ends up:

| Variable | Applied | As user | Lands in |
|---|---|---|---|
| `DNF`, `TOOLS` | build | root | image |
| `AGENTS` | build | dev | image → seeded into the `.local`/agent volume on first run |
| `ROOT_STARTUP`, `ROOT_WRAPPERS` | container start | root | `/etc/sandbox` (rootconf volume), written only if absent |
| `DEV_DOTFILES` | container start | root (chown dev) | `~/.local/etc` (local volume), written only if absent |
| everything else | container start | — | `podman run` flags / container env (nothing stored) |

Two consequences that trip people up (both handled in [Rebuilding](#rebuilding)):

- `AGENTS` install into volume-mounted paths (`~/.local`, `~/.claude`), so the first
  run seeds the volume from the image; afterwards the **volume wins**. Updating an
  agent through a rebuild needs the volume purged — or let the agent self-update.
- `ROOT_WRAPPERS` / `ROOT_STARTUP` / `DEV_DOTFILES` are written to their volume only
  if the file isn't there yet, so a rebuild alone won't refresh them. Delete the stale
  file from the volume (or `clean --purge`) and the next run regenerates it.

---

## Profile variables

Every setting follows the `DEFAULT_<NAME>` / `PROFILE_<profile>_<NAME>` pattern: set
`DEFAULT_<NAME>` to change it everywhere, or `PROFILE_<profile>_<NAME>` for one profile.

**Runtime & isolation**

| Variable | Default | Purpose |
|---|---|---|
| `USE_KRUN` | `true` | krun microVM (stronger isolation) vs. a standard container (`false`; needed for device passthrough, GUI, SSH port mapping). |
| `RAM` | `4096` | Memory in MiB. A hard VM limit under krun, otherwise `--memory`. |
| `CPUS` | *(empty)* | CPU cores. Empty = no limit (krun uses `nproc`). |
| `COLOR` | `0` | ANSI prompt color (`32` green, `31` red, `33` yellow, `34` blue, `35` magenta). Marks trusted vs. untrusted profiles at a glance. |
| `DESCRIPTION` | — | Shown by `profiles` / `status` / `info`. |

**Network**

| Variable | Default | Purpose |
|---|---|---|
| `NET_MODE` | `open` | `open`, `locked` (loopback only), or `filtered` (allow-list via `--allow`). |
| `RUN_PRIVOXY` | `false` | Run Privoxy (HTTP → SOCKS5) on `:8118`. |
| `PRIVOXY_SOCKS` | `host.containers.internal:1080` | Upstream SOCKS for Privoxy. |

**Services**

| Variable | Default | Purpose |
|---|---|---|
| `SSH_PORT` | `0` | `0` = no SSH. A port opens sshd on `127.0.0.1:<port>`. (Under krun, SSH port mapping and the firewall are mutually exclusive — see the script's notes.) |
| `SSH_KEY` | *(empty)* | Public key for passwordless SSH, e.g. `~/.ssh/id_ed25519.pub` (only with `SSH_PORT` > 0). |

**Environment**

| Variable | Default | Purpose |
|---|---|---|
| `ENV` | `()` | Variables set inside the container, as `KEY=VALUE` (values live in the config). |
| `ENV_PASS` | `()` | Variables forwarded **from the host**, as `KEY` only (keeps secrets out of the script). |

**Storage**

| Variable | Default | Purpose |
|---|---|---|
| `VOLUMES` | `(.cache)` | Which `~/.<name>` dirs are persistent named volumes. Credentials, caches and settings go here. |
| `PODMAN_ARGS` | tmpfs for `/var/log`, `/tmp` | Raw `podman run` flags (tmpfs, `-p`, `--device`, `--shm-size`). Static — resolved when the profile is read. For run-time/dynamic flags, see [Run hooks](#run-hooks-prepost-run). |

**Build — baked into the image (needs a rebuild)**

| Variable | Default | Purpose |
|---|---|---|
| `DNF` | `()` | Extra dnf packages for this profile (installed as root). |
| `TOOLS` | `()` | Arbitrary root install commands at build time (e.g. `bash /opt/ctx/setup-root.sh`). |
| `AGENTS` | `()` | Agent install commands, run as `dev` (e.g. `curl … | bash`). |

**In-container behavior — written to a volume on first start**

| Variable | Default | Purpose |
|---|---|---|
| `ROOT_STARTUP` | `''` | Bash sourced as root on every start (file written once, to `/etc/sandbox/startup.sh`). For root-level setup: restoring config, preparing dirs, launching services. |
| `ROOT_WRAPPERS` | `()` | `name\|body` entries → `/usr/local/bin/<name>` wrapper commands (e.g. the `claude` launcher). Early on `PATH`. |
| `DEV_DOTFILES` | `bashrc.local`, `tmux.conf` | `name\|body` entries → `~/.local/etc/<name>`, loaded into each dev session. |

The profile registry is `ALL_PROFILES=(…)`; its first entry is the default profile.
Built-in profiles: `claude`, `agy`, `research`, `vncgui`.

---

## Environment variable overrides

A few settings can be changed for a single run without editing the script:

```bash
DEV_SANDBOX_RAM=8192 dev-sandbox                    # memory (MiB)
DEV_SANDBOX_CPUS=8   dev-sandbox                    # CPU cores
DEV_SANDBOX_STORAGE="/mnt/disk2/podman" dev-sandbox # podman storage root
```

For arbitrary variables inside the container, use the CLI:

```bash
dev-sandbox --env KEY=VALUE                 # set a value
dev-sandbox --env KEY                        # forward KEY from the host
```

---

## What persists between sessions

| Data | Where | Persists? |
|---|---|---|
| Project files | bind mount `/app/<dir>` ↔ your working directory | yes, on the host |
| pip/npm globals, scripts, dotfiles (`~/.local/etc`), bash history, seeded agent binaries | `<profile>-sandbox-local` volume → `~/.local` | yes |
| SSH host keys, `startup.sh`, wrappers, Privoxy config, generated `env.sh`, config backup | `<profile>-sandbox-rootconf` volume → `/etc/sandbox` | yes |
| Agent credentials, caches, settings (`.claude`, `.gemini`, `.cache`, …) | `<profile>-sandbox-<name>` volumes → `~/.<name>` | yes |
| System (dnf) packages | the image | only by editing the profile and rebuilding |
| Anything else outside `/app` and the mounted `~/…` paths | — | lost on exit (`--rm`) |

`env.sh` is regenerated on every start, so it always reflects the current `ENV` /
proxy / color settings.

---

## Adding a new profile

Minimal profile — a description and an agent:

```bash
PROFILE_test_DESCRIPTION="My test sandbox"
PROFILE_test_AGENTS=('pip install --user aider-chat')

ALL_PROFILES=(claude agy research vncgui test)   # register it (first entry = default)
```

Override any `DEFAULT_*` as needed:

```bash
PROFILE_test_COLOR="33"
PROFILE_test_SSH_PORT=2232                                   # enable SSH (0 = off)
PROFILE_test_DNF=(htop strace)
PROFILE_test_VOLUMES=(.cache .config)
PROFILE_test_ENV=("OLLAMA_HOST=http://host.containers.internal:11434")
PROFILE_test_ENV_PASS=("ANTHROPIC_API_KEY")                 # forwarded from the host
```

Build and run:

```bash
dev-sandbox -p test build -f
dev-sandbox -p test
```

---

## External config files

Keep profiles or site policies in separate files instead of editing the script.

> ⚠️ **Security:** a config file is a bash script sourced on the **host**, before the
> container starts — not inside the sandbox. A config from an untrusted source can run
> anything as you: read your files, change your sudo rules, install software. Only load
> configs you trust.

### Usage

```bash
dev-sandbox --config ~/my-configs/devhw.sh          # by path
cp devhw.sh ~/.dev-sandbox/ && dev-sandbox --config devhw.sh   # install, then by name
dev-sandbox --config devhw.sh -p devhw              # a profile config
dev-sandbox --config base.sh --config agents.sh     # repeatable / composable
```

### How it works

The file is **sourced** at the very top, before argument parsing and profile
validation. It can therefore define `PROFILE_<name>_*` variables, override any
`DEFAULT_*`, change `ALL_PROFILES`, and register [run hooks](#run-hooks-prepost-run).

### Config file lookup

The name is resolved as given, then with `.sh` and `.conf` appended — each tried in
the current directory first, then in `~/.dev-sandbox/`:

```
myconfig → ./myconfig → ./myconfig.sh → ./myconfig.conf
         → ~/.dev-sandbox/myconfig → ~/.dev-sandbox/myconfig.sh → ~/.dev-sandbox/myconfig.conf
```

So `--config run_proxy` finds `./run_proxy.sh` or `~/.dev-sandbox/run_proxy.conf`.

### Two types of config files

- **Profile config** — defines a profile (`PROFILE_<name>_*`) and adds it to
  `ALL_PROFILES`; pick it with `-p <name>`. Examples: `configs/devhw.sh` (USB, camera,
  Wayland), `configs/decompile.sh` (reverse-engineering toolchain).
- **Add-on config** — defines no profile; it layers behavior onto whatever profile you
  run. Two ways to do that:
  - *container-side* via `ROOT_WRAPPERS` / `ROOT_STARTUP` — e.g. `configs/_git-guard.sh`
    intercepts `git` to block `push`, `tag`, branch creation, `reset --hard` and
    `clean -f`.
  - *host-side* via [run hooks](#run-hooks-prepost-run) — e.g. `configs/run_proxy.sh`
    (SSH SOCKS5 tunnel), `configs/bg_color.sh` (terminal background tint).

Combine freely — `dev-sandbox --config devhw.sh --config _git-guard.sh` — and because
add-ons register by unique name, several coexist. `dev-sandbox -p <p> info` shows the
resolved settings so you can confirm what a config changed.

### Run hooks (pre/post-run)

A config can register functions that run around the container:

```bash
PRE_RUN_HOOKS+=(my_pre)    # runs just before `pcmd run`, $1 = profile
POST_RUN_HOOKS+=(my_post)  # runs after the container exits (also on Ctrl-C)
```

A pre-run hook may append podman flags to `HOOK_PODMAN_ARGS`, which are spliced into
`pcmd run` before the image name. These are **global** (every profile) and **dynamic**
(resolved at run time — e.g. a path from `mktemp`), unlike the static per-profile
`PROFILE_<p>_PODMAN_ARGS`. A pre-run error aborts the run; a post-run error is only
reported, and the remaining hooks still run (teardown is registered before the hooks,
so cleanup happens even if a pre-run hook fails).

Minimal example:

```bash
_my_pre()  { _MY_DIR=$(mktemp -d); HOOK_PODMAN_ARGS+=(-v "${_MY_DIR}:/run/sandbox"); }
_my_post() { rm -rf "${_MY_DIR:-/nonexistent}"; }
PRE_RUN_HOOKS+=(_my_pre)
POST_RUN_HOOKS+=(_my_post)
```

### Staging files into the image (`ctx/`)

If a `ctx/` directory sits next to the profile (`~/.dev-sandbox/<profile>/ctx`), the
build adds `COPY ctx /opt/ctx`, so real script files can be baked in and called from
`TOOLS` / `AGENTS` (e.g. `TOOLS=("bash /opt/ctx/setup-root.sh")`). A config can stage
it on load (`cp -a mysrc/. ctx/`); changing `ctx/` changes the build context, so the
image rebuilds.

### Tips

- `ALL_PROFILES=(devhw)` makes a config self-contained (only its profile is offered);
  `ALL_PROFILES=(claude devhw research)` adds to the built-ins.
- Keep secrets out of config files — forward them with `ENV_PASS` / `--env KEY`.
- An add-on config should do nothing unless its trigger is present (e.g. `run_proxy`
  only acts on `--proxy`), so it's safe to load by default.

---

## Rebuilding

What a change needs depends on where it lands (see [Build model](#build-model)):

| You changed | Needs | Also |
|---|---|---|
| `DNF` / `TOOLS` (profile packages) | `dev-sandbox -p <p> build` | — |
| `AGENTS` (agent version) | `dev-sandbox -p <p> build` | **purge** the `.local`/agent volume, or let the agent self-update |
| `ROOT_WRAPPERS` / `ROOT_STARTUP` / `DEV_DOTFILES` | `dev-sandbox -p <p> build` | **delete** the stale file from the rootconf/local volume (or `clean --purge`) |
| `BASE_DNF_PACKAGES` / `BASE_EXTERNAL_TOOLS` | `dev-sandbox build -f` | profile rebuilds on top |
| `VOLUMES`, `ENV`, `PODMAN_ARGS`, color, RAM, network, SSH, Privoxy, … | nothing | takes effect next run |

Commands:

```bash
dev-sandbox -p <profile> build        # rebuild profile (and base if missing)
dev-sandbox -p <profile> build -f     # rebuild without cache (--no-cache; rebuilds base too)
dev-sandbox -p <profile> clean        # remove the image (volumes kept)
dev-sandbox -p <profile> clean --purge # remove the image AND all volumes
```

To refresh one wrapper/startup/dotfile without purging the whole profile, delete just
that file from its volume, then run again:

```bash
podman volume rm <profile>-sandbox-rootconf   # or edit the single file instead (below)
# surgical: remove just one wrapper from the rootconf volume
podman run --rm -v <profile>-sandbox-rootconf:/x alpine rm -f /x/wrappers/<name>
dev-sandbox -p <profile>                      # entrypoint rewrites it on next start
```

> Removing the `*-sandbox-local` volume also deletes bash history and all pip/npm
> packages installed in the session. Agent credentials live in separate volumes
> (`.claude`, `.gemini`), so they survive unless you remove those too (or `clean --purge`).
> Your `~/.dev-sandbox/*.sh` config files are never touched by `clean`.

---

## CLI reference

```
dev-sandbox                           Start the default profile
dev-sandbox -p <profile>              Start a specific profile
dev-sandbox build [-f]                Build the profile image (-f: no cache)
dev-sandbox info                      Show the resolved settings for a profile
dev-sandbox profiles                  List configured profiles
dev-sandbox ls                        List running sandboxes
dev-sandbox status                    Image/volume health and system info
dev-sandbox clean [--purge]           Remove image (--purge: also volumes)
dev-sandbox --version                 Print version
dev-sandbox help                      Full help

-p <profile>            Select profile (default: first in ALL_PROFILES)
--config PATH           Source an external config/profile file (repeatable)
--krun | --no-krun      Force microVM / standard container
--tsi                   Force TSI networking (bypasses passt/firewall)
--ram MiB | --cpus N    Resource limits
--force                 Kill an existing session for this directory and restart
--net open | locked     Network mode
--allow host:port       Allow one egress destination (repeatable → filtered)
--allow-dns [host[:p]]  Allow DNS resolution
--proxy PORT            Route traffic via a host SOCKS5 proxy
--run-privoxy | --no-privoxy
--privoxy-socks host:p  Upstream SOCKS for Privoxy
--ssh-port PORT         Enable sshd on a host port
--ssh-key PATH          Install a public key for SSH
--env KEY=VALUE | --env KEY   Set / forward an environment variable (repeatable)
```

---

## Connecting to host services

From inside the container, reach a service listening on the host (a database, an LLM
server, a dev server) via the hostname `host.containers.internal`:

```bash
curl http://host.containers.internal:11434/api/tags   # host Ollama
psql -h host.containers.internal -U myuser mydb        # host PostgreSQL
getent hosts host.containers.internal                  # verify it resolves
```

This is also how `--proxy` / Privoxy reach the host SOCKS5 endpoint. Note that under
`--no-krun` the container has its own network namespace, so `localhost` /
`127.0.0.1` means the **container itself**, not the host — always use
`host.containers.internal` for host services.
