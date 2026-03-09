#!/bin/bash
#
# sync_to_airgap.sh
#
# Developed by: Dániel Némethy (nemethy@moderato.hu)
# Assisted iteratively by automation (GitHub Copilot, GPT-5-Codex)
# Last Updated: 2026-03-09
#
# Synchronizes repositories to an air-gapped Windows server using rsync.
# This script reads the repository mappings from the PowerShell script
# 'syncrepo.ps1' and uses rsync to mirror the directories.
#

set -e
set -o pipefail

VERSION="1.2.0"

# --- Configuration ---
REMOTE_HOST="mgmt3"
REMOTE_USER="nemethy"
# mgmt3 (Windows Server 2025, Git Bash SSH) serves the repo from D:\repo
# Path style: /d/... (Git Bash), NOT /cygdrive/d/... (Cygwin)
REMOTE_BASE_PATH_WIN="D:/repo/OracleLinux/OL9"
SOURCE_BASE_PATH="$HOME/shared-repo/ol9_repos"
MAPPING_FILE="$HOME/shared-repo/syncrepo.ps1"

# --- Argument Parsing ---
DRY_RUN=""
if [[ "$1" == "--dry-run" ]]; then
    DRY_RUN="--dry-run"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] --- DRY RUN MODE ENABLED ---"
fi

# --- Functions ---

# Function to log messages
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

# Function to convert a Windows path (e.g. D:/path) to a Git Bash-style path (/d/path)
# mgmt3 uses Git Bash over SSH, not Cygwin — paths are /d/... not /cygdrive/d/...
windows_to_cygdrive() {
    local win_path=$1
    local drive_letter
    drive_letter=$(printf "%s" "${win_path:0:1}" | tr '[:upper:]' '[:lower:]')
    local path_without_drive="${win_path:2}"
    path_without_drive="${path_without_drive//\\//}"
    path_without_drive="${path_without_drive#/}"
    echo "/${drive_letter}/${path_without_drive}"
}


# Ensure the destination directory exists on the remote host.
# Uses PowerShell New-Item via SSH; silent if already exists.
ensure_remote_dir() {
    local win_path="$1"   # e.g. D:/repo/OracleLinux/OL9/pgdg16/x86_64

    local result
    result=$(ssh -l "${REMOTE_USER}" -o LogLevel=ERROR -o ServerAliveInterval=60 \
        "${REMOTE_HOST}" \
        "powershell.exe -NoProfile -Command \"if (!(Test-Path '$win_path')) { New-Item -ItemType Directory -Force -Path '$win_path' | Out-Null; Write-Host 'CREATED' } else { Write-Host 'EXISTS' }\"" \
        2>/dev/null)

    if [[ "$result" == *"CREATED"* ]]; then
        log "  Remote dir created: ${win_path}"
    elif [[ "$result" != *"EXISTS"* ]]; then
        log "WARNING: Could not verify/create remote dir: ${win_path} (response: ${result})"
    fi
}
# --- Main Script ---

log "sync_to_airgap.sh v$VERSION"
log "Starting repository synchronization to $REMOTE_HOST..."

if [[ ! -f "$MAPPING_FILE" ]]; then
    log "ERROR: Mapping file not found at $MAPPING_FILE"
    exit 1
fi

if [[ ! -d "$SOURCE_BASE_PATH" ]]; then
    log "ERROR: Source directory not found at $SOURCE_BASE_PATH"
    exit 1
fi

# Parse the PowerShell hashtable from syncrepo.ps1
# This uses grep to find lines with '=', sed to clean them up, and a while loop to read them.
log "Reading repository mappings from $MAPPING_FILE..."
grep -E '^\s*".+"\s*=\s*".+"' "$MAPPING_FILE" | sed -E 's/^\s*"//; s/"\s*=\s*"/ /; s/"\s*$//' | while read -r source_fragment dest_fragment; do
    
    source_dir="${SOURCE_BASE_PATH}/${source_fragment}/"
    
    # The destination path needs to be constructed for rsync
    # The path on the remote machine will be something like:
    # /cygdrive/c/repo/OracleLinux/OL9/UEKR7/x86_64
    # Rsync on Windows via ssh often uses /cygdrive/c/ style paths.
    # Let's construct the path without it first and see if the server handles it.
    remote_dest_path_win="${REMOTE_BASE_PATH_WIN}/${dest_fragment//\\//}"
    remote_dest_path_rsync=$(windows_to_cygdrive "${remote_dest_path_win}")

    log "--- Syncing ${source_fragment} ---"
    
    if [[ ! -d "$source_dir" ]]; then
        log "WARNING: Source directory not found, skipping: $source_dir"
        continue
    fi

    log "Source: $source_dir"
    log "Destination (Windows): ${REMOTE_HOST}:${remote_dest_path_win}"
    log "Destination (rsync): ${REMOTE_HOST}:${remote_dest_path_rsync}"

    # Ensure destination directory exists on remote before rsync
    ensure_remote_dir "${remote_dest_path_win}"

    # The rsync command
    # --archive: recursive, preserves permissions, times, etc.
    # --verbose: show what's happening
    # --compress: compress file data during the transfer
    # --delete: delete extraneous files from dest dirs
    # --partial: keep partially transferred files so VPN reconnects can resume
    # --info=progress2: show overall progress (percent, ETA, throughput)
    # --human-readable: format sizes in friendly units
    # -e "ssh": use our custom rssh command
        rsync --archive --verbose --compress --delete --partial \
                    --info=progress2 --human-readable ${DRY_RUN} \
                    -e "ssh -l ${REMOTE_USER} -o ServerAliveInterval=60 -o ServerAliveCountMax=10" \
                    "${source_dir}" \
                    "${REMOTE_HOST}:${remote_dest_path_rsync}"

    log "Sync for ${source_fragment} completed."
    echo # Add a blank line for readability

done

log "All repositories synchronized successfully."
