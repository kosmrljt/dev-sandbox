#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════
#  ~/.dev-sandbox/_git-guard.sh
#
#  Global Policy Modifier:
#  Enforces Git security restrictions across all profiles registered
#  in the ALL_PROFILES array by attaching hooks from lib/git-guard.sh.
#
#  Usage:
#    dev-sandbox --config devhw.sh --config _git-guard.sh -p devhw build -f
# ═══════════════════════════════════════════════════════════════════════

# Dynamically resolve directory of this script to locate helper libraries
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

# Source the git-guard definition library
if [ -f "${SCRIPT_DIR}/lib/git-guard.sh" ]; then
    source "${SCRIPT_DIR}/lib/git-guard.sh"
else
    echo "✗ [git-guard] Error: Required library not found at ${SCRIPT_DIR}/lib/git-guard.sh" >&2
    return 1 2>/dev/null || exit 1
fi

# Apply Git restrictions to every profile defined so far
for profile_name in "${ALL_PROFILES[@]}"; do
    apply_git_guard_to_profile "$profile_name"
done
