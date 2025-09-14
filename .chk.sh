#!/bin/bash
# shellcheck shell=bash
# shellcheck disable=SC2155  # Allow 'local var=$(...)' style across the script

# Developed by: Dániel Némethy (nemethy@moderato.hu)
# Assisted iteratively by AI automation (GitHub Copilot Chat) per documented prompts.
# Last Updated: 2025-08-16

# MIT licensing
# Purpose:
# This script replicates and updates repositories from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# local repositories. Optimized for performance with intelligent caching.

# Lightweight, producti0on-focused version (complex adaptive tuning removed previously).

# Script version

VERSION="2.4.4"
# Bash version guard (requires >= 4 for associative arrays used extensively)
if [[ -z "${MYREPO_BASH_VERSION_CHECKED:-}" ]]; then
    MYREPO_BASH_VERSION_CHECKED=1
    if (( BASH_VERSINFO[0] < 4 )); then
        echo -e "\e[31m❌ Bash 4+ required (found ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}). Aborting.\e[0m" >&2
        exit 1
    fi
fi

# Default Configuration (can be overridden by myrepo.cfg)
LOCAL_REPO_PATH="${LOCAL_REPO_PATH:-/repo}"  # Allow external override for testing/isolated runs
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
MANUAL_REPOS=("ol9_edge")  # Array for manually managed repositories (not downloadable via DNF)
LOCAL_RPM_SOURCES=()  # Array for local RPM source directories
DEBUG_LEVEL=${DEBUG_LEVEL:-1}
PLAIN_MODE=${PLAIN_MODE:-0}  # 1 = disable emojis & colors in log output (plain tokens)
# Early pre-scan of arguments for plain mode so even initial configuration logs honor it
if [[ $PLAIN_MODE -eq 0 ]]; then
    for __arg in "$@"; do
        case "$__arg" in
            --plain|--no-emoji|--plain-output)
                PLAIN_MODE=1; break;;
        esac
    done
fi
# Debug level semantic constants (use in place of raw numbers when adding new log lines)
DEBUG_LVL_INFO=1        # Important high-level informational events
DEBUG_LVL_DETAIL=2      # Detailed operational messages (default verbose mode)
DEBUG_LVL_VERBOSE=3     # Very verbose diagnostic messages
# Reference debug level constants once to satisfy static analyzers (SC2034 false positives)
[[ -n "${DEBUG_LVL_INFO}" && -n "${DEBUG_LVL_DETAIL}" && -n "${DEBUG_LVL_VERBOSE}" ]] || true # refs for analyzers
# (Former DEBUG_LVL_TRACE=4 removed; deepest diagnostics now use DEBUG_LVL_VERBOSE)
DRY_RUN=${DRY_RUN:-0}
MAX_PACKAGES=${MAX_PACKAGES:-0}
MAX_CHANGED_PACKAGES=${MAX_CHANGED_PACKAGES:--1}
SYNC_ONLY=${SYNC_ONLY:-0}
NO_SYNC=${NO_SYNC:-0}
NO_METADATA_UPDATE=${NO_METADATA_UPDATE:-0}  # Skip repository metadata updates (createrepo_c)
PARALLEL=${PARALLEL:-6}
EXCLUDE_REPOS=""
REPOS=""
NAME_FILTER=""
FULL_REBUILD=${FULL_REBUILD:-0}
LOG_DIR=${LOG_DIR:-"/var/log/myrepo"}
SET_PERMISSIONS=${SET_PERMISSIONS:-0}
REFRESH_METADATA=${REFRESH_METADATA:-0}
DNF_SERIAL=${DNF_SERIAL:-0}
# Self-test mode (diagnostic JSON output)
SELF_TEST=${SELF_TEST:-0}
JSON_SUMMARY=${JSON_SUMMARY:-0}
# ELEVATE_COMMANDS is now automatically detected based on execution context:
# - When running as root (EUID=0): Uses 'dnf' directly 
# - When running under sudo (SUDO_USER set): Uses 'dnf' directly
# - When running as user: Uses 'sudo dnf' automatically
# - Manual override in config: Set to 0 to disable sudo usage (not recommended unless running as root)
# - The script intelligently detects multiple privilege escalation scenarios
ELEVATE_COMMANDS=${ELEVATE_COMMANDS:-1}  # 1=auto-detect (default), 0=never use sudo
CACHE_MAX_AGE=${CACHE_MAX_AGE:-14400}  # 4 hours cache validity (in seconds)
CLEANUP_UNINSTALLED=${CLEANUP_UNINSTALLED:-1}  # Clean up uninstalled packages by default
USE_PARALLEL_COMPRESSION=${USE_PARALLEL_COMPRESSION:-1}  # Enable parallel compression for createrepo
SHARED_CACHE_PATH=${SHARED_CACHE_PATH:-"/var/cache/myrepo"}  # Shared cache directory for root/user access

# DNF command array (declared early so initialization call works when sourced in tests)
declare -a DNF_CMD  # Global array holding the dnf invocation (sudo dnf | dnf)

# Helper: populate DNF_CMD array (safe, quoted usage everywhere)
function get_dnf_cmd() {
    if [[ $EUID -eq 0 ]] || [[ -n "${SUDO_USER:-}" ]] || [[ -w /root ]]; then
        DNF_CMD=(dnf)
    elif [[ ${ELEVATE_COMMANDS:-1} -eq 1 ]]; then
        DNF_CMD=(sudo dnf)
    else
        DNF_CMD=(dnf)
    fi
}

# Self-test routine: validates environment and outputs JSON summary then exits.
function run_self_test() {
    local ok=1
    local failures=()
    local json
    local required_cmds=(dnf rpm createrepo_c createrepo rsync find awk sed grep sort uniq tee xargs)

    # Collect command availability
    declare -A cmd_status=()
    for c in "${required_cmds[@]}"; do
        if command -v "$c" >/dev/null 2>&1; then
            cmd_status[$c]=1
        else
            cmd_status[$c]=0
            failures+=("missing_command:$c")
            ok=0
        fi
    done

    # Bash version
    local bash_ok=0
    if (( BASH_VERSINFO[0] >= 4 )); then
        bash_ok=1
    else
        failures+=("bash_version_too_old:${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}")
        ok=0
    fi

    # Privilege / sudo test (non-fatal unless elevation required later)
    local sudo_mode
    if [[ $EUID -eq 0 ]]; then
        sudo_mode="root"
    else
        if command -v sudo >/dev/null 2>&1; then
            if timeout "${SUDO_TEST_TIMEOUT:-5}" sudo -n true 2>/dev/null; then
                sudo_mode="sudo-nopass"
            else
                sudo_mode="sudo-pass"
            fi
        else
            sudo_mode="no-sudo"
        fi
    fi

    # Path writability checks
    local paths=("$LOCAL_REPO_PATH" "$SHARED_CACHE_PATH")
    local path_json_entries=()
    for p in "${paths[@]}"; do
        [[ -z "$p" ]] && continue
        local writable=0 exists=0
        if [[ -d "$p" ]]; then
            exists=1
            if [[ -w "$p" ]]; then writable=1; fi
        else
            exists=0
            writable=0
            failures+=("missing_dir:$p")
            ok=0
        fi
        # Attempt a touch test if supposed writable
        if [[ $exists -eq 1 && $writable -eq 1 ]]; then
            local tf="$p/.myrepo_selftest_$$"
            if ( : >"$tf" ) 2>/dev/null; then
                rm -f "$tf" || true
            else
                writable=0
                failures+=("not_writable:$p")
                ok=0
            fi
        fi
        path_json_entries+=("{\"path\":\"$p\",\"exists\":$exists,\"writable\":$writable}")
    done

    # DNF basic query test (lightweight)
    local dnf_query_ok=0
    if command -v dnf >/dev/null 2>&1; then
    if timeout "${DNF_QUERY_TIMEOUT:-10}" dnf -q repolist >/dev/null 2>&1; then
            dnf_query_ok=1
        else
            failures+=("dnf_query_failed")
            ok=0
        fi
    fi

    # Build command status JSON fragment
    local cmd_entries=()
    for k in "${!cmd_status[@]}"; do
        cmd_entries+=("{\"name\":\"$k\",\"present\":${cmd_status[$k]}}")
    done

    # Failures JSON array
    local failures_json="[]"
    if ((${#failures[@]} > 0)); then
        local f_json_parts=()
        for f in "${failures[@]}"; do
            f_json_parts+=("\"$f\"")
        done
        failures_json="[${f_json_parts[*]}]"
    fi

    json=$(printf '{"version":"%s","ok":%s,"bash_ok":%s,"dnf_query_ok":%s,"sudo_mode":"%s","commands":[%s],"paths":[%s],"failures":%s}\n' \
        "$VERSION" "$ok" "$bash_ok" "$dnf_query_ok" "$sudo_mode" \
        "${cmd_entries[*]}" "${path_json_entries[*]}" "$failures_json")

    echo "$json"
    # Exit status 0 if ok else 2 (distinct from general errors)
    if (( ok )); then
        exit 0
    else
        exit 2
    fi
}

# Initialize DNF_CMD early so later functions have a populated command array
get_dnf_cmd

# Timeout configuration (in seconds)
DNF_QUERY_TIMEOUT=${DNF_QUERY_TIMEOUT:-60}    # Timeout for basic DNF queries
DNF_CACHE_TIMEOUT=${DNF_CACHE_TIMEOUT:-120}   # Timeout for DNF cache building operations
DNF_DOWNLOAD_TIMEOUT=${DNF_DOWNLOAD_TIMEOUT:-1800}  # Timeout for DNF download operations (30 minutes)
SUDO_TEST_TIMEOUT=${SUDO_TEST_TIMEOUT:-10}    # Timeout for sudo test commands

# Performance and monitoring configuration
PROGRESS_REPORT_INTERVAL=${PROGRESS_REPORT_INTERVAL:-50}  # Report progress every N packages
PROGRESS_UPDATE_INTERVAL=${PROGRESS_UPDATE_INTERVAL:-30}  # Update interval for progress heartbeats (seconds)
PROGRESS_OVERLAY=${PROGRESS_OVERLAY:-1}  # 1=overwrite single line for progress/stats when TTY
CONFIG_FILE_MAX_LINES=${CONFIG_FILE_MAX_LINES:-500}       # Maximum lines to read from config file
MAX_PARALLEL_DOWNLOADS=${MAX_PARALLEL_DOWNLOADS:-8}       # DNF parallel downloads
DNF_RETRIES=${DNF_RETRIES:-2}                             # DNF retry attempts
DEBUG_FILE_LIST_THRESHOLD=${DEBUG_FILE_LIST_THRESHOLD:-10} # Show file list if repo has fewer RPMs than this
DEBUG_FILE_LIST_COUNT=${DEBUG_FILE_LIST_COUNT:-5}          # Number of files to show in debug list

# Unified batch size configuration
BATCH_SIZE=${BATCH_SIZE:-50}              # Primary batch size used for downloads, rpm metadata queries and removals
FORCE_REDOWNLOAD=${FORCE_REDOWNLOAD:-0}    # 1 = remove existing RPM before downloading; 0 = keep until new file succeeds

# Progress reporting thresholds (configurable to avoid hardcoded magic numbers)
LARGE_BATCH_THRESHOLD=${LARGE_BATCH_THRESHOLD:-200}       # Threshold for large batch progress reporting
PROGRESS_BATCH_THRESHOLD=${PROGRESS_BATCH_THRESHOLD:-50}  # Threshold for periodic progress updates
PACKAGE_LIST_THRESHOLD=${PACKAGE_LIST_THRESHOLD:-100}     # Threshold for package list display in logs
ETA_DISPLAY_THRESHOLD=${ETA_DISPLAY_THRESHOLD:-60}        # Threshold for displaying ETA in minutes vs seconds

# Directory permissions (configurable)
DEFAULT_DIR_PERMISSIONS=${DEFAULT_DIR_PERMISSIONS:-755}   # Default directory permissions (octal)
SHARED_CACHE_PERMISSIONS=${SHARED_CACHE_PERMISSIONS:-1777} # Shared cache directory permissions (sticky bit)
CACHE_FILE_PERMISSIONS=${CACHE_FILE_PERMISSIONS:-644}    # Cache file permissions (readable by all)

# Common Oracle Linux 9 repositories (for fallback repository detection)
declare -a REPOSITORIES=(
    "ol9_baseos_latest"
    "ol9_appstream"
    "ol9_codeready_builder"
    "ol9_developer_EPEL"
    "ol9_developer"
    "ol9_edge"
)

# Formatting constants (matching original script)
PADDING_LENGTH=30  # Default padding length for repository names

# Summary table formatting constants
TABLE_REPO_WIDTH=$PADDING_LENGTH  # Repository name column width
TABLE_NEW_WIDTH=6                 # New packages column width
TABLE_UPDATE_WIDTH=6              # Update packages column width  
TABLE_EXISTS_WIDTH=6              # Existing packages column width
TABLE_STATUS_WIDTH=8              # Status column width

# Statistics tracking arrays
declare -A stats_new_count
declare -A stats_update_count  
declare -A stats_exists_count
declare -A GLOBAL_ENABLED_REPOS_CACHE  # Populated once; reused by is_repo_enabled
GLOBAL_ENABLED_REPOS_CACHE_POPULATED=0

# Failed downloads tracking arrays
declare -A failed_downloads
declare -A failed_download_reasons
# Unknown packages tracking arrays (packages not found in any repository)
declare -A unknown_packages
declare -A unknown_package_reasons
 # Track repositories whose RPM contents changed (new/update/download/removal) to limit metadata updates
declare -A CHANGED_REPOS  # Repos with added/updated/removed RPMs this run
# stats arrays intentionally referenced indirectly (SC2034 suppressed globally)

# Cache for repository package metadata (like original script)
declare -A available_repo_packages
declare -A repo_package_lookup  # key: package signature name|epoch|version|release|arch -> repo

# Helper to reference rarely-touched associative arrays so static analyzers (SC2034) see legitimate use.
function _touch_internal_state_refs() { : "${#stats_new_count[@]}${#stats_update_count[@]}${#stats_exists_count[@]}${#failed_downloads[@]}${#failed_download_reasons[@]}${#unknown_packages[@]}${#unknown_package_reasons[@]}${#CHANGED_REPOS[@]}${#available_repo_packages[@]}"; }

### Function Definitions ###
#
# Grouped by dependency layers (low-level -> mid-level -> high-level orchestration)
# 1. Core utilities & logging (no internal dependencies)
# 2. Environment / path helpers & validation
# 3. Metadata & status helpers (use core + env helpers)
# 4. Classification & batching logic (use status helpers)
# 5. Download, cache, cleanup, sync logic (use batching + helpers)
# 6. Reporting & summary (depend on collected state)
# 7. Main orchestration (glues everything; guarded for sourcing in tests)
#
# NOTE: We no longer force strict alphabetical ordering—functions live in the
#       section matching their dependency level. When adding a new function,
#       pick the lowest section that satisfies its dependencies. This reduces
#       required future movement though some relocation may still occur when
#       refactoring layers.

###############################
# 1. CORE UTILITIES & LOGGING #
###############################

# Align repository names (kept lightweight & pure)
function align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

# Simple logging function with colors (moved early so all later funcs can use it)
