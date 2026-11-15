# run_ssh_proxy.sh — dev-sandbox config: SSH SOCKS5 tunnel for --proxy.
# Usage: dev-sandbox --config run_ssh_proxy.sh --proxy 1080
#
# SECURITY: 0.0.0.0 exposes the SOCKS5 proxy on all host interfaces (LAN included).
 
RUN_SSH_PROXY_REMOTE="${RUN_SSH_PROXY_REMOTE:-localhost}"
RUN_SSH_PROXY_BIND="${RUN_SSH_PROXY_BIND:-0.0.0.0}"   # 0.0.0.0 so the container can reach it
 
_proxy_pre() {
    [[ -n "${PROXY_SHORTCUT:-}" ]] || return 0
    _RUN_SSH_PROXY_CTL=$(mktemp -u "${XDG_RUNTIME_DIR:-/tmp}/ds-proxy.XXXXXX.ctl")
    ssh -fN -M -S "$_RUN_SSH_PROXY_CTL" -D "${RUN_SSH_PROXY_BIND}:${PROXY_SHORTCUT}" \
        -o ExitOnForwardFailure=yes \
        -o ServerAliveInterval=30 "$RUN_SSH_PROXY_REMOTE" \
        || { warn "proxy: SSH tunnel to ${RUN_SSH_PROXY_REMOTE} failed"; _RUN_SSH_PROXY_CTL=""; }
}
 
_proxy_post() {
    [[ -n "${_RUN_SSH_PROXY_CTL:-}" ]] || return 0
    ssh -S "$_RUN_SSH_PROXY_CTL" -O exit "$RUN_SSH_PROXY_REMOTE" 2>/dev/null || true
    _RUN_SSH_PROXY_CTL=""
}
 
PRE_RUN_HOOKS+=(_proxy_pre)
POST_RUN_HOOKS+=(_proxy_post)
