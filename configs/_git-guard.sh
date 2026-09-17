#!/usr/bin/env bash
# ~/.dev-sandbox/_git-guard.sh
# Global policy: Enforce Git restrictions across all registered profiles

BASE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
source "${BASE_DIR}/lib/git-guard.sh"

for profile_name in "${ALL_PROFILES[@]}"; do
    apply_git_guard_to_profile "$profile_name"
done
