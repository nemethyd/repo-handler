#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2030,SC2031
# Script globals are consumed by sourced functions; cases intentionally use subshells.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export MYREPO_SOURCE_ONLY=1 ELEVATE_COMMANDS=0 DEBUG_LEVEL=0
# shellcheck source=/dev/null
source "$REPO_ROOT/myrepo.sh"

log() { printf '%s\n' "$*" >> "$TEMP_DIR/test.log"; }
get_dnf_cmd() { DNF_CMD=(mock_dnf); }
timeout() { shift; "$@"; }

mock_dnf() {
    if [[ "$1" == repoquery ]]; then
        printf '%s\n' "$INSTALLED"
        return "${MOCK_DNF_QUERY_FAILURE:-0}"
    fi
    [[ "$1" == download ]] || return 1
    [[ -f "$OLD_RPM" ]] || { echo "Old RPM missing before download" >&2; return 1; }
    [[ "${MOCK_DOWNLOAD_FAILURE:-0}" == 0 ]] || return 1
    printf '%s\n' "$INSTALLED" > "$NEW_RPM"
}

rpm() {
    if [[ "$1" == -K ]]; then
        printf '%s\n' "$3" >> "$TEMP_DIR/integrity-checks.log"
        if grep -q '^CORRUPT$' "$3"; then return 1; fi
        return 0
    fi
    [[ "$1" == --eval ]] && return 1
    [[ "$1" == -qp ]] || return 1
    shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nosignature|--nodigest) shift ;;
            --queryformat) shift 2; break ;;
            *) return 1 ;;
        esac
    done
    if [[ "$#" -gt 1 && "${MOCK_BATCH_MODE:-normal}" == fail ]]; then
        return 1
    fi
    local file
    for file in "$@"; do
        [[ -f "$file" ]] || return 1
        [[ "$(head -n 1 "$file")" != UNREADABLE ]] || return 1
        head -n 1 "$file"
        [[ "$#" -gt 1 && "${MOCK_BATCH_MODE:-normal}" == partial ]] && break
    done
    return 0
}

setup_case() {
    LOCAL_REPO_PATH="$TEMP_DIR/$1"
    PACKAGES="$LOCAL_REPO_PATH/testrepo/getPackage"
    mkdir -p "$PACKAGES"
    OLD_RPM="$PACKAGES/demo-1.0-1.x86_64.rpm"
    NEW_RPM="$PACKAGES/demo-2.0-1.x86_64.rpm"
    INSTALLED='demo|0|2.0|1|x86_64'
    printf '%s\n' 'demo|0|1.0|1|x86_64' > "$OLD_RPM"
    CHANGED_REPOS=()
    stats_new_count[testrepo]=0
    stats_update_count[testrepo]=0
    stats_exists_count[testrepo]=0
    MANUAL_REPOS=()
    REPOS=''
    EXCLUDE_REPOS=''
    DRY_RUN=0
    FORCE_REDOWNLOAD=0
    CLEANUP_UNINSTALLED=1
    NO_METADATA_UPDATE=0
    BATCH_SIZE=2
    MOCK_BATCH_MODE=normal
    MOCK_DOWNLOAD_FAILURE=0
    MOCK_DNF_QUERY_FAILURE=0
    MAX_CHANGED_PACKAGES=-1
    NAME_FILTER=''
    LOCAL_RPM_SOURCES=()
}

cleanup_packages() {
    if ! cleanup_uninstalled_packages "$@" > "$TEMP_DIR/cleanup.out"; then
        echo "FAIL: cleanup failed in $LOCAL_REPO_PATH" >&2
        exit 1
    fi
}

download_packages() {
    if ! batch_download_packages <<< 'testrepo|demo|0|2.0|1|x86_64'; then
        echo 'FAIL: batch download processing failed' >&2
        exit 1
    fi
}

classify_packages() {
    queued_new=() queued_updates=()
    processed=0 new_count=0 update_count=0 exists_count=0 changed_count=0
    if ! classify_and_queue_packages "$INSTALLED|testrepo" queued_new queued_updates \
        processed new_count update_count exists_count changed_count 1 > "$TEMP_DIR/classify.out"; then
        echo 'FAIL: classification failed' >&2
        exit 1
    fi
}

assert_present() { [[ -f "$1" ]] || { echo "FAIL: expected retained RPM: $1" >&2; exit 1; }; }
assert_absent() { [[ ! -f "$1" ]] || { echo "FAIL: expected removed RPM: $1" >&2; exit 1; }; }

test_upgrade() (
    setup_case upgrade
    printf '%s\n' 'removed|0|1.0|1|x86_64' > "$PACKAGES/removed.rpm"
    cleanup_packages
    assert_present "$OLD_RPM"
    assert_absent "$PACKAGES/removed.rpm"
    [[ "$(get_package_status demo 2.0 1 x86_64 "$PACKAGES")" == UPDATE ]]
    download_packages
    assert_present "$OLD_RPM"
    assert_present "$NEW_RPM"
    # Invoked indirectly by finalize_and_report() from the sourced script.
    # shellcheck disable=SC2317,SC2329
    update_all_repository_metadata() {
        assert_absent "$OLD_RPM"
        assert_present "$NEW_RPM"
        [[ "${CHANGED_REPOS[testrepo]:-0}" == 1 ]]
    }
    if ! finalize_and_report "$(date +%s)" 1 0 1 0 > "$TEMP_DIR/finalize.out"; then
        echo 'FAIL: finalization failed' >&2
        exit 1
    fi
    [[ "$(get_package_status demo 2.0 1 x86_64 "$PACKAGES")" == EXISTS ]]
)

test_failed_download() (
    setup_case failed-download
    cleanup_packages
    MOCK_DOWNLOAD_FAILURE=1
    download_packages
    [[ "${#failed_downloads[@]}" -gt 0 ]]
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    assert_absent "$NEW_RPM"
    [[ "$(get_package_status demo 2.0 1 x86_64 "$PACKAGES")" == UPDATE ]]
)

test_no_replacement() (
    setup_case limited-or-filtered
    MAX_CHANGED_PACKAGES=0
    cleanup_packages
    classify_packages
    [[ ${#queued_updates[@]} -eq 0 && $update_count -eq 0 && $new_count -eq 0 ]]
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    [[ -z "${CHANGED_REPOS[testrepo]:-}" ]]
)

test_local_source() (
    setup_case local-source
    mkdir -p "$LOCAL_REPO_PATH/source"
    printf '%s\n' "$INSTALLED" > "$LOCAL_REPO_PATH/source/$(basename "$NEW_RPM")"
    LOCAL_RPM_SOURCES=("$LOCAL_REPO_PATH/source")
    cleanup_packages
    classify_packages
    [[ $new_count -eq 0 && $update_count -eq 1 && ${#queued_updates[@]} -eq 0 ]]
    assert_present "$OLD_RPM"
    assert_present "$NEW_RPM"
    cleanup_packages obsolete
    assert_absent "$OLD_RPM"
)

test_cleanup_toggles() (
    setup_case toggles
    printf '%s\n' "$INSTALLED" > "$NEW_RPM"
    CLEANUP_UNINSTALLED=0
    NO_METADATA_UPDATE=1
    if ! finalize_and_report "$(date +%s)" 1 0 1 0 > "$TEMP_DIR/finalize.out"; then
        echo 'FAIL: finalization with cleanup disabled failed' >&2
        exit 1
    fi
    assert_present "$OLD_RPM"
    CLEANUP_UNINSTALLED=1
    if ! finalize_and_report "$(date +%s)" 1 0 1 0 > "$TEMP_DIR/finalize.out"; then
        echo 'FAIL: finalization without metadata updates failed' >&2
        exit 1
    fi
    assert_absent "$OLD_RPM"
    [[ "${CHANGED_REPOS[testrepo]:-0}" == 1 ]]
)

test_replacement_in_another_repo() (
    setup_case another-repo
    mkdir -p "$LOCAL_REPO_PATH/otherrepo/getPackage"
    printf '%s\n' "$INSTALLED" > "$LOCAL_REPO_PATH/otherrepo/getPackage/demo-2.0-1.x86_64.rpm"
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
)

test_corrupt_replacement() (
    setup_case corrupt
    printf '%s\nCORRUPT\n' "$INSTALLED" > "$NEW_RPM"
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    assert_present "$NEW_RPM"
    grep -q 'RPM integrity check failed' "$TEMP_DIR/test.log"
)

test_module_protection() (
    setup_case modules
    printf '%s\n' "$INSTALLED" > "$NEW_RPM"
    cat > "$LOCAL_REPO_PATH/testrepo/modules.yaml" <<'YAML'
document: modulemd
version: 2
data:
  name: demo
  stream: "2"
  artifacts:
    rpms:
    - demo-0:1.0-1.x86_64
    - module-only-0:1.0-1.noarch
YAML
    printf '%s\n' 'module-only|0|1.0|1|noarch' > "$PACKAGES/module-only.rpm"
    cleanup_packages
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    assert_present "$PACKAGES/module-only.rpm"
)

test_metadata_mapping() (
    setup_case "mapping-$1"
    MOCK_BATCH_MODE="$1"
    mv "$OLD_RPM" "$PACKAGES/upstream_old.rpm"
    OLD_RPM="$PACKAGES/upstream_old.rpm"
    printf '%s\n' "$INSTALLED" > "$PACKAGES/upstream_new.rpm"
    printf '%s\n' 'demo|0|1.0|1|x86_64' > "$PACKAGES/duplicate_old.rpm"
    printf '%s\n' 'UNREADABLE' > "$PACKAGES/unreadable.rpm"
    cleanup_packages
    assert_present "$OLD_RPM"
    cleanup_packages obsolete
    assert_absent "$OLD_RPM"
    assert_absent "$PACKAGES/duplicate_old.rpm"
    assert_present "$PACKAGES/upstream_new.rpm"
    assert_present "$PACKAGES/unreadable.rpm"
    [[ "${CHANGED_REPOS[testrepo]:-0}" == 1 ]]
)

test_arch_epoch_and_installonly() (
    setup_case arch-epoch
    INSTALLED=$'demo|1|2.0|1|x86_64\nkernel|0|1.0|1|x86_64\nkernel|0|2.0|1|x86_64'
    printf '%s\n' 'demo|0|2.0|1|x86_64' > "$NEW_RPM"
    printf '%s\n' 'demo|1|2.0|1|i686' > "$PACKAGES/demo-i686.rpm"
    printf '%s\n' 'kernel|0|1.0|1|x86_64' > "$PACKAGES/kernel-old.rpm"
    printf '%s\n' 'kernel|0|2.0|1|x86_64' > "$PACKAGES/kernel-new.rpm"
    cleanup_packages
    assert_absent "$PACKAGES/demo-i686.rpm"
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    printf '%s\n' 'demo|1|2.0|1|x86_64' > "$NEW_RPM"
    cleanup_packages obsolete
    assert_absent "$OLD_RPM"
    assert_present "$PACKAGES/kernel-old.rpm"
    assert_present "$PACKAGES/kernel-new.rpm"
)

test_scopes_and_dry_run() (
    setup_case scopes
    printf '%s\n' "$INSTALLED" > "$NEW_RPM"
    DRY_RUN=1
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    [[ -z "${CHANGED_REPOS[testrepo]:-}" ]]
    DRY_RUN=0
    EXCLUDE_REPOS=testrepo
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    EXCLUDE_REPOS=''
    REPOS=anotherrepo
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    REPOS=''
    MANUAL_REPOS=(testrepo)
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
)

test_query_failure() (
    setup_case query-failure
    INSTALLED='unrelated|0|1.0|1|x86_64'
    MOCK_DNF_QUERY_FAILURE=1
    if cleanup_uninstalled_packages > "$TEMP_DIR/cleanup.out"; then
        echo 'FAIL: cleanup accepted partial output from a failed DNF query' >&2
        exit 1
    fi
    assert_present "$OLD_RPM"
    MOCK_DNF_QUERY_FAILURE=0
    INSTALLED='malformed'
    if cleanup_uninstalled_packages > "$TEMP_DIR/cleanup.out"; then
        echo 'FAIL: cleanup accepted malformed installed package metadata' >&2
        exit 1
    fi
    assert_present "$OLD_RPM"
)

test_os_major_cleanup() (
    setup_case os-major
    mv "$LOCAL_REPO_PATH/testrepo" "$LOCAL_REPO_PATH/ol9_appstream"
    OLD_RPM="$LOCAL_REPO_PATH/ol9_appstream/getPackage/demo-1.0-1.x86_64.rpm"
    mkdir -p "$LOCAL_REPO_PATH/ol10_appstream/getPackage"
    NEW_RPM="$LOCAL_REPO_PATH/ol10_appstream/getPackage/removed.rpm"
    printf '%s\n' 'removed|0|1.0|1|x86_64' > "$NEW_RPM"
    REPO_OS_MAJOR=10
    cleanup_packages
    assert_present "$OLD_RPM"
    assert_absent "$NEW_RPM"
    cleanup_packages obsolete
    assert_present "$OLD_RPM"
    [[ -z "${CHANGED_REPOS[ol9_appstream]:-}" ]]
)

test_upgrade
test_failed_download
test_no_replacement
test_local_source
test_cleanup_toggles
test_replacement_in_another_repo
test_corrupt_replacement
test_module_protection
test_metadata_mapping normal
test_metadata_mapping fail
test_metadata_mapping partial
test_arch_epoch_and_installonly
test_scopes_and_dry_run
test_query_failure
test_os_major_cleanup
echo 'PASS: upgrade cleanup regression tests (15 scenarios)'
