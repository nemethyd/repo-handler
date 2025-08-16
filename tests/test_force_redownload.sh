#!/usr/bin/env bash
# shellcheck shell=bash
# Test: Validate FORCE_REDOWNLOAD safe replacement logic in myrepo.sh
# Version synced with script 2.3.15
# This script performs controlled scenarios. It requires root or sudo for network/firewall and dnf ops.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MYREPO_SH="$REPO_ROOT/myrepo.sh"
PKG_NAME="zstd"
NAME_FILTER="^${PKG_NAME}$"
LOG_PREFIX="[test-force-redownload]"
# Store state alongside this test script (tests/test_force_redownload_state)
TEMP_STATE="$SCRIPT_DIR/test_force_redownload_state"
mkdir -p "$TEMP_STATE"

info(){ echo -e "${LOG_PREFIX} $*"; }
fail(){ echo -e "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

check_prereqs(){
  command -v dnf >/dev/null || fail "dnf not found"
  command -v rpm >/dev/null || fail "rpm not found"
  [[ -x "$MYREPO_SH" ]] || fail "myrepo.sh not executable"
}

rpm_files(){ find /repo -maxdepth 3 -type f -name "${PKG_NAME}-*.rpm" -print 2>/dev/null | sort; }

sha_list(){ rpm_files | xargs -r sha256sum; }

snapshot_state(){
  local tag="$1"; mkdir -p "$TEMP_STATE/$tag" || true
  rpm_files > "$TEMP_STATE/$tag/files.list" || true
  sha_list > "$TEMP_STATE/$tag/sha256.list" || true
}

diff_state(){
  local a="$1" b="$2"
  diff -u "$TEMP_STATE/$a/sha256.list" "$TEMP_STATE/$b/sha256.list" || true
}

# Scenario: baseline collection
scenario_baseline(){
  info "Baseline collection"
  sudo dnf -y install "$PKG_NAME" >/dev/null 2>&1 || true
  FORCE_REDOWNLOAD=0 "$MYREPO_SH" --name-filter "$NAME_FILTER" --debug 1 || fail "baseline run failed"
  snapshot_state baseline
}

# Attempt downgrade (may fail if no older NEVRA)
maybe_downgrade(){
  if sudo dnf -y downgrade "$PKG_NAME" >/dev/null 2>&1; then
    info "Downgraded $PKG_NAME to older version for update simulation"
  else
    info "No downgrade available; proceeding with existing version"
  fi
}

scenario_safe_update(){
  info "Scenario: safe replacement (FORCE_REDOWNLOAD=0)"
  maybe_downgrade
  # Force a NEW status by deleting one existing RPM (no backup per user request)
  local victim
  victim=$(rpm_files | head -n1 || true)
  if [[ -n "$victim" ]]; then
    if sudo rm -f "$victim" 2>/dev/null || rm -f "$victim"; then
      info "Removed RPM to force NEW classification: $(basename "$victim")"
    else
      info "Could not remove $victim (insufficient permissions?)"
    fi
  else
    info "No existing RPM found to delete for NEW simulation"
  fi
  FORCE_REDOWNLOAD=0 "$MYREPO_SH" --name-filter "$NAME_FILTER" --debug 1 || fail "safe update run failed"
  snapshot_state safe
}

scenario_forced_update(){
  info "Scenario: forced pre-removal (FORCE_REDOWNLOAD=1)"
  maybe_downgrade
  # Delete again to ensure another NEW (or re-download) event
  local victim
  victim=$(rpm_files | head -n1 || true)
  if [[ -n "$victim" ]]; then
    if sudo rm -f "$victim" 2>/dev/null || rm -f "$victim"; then
      info "Removed RPM before forced run: $(basename "$victim")"
    else
      info "Could not remove $victim (insufficient permissions?)"
    fi
  else
    info "No existing RPM found to delete before forced run"
  fi
  FORCE_REDOWNLOAD=1 "$MYREPO_SH" --name-filter "$NAME_FILTER" --debug 1 || fail "forced update run failed"
  snapshot_state forced
}

scenario_failed_download(){
  info "Scenario: simulate failed download (block network)"
  local ipt_added=0
  if sudo iptables -I OUTPUT -p tcp --dport 443 -j REJECT 2>/dev/null; then
    ipt_added=1
  else
    info "Could not insert iptables REJECT rule; skipping network block test"
    return 0
  fi
  # Run with safe mode first
  set +e
  FORCE_REDOWNLOAD=0 "$MYREPO_SH" --name-filter "$NAME_FILTER" --debug 1 >/dev/null 2>"$TEMP_STATE/failed_safe.err"
  local rc_safe=$?
  set -e
  snapshot_state failed_safe
  # Run with forced mode
  set +e
  FORCE_REDOWNLOAD=1 "$MYREPO_SH" --name-filter "$NAME_FILTER" --debug 1 >/dev/null 2>"$TEMP_STATE/failed_forced.err"
  local rc_forced=$?
  set -e
  snapshot_state failed_forced
  if [[ $ipt_added -eq 1 ]]; then
    sudo iptables -D OUTPUT 1 || true
  fi
  info "Failed download exit codes: safe=$rc_safe forced=$rc_forced (expected non-zero for at least one)"
}

report(){
  info "Diff baseline -> safe:"; diff_state baseline safe
  info "Diff safe -> forced:"; diff_state safe forced
  if [[ -f "$TEMP_STATE/failed_safe/sha256.list" && -f "$TEMP_STATE/failed_forced/sha256.list" ]]; then
    info "Diff failed_safe -> failed_forced:"; diff_state failed_safe failed_forced
  fi
  info "File snapshots stored under $TEMP_STATE"
}

main(){
  check_prereqs
  scenario_baseline
  scenario_safe_update
  scenario_forced_update
  scenario_failed_download
  report
  info "Completed FORCE_REDOWNLOAD test scenarios"
}

main "$@"
