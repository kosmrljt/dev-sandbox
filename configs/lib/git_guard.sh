#!/usr/bin/env bash
# lib/git-guard.sh

apply_git_guard_to_profile() {
    local prof="$1"

    # Inconspicuous name for the real git binary
    local real_git_name="git-bin-8472"
    local real_git_path="/usr/bin/${real_git_name}"

    # 1. ROOT_STARTUP hook (runs as root at container startup)
    local startup_snippet
    startup_snippet=$(cat <<EOF
if [ -f /usr/bin/git ] && [ ! -f "${real_git_path}" ]; then
    mv /usr/bin/git "${real_git_path}"
    chmod 755 "${real_git_path}"
fi
EOF
)

    # 2. Wrapper definition for /usr/bin/git
    # Single-quoted heredoc ('EOF') ensures NO variable expansion happens during source/eval!
    local wrapper_body
    wrapper_body=$(cat <<'EOF'
#!/usr/bin/env bash
REAL_GIT="/usr/bin/git-bin-8472"

# Fallback if the renamed binary does not exist
[ -x "$REAL_GIT" ] || REAL_GIT="/usr/bin/git"

BLOCKED_SUBCOMMANDS=("push" "branch" "tag" "remote")
BLOCKED_BRANCH_FLAGS=("-b" "-B" "-c" "-C" "--create" "--orphan")

subcommand=""
skip_next=false

# Robust argument parser to detect the actual git subcommand
for arg in "$@"; do
    if [ "$skip_next" = true ]; then
        skip_next=false
        continue
    fi
    case "$arg" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
            skip_next=true
            ;;
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-*)
            ;;
        *)
            subcommand="$arg"
            break
            ;;
    esac
done

# 1. Intercept blocked subcommands (push, branch, tag, remote)
for blocked in "${BLOCKED_SUBCOMMANDS[@]}"; do
    if [ -n "$subcommand" ] && [ "$subcommand" = "$blocked" ]; then
        cat >&2 <<MSG
[git-guard] Policy Notice:
  Command: git $subcommand
  Status:  DISABLED in this sandbox environment.
  Reason:  Remote synchronization and branch/tag operations are restricted by security policy.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
MSG
        exit 1
    fi
done

# 2. Intercept branch creation flags with checkout or switch
if [ -n "$subcommand" ] && [[ "$subcommand" =~ ^(checkout|switch)$ ]]; then
    for arg in "$@"; do
        for flag in "${BLOCKED_BRANCH_FLAGS[@]}"; do
            if [ "$arg" = "$flag" ]; then
                cat >&2 <<MSG
[git-guard] Policy Notice:
  Command: git $subcommand $flag
  Status:  DISABLED in this sandbox environment.
  Reason:  Branch creation is disabled to keep modifications on the active branch.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
MSG
                exit 1
            fi
        done
    done
fi

# 3. Intercept destructive reset (--hard)
if [ "$subcommand" = "reset" ]; then
    for arg in "$@"; do
        if [ "$arg" = "--hard" ]; then
            cat >&2 <<MSG
[git-guard] Policy Notice:
  Command: git reset --hard
  Status:  DISABLED in this sandbox environment.
  Reason:  Destructive workspace resets are disabled to protect against data loss.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
MSG
            exit 1
        fi
    done
fi

# 4. Intercept forced clean (-f)
if [ "$subcommand" = "clean" ]; then
    for arg in "$@"; do
        if [[ "$arg" =~ -[a-zA-Z]*f[a-zA-Z]* ]]; then
            cat >&2 <<MSG
[git-guard] Policy Notice:
  Command: git clean -f
  Status:  DISABLED in this sandbox environment.
  Reason:  Forced deletion of untracked files is disabled.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
MSG
            exit 1
        fi
    done
fi

# Execute the real git binary directly as current user (without sudo)
exec "$REAL_GIT" "$@"
EOF
)

    # Safely assign to profile arrays using namerefs instead of eval
    local startup_ref="PROFILE_${prof}_ROOT_STARTUP"
    local wrappers_ref="PROFILE_${prof}_ROOT_WRAPPERS"

    printf -v "$startup_ref" "%s\n%s" "${!startup_ref:-}" "$startup_snippet"

    # Append to the array safely
    eval "${wrappers_ref}+=(\"git|\$wrapper_body\")"
}
