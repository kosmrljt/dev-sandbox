# Architecture

## System overview

```mermaid
graph TB
    subgraph Host
        Script[dev-sandbox.sh]
        Script -->|scaffold| Files[Dockerfile + entrypoint.sh]
        Script -->|build| Base[Base Image<br/>fedora:44 + packages]
        Base --> Claude[claude-sandbox-krun]
        Base --> Research[research-sandbox-krun]
        Base --> Agy[agy-sandbox-krun]
        Base --> VNC[vncgui-sandbox-krun]

        Script -->|run| Container

        subgraph Container [krun microVM or standard container]
            Entry[entrypoint.sh — PID 1, root]
            Entry --> Sudo[Set sudo password from hash]
            Entry --> Chown[Fix volume ownership]
            Entry --> Hooks[Run startup hooks + install wrappers]
            Entry --> Dotfiles[Generate dotfiles — first run]
            Entry --> SSHD[sshd — if configured]
            Entry --> Privoxy[Privoxy — if configured]
            Entry --> FW[nftables firewall — if configured]
            Entry --> Switch[Drop to dev user → bash]
        end

        subgraph Volumes [Named volumes — persist between sessions]
            V1["pip — ~/.local"]
            V2["rootconf — /etc/sandbox"]
            V3["credentials — ~/.claude, ~/.gemini"]
            V4["cache — ~/.cache"]
        end

        Container -.-> Volumes
        Project[Project directory] -->|bind mount| Container
    end
```

## Image layers

```mermaid
graph TB
    F[fedora:44] --> B[dev-sandbox-base<br/>packages, SSH, Privoxy, user setup]
    B --> C[claude-sandbox-krun<br/>Claude Code]
    B --> R[research-sandbox-krun<br/>template — add your agents]
    B --> A[agy-sandbox-krun<br/>Antigravity]
    B --> V[vncgui-sandbox-krun<br/>XFCE, TigerVNC, Java]
```

Base image is built once and shared. Profile images add only agent-specific packages. Layers are deduplicated — total disk usage is much less than the sum of image sizes.

## Network modes

```mermaid
graph LR
    subgraph Open ["--net open (default)"]
        A1[App] --> I1[Internet]
    end

    subgraph Locked ["--net locked"]
        A2[App] --> B2[nftables<br/>policy drop]
        B2 -.-x I2[Internet]
    end

    subgraph Filtered ["--allow [host:]port"]
        A3[App] --> P3[Privoxy :8118]
        P3 --> S3[SOCKS5 on host]
        S3 --> I3[Internet]
        A3 -.-x|blocked| I3
    end
```

With `--allow`, nftables drops all outbound traffic except loopback and explicitly allowed destinations. When Privoxy is enabled with `forward-socks5t`, DNS queries also go through the SOCKS proxy — nothing leaks. Use `--allow-dns` to optionally allow direct DNS.

### Allow formats

```
--allow host.containers.internal:1080   Host + port
--allow :8000                           Port only (any destination)
--allow 8000                            Port only (short form)
```

## krun networking

```mermaid
graph TD
    subgraph TSI ["TSI — default when SSH is on"]
        App1[App] -->|socket syscall| VMM1[VMM proxy]
        VMM1 --> Net1[Host network]
        FW1[nftables] -.->|bypassed| VMM1
    end

    subgraph Passt ["Passt — when firewall active or SSH off"]
        App2[App] -->|socket| Kern[VM kernel]
        Kern --> NFT[nftables]
        NFT --> Virtio[virtio-net]
        Virtio --> Passt2[passt]
        Passt2 --> Net2[Host network]
    end
```

### TSI (Transparent Socket Impersonation)

Default krun networking. VMM intercepts socket system calls and proxies them directly through the host. Fast, but nftables rules inside the VM have no effect — traffic never reaches the kernel network stack.

Limitation: stalls under many concurrent connections (~3 conn/s). Loading a web portal with many resources may hang.

### Passt

Creates a virtual network interface (eth0) inside the VM. Traffic flows through the kernel's netfilter, so nftables works. Automatically enabled when:

- SSH is off (no port mapping needed)
- Firewall is active (`--allow` or `--net locked`)

Limitation: Podman `-p` port mapping does not work with passt. SSH server inside the VM cannot be reached from the host.

Force TSI for testing: `dev-sandbox --tsi`

## krun microVM vs standard container

| | krun microVM | Standard container |
|---|---|---|
| Isolation | Own kernel (VM boundary) | Shared kernel (namespaces) |
| Networking | passt or TSI | Standard podman networking |
| nftables firewall | Works with passt | Works natively |
| SSH port mapping | TSI only (not passt) | Works |
| Container escape | Requires VM escape (hard) | Requires namespace escape (easier) |
| `podman exec` | Not supported | Works |
| Overhead | ~200ms startup, fixed RAM | Minimal |

## Entrypoint sequence

1. Set sudo password from host-provided hash
2. Fix volume ownership (skip `.` and `..`)
3. Generate defaults in rootconf volume (first run only)
4. Run root startup hook (`/etc/sandbox/startup.sh`)
5. Install command wrappers to `/usr/local/bin/`
6. Generate dev dotfiles in `~/.local/etc/` (first run only)
7. Start sshd (if configured)
8. Start Privoxy (if configured)
9. Configure nftables firewall (if configured)
10. Switch to dev user → bash

## Key Podman parameters

| Parameter | Purpose |
|---|---|
| `--annotation run.oci.handler=krun` | Use krun microVM runtime |
| `--annotation krun.ram_mib=N` | VM memory limit in MiB |
| `--annotation krun.cpus=N` | VM CPU cores |
| `--annotation krun.use_passt=1` | Use passt networking |
| `--userns keep-id` | Map host UID to container UID 1:1 |
| `--security-opt label=disable` | Disable SELinux labeling |
| `--cap-add NET_ADMIN` | Allow firewall rules (only when needed) |
| `--tmpfs /path:opts` | RAM-backed filesystem (cleared on exit) |
| `-v name:/path` | Named volume (persists between runs) |
| `-v /host/path:/path` | Bind mount (project directory) |
| `-p host:container` | Port mapping (SSH server) |
