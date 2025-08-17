#!/usr/bin/env bash
# shellcheck shell=bash
# Test: version_is_newer edge cases
# Focus: epochs, release comparisons, equal versions, numeric vs lexical.
set -uo pipefail  # removed -e to allow all test cases to run even if one fails
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MYREPO_SH="$REPO_ROOT/myrepo.sh"

# Source functions only (skip main) by setting guard
export MYREPO_SOURCE_ONLY=1
source "$MYREPO_SH"

pass=0; fail=0

test_case(){
   local left=$1 right=$2 expected=$3 label=$4
   if version_is_newer "$left" "$right"; then
      result=1
   else
      result=0
   fi
   if [[ $result -eq $expected ]]; then
      ((pass++)); echo "[OK] $label"
   else
      ((fail++)); echo "[FAIL] $label (expected=$expected got=$result)" >&2
   fi
}

# Core equality
test_case "1.2.3-1" "1.2.3-1" 0 "equal version -> not newer"

# Simple higher minor
test_case "1.3.0-1" "1.2.9-1" 1 "minor bump"

# Additional segment (should be newer)
test_case "1.2.3.1-1" "1.2.3-1" 1 "extra segment newer"

# Fewer segments (not newer)
test_case "1.2.3-1" "1.2.3.1-1" 0 "missing trailing segment not newer"

# Epoch comparisons (colon style) higher epoch wins
test_case "1:1.0.0-1" "0:1.0.0-1" 1 "epoch higher newer"
test_case "0:1.0.0-1" "1:1.0.0-1" 0 "epoch lower not newer"

# Release comparison when versions equal
test_case "1.0.0-2" "1.0.0-1" 1 "release higher newer"
test_case "1.0.0-1" "1.0.0-2" 0 "release lower not newer"

# Large number vs smaller major
test_case "100.0.0-1" "2.0.0-1" 1 "very large major"

# Numeric vs lexical mix (1.10 vs 1.9)
test_case "1.10.0-1" "1.9.9-1" 1 "numeric segment compare"

# Trailing zeros equivalence (1.0 vs 1)
test_case "1.0-1" "1-1" 0 "trailing zeros equal"

# Alphanumeric release segments (treated numerically -> equal)
test_case "1.2.3-2a" "1.2.3-2b" 0 "alpha suffix ignored -> not newer"

# Distro release differentiation (suffix not parsed numerically in fallback comparator)
test_case "1.0.0-1.el9" "1.0.0-1.el8" 0 "distro tag ignored numerically"

# Multi-digit distro release still ignored
test_case "1.0.0-1.el10" "1.0.0-1.el9" 0 "multi-digit suffix ignored"

# Higher release numeric with suffix
test_case "1.0.0-3.el9" "1.0.0-2.el9" 1 "higher release numeric with suffix"

# Lower version but higher release not newer
test_case "1.2.2-100" "1.2.3-1" 0 "higher release lower version not newer"

echo "Passed: $pass  Failed: $fail"
exit $fail
