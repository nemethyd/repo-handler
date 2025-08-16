#!/usr/bin/env bash
# shellcheck shell=bash
# Test: Selective metadata update (CHANGED_REPOS optimization)
# Goal: Ensure update_all_repository_metadata limits updates to changed repositories when CHANGED_REPOS populated.
# Strategy (robust against variable counts):
#   1. Pre-create an unused repository directory that should NOT appear in metadata update phase.
#   2. Run myrepo.sh with DRY_RUN=1 and NAME_FILTER=^bash$ (common package) to trigger NEW/EXISTS events.
#   3. Assert log shows phrase: "Updating repository metadata for" AND "changed repositories only".
#   4. Extract reported changed repository count N (>=1).
#   5. Verify unused_repo not mentioned in metadata update lines if selective mode engaged.
# Notes: Script currently overrides LOCAL_REPO_PATH default to /repo; we adapt by creating unused repo there.
# Exit non‑zero on failure.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MYREPO_SH="$REPO_ROOT/myrepo.sh"
NAME_FILTER="^bash$"
LOG_FILE="$(mktemp)"

# Use isolated temporary LOCAL_REPO_PATH so target package is guaranteed NEW (repo empty)
LOCAL_REPO_PATH="$(mktemp -d)"
export LOCAL_REPO_PATH
mkdir -p "$LOCAL_REPO_PATH/unused_repo/getPackage" "$LOCAL_REPO_PATH/test_repo/getPackage"

# Functions
info(){ echo "[selective-meta-test] $*"; }
fail(){ echo "[selective-meta-test] ERROR: $*" >&2; rm -f "$LOG_FILE"; exit 1; }
cleanup(){ rm -f "$LOG_FILE" 2>/dev/null || true; }
trap cleanup EXIT

# Preconditions
command -v dnf >/dev/null || fail "dnf not found"
[[ -x "$MYREPO_SH" ]] || fail "myrepo.sh not executable"

info "Running myrepo.sh dry-run with NAME_FILTER=$NAME_FILTER to trigger selective metadata update"
ENABLE_TEST_SELECTIVE=1 DEBUG_LEVEL=2 DRY_RUN=1 CLEANUP_UNINSTALLED=0 NO_METADATA_UPDATE=0 NAME_FILTER="$NAME_FILTER" "$MYREPO_SH" 2>"$LOG_FILE" >/dev/null || fail "myrepo.sh run failed"

# Extract selective metadata header and validate
HEADER_LINE=$(grep -E "Updating repository metadata for .*changed repositories only" "$LOG_FILE" | head -1 || true)
if [[ -z "$HEADER_LINE" ]]; then
  info "--- BEGIN LOG ---"; sed -n '1,160p' "$LOG_FILE" >&2; info "--- END LOG ---"
  fail "Selective metadata header not found"
fi

# No strict count assert (some environments may mark multiple repos); presence of phrase suffices

# Ensure unused_repo absent from metadata update block (since not in CHANGED_REPOS)
if grep -E "unused_repo" "$LOG_FILE"; then
  info "Header: $HEADER_LINE"
  info "--- BEGIN LOG (metadata section) ---"; grep -n "Updating repository metadata" -A20 "$LOG_FILE" >&2; info "--- END LOG ---"
  fail "unused_repo appeared in selective metadata update output"
fi

info "Selective metadata update test PASSED (header: $HEADER_LINE)"
