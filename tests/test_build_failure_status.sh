#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export MYREPO_SOURCE_ONLY=1
source "$TEST_ROOT/myrepo.sh"

TEMP_REPO="$(mktemp -d)"
trap 'rm -rf -- "$TEMP_REPO"' EXIT
LOCAL_REPO_PATH="$TEMP_REPO"
REPO_OS_MAJOR=""
REPOS=fixture
EXCLUDE_REPOS=""
MANUAL_REPOS=(fixture)
DRY_RUN=0
SYNC_ONLY=0
NO_METADATA_UPDATE=0
CLEANUP_UNINSTALLED=0
DEBUG_LEVEL=0
PLAIN_MODE=1
mkdir -p "$TEMP_REPO/fixture/getPackage"

cleanup_old_repodata() { return 0; }
update_repository_metadata() { return 1; }
is_repo_enabled() { return 0; }
draw_metadata_table_border() { :; }
draw_metadata_table_header() { :; }
draw_metadata_table_row() { :; }

if update_all_repository_metadata; then
    printf 'FAIL: metadata failure returned success\n' >&2
    exit 1
fi

generate_summary_table() { :; }
update_all_repository_metadata() { return 1; }
if finalize_and_report "$(date +%s)" 0 0 0 0; then
    printf 'FAIL: finalization hid metadata failure\n' >&2
    exit 1
fi

NO_METADATA_UPDATE=1
reported=0
report_failed_downloads() { reported=1; }
declare -A failed_downloads=([fixture]=fixture)
if finalize_and_report "$(date +%s)" 1 0 0 0; then
    printf 'FAIL: failed download returned success\n' >&2
    exit 1
fi
[[ "$reported" == 1 ]]

failed_downloads=()
finalize_and_report "$(date +%s)" 0 0 0 0
printf 'PASS: metadata and download failures propagate; successful finalization remains successful\n'