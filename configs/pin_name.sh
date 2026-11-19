# dev-sandbox config: pin the sandbox name for the current directory
#
# Usage (from the project directory):
#   dev-sandbox --config pin_name                      # name = computed <dir>-<hash>
#   DEV_SANDBOX_NAME="Moj projekt" dev-sandbox --config pin_name   # → Moj-projekt
#
# Creates .dev-sandbox/name if it does not exist yet; an existing file is never
# overwritten. Uses sandbox_default_name / sandbox_sanitize_name from
# dev-sandbox.sh, so the name is built exactly as dev-sandbox builds it.
#
# Runs when the config is loaded, not as a PRE_RUN hook: pre-run hooks run after
# dev-sandbox has already computed the container name, so the file would only
# take effect on the next start.

if ! declare -F sandbox_sanitize_name >/dev/null; then
    echo "✗ pin_name.sh must be loaded by dev-sandbox (--config pin_name)" >&2
    exit 1
fi

if [[ -f "$SANDBOX_NAME_FILE" ]]; then
    echo "Sandbox name: $(cat "$SANDBOX_NAME_FILE") (from $SANDBOX_NAME_FILE)"
else
    if [[ -n "${DEV_SANDBOX_NAME:-}" ]]; then
        _dsn_name="$(sandbox_sanitize_name "$DEV_SANDBOX_NAME")"
        if [[ -z "$_dsn_name" ]]; then
            echo "✗ DEV_SANDBOX_NAME contains no usable name: '$DEV_SANDBOX_NAME'" >&2
            exit 1
        fi
    else
        _dsn_name="$(sandbox_default_name "$(pwd)")"
    fi
    mkdir -p "$(dirname "$SANDBOX_NAME_FILE")"
    printf '%s\n' "$_dsn_name" > "$SANDBOX_NAME_FILE"
    echo "Created $SANDBOX_NAME_FILE: $_dsn_name"
    unset _dsn_name
fi
