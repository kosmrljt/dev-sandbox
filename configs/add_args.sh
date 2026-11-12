# ─────────────────────────────────────────────────────────────────────────────
# add_args.sh — dev-sandbox config: extra podman run flags for one session
# ─────────────────────────────────────────────────────────────────────────────
#
# PURPOSE
#   Add podman flags ad hoc (port publishing while testing, an extra mount, ...)
#   without editing a profile. Nothing persists between runs.
#
# USAGE
#   ADD_PODMAN_ARGS='-p 127.0.0.1:8080:8080' dev-sandbox --config add_args
#   ADD_PODMAN_ARGS='-p 127.0.0.1:8080:8080 -v /tmp/data:/data:ro' dev-sandbox --config add_args
#   ADD_PODMAN_ARGS='--label "note=my test"' dev-sandbox --config add_args   # quotes work
#
# Quoting follows xargs rules ('...' and "..." group words); nothing is
# expanded or executed. The flags are appended after the profile's own
# flags, just before the image name.

_add_args_pre() {
    [[ -n "${ADD_PODMAN_ARGS:-}" ]] || return 0
    local out
    local -a add=()
    out=$(xargs -r printf '%s\n' <<< "$ADD_PODMAN_ARGS" 2>/dev/null) \
        || { err "add_args: cannot parse ADD_PODMAN_ARGS (unbalanced quotes?)"; exit 1; }
    [[ -n "$out" ]] || return 0
    mapfile -t add <<< "$out"
    info "  Extra podman args: ${add[*]}"
    HOOK_PODMAN_ARGS+=("${add[@]}")
}

PRE_RUN_HOOKS+=(_add_args_pre)
