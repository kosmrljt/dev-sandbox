#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  git_guard.sh — Git command enforcement wrapper for dev-sandbox
# ═══════════════════════════════════════════════════════════════════════

# Commands executed as root at container startup:
# 1. Moves real git binary and locks permissions
# 2. Locks git-core sub-binaries in libexec
GIT_GUARD_ROOT_STARTUP='
if [ -f /usr/bin/git ] && [ ! -f /usr/bin/git-real ]; then
    mv /usr/bin/git /usr/bin/git-real
    chmod 700 /usr/bin/git-real
fi

# Restrict direct access to critical subprograms in git-core
if [ -d /usr/libexec/git-core ]; then
    chmod 700 /usr/libexec/git-core/git-push \
              /usr/libexec/git-core/git-branch \
              /usr/libexec/git-core/git-tag 2>/dev/null || true
fi
'

# The wrapper installed to /usr/local/bin/git (or /usr/bin/git)
GIT_GUARD_WRAPPER_CONTENT='#!/usr/bin/env bash
REAL_GIT="/usr/bin/git-real"

# Fallback in case git was not moved
if [ ! -x "$REAL_GIT" ]; then
    REAL_GIT="/usr/bin/git"
fi

# ─── CONFIGURE YOUR RESTRICTIONS HERE ───────────────────────────────────
# Subcommands strictly forbidden
BLOCKED_SUBCOMMANDS=(
    "push"
    "branch"
    "tag"
    "remote"
)

# Branch creation flags forbidden with checkout / switch
BLOCKED_BRANCH_FLAGS=(
    "-b" "-B" "-c" "-C" "--create" "--orphan"
)
# ────────────────────────────────────────────────────────────────────────

subcommand=""
skip_next=false

# Robust CLI parser: find the first non-option argument (the real subcommand)
for arg in "$@"; do
    if [ "$skip_next" = true ]; then
        skip_next=false
        continue
    fi

    case "$arg" in
        # Global options that take a separate argument
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
            skip_next=true
            ;;
        # Global options with inline values or standalone flags
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-*)
            ;;
        # First non-flag argument is the subcommand
        *)
            subcommand="$arg"
            break
            ;;
    esac
done

# 1. Check exact subcommands
for blocked in "${BLOCKED_SUBCOMMANDS[@]}"; do
    if [ "$subcommand" = "$blocked" ]; then
        echo "✗ [git-guard] Blocked: git \"$subcommand\" is disabled in this sandbox." >&2
        exit 1
    fi
done

# 2. Check checkout / switch for branch creation
if [[ "$subcommand" =~ ^(checkout|switch)$ ]]; then
    for arg in "$@"; do
        for flag in "${BLOCKED_BRANCH_FLAGS[@]}"; do
            if [ "$arg" = "$flag" ]; then
                echo "✗ [git-guard] Blocked: Creating new branches with \"$flag\" is disabled." >&2
                exit 1
            fi
        done
    done
fi

# 3. Check reset --hard
if [ "$subcommand" = "reset" ]; then
    for arg in "$@"; do
        if [ "$arg" = "--hard" ]; then
            echo "✗ [git-guard] Blocked: \"git reset --hard\" is disabled." >&2
            exit 1
        fi
    done
fi

# 4. Check clean -f (forced delete of untracked files)
if [ "$subcommand" = "clean" ]; then
    for arg in "$@"; do
        if [[ "$arg" =~ -[a-zA-Z]*f[a-zA-Z]* ]]; then
            echo "✗ [git-guard] Blocked: \"git clean -f\" is disabled." >&2
            exit 1
        fi
    done
fi

# Execute real git with root privileges if locked down, else direct exec
if [ -u "$REAL_GIT" ] || [ "$(id -u)" -eq 0 ]; then
    exec "$REAL_GIT" "$@"
else
    exec sudo "$REAL_GIT" "$@"
fi
'
