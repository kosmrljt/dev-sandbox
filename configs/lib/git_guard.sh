#!/usr/bin/env bash
# ~/.dev-sandbox/lib/git-guard.sh

apply_git_guard_to_profile() {
    local prof="$1"

    # 1. Root startup hook: move real binary & lock libexec tools
    local startup_var="PROFILE_${prof}_ROOT_STARTUP"
    eval "${startup_var}+='
if [ -f /usr/bin/git ] && [ ! -f /usr/bin/git-real ]; then
    mv /usr/bin/git /usr/bin/git-real
    chmod 700 /usr/bin/git-real
fi

if [ -d /usr/libexec/git-core ]; then
    chmod 700 /usr/libexec/git-core/git-push \
              /usr/libexec/git-core/git-branch \
              /usr/libexec/git-core/git-tag 2>/dev/null || true
fi
'"

    # 2. Add git wrapper to ROOT_WRAPPERS
    local wrappers_var="PROFILE_${prof}_ROOT_WRAPPERS"
    eval "${wrappers_var}+=(
        'git|#!/usr/bin/env bash
REAL_GIT=\"/usr/bin/git-real\"
[ -x \"\$REAL_GIT\" ] || REAL_GIT=\"/usr/bin/git\"

BLOCKED_SUBCOMMANDS=(\"push\" \"branch\" \"tag\" \"remote\")
BLOCKED_BRANCH_FLAGS=(\"-b\" \"-B\" \"-c\" \"-C\" \"--create\" \"--orphan\")

subcommand=\"\"
skip_next=false

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

for blocked in \"\${BLOCKED_SUBCOMMANDS[@]}\"; do
    if [ \"\$subcommand\" = \"\$blocked\" ]; then
        echo \"✗ [git-guard] Blocked: git \\\"\$subcommand\\\" is disabled in this sandbox.\" >&2
        exit 1
    fi
done

if [[ \"\$subcommand\" =~ ^(checkout|switch)$ ]]; then
    for arg in \"\$@\"; do
        for flag in \"\${BLOCKED_BRANCH_FLAGS[@]}\"; do
            if [ \"\$arg\" = \"\$flag\" ]; then
                echo \"✗ [git-guard] Blocked: Creating new branches with \\\"\$flag\\\" is disabled.\" >&2
                exit 1
            fi
        done
    done
fi

if [ \"\$subcommand\" = \"reset\" ]; then
    for arg in \"\$@\"; do
        if [ \"\$arg\" = \"--hard\" ]; then
            echo \"✗ [git-guard] Blocked: \\\"git reset --hard\\\" is disabled.\" >&2
            exit 1
        fi
    done
fi

if [ \"\$subcommand\" = \"clean\" ]; then
    for arg in \"\$@\"; do
        if [[ \"\$arg\" =~ -[a-zA-Z]*f[a-zA-Z]* ]]; then
            echo \"✗ [git-guard] Blocked: \\\"git clean -f\\\" is disabled.\" >&2
            exit 1
        fi
    done
fi

exec sudo \"\$REAL_GIT\" \"\$@\"'
    )"
}
