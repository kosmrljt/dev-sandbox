# run_proxy.sh — dev-sandbox config: SSH SOCKS5 tunnel for --proxy.
# Usage: dev-sandbox --config run_proxy.sh --proxy 1080
#
# SECURITY: 0.0.0.0 exposes the SOCKS5 proxy on all host interfaces (LAN included).

REMOTE="${DEV_SANDBOX_PROXY_REMOTE:-localhost}"
BIND="${DEV_SANDBOX_PROXY_BIND:-0.0.0.0}"   # 0.0.0.0 so the container can reach it

_proxy_pre() {
    [[ -n "${PROXY_SHORTCUT:-}" ]] || return 0
    PROXY_CTL=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/ds-proxy.XXXXXX.ctl")
    ssh -fN -M -S "$PROXY_CTL" -D "${BIND}:${PROXY_SHORTCUT}" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 "$REMOTE" \
        || { warn "proxy: SSH tunnel to ${REMOTE} failed"; PROXY_CTL=""; }
}

_proxy_post() {
    [[ -n "${PROXY_CTL:-}" ]] || return 0
    ssh -S "$PROXY_CTL" -O exit "$REMOTE" 2>/dev/null || true
    PROXY_CTL=""
}

PRE_RUN_HOOKS+=(_proxy_pre)
POST_RUN_HOOKS+=(_proxy_post)
