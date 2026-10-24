#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

export MYREPO_SOURCE_ONLY=1 ELEVATE_COMMANDS=0 DEBUG_LEVEL=0 REPO_OS_MAJOR=''
source "$REPO_ROOT/myrepo.sh"

log() { printf '%s\n' "$*"; }
get_host_os_major() { printf '%s\n' "$MOCK_HOST_MAJOR"; }
remote_sync_ensure_remote_dir() { printf '%s\n' "$1" >> "$TEMP_DIR/remote-dirs"; }
rsync() { printf '%s\n' "$*" >> "$TEMP_DIR/transfers"; }
is_repo_enabled() { return 0; }
print_phase_banner() { :; }

MOCK_HOST_MAJOR=10
LOCAL_REPO_PATH="$TEMP_DIR/repos"
SHARED_CACHE_PATH="$TEMP_DIR/cache"
SHARED_REPO_PATH="$TEMP_DIR/published"
REMOTE_SYNC_SOURCE_BASE="$LOCAL_REPO_PATH"
REMOTE_SYNC_TARGET_BASE='D:/repo/OracleLinux/OL10'
REMOTE_SYNC_HOST=mock-host
REMOTE_SYNC_USER=mock-user
REMOTE_SYNC_MAPPING_FILE=''
SYNC_MODE=remote
mkdir -p "$LOCAL_REPO_PATH" "$SHARED_REPO_PATH"

parse_args --os-major 10
[[ "$REPO_OS_MAJOR" == 10 ]]
if parse_args --os-major; then exit 1; fi
if parse_args --os-major 11; then exit 1; fi
configure_os_major_boundary
[[ "$SHARED_CACHE_PATH" == "$TEMP_DIR/cache/ol10" ]]
configure_os_major_boundary
[[ "$SHARED_CACHE_PATH" == "$TEMP_DIR/cache/ol10" ]]
should_process_repo ol10_baseos_latest
for repo in ol9_baseos_latest ol9_UEKR8 ol100_appstream pgdg16 ol10_../ol9_appstream; do
    if should_process_repo "$repo"; then exit 1; fi
done
REPOS=ol9_baseos_latest
if should_process_repo ol9_baseos_latest; then exit 1; fi
REPOS=ol10_appstream
if should_process_repo ol10_baseos_latest; then exit 1; fi
EXCLUDE_REPOS=ol10_appstream
if should_process_repo ol10_appstream; then exit 1; fi
REPOS=''
EXCLUDE_REPOS=''
MOCK_HOST_MAJOR=9
if configure_os_major_boundary; then exit 1; fi
SYNC_ONLY=1
configure_os_major_boundary
MOCK_HOST_MAJOR=10
REPO_OS_MAJOR=invalid
if configure_os_major_boundary; then exit 1; fi
REPO_OS_MAJOR=10
printf 'PASS: CLI, host-major guard, cache namespace and repository selection\n'

for target in 'D:/repo/OracleLinux/OL9' 'D:/repo/OracleLinux/OL8' 'D:/repo/OL10/../OL9'; do
    REMOTE_SYNC_TARGET_BASE="$target"
    if validate_os_major_sync_paths; then exit 1; fi
done
REMOTE_SYNC_TARGET_BASE='D:/repo/OracleLinux/OL10'
if validate_os_major_path '/unversioned/publication' 1; then exit 1; fi
REMOTE_SYNC_MAPPING_FILE="$TEMP_DIR/mapping.ps1"
printf '%s\n' '"ol10_appstream" = "appstream/x86_64"' '"ol10_baseos_latest" = "OL9/baseos"' > "$REMOTE_SYNC_MAPPING_FILE"
mkdir -p "$LOCAL_REPO_PATH/ol10_appstream" "$LOCAL_REPO_PATH/ol10_baseos_latest"
if sync_to_remote_target; then exit 1; fi
[[ ! -e "$TEMP_DIR/remote-dirs" && ! -e "$TEMP_DIR/transfers" ]]
printf 'PASS: conflicting mapping aborts before any remote writes\n'

printf '%s\n' '"ol9_appstream" = "appstream/x86_64"' '"ol10_appstream" = "appstream/x86_64"' '"ol10_addons" = "addons/x86_64"' > "$REMOTE_SYNC_MAPPING_FILE"
mkdir -p "$LOCAL_REPO_PATH/ol9_appstream" "$LOCAL_REPO_PATH/ol10_addons" "$LOCAL_REPO_PATH/pgdg16"
EXCLUDE_REPOS=ol10_addons
if ! sync_to_remote_target; then exit 1; fi
[[ "$(wc -l < "$TEMP_DIR/transfers")" -eq 1 ]]
grep -q 'OL10/appstream' "$TEMP_DIR/remote-dirs"
if grep -Eq 'ol9_|addons|pgdg16' "$TEMP_DIR/transfers"; then exit 1; fi
printf 'PASS: mapped remote sync honors major boundary and exclusions\n'

rm "$TEMP_DIR/transfers" "$TEMP_DIR/remote-dirs"
REMOTE_SYNC_MAPPING_FILE=''
if ! sync_to_remote_target; then exit 1; fi
[[ "$(wc -l < "$TEMP_DIR/transfers")" -eq 2 ]]
if grep -Eq 'ol9_|addons|pgdg16' "$TEMP_DIR/transfers"; then exit 1; fi
printf 'PASS: unmapped remote sync honors major boundary and exclusions\n'

SYNC_MODE=local
rm "$TEMP_DIR/transfers"
if ! sync_to_shared_repos; then exit 1; fi
[[ "$(wc -l < "$TEMP_DIR/transfers")" -eq 2 ]]
if grep -Eq 'ol9_|addons|pgdg16' "$TEMP_DIR/transfers"; then exit 1; fi
SHARED_REPO_PATH="$TEMP_DIR/OL9"
if validate_os_major_sync_paths; then exit 1; fi
printf 'PASS: local sync honors boundary, exclusions and destination checks\n'

FULL_REBUILD=1
for repo in ol9_appstream ol10_appstream ol10_addons pgdg16; do
    mkdir -p "$LOCAL_REPO_PATH/$repo/getPackage"
    touch "$LOCAL_REPO_PATH/$repo/getPackage/test.rpm"
done
if ! full_rebuild_repos; then exit 1; fi
[[ ! -f "$LOCAL_REPO_PATH/ol10_appstream/getPackage/test.rpm" ]]
for repo in ol9_appstream ol10_addons pgdg16; do
    [[ -f "$LOCAL_REPO_PATH/$repo/getPackage/test.rpm" ]]
done
REPO_OS_MAJOR=''
should_process_repo pgdg16
printf 'PASS: rebuild preserves protected repositories; legacy mode remains available\n'