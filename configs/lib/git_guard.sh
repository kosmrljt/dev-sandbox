#!/usr/bin/env bash
# lib/git-guard.sh

apply_git_guard_to_profile() {
    local prof="$1"

    # Inconspicuous name for the real git binary
    local real_git_name="git-bin-8472"
    local real_git_path="/usr/bin/${real_git_name}"

    # 1. ROOT_STARTUP: Rename the real git binary once at startup (runs as root)
    local startup_var="PROFILE_${prof}_ROOT_STARTUP"
    eval "${startup_var}+='
if [ -f /usr/bin/git ] && [ ! -f \"${real_git_path}\" ]; then
    mv /usr/bin/git \"${real_git_path}\"
    chmod 755 \"${real_git_path}\"
fi
'"

    # 2. Wrapper at /usr/bin/git providing explicit policy notices to AI agents
    local wrappers_var="PROFILE_${prof}_ROOT_WRAPPERS"
    eval "${wrappers_var}+=(
        'git|#!/usr/bin/env bash
REAL_GIT=\"'${real_git_path}'\"

# Fallback if the renamed binary does not exist
[ -x \"\$REAL_GIT\" ] || REAL_GIT=\"/usr/bin/git\"

BLOCKED_SUBCOMMANDS=(\"push\" \"branch\" \"tag\" \"remote\")
BLOCKED_BRANCH_FLAGS=(\"-b\" \"-B\" \"-c\" \"-C\" \"--create\" \"--orphan\")

subcommand=\"\"
skip_next=false

# Robust argument parser to detect the actual git subcommand
for arg in \"\$@\"; do
    if [ \"\$skip_next\" = true ]; then
        skip_next=false
        continue
    fi
    case \"\$arg\" in
        -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
            skip_next=true
            ;;
        --git-dir=*|--work-tree=*|--namespace=*|--exec-path=*|-*)
            ;;
        *)
            subcommand=\"\$arg\"
            break
            ;;
    esac
done

# 1. Intercept blocked subcommands (push, branch, tag, remote)
for blocked in \"\${BLOCKED_SUBCOMMANDS[@]}\"; do
    if [ \"\$subcommand\" = \"\$blocked\" ]; then
        cat >&2 <<EOF
[git-guard] Policy Notice:
  Command: git $subcommand
  Status:  DISABLED in this sandbox environment.
  Reason:  Remote synchronization and branch/tag operations are restricted by security policy.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
EOF
        exit 1
    fi
done

# 2. Intercept branch creation flags with checkout or switch
if [[ \"\$subcommand\" =~ ^(checkout|switch)$ ]]; then
    for arg in \"\$@\"; do
        for flag in \"\${BLOCKED_BRANCH_FLAGS[@]}\"; do
            if [ \"\$arg\" = \"\$flag\" ]; then
                cat >&2 <<EOF
[git-guard] Policy Notice:
  Command: git $subcommand $flag
  Status:  DISABLED in this sandbox environment.
  Reason:  Branch creation is disabled to keep modifications on the active branch.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
EOF
                exit 1
            fi
        done
    done
fi

# 3. Intercept destructive reset (--hard)
if [ \"\$subcommand\" = \"reset\" ]; then
    for arg in \"\$@\"; do
        if [ \"\$arg\" = \"--hard\" ]; then
            cat >&2 <<EOF
[git-guard] Policy Notice:
  Command: git reset --hard
  Status:  DISABLED in this sandbox environment.
  Reason:  Destructive workspace resets are disabled to protect against data loss.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
EOF
            exit 1
        fi
    done
fi

# 4. Intercept forced clean (-f)
if [ \"\$subcommand\" = \"clean\" ]; then
    for arg in \"\$@\"; do
        if [[ \"\$arg\" =~ -[a-zA-Z]*f[a-zA-Z]* ]]; then
            cat >&2 <<EOF
[git-guard] Policy Notice:
  Command: git clean -f
  Status:  DISABLED in this sandbox environment.
  Reason:  Forced deletion of untracked files is disabled.
  Action:  Do not try to work around this restriction. Ask the user for guidance on how to proceed.
EOF
            exit 1
        fi
    done
fi

# Execute the real git binary directly as current user (without sudo)
exec \"\$REAL_GIT\" \"\$@\"'
    )"
}
