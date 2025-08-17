#!/usr/bin/env bash
set -euo pipefail
# Test: Ensure manual repository package classification does not leave negative counters
# Scenario: Provide NEW and UPDATE packages from a manual repo with no local RPMs present.
# Expectation: new_count/update_count return to 0 after manual skip logic; stats arrays non-negative; processed count reflects inputs.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export MYREPO_SOURCE_ONLY=1  # prevent auto main
export DEBUG_LEVEL=${DEBUG_LEVEL:-2}

manual_repo="manualrepo"

# Source script first (it sets defaults overriding env vars), then configure overrides
# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"

# Override repo root AFTER sourcing so our path sticks
export LOCAL_REPO_PATH="$(mktemp -d)"
mkdir -p "${LOCAL_REPO_PATH}/${manual_repo}/getPackage"

# Override manual repos (clear original)
MANUAL_REPOS=("$manual_repo")

# Initialize stats arrays for manual repo to avoid unbound errors under set -u when decremented
stats_new_count["$manual_repo"]=0
stats_update_count["$manual_repo"]=0

# Create older version of pkgB to force UPDATE classification when newer metadata provided.
: >"${LOCAL_REPO_PATH}/${manual_repo}/getPackage/pkgB-1.0-1.el9.x86_64.rpm"

# Input packages: pkgA new, pkgB update (newer version 1.1 vs existing 1.0)
filtered_packages=$(cat <<PKGS
pkgA|0|1.0|1.el9|x86_64|$manual_repo
pkgB|0|1.1|1.el9|x86_64|$manual_repo
PKGS
)

new_packages=()
update_packages=()
processed=0
new_count=0
update_count=0
exists_count=0
changed_count=0

# Call classification (temporarily disable errexit to allow internal non-critical command failures)
set +e
DRY_RUN=0 classify_and_queue_packages "$filtered_packages" new_packages update_packages processed new_count update_count exists_count changed_count 2
set -e

# Debug dump after classification
echo "DEBUG: processed=$processed new_count=$new_count update_count=$update_count exists_count=$exists_count changed_count=$changed_count" >&2

fail(){ echo "FAIL: $*" >&2; exit 1; }

[[ $new_count -eq 0 ]] || fail "Expected new_count 0 after manual skip, got $new_count"
[[ $update_count -eq 0 ]] || fail "Expected update_count 0 after manual skip, got $update_count"
[[ $changed_count -eq 0 ]] || fail "Expected changed_count 0 after manual skip, got $changed_count"

[[ ${#new_packages[@]} -eq 0 ]] || fail "Expected no queued new packages, got ${#new_packages[@]}"
[[ ${#update_packages[@]} -eq 0 ]] || fail "Expected no queued update packages, got ${#update_packages[@]}"

[[ $processed -eq 2 ]] || fail "Expected processed=2, got $processed"

n=${stats_new_count[$manual_repo]:-0}; (( n >= 0 )) || fail "stats_new_count negative: $n"
u=${stats_update_count[$manual_repo]:-0}; (( u >= 0 )) || fail "stats_update_count negative: $u"

set +e
output=$(DRY_RUN=0 classify_and_queue_packages "$filtered_packages" new_packages update_packages processed new_count update_count exists_count changed_count 2 2>&1 || true)
set -e
echo "$output" | grep -q "manual repository (no download attempted)" || fail "Missing manual repository skip log"

echo "PASS: Manual repo counter clamp test succeeded." >&2
