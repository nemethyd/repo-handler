#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with different AI support models
# AI flock: ChatGPT, Claude, Gemini
# Last Updated: 2025-05-25

# MIT licensing
# Purpose:
# This script replicates and updates a local repository from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# older package versions.

# Script version
VERSION=2.1.9
# Default values for environment variables if not set
: "${BATCH_SIZE:=10}"
: "${CONTINUE_ON_ERROR:=0}"
: "${DEBUG_MODE:=0}"
: "${DRY_RUN:=0}"
: "${FULL_REBUILD:=0}"
: "${GROUP_OUTPUT:=1}"
: "${IS_USER_MODE:=0}"
: "${LOG_LEVEL:=INFO}"
: "${MAX_PACKAGES:=0}"
: "${PARALLEL:=4}"
: "${SYNC_ONLY:=0}"

# Default configuration values
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
LOCAL_REPOS=("ol9_edge" "pgdg-common" "pgdg16")
RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Cache configuration defaults
: "${CACHE_MAX_AGE_HOURS:=1}"
: "${CACHE_MAX_AGE_HOURS_NIGHT:=4}"
: "${NIGHT_START_HOUR:=22}"
: "${NIGHT_END_HOUR:=6}"
: "${CACHE_CLEANUP_DAYS:=7}"

# Performance and timing defaults
# Removed unused variables from experimental batch processing:
# JOB_STATUS_CHECK_INTERVAL, XARGS_BATCH_SIZE, MAX_PARALLEL_DOWNLOADS
: "${JOB_WAIT_REPORT_INTERVAL:=60}"
: "${REPOQUERY_PARALLEL:=4}"

# Log directory
LOG_DIR="/var/log/myrepo"

# create a temporary file for logging
TEMP_FILE=$(mktemp /tmp/myrepo_main_$$.XXXXXX)

TEMP_FILES=()

CONFIG_FILE="myrepo.cfg"

# Summary table formatting constants
PADDING_LENGTH=26
TABLE_REPO_WIDTH=$PADDING_LENGTH  # Repository name column width
TABLE_COUNT_WIDTH=8               # Numeric count column width  
TABLE_STATUS_WIDTH=12             # Status column width

# Declare associative arrays
declare -A used_directories
declare -A available_repo_packages

# shellcheck disable=SC2034  # Variable used in functions, not a false positive
declare -A PROCESSED_PACKAGE_MAP

declare -A repo_cache

# Statistics tracking arrays
declare -A stats_new_count
declare -A stats_update_count  
declare -A stats_exists_count
declare -A stats_skipped_count


######################################
### Functions section in abc order ###
######################################

function align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

function check_user_mode() {
    # Check if script is run as root
    if [[ -z $IS_USER_MODE && $EUID -ne 0 ]]; then
        log "ERROR" "This script must be run as root or with sudo privileges."
        exit 1
    fi
    # Set the base directory for temporary files depending on IS_USER_MODE
    if [[ $IS_USER_MODE -eq 1 ]]; then
        TMP_DIR="$HOME/tmp"
        mkdir -p "$TMP_DIR" || {
            log "ERROR" "Failed to create temporary directory $TMP_DIR for user mode."
            exit 1
        }
    else
        TMP_DIR="/tmp"
    fi
    INSTALLED_PACKAGES_FILE="$TMP_DIR/installed_packages.lst"
    PROCESSED_PACKAGES_FILE="$TMP_DIR/processed_packages.share"
}

# Cleanup function to remove temporary files
function cleanup() {
    rm -f "$TEMP_FILE" "$INSTALLED_PACKAGES_FILE" "$PROCESSED_PACKAGES_FILE"
    rm -f "${TEMP_FILES[@]}"
}

function cleanup_metadata_cache() {
    local cache_dir="$HOME/.cache/myrepo"
    local max_age_days=7
    
    if [[ -d "$cache_dir" ]]; then
        # Remove cache files older than max_age_days
        find "$cache_dir" -name "*.cache" -type f -mtime +$max_age_days -delete 2>/dev/null
        log "DEBUG" "Cleaned old metadata cache files (older than $max_age_days days)"
    fi
}

# Create the temporary files and ensure they have correct permissions
function create_helper_files() {
    touch "$INSTALLED_PACKAGES_FILE" "$PROCESSED_PACKAGES_FILE" || {
        log "ERROR" "Failed to create temporary files in $TMP_DIR."
        exit 1
    }
    # Print debug information if DEBUG_MODE is enabled
    if [ "${DEBUG_MODE:-0}" -gt 0 ]; then
        log "DEBUG" "Created helper files: INSTALLED_PACKAGES_FILE=$INSTALLED_PACKAGES_FILE, PROCESSED_PACKAGES_FILE=$PROCESSED_PACKAGES_FILE"
    fi
}

function create_temp_file() {
    local tmp_file
    tmp_file=$(mktemp /tmp/myrepo_"$(date +%s)"_$$.XXXXXX)
    TEMP_FILES+=("$tmp_file")
    echo "$tmp_file"
}

function determine_repo_source() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_release=$4
    local package_arch=$5

    for repo in "${ENABLED_REPOS[@]}"; do
        # Reconstruct the expected package string without epoch if it's '0'
        local expected_package
        if [[ -n "$epoch_version" && "$epoch_version" != "0" ]]; then
            expected_package="${package_name}|${epoch_version}|${package_version}|${package_release}|${package_arch}"
        else
            expected_package="${package_name}|0|${package_version}|${package_release}|${package_arch}"
        fi

        # Compare with cached repo metadata
        if echo "${available_repo_packages[$repo]}" | grep -Fxq "$expected_package"; then
            echo "$repo"
            return
        fi
    done

    echo "Invalid" # Default to Invalid if no matching repo is found
}

# Download packages with parallel downloads or use local cached RPMs
function download_packages() {
    local packages=("$@")
    local repo_path
    local package_name
    local package_version
    local package_release
    local package_arch
    local epoch

    declare -A repo_packages

    for pkg in "${packages[@]}"; do
        IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<<"$pkg"

        # Only include epoch if it's not '0'
        if [[ -n "$epoch" && "$epoch" != "0" ]]; then
            package_version_full="${epoch}:${package_version}-${package_release}.$package_arch"
        else
            package_version_full="${package_version}-${package_release}.$package_arch"
        fi

        if [ -n "$repo_path" ]; then
            if [[ ! " ${LOCAL_REPOS[*]} " == *" ${repo_name} "* ]]; then
                # Check if RPM is available locally
                local rpm_path
                rpm_path=$(locate_local_rpm "$package_name" "$package_version" "$package_release" "$package_arch")

                if [[ -n "$rpm_path" ]]; then
                    echo -e "\e[32m$(align_repo_name "$repo_name"): Using local RPM for $package_name-$package_version-$package_release.$package_arch\e[0m"
                    cp "$rpm_path" "$repo_path"
                else
                    # Add to repo_packages for downloading
                    repo_packages["$repo_path"]+="$package_name-$package_version_full "
                fi
            fi
        fi
    done

    for repo_path in "${!repo_packages[@]}"; do
        mkdir -p "$repo_path" || {
            log_to_temp_file "Failed to create directory: $repo_path"
            exit 1
        }

        # Run download in background
        if ((DRY_RUN)); then
            log_to_temp_file "Dry Run: Would download packages to $repo_path: ${repo_packages[$repo_path]}"
        else
            {
                log_to_temp_file "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
                # Check if sudo is required and set the appropriate command prefix
                DNF_COMMAND="dnf --setopt=max_parallel_downloads=$PARALLEL_DOWNLOADS download --arch=x86_64,noarch --destdir=$repo_path --resolve ${repo_packages[$repo_path]}"

                if [[ -z "$IS_USER_MODE" ]]; then
                    DNF_COMMAND="sudo $DNF_COMMAND"
                fi

                [[ DEBUG_MODE -ge 2 ]] && log "INFO" "Executing: $DNF_COMMAND"
                if ! $DNF_COMMAND 1>>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then

                    log_to_temp_file "Failed to download packages: ${repo_packages[$repo_path]}"
                    ((CONTINUE_ON_ERROR == 0)) && exit 1
                fi
            } &
        fi
        wait_for_jobs # Control the number of parallel jobs
    done
}

# Intelligent caching system with version-based metadata management
function download_repo_metadata() {
    local cache_dir="$HOME/.cache/myrepo"
    mkdir -p "$cache_dir"
    local cache_max_age=$((CACHE_MAX_AGE_HOURS * 3600))  # Convert hours to seconds
    local hour
    hour=$(date +%H)
    # Remove leading zero to avoid octal interpretation
    hour=$((10#$hour))
    if (( hour >= NIGHT_START_HOUR || hour <= NIGHT_END_HOUR )); then
        cache_max_age=$((CACHE_MAX_AGE_HOURS_NIGHT * 3600))
    fi

    declare -A repo_needs_update
    declare -A repo_versions

    # Helper: get repomd.xml URL for a repo
    function get_repomd_url() {
        local repo="$1"
        local baseurl
        baseurl=$(dnf config-manager --dump "$repo" 2>/dev/null | awk -F= '/^baseurl/ {print $2; exit}')
        # Remove trailing slashes
        baseurl="${baseurl%%/}"
        echo "$baseurl/repodata/repomd.xml"
    }

    # Helper: get repomd.xml checksum or timestamp
    function get_repomd_version() {
        local url="$1"
        local version=""
        # Try to fetch and parse repomd.xml
        if curl -s --max-time 10 "$url" >"$cache_dir/repomd.xml.tmp"; then
            # Try to extract <revision> (timestamp) or <checksum>
            version=$(awk -F'[<>]' '/<revision>/ {print $3; exit}' "$cache_dir/repomd.xml.tmp")
            if [[ -z "$version" ]]; then
                version=$(awk -F'[<>]' '/<checksum/ {getline; print $1; exit}' "$cache_dir/repomd.xml.tmp")
            fi
        fi
        rm -f "$cache_dir/repomd.xml.tmp"
        echo "$version"
    }

    for repo in "${ENABLED_REPOS[@]}"; do
        local cache_file="$cache_dir/${repo}.cache"
        local version_file="$cache_dir/${repo}.version"
        local repomd_url
        repomd_url=$(get_repomd_url "$repo")
        local upstream_version
        upstream_version=$(get_repomd_version "$repomd_url")
        repo_versions["$repo"]="$upstream_version"
        local cached_version=""
        [[ -f "$version_file" ]] && cached_version=$(cat "$version_file")
        if [[ -z "$upstream_version" ]]; then
            # Fallback: time-based aging
            if [[ ! -f "$cache_file" || $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -gt $cache_max_age ]]; then
                repo_needs_update["$repo"]=1
            else
                repo_needs_update["$repo"]=0
            fi
        else
            if [[ ! -f "$cache_file" || "$upstream_version" != "$cached_version" ]]; then
                repo_needs_update["$repo"]=1
            else
                repo_needs_update["$repo"]=0
            fi
        fi
    done

    # Fetch metadata in parallel for repos that need update
    local max_parallel=${REPOQUERY_PARALLEL}
    local running=0
    for repo in "${ENABLED_REPOS[@]}"; do
        if [[ " ${EXCLUDED_REPOS[*]} " =~ $repo ]]; then
            continue
        fi
        if [[ ${repo_needs_update["$repo"]} -eq 1 ]]; then
            log "INFO" "Fetching metadata for $repo in background..."
            (
                if repo_data=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>"$MYREPO_ERR_FILE"); then
                    echo "$repo_data" > "$cache_dir/${repo}.cache"
                    # Save version if available
                    if [[ -n "${repo_versions[$repo]}" ]]; then
                        echo "${repo_versions[$repo]}" > "$cache_dir/${repo}.version"
                    fi
                    if [[ -n "${repo_versions[$repo]}" ]]; then
                        log "INFO" "Cached metadata for $repo ($(echo "$repo_data" | wc -l) packages) [version: ${repo_versions[$repo]}]"
                    else
                        log "INFO" "Cached metadata for $repo ($(echo "$repo_data" | wc -l) packages)"
                    fi
                else
                    log "ERROR" "Failed to fetch metadata for $repo"
                fi
            ) &
            ((++running))
            if (( running >= max_parallel )); then
                wait -n 2>/dev/null || wait
                ((--running))
            fi
        else
            if [[ -n "${repo_versions[$repo]}" ]]; then
                log "DEBUG" "Using cached metadata for $repo [version: ${repo_versions[$repo]}]"
            else
                log "DEBUG" "Using cached metadata for $repo"
            fi
        fi
    done
    # Wait for all background jobs to finish
    wait
    log "INFO" "All metadata fetch jobs finished."
    # Load metadata into available_repo_packages
    for repo in "${ENABLED_REPOS[@]}"; do
        local cache_file="$cache_dir/${repo}.cache"
        if [[ -f "$cache_file" ]]; then
            available_repo_packages["$repo"]=$(cat "$cache_file")
        fi
    done
}

function draw_table_border() {
    local border_type="${1:-top}" # top, middle, bottom
    
    # Box drawing characters
    case "$border_type" in
        "top")
            local left="┌" middle="┬" right="┐" horizontal="─"
            ;;
        "middle")
            local left="├" middle="┼" right="┤" horizontal="─"
            ;;
        "bottom")
            local left="└" middle="┴" right="┘" horizontal="─"
            ;;
    esac
    
    printf "%s" "$left"
    printf "%*s" $TABLE_REPO_WIDTH "" | tr ' ' "$horizontal"
    printf "%s" "$middle"
    printf "%*s" $TABLE_COUNT_WIDTH "" | tr ' ' "$horizontal"
    printf "%s" "$middle"
    printf "%*s" $TABLE_COUNT_WIDTH "" | tr ' ' "$horizontal"
    printf "%s" "$middle"
    printf "%*s" $TABLE_COUNT_WIDTH "" | tr ' ' "$horizontal"
    printf "%s" "$middle"
    printf "%*s" $TABLE_COUNT_WIDTH "" | tr ' ' "$horizontal"
    printf "%s" "$middle"
    printf "%*s" $TABLE_STATUS_WIDTH "" | tr ' ' "$horizontal"
    printf "%s\n" "$right"
}

function draw_table_header() {
    printf "│ %-*s │ %*s │ %*s │ %*s │ %*s │ %-*s │\n" \
        $TABLE_REPO_WIDTH "Repository" \
        $TABLE_COUNT_WIDTH "New" \
        $TABLE_COUNT_WIDTH "Update" \
        $TABLE_COUNT_WIDTH "Exists" \
        $TABLE_COUNT_WIDTH "Skipped" \
        $TABLE_STATUS_WIDTH "Status"
}

function draw_table_row() {
    local repo_name="$1"
    local new_count="$2"
    local update_count="$3"
    local exists_count="$4"
    local skipped_count="$5"
    local status="$6"
    
    printf "│ %-*s │ %*s │ %*s │ %*s │ %*s │ %-*s │\n" \
        $TABLE_REPO_WIDTH "$repo_name" \
        $TABLE_COUNT_WIDTH "$new_count" \
        $TABLE_COUNT_WIDTH "$update_count" \
        $TABLE_COUNT_WIDTH "$exists_count" \
        $TABLE_COUNT_WIDTH "$skipped_count" \
        $TABLE_STATUS_WIDTH "$status"
}

function generate_summary_table() {
    local total_new=0 total_update=0 total_exists=0 total_skipped=0
    
    # Calculate totals - check if arrays exist first
    if [[ ${#stats_new_count[@]} -gt 0 ]]; then
        for repo in "${!stats_new_count[@]}"; do
            ((total_new += stats_new_count[$repo]))
        done
    fi
    if [[ ${#stats_update_count[@]} -gt 0 ]]; then
        for repo in "${!stats_update_count[@]}"; do
            ((total_update += stats_update_count[$repo]))
        done
    fi
    if [[ ${#stats_exists_count[@]} -gt 0 ]]; then
        for repo in "${!stats_exists_count[@]}"; do
            ((total_exists += stats_exists_count[$repo]))
        done
    fi
    if [[ ${#stats_skipped_count[@]} -gt 0 ]]; then
        for repo in "${!stats_skipped_count[@]}"; do
            ((total_skipped += stats_skipped_count[$repo]))
        done
    fi
    
    # Collect all unique repo names and sort them
    local all_repos=()
    for repo in "${!stats_new_count[@]}" "${!stats_update_count[@]}" "${!stats_exists_count[@]}" "${!stats_skipped_count[@]}"; do
        if [[ -n "$repo" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
            all_repos+=("$repo")
        fi
    done
    
    # Sort repositories alphabetically
    mapfile -t all_repos < <(printf '%s\n' "${all_repos[@]}" | sort)
    
    # Print summary table
    echo
    log "INFO" "Package Processing Summary:"
    echo
    draw_table_border "top"
    draw_table_header
    draw_table_border "middle"
    
    for repo in "${all_repos[@]}"; do
        local new_count=${stats_new_count[$repo]:-0}
        local update_count=${stats_update_count[$repo]:-0}  
        local exists_count=${stats_exists_count[$repo]:-0}
        local skipped_count=${stats_skipped_count[$repo]:-0}
        local total_repo=$((new_count + update_count + exists_count + skipped_count))
        
        # Determine status based on activity
        local status
        if ((new_count > 0 || update_count > 0)); then
            status="Modified"
        elif ((exists_count > 0)); then
            status="Unchanged"
        elif ((skipped_count > 0)); then
            status="Skipped"
        else
            status="Empty"
        fi
        
        # Only show repos that had some activity
        if ((total_repo > 0)); then
            draw_table_row "$repo" "$new_count" "$update_count" "$exists_count" "$skipped_count" "$status"
        fi
    done
    
    draw_table_border "middle"
    draw_table_row "TOTAL" "$total_new" "$total_update" "$total_exists" "$total_skipped" "Summary"
    draw_table_border "bottom"
    echo
}

function get_package_status() {
    local repo_name="$1"
    local package_name="$2"
    local epoch="$3"
    local package_version="$4"
    local package_release="$5"
    local package_arch="$6"
    local repo_path="$7"

    [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Checking package status: repo=$repo_name name=$package_name epoch=$epoch version=$package_version release=$package_release arch=$package_arch path=$repo_path"

    # Find all matching RPMs for this package name and arch in the repo_path
    local found_exact=0
    local found_other=0
    shopt -s nullglob
    for rpm_file in "$repo_path"/"${package_name}"-*."$package_arch".rpm; do
        local rpm_epoch rpm_version rpm_release rpm_arch
        rpm_epoch=$(rpm -qp --queryformat '%{EPOCH}' "$rpm_file" 2>/dev/null)
        rpm_version=$(rpm -qp --queryformat '%{VERSION}' "$rpm_file" 2>/dev/null)
        rpm_release=$(rpm -qp --queryformat '%{RELEASE}' "$rpm_file" 2>/dev/null)
        rpm_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>/dev/null)
        [[ "$rpm_epoch" == "(none)" || -z "$rpm_epoch" ]] && rpm_epoch="0"
        # Compare all fields for exact match
        if [[ "$package_name" == "$(rpm -qp --queryformat '%{NAME}' "$rpm_file" 2>/dev/null)" \
           && "$epoch" == "$rpm_epoch" \
           && "$package_version" == "$rpm_version" \
           && "$package_release" == "$rpm_release" \
           && "$package_arch" == "$rpm_arch" ]]; then
            found_exact=1
            break
        else
            # If name and arch match, but version/release/epoch differ, mark as other
            if [[ "$package_name" == "$(rpm -qp --queryformat '%{NAME}' "$rpm_file" 2>/dev/null)" \
               && "$package_arch" == "$rpm_arch" ]]; then
                found_other=1
            fi
        fi
    done
    shopt -u nullglob
    if ((found_exact)); then
        echo "EXISTS"
    elif ((found_other)); then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Left here for consistency
function get_repo_name() {
    local package_repo=$1
    echo "$package_repo"
}

function get_repo_path() {
    local package_repo=$1
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi

    # Construct the path based on repository name
    echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
}

function is_package_in_local_sources() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_release=$4
    local package_arch=$5

    for repo in "${LOCAL_REPOS[@]}"; do
        if [[ -n "$epoch_version" ]]; then
            if echo "${repo_cache[$repo]}" | grep -Fxq "$package_name|$epoch_version|$package_version|$package_release|$package_arch"; then
                echo "$repo"
                return
            fi
        else
            if echo "${repo_cache[$repo]}" | grep -Fxq "$package_name|0|$package_version|$package_release|$package_arch"; then
                echo "$repo"
                return
            fi
        fi
    done

    # Check in rpmbuild directory
    if find "$RPMBUILD_PATH" -name "${package_name}-${package_version}-${package_release}.${package_arch}.rpm" | grep -q .; then
        echo "no"
        return
    fi

    echo "no"
}

function is_package_processed() {
    [[ "${PROCESSED_PACKAGE_MAP[$1]}" == 1 ]]
}

# Load configuration from file, searching standard locations
function load_config() {
    # Check if this is a help/version request - if so, load config silently
    local silent_mode=false
    for arg in "$@"; do
        case "$arg" in
        --help|--version|--clear-cache)
            silent_mode=true
            break
            ;;
        esac
    done

    # Use the global CONFIG_FILE variable
    local current_dir
    local script_dir
    local config_path_current
    local config_path_script
    local found_config_path=""

    current_dir=$(pwd)
    # Get the directory where the script *actually* is, resolving symlinks for robustness
    script_dir=$(cd "$(dirname "$(readlink -f "$0" || echo "$0")")" &>/dev/null && pwd)

    config_path_current="${current_dir}/${CONFIG_FILE}"
    config_path_script="${script_dir}/${CONFIG_FILE}"

    if [[ "$silent_mode" == "false" ]]; then
        log "DEBUG" "Searching for config file '${CONFIG_FILE}'"
        log "DEBUG" "Checking current directory: ${config_path_current}"
    fi

    # --- Search Logic ---
    # 1. Check Current Directory
    if [[ -f "$config_path_current" ]]; then
        [[ "$silent_mode" == "false" ]] && log "INFO" "Found configuration file in current directory: ${config_path_current}"
        found_config_path="$config_path_current"
    else
        # 2. Check Script Directory (only if different from current and not found above)
        #    Use -ef to check if paths resolve to the same file/directory inode, robust way to compare paths
        if ! [[ "$config_path_current" -ef "$config_path_script" ]]; then
            [[ "$silent_mode" == "false" ]] && log "DEBUG" "Checking script directory: ${config_path_script}"
            if [[ -f "$config_path_script" ]]; then
                [[ "$silent_mode" == "false" ]] && log "INFO" "Found configuration file in script directory: ${config_path_script}"
                found_config_path="$config_path_script"
            fi
        fi
    fi

    # --- Load Configuration ---
    if [[ -n "$found_config_path" ]]; then
        [[ "$silent_mode" == "false" ]] && log "INFO" "Loading configuration from ${found_config_path}"
        # Use process substitution to feed the filtered file content to the loop
        while IFS='=' read -r key value || [[ -n "$key" ]]; do # Handle last line without newline correctly
            # Ignore empty lines and lines starting with #
            if [[ -z "$key" || "$key" =~ ^\s*# ]]; then
                continue
            fi

            # Trim leading/trailing whitespace from key and value
            key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # Trim leading/trailing whitespace and remove surrounding quotes from value
            value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//; s/^["'\'']\|["'\'']$//g')

            # Skip if key became empty after trimming
            if [[ -z "$key" ]]; then
                continue
            fi

            log "DEBUG" "Config Override: Setting $key = $value"
            # shellcheck disable=SC2034  # Some variables kept for backward compatibility
            case "$key" in
            BATCH_SIZE) BATCH_SIZE="$value" ;;
            CONTINUE_ON_ERROR) CONTINUE_ON_ERROR="$value" ;;
            DEBUG_MODE) DEBUG_MODE="$value" ;;
            DRY_RUN) DRY_RUN="$value" ;;
            EXCLUDED_REPOS) IFS=',' read -r -a EXCLUDED_REPOS <<<"$value" ;;
            FULL_REBUILD) FULL_REBUILD="$value" ;;
            GROUP_OUTPUT) GROUP_OUTPUT="$value" ;;
            IS_USER_MODE) IS_USER_MODE="$value" ;;
            LOCAL_REPO_PATH) LOCAL_REPO_PATH="$value" ;;
            LOCAL_REPOS) IFS=',' read -r -a LOCAL_REPOS <<<"$value" ;;
            LOG_DIR) LOG_DIR="$value" ;;
            LOG_LEVEL) LOG_LEVEL="$value" ;;
            MAX_PACKAGES) MAX_PACKAGES="$value" ;;
            PARALLEL) PARALLEL="$value" ;;
            RPMBUILD_PATH) RPMBUILD_PATH="$value" ;;
            SHARED_REPO_PATH) SHARED_REPO_PATH="$value" ;;
            SYNC_ONLY) SYNC_ONLY="$value" ;;
            CACHE_MAX_AGE_HOURS) CACHE_MAX_AGE_HOURS="$value" ;;
            CACHE_MAX_AGE_HOURS_NIGHT) CACHE_MAX_AGE_HOURS_NIGHT="$value" ;;
            NIGHT_START_HOUR) NIGHT_START_HOUR="$value" ;;
            NIGHT_END_HOUR) NIGHT_END_HOUR="$value" ;;
            CACHE_CLEANUP_DAYS) CACHE_CLEANUP_DAYS="$value" ;;
            JOB_STATUS_CHECK_INTERVAL) JOB_STATUS_CHECK_INTERVAL="$value" ;;  # Backward compatibility
            JOB_WAIT_REPORT_INTERVAL) JOB_WAIT_REPORT_INTERVAL="$value" ;;
            XARGS_BATCH_SIZE) XARGS_BATCH_SIZE="$value" ;;  # Backward compatibility
            MAX_PARALLEL_DOWNLOADS) MAX_PARALLEL_DOWNLOADS="$value" ;;  # Backward compatibility
            REPOQUERY_PARALLEL) REPOQUERY_PARALLEL="$value" ;;
            *) [[ "$silent_mode" == "false" ]] && log "WARN" "Unknown configuration option in '$found_config_path': $key" ;; # Changed from ERROR to WARN
            esac
        done < <(grep -v '^\s*#' "$found_config_path") # Use grep to filter comments before the loop
    else
        [[ "$silent_mode" == "false" ]] && log "INFO" "Configuration file '${CONFIG_FILE}' not found in current ('${current_dir}') or script ('${script_dir}') directory. Using defaults and command-line arguments."
        # No exit here - defaults defined earlier will be used.
    fi
}

# Load once, at start‑up the processed packages into memory
function load_processed_packages() {
    if [[ -f "$PROCESSED_PACKAGES_FILE" ]]; then
        while IFS= read -r line; do
            PROCESSED_PACKAGE_MAP["$line"]=1
        done <"$PROCESSED_PACKAGES_FILE"
        log "DEBUG" "Loaded ${#PROCESSED_PACKAGE_MAP[@]} processed keys into RAM"
    fi
}

function locate_local_rpm() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local package_arch="$4"

    local rpm_path

    # Search in dnf cache directory
    rpm_path=$(find /var/cache/dnf -name "${package_name}-${package_version}-${package_release}.${package_arch}.rpm" 2>/dev/null | head -n 1)

    if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
        echo "$rpm_path"
    else
        echo ""
    fi
}

# --- compact / full dual‑output logger ---
function log() {
    local level="$1"
    shift
    local message="$1"
    shift
    local color="${1:-}" # optional ANSI color for console
    local color_reset="\e[0m"

    # mapping: level‑>index, level‑>1‑char
    local levels=(ERROR WARN INFO DEBUG)
    local abbrev=(E W I D)
    local lvl_idx=0 tgt_idx=0
    for i in "${!levels[@]}"; do
        [[ ${levels[$i]} == "$LOG_LEVEL" ]] && lvl_idx=$i
        [[ ${levels[$i]} == "$level" ]] && tgt_idx=$i
    done
    ((tgt_idx > lvl_idx)) && return # below current LOG_LEVEL – do nothing

    # ---------- console (compact) ----------
    local compact="[${abbrev[$tgt_idx]}] $message"
    if [[ -n "$color" ]]; then
        echo -e "${color}${compact}${color_reset}"
    else
        echo "$compact"
    fi

    # ---------- full logs ----------
    local ts
    local full
    ts="[$(date '+%Y-%m-%d %H:%M:%S')]"
    full="${ts} [${levels[$tgt_idx]}] $message"
    echo "$full" >>"${PROCESS_LOG_FILE:-/dev/null}"
    [[ -n "$TEMP_FILE" ]] && echo "$full" >>"$TEMP_FILE"
}

function log_to_temp_file() {
    [[ DEBUG_MODE -ge 1 ]] && echo "$1"
    echo "$1" >>"$TEMP_FILE"
}

# Mark a package as processed
function mark_processed() {
    local key="$1"
    PROCESSED_PACKAGE_MAP["$key"]=1
    (
        flock -x 200
        echo "$key" >>"$PROCESSED_PACKAGES_FILE"
    ) 200>>"$PROCESSED_PACKAGES_FILE"
}

### Function: Parse command-line options ###
function parse_args() {
    # Parse command-line options (overrides config file and defaults)
    while [[ "$1" =~ ^-- ]]; do
        case "$1" in
        --batch-size)
            shift
            BATCH_SIZE=$1
            ;;
        --debug-level)
            shift
            DEBUG_MODE=$1
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --exclude-repos)
            shift
            IFS=',' read -r -a EXCLUDED_REPOS <<<"$1"
            ;;
        --full-rebuild)
            FULL_REBUILD=1
            ;;
        --no-group-output)
            GROUP_OUTPUT=0
            ;;
        --local-repo-path)
            shift
            LOCAL_REPO_PATH=$1
            ;;
        --local-repos)
            shift
            IFS=',' read -r -a LOCAL_REPOS <<<"$1"
            ;;
        --log-dir)
            shift
            LOG_DIR=$1
            ;;
        --max-packages)
            shift
            MAX_PACKAGES=$1
            ;;
        --user-mode)
            IS_USER_MODE=1
            ;;
        --parallel)
            shift
            PARALLEL=$1
            ;;
        --shared-repo-path)
            shift
            SHARED_REPO_PATH=$1
            ;;
        --sync-only)
            SYNC_ONLY=1
            ;;
        --version)
            echo "myrepo.sh Version $VERSION"
            exit 0
            ;;
        --help)
            echo "Usage: myrepo.sh [OPTIONS]"
            echo "Options:"
            echo "  --batch-size NUM          Number of packages per batch (default: 10)"
            echo "  --debug-level LEVEL       Set debug level (default: 0)"
            echo "  --dry-run                 Perform a dry run without making changes"
            echo "  --exclude-repos REPOS     Comma-separated list of repos to exclude (default: none)"
            echo "  --full-rebuild            Perform a full rebuild of the repository"
            echo "  --no-group-output         Disable grouping of EXISTS package outputs (show individual messages)"
            echo "  --local-repo-path PATH    Set local repository path (default: /repo)"
            echo "  --local-repos REPOS       Comma-separated list of local repos (default: ol9_edge,pgdg-common,pgdg16)"
            echo "  --log-dir PATH            Set log directory (default: /var/log/myrepo)"
            echo "  --max-packages NUM        Maximum number of packages to process (default: 0)"
            echo "  --parallel NUM            Number of parallel processes (default: 2)"
            echo "  --shared-repo-path PATH   Set shared repository path (default: /mnt/hgfs/ForVMware/ol9_repos)"
            echo "  --sync-only               Only perform createrepo and rsync steps"
            echo "  --user-mode               Run without sudo privileges"
            echo "  --version                 Print script version and exit"
            echo "  --help                    Display this help message and exit"
            exit 0
            ;;
        --clear-cache)
            rm -rf "$HOME/.cache/myrepo"
            echo "Cleared metadata cache"
            exit 0
            ;;
        --cache-max-age)
            shift
            CACHE_MAX_AGE_HOURS=$1
            ;;
        *)
            log "ERROR" "Unknown option: $1"
            exit 1
            ;;
        esac
        shift
    done
}

# Then add this function before is_package_in_local_sources() is called
function populate_repo_cache() {
    log "INFO" "Populating repository cache for local package lookup..."
    
    # Initialize the repo_cache associative array
    for repo in "${LOCAL_REPOS[@]}"; do
        # Skip if the repository is excluded
        if [[ " ${EXCLUDED_REPOS[*]} " == *" ${repo} "* ]]; then
            continue
        fi
        
        repo_path="$LOCAL_REPO_PATH/$repo/getPackage"
        if [[ -d "$repo_path" ]]; then
            # Create a temporary file to store package information
            local tmp_file
            tmp_file=$(mktemp)
            TEMP_FILES+=("$tmp_file")
            
            # Find all RPMs and extract their metadata
            # shellcheck disable=SC2016 # Variables are intentionally not expanded in parent shell
            find "$repo_path" -type f -name "*.rpm" -print0 | \
            xargs -0 -r -n 10 sh -c '
                for rpm_file in "$@"; do
                    if meta=$(rpm -qp --queryformat "%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}" "$rpm_file" 2>/dev/null); then
                        # Handle (none) epoch
                        meta=${meta//(none)/0}
                        echo "$meta"
                    fi
                done
            ' _ >> "$tmp_file"
            
            # Store the cached data
            repo_cache["$repo"]=$(cat "$tmp_file")
        else
            # If directory doesn't exist, initialize with empty string
            repo_cache["$repo"]=""
        fi
    done
}

function prepare_log_files() {
    # Ensure that the log directory exists and is writable
    mkdir -p "$LOG_DIR" || {
        log "ERROR" "Failed to create log directory: $LOG_DIR"
        exit 1
    }

    # Ensure the log directory is writable by the user running the script
    if [[ ! -w "$LOG_DIR" ]]; then
        log "ERROR" "Log directory $LOG_DIR is not writable by the current user."
        log "INFO" "Attempting to set permissions..."

        if [[ $IS_USER_MODE -eq 1 ]]; then
            sudo chown -R "$USER" "$LOG_DIR" || {
                log "ERROR" "Failed to change ownership of $LOG_DIR to $USER"
                exit 1
            }
        fi
        sudo chmod u+w "$LOG_DIR" || {
            log "ERROR" "Failed to set write permissions on $LOG_DIR for the current user."
            exit 1
        }
    fi

    # Define log file paths
    LOCALLY_FOUND_FILE="$LOG_DIR/locally_found.lst"
    MYREPO_ERR_FILE="$LOG_DIR/myrepo.err"
    PROCESS_LOG_FILE="$LOG_DIR/process_package.log"

    # Ensure the log directory is writable by the user running the script
    if [[ ! -w "$LOG_DIR" ]]; then
        log "ERROR" "Log directory $LOG_DIR is not writable by the current user."
        log "INFO" "Attempting to set permissions..."

        if [[ $IS_USER_MODE -eq 0 ]]; then
            sudo chown -R "$USER" "$LOG_DIR" || {
                log "ERROR" "Failed to change ownership of $LOG_DIR to $USER"
                exit 1
            }
        fi

        # In both IS_USER_MODE and non-IS_USER_MODE, attempt to change permissions to allow writing
        chmod u+w "$LOG_DIR" || {
            log "ERROR" "Failed to set write permissions on $LOG_DIR for the current user."
            exit 1
        }
    fi

    # Ensure that the log files exist, then truncate them
    touch "$LOCALLY_FOUND_FILE" "$MYREPO_ERR_FILE" "$PROCESS_LOG_FILE" || {
        log "ERROR" "Failed to create log files in $LOG_DIR."
        exit 1
    }

    : >"$LOCALLY_FOUND_FILE"
    : >"$MYREPO_ERR_FILE"
    : >"$PROCESS_LOG_FILE"
    : >"$INSTALLED_PACKAGES_FILE"

    [[ -f "$PROCESSED_PACKAGES_FILE" ]] || touch "$PROCESSED_PACKAGES_FILE"

    if [[ -n "$FULL_REBUILD" ]]; then
        log "INFO" "Performing full rebuild: clearing processed‑package cache"
        : >"$PROCESSED_PACKAGES_FILE"
    fi
}

#Function for batch processing subprocess
function process_batch() {
    local batch_packages=("$@")

    if ((${#batch_packages[@]} > 0)); then
        [[ DEBUG_MODE -ge 1 ]] && log "INFO" "Processing batch: ${batch_packages[*]}"
        process_packages \
            "$DEBUG_MODE" \
            "${batch_packages[*]}" \
            "${LOCAL_REPOS[*]}" \
            "$PROCESSED_PACKAGES_FILE" \
            "$PARALLEL" &
        # Wait for background jobs to finish before starting a new batch
        wait_for_jobs
    fi
}

function process_packages() {
    local DEBUG_MODE
    local PACKAGES
    local LOCAL_REPOS
    local PROCESSED_PACKAGES_FILE
    local PARALLEL

    DEBUG_MODE=$1
    PACKAGES=("$2")
    LOCAL_REPOS=("$3")
    PROCESSED_PACKAGES_FILE=$4
    PARALLEL=$5

    if [ ${#PACKAGES[@]} -eq 0 ]; then
        log "INFO" "No packages to process."
        return
    fi

    local TEMP_FILE
    TEMP_FILE=$(create_temp_file)

    # Initialize arrays for grouping EXISTS results (when GROUP_OUTPUT=1)
    declare -A exists_count
    declare -A exists_packages

    ### Main processing section ###

    IFS=' ' read -r -a packages <<<"${PACKAGES[@]}"
    local_repos=("${LOCAL_REPOS[@]}")

    # Ensure a temporary file is set for the thread
    if [[ -z "$TEMP_FILE" ]]; then
        log "ERROR" "Temporary file not provided. Creating one."
        TEMP_FILE=$(create_temp_file)
    fi

    # Handle the packages based on their status
    for pkg in "${packages[@]}"; do
        IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<<"$pkg"

        PADDING_LENGTH=22 # Set constant padding length

        pkg_key="${package_name}-${package_version}-${package_release}.${package_arch}"

        # Skip if already processed
        if is_package_processed "$pkg_key"; then
            [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Package $pkg_key already processed, skipping."
            continue
        fi

        if [[ -z "$repo_path" ]]; then
            [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Skipping package with empty repo_path: $package_name"
            continue
        fi

        if ! package_status=$(get_package_status "$repo_name" "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch" "$repo_path"); then
            log "ERROR" "Failed to determine status for package: $package_name-$package_version-$package_release.$package_arch"
            exit 1
        fi

        case $package_status in
        "EXISTS")
            # Track statistics
            ((stats_exists_count["$repo_name"]++))
            
            if [[ $GROUP_OUTPUT -eq 1 ]]; then
                # Collect for batch summary
                ((exists_count["$repo_name"]++))
                if [[ -z "${exists_packages[$repo_name]}" ]]; then
                    exists_packages["$repo_name"]="$package_name-$package_version-$package_release.$package_arch"
                else
                    exists_packages["$repo_name"]="${exists_packages[$repo_name]}, $package_name-$package_version-$package_release.$package_arch"
                fi
            else
                # Default behavior: log immediately
                log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch exists." "\e[32m" # Green
            fi
            mark_processed "$pkg_key"
            ;;
        "NEW")
            # Track statistics
            ((stats_new_count["$repo_name"]++))
            
            if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is new." "\e[33m" # Yellow
                download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                mark_processed "$pkg_key"
            else
                log "INFO" "$(align_repo_name "$repo_name"): Skipping download for local package $package_name-$package_version-$package_release.$package_arch." "\e[33m" # Yellow
            fi
            ;;
        "UPDATE")
            # Track statistics
            ((stats_update_count["$repo_name"]++))
            
            if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                remove_existing_packages "$package_name" "$package_version" "$package_release" "$repo_path"
                log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is updated." "\e[34m" # Blue
                download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                mark_processed "$pkg_key"
            else
                log "INFO" "$(align_repo_name "$repo_name"): Skipping update for local package $package_name-$package_version-$package_release.$package_arch." "\e[34m" # Blue
            fi
            ;;
        *)
            log "ERROR" "$(align_repo_name "$repo_name"): Unknown package status '$package_status' for $package_name-$package_version-$package_release.$package_arch." "\e[31m" # Red
            ;;
        esac
    done

    # Print batch summary for EXISTS packages when GROUP_OUTPUT=1
    if [[ $GROUP_OUTPUT -eq 1 ]]; then
        for repo_name in "${!exists_count[@]}"; do
            local count="${exists_count[$repo_name]}"
            if [[ $count -gt 0 ]]; then
                # Extract package names and create dictionary-style range
                local first_letters=""
                if [[ -n "${exists_packages[$repo_name]}" ]]; then
                    local packages_string="${exists_packages[$repo_name]}"
                    local package_names=()
                    
                    # Split packages and extract package names (preserve case)
                    IFS=', ' read -ra pkg_array <<< "$packages_string"
                    for pkg in "${pkg_array[@]}"; do
                        # Extract package name (before first hyphen)
                        local pkg_name="${pkg%%-*}"
                        package_names+=("$pkg_name")
                    done
                    
                    # Sort package names and remove duplicates using mapfile
                    local sorted_names
                    mapfile -t sorted_names < <(printf '%s\n' "${package_names[@]}" | sort -u)
                    package_names=("${sorted_names[@]}")
                    
                    # Create dictionary-style range display
                    if [[ ${#package_names[@]} -eq 1 ]]; then
                        # Single package: show just the name
                        first_letters=" (${package_names[0]})"
                    elif [[ ${#package_names[@]} -eq 2 ]]; then
                        # Two packages: show both
                        first_letters=" (${package_names[0]}, ${package_names[-1]})"
                    else
                        # Multiple packages: create dictionary-style range
                        local first_pkg="${package_names[0]}"
                        local last_pkg="${package_names[-1]}"
                        
                        # Find common prefix and first difference
                        local min_len=${#first_pkg}
                        [[ ${#last_pkg} -lt $min_len ]] && min_len=${#last_pkg}
                        
                        local common_prefix=""
                        local diff_pos=0
                        for ((i=0; i<min_len; i++)); do
                            if [[ "${first_pkg:$i:1}" == "${last_pkg:$i:1}" ]]; then
                                common_prefix+="${first_pkg:$i:1}"
                                diff_pos=$((i+1))
                            else
                                break
                            fi
                        done
                        
                        # Create range showing up to first difference
                        if [[ $diff_pos -eq 0 ]]; then
                            # No common prefix, show first characters
                            first_letters=" (${first_pkg:0:1}-${last_pkg:0:1})"
                        elif [[ $diff_pos -ge ${#first_pkg} ]] && [[ $diff_pos -ge ${#last_pkg} ]]; then
                            # One is prefix of other or identical - avoid redundant display
                            if [[ "$first_pkg" == "$last_pkg" ]]; then
                                first_letters=" ($first_pkg)"
                            else
                                first_letters=" (${first_pkg}-${last_pkg})"
                            fi
                        else
                            # Show common prefix + first differing characters
                            local first_range="${first_pkg:0:$((diff_pos+1))}"
                            local last_range="${last_pkg:0:$((diff_pos+1))}"
                            
                            # Handle case where one string is shorter
                            [[ $diff_pos -ge ${#first_pkg} ]] && first_range="$first_pkg"
                            [[ $diff_pos -ge ${#last_pkg} ]] && last_range="$last_pkg"
                            
                            # Avoid showing identical ranges like (gnome-gnome)
                            if [[ "$first_range" == "$last_range" ]]; then
                                # If ranges are identical, show just the common part or full names
                                if [[ ${#package_names[@]} -le 5 ]]; then
                                    # For small lists, show first and last full names
                                    first_letters=" (${first_pkg}-${last_pkg})"
                                else
                                    # For larger lists, show just the common prefix
                                    first_letters=" (${common_prefix}*)"
                                fi
                            else
                                first_letters=" ($first_range-$last_range)"
                            fi
                        fi
                    fi
                fi
                
                if [[ $count -eq 1 ]]; then
                    log "INFO" "$(align_repo_name "$repo_name"): 1 package already exists${first_letters}." "\e[32m" # Green
                else
                    log "INFO" "$(align_repo_name "$repo_name"): $count packages already exist${first_letters}." "\e[32m" # Green
                fi
                # Optionally show package details in debug mode
                if [[ $DEBUG_MODE -ge 1 ]]; then
                    log "DEBUG" "$(align_repo_name "$repo_name"): EXISTS packages: ${exists_packages[$repo_name]}" "\e[90m" # Gray
                fi
            fi
        done
    fi

    # Wait for all background jobs to complete before finishing the script
    wait
}

function process_rpm_file() {
    local rpm_file="$1"

    # Debug line to check what rpm_file is being received
    if [[ -z "$rpm_file" ]]; then
        log "ERROR" "Received empty rpm_file argument." "\e[90m" # Gray
        return 1
    fi

    local repo_name
    repo_name=$(basename "$(dirname "$(dirname "$rpm_file")")") # Extract the parent directory name of getPackage

    # Extract package name, version, release, and arch
    local package_name package_version package_release package_arch package_epoch
    package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_version=$(rpm -qp --queryformat '%{VERSION}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_release=$(rpm -qp --queryformat '%{RELEASE}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_epoch=$(rpm -qp --queryformat '%{EPOCH}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    if [[ "$package_epoch" == "(none)" || -z "$package_epoch" ]]; then
        package_epoch="0"
    fi

    # Validate extraction
    if [[ -z "$package_name" || -z "$package_version" || -z "$package_release" || -z "$package_arch" ]]; then
        log "ERROR" "Failed to extract package details from $rpm_file" "\e[90m" # Gray
        return 1
    fi

    # Output formatted with gray text
    [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): ${package_name}-${package_version}-${package_release}.${package_arch} checking" "\e[90m" # Gray

    # Proceed with other operations
    if ! awk -F '|' \
        -v name="$package_name" \
        -v epoch="$package_epoch" \
        -v version="$package_version" \
        -v release="$package_release" \
        -v arch="$package_arch" \
        '($1 == name && $2 == epoch && $3 == version && $4 == release && $5 == arch)' \
        "$INSTALLED_PACKAGES_FILE" >/dev/null; then
        if ((DRY_RUN)); then
            log "INFO" "$(align_repo_name "$repo_name"): ${package_name}-${package_version}-${package_release}.${package_arch} would be removed (dry-run)" "\e[90m" # Gray
        else
            if rm -f "$rpm_file"; then
                log "INFO" "$(align_repo_name "$repo_name"): ${package_name}-${package_version}-${package_release}.${package_arch} removed successfully" "\e[90m" # Gray
            else
                log "ERROR" "$(align_repo_name "$repo_name"): ${package_name}-${package_version}-${package_release}.${package_arch} removal failed" "\e[90m" # Gray
                return 1
            fi
        fi
    else
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): ${package_name}-${package_version}-${package_release}.${package_arch} exists and is not being removed." "\e[90m" # Gray
    fi

}

function remove_excluded_repos() {
    for repo in "${EXCLUDED_REPOS[@]}"; do
        repo_path="$LOCAL_REPO_PATH/$repo"

        # Remove the actual repository directory if it exists
        if [[ -d "$repo_path" ]]; then
            log "INFO" "Removing excluded repository: $repo_path"
            rm -rf "$repo_path"
        fi

        # Determine the sanitized symbolic link name
        sanitized_name=$(sanitize_repo_name "$repo")
        sanitized_link="$LOCAL_REPO_PATH/$sanitized_name"

        # Remove the symbolic link if it exists
        if [[ -L "$sanitized_link" ]]; then
            log "INFO" "Removing symbolic link: $sanitized_link"
            rm -f "$sanitized_link"
        fi
    done
}

# Remove existing package files (ensures only older versions are removed)
function remove_existing_packages() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local repo_path="$4"

    # Only display messages in debug mode
    if ((DEBUG_MODE >= 1)); then
        log "DEBUG" "$(align_repo_name "$repo_name"): Removing older versions of $package_name from $repo_name" "\e[90m" # Gray
    fi

    # Enable nullglob so that the pattern expands to nothing if there are no matches
    shopt -s nullglob

    # Find all RPM files for the exact package
    for file in "$repo_path"/"${package_name}"-[0-9]*.rpm; do
        [ -e "$file" ] || continue
        local filename
        filename=$(basename "$file")

        # Extract the version-release
        file_version_release=$(rpm -qp --queryformat '%{EPOCH}:%{VERSION}-%{RELEASE}' "$file" 2>/dev/null)
        current_version_release="$epoch:$package_version-$package_release"

        # Compare versions
        if [[ "$file_version_release" < "$current_version_release" ]]; then
            if ((DRY_RUN)); then
                if ((DEBUG_MODE >= 1)); then
                    log "DEBUG" "$(align_repo_name "$repo_name"): $filename would be removed (dry-run)" "\e[34m" # Green
                fi
            else
                if ((DEBUG_MODE >= 1)); then
                    log "DEBUG" "$(align_repo_name "$repo_name"): $filename removed" "\e[34m" # Green
                fi
                rm -f "$file"
            fi
        fi
    done

    # Disable nullglob after we're done
    shopt -u nullglob
}

# Optimized function to remove uninstalled packages
function remove_uninstalled_packages() {
    local repo_path="$1"
    local repo_name
    repo_name=$(basename "$(dirname "$repo_path")") # Extract parent directory name

    log "INFO" "$(align_repo_name "$repo_name"): Checking for removed packages" "\e[90m"

    # Create a lookup file for faster searching
    local installed_pkgs_file
    installed_pkgs_file=$(mktemp) || {
        log "ERROR" "Failed to create temporary lookup file"
        return 1
    }
    TEMP_FILES+=("$installed_pkgs_file")
    
    # Extract and sort all installed packages into a lookup file
    if [[ -f "$INSTALLED_PACKAGES_FILE" ]]; then
        awk -F '|' '{print $1"|"$2"|"$3"|"$4"|"$5}' "$INSTALLED_PACKAGES_FILE" | sort > "$installed_pkgs_file"
    fi
    
    # Count total packages for better progress reporting
    local total_rpms
    total_rpms=$(find "$repo_path" -type f -name "*.rpm" | wc -l)
    log "INFO" "$(align_repo_name "$repo_name"): Found $total_rpms RPM packages to check" "\e[90m"
    
    # Create a temporary file to hold packages to remove
    local remove_list
    remove_list=$(mktemp)
    TEMP_FILES+=("$remove_list")
    
    # shellcheck disable=SC2016 # Expressions don't expand in single quotes, but that's intended here
    find "$repo_path" -type f -name "*.rpm" -print0 | \
    xargs -0 -r -P "$PARALLEL" -n 50 sh -c '
        installed_file="$1"
        remove_file="$2"
        dry_run="$3"
        debug_mode="$4"
        shift 4
        for rpm_file in "$@"; do
            # Get all metadata in a single rpm call
            if ! rpm_data=$(rpm -qp --queryformat "%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}" "$rpm_file" 2>/dev/null); then
                echo "Error reading $rpm_file, skipping" >&2
                continue
            fi
            rpm_data=${rpm_data//(none)/0}
            if ! grep -qF "$rpm_data" "$installed_file"; then
                if [ "$dry_run" -eq 1 ]; then
                    echo "$rpm_file" >> "$remove_file.dryrun"
                else
                    echo "$rpm_file" >> "$remove_file"
                fi
            fi
        done
    ' _ "$installed_pkgs_file" "$remove_list" "$DRY_RUN" "$DEBUG_MODE"
    
    local removed_count=0
    local dryrun_count=0
    if [[ -s "$remove_list" && "$DRY_RUN" -eq 0 ]]; then
        removed_count=$(wc -l < "$remove_list")
        if ((DEBUG_MODE >= 1)); then
            while IFS= read -r pkg; do
                log "DEBUG" "$(align_repo_name "$repo_name"): Removed $(basename "$pkg")" "\e[31m"
            done < "$remove_list"
        fi
        xargs -a "$remove_list" -P "$PARALLEL" -n 20 rm -f
        log "INFO" "$(align_repo_name "$repo_name"): $removed_count uninstalled packages removed successfully." "\e[32m"
    elif [[ -f "$remove_list.dryrun" && "$DRY_RUN" -eq 1 ]]; then
        dryrun_count=$(wc -l < "$remove_list.dryrun")
        if ((dryrun_count > 0)); then
            if ((DEBUG_MODE >= 1)); then
                while IFS= read -r pkg; do
                    log "DEBUG" "$(align_repo_name "$repo_name"): Would remove $(basename "$pkg") (dry-run)" "\e[33m"
                done < "$remove_list.dryrun"
            fi
            log "INFO" "$(align_repo_name "$repo_name"): $dryrun_count uninstalled packages would be removed (dry-run)." "\e[33m"
        else
            log "INFO" "$(align_repo_name "$repo_name"): No uninstalled packages to remove." "\e[32m"
        fi
    else
        log "INFO" "$(align_repo_name "$repo_name"): No uninstalled packages to remove." "\e[32m"
    fi
}


function sanitize_repo_name() {
    local repo_name="$1"
    echo "${repo_name//[^a-zA-Z0-9._-]/_}"
}

function set_parallel_downloads() {
    # Calculate the parallel download factor by multiplying PARALLEL and BATCH_SIZE
    PARALLEL_DOWNLOADS=$((PARALLEL * BATCH_SIZE))
    # Cap the parallel downloads at a maximum of 20
    if ((PARALLEL_DOWNLOADS > 20)); then
        PARALLEL_DOWNLOADS=20
    fi
}

# Traverse all packages and place them in local repositories
function traverse_local_repos() {
    if ((SYNC_ONLY == 0)); then

        # Fetch installed packages list with detailed information
        log "INFO" "Fetching list of installed packages..."

        if ! dnf repoquery --installed --qf '%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{repoid}' >"$INSTALLED_PACKAGES_FILE" 2>>"$MYREPO_ERR_FILE"; then
            log "ERROR" "Failed to fetch installed packages list."
            exit 1
        fi

        # Fetch the list of enabled repositories
        log "INFO" "Fetching list of enabled repositories..."

        mapfile -t ENABLED_REPOS < <(dnf repolist enabled | awk 'NR>1 {print $1}')

        if [[ ${#ENABLED_REPOS[@]} -eq 0 ]]; then
            log "ERROR" "No enabled repositories found."
            exit 1
        fi

        # Download repository metadata for enabled repos
        download_repo_metadata

        # Read the installed packages list
        mapfile -t package_lines <"$INSTALLED_PACKAGES_FILE"

        # Processing installed packages
        log "INFO" "Processing installed packages..."
        package_counter=0
        batch_packages=()

        # Main loop processing the lines
        for line in "${package_lines[@]}"; do
            # Expected format: name|epoch|version|release|arch|repoid
            IFS='|' read -r package_name epoch_version package_version package_release package_arch package_repo <<<"$line"

            # Skip if the package is in the excluded list
            if [[ "${EXCLUDED_REPOS[*]}" == *" ${package_repo} "* ]]; then
                log "INFO" "Skipping package $package_name from excluded repository: $package_repo"
                continue
            fi
            if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "@commandline" ]]; then
                package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
                if [[ $DEBUG_MODE -ge 1 ]]; then
                    log "DEBUG" "Determined repo for $package_name: $package_repo"
                fi
            fi
            if [[ "$epoch_version" == "0" || -z "$epoch_version" ]]; then
                package_version_full="$package_version-$package_release.$package_arch"
            else
                package_version_full="$epoch_version:$package_version-$package_release.$package_arch"
            fi
            pkg_key="${package_name}-${package_version_full}"
            if is_package_processed "$pkg_key"; then
                continue
            fi
            if [[ $DEBUG_MODE -ge 2 ]]; then
                log "DEBUG" "Captured: package_name=$package_name, epoch_version=$epoch_version, package_version=$package_version, package_release=$package_release, package_arch=$package_arch, package_repo=$package_repo" >&2
            fi
            if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
                package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
                if [[ $DEBUG_MODE -ge 1 ]]; then
                    log "DEBUG" "Determined repo for $package_name: $package_repo" >&2
                fi
            fi
            if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
                continue
            fi
            repo_path=$(get_repo_path "$package_repo")
            repo_name=$(get_repo_name "$package_repo")
            if [[ -n "$repo_path" ]]; then
                used_directories["$repo_name"]="$repo_path"
                
                # Check package status and update statistics
                if ! package_status=$(get_package_status "$repo_name" "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch" "$repo_path"); then
                    log "WARN" "Failed to determine status for package: $package_name-$package_version-$package_release.$package_arch"
                    package_status="UNKNOWN"
                fi
                
                # Update statistics based on package status
                case $package_status in
                    "EXISTS")
                        ((stats_exists_count["$repo_name"]++))
                        ;;
                    "NEW")
                        ((stats_new_count["$repo_name"]++))
                        ;;
                    "UPDATE")
                        ((stats_update_count["$repo_name"]++))
                        ;;
                    *)
                        ((stats_skipped_count["$repo_name"]++))
                        ;;
                esac
                
                batch_packages+=("$repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path")
                if [[ $DEBUG_MODE -ge 2 ]]; then
                    log "DEBUG" "Adding to batch: $repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path" >&2
                fi
            else
                continue
            fi
            ((package_counter++))
            if ((MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES)); then
                break
            fi
            if ((${#batch_packages[@]} >= BATCH_SIZE)); then
                process_batch "${batch_packages[@]}"
                batch_packages=()
            fi
        done
        if ((${#batch_packages[@]} > 0)); then
            process_batch "${batch_packages[@]}"
        fi
        wait
        log "INFO" "Removing uninstalled packages..."
        for repo in "${!used_directories[@]}"; do
            repo_path="${used_directories[$repo]}"
            
            # Skip removal for repositories listed in LOCAL_REPOS
            if [[ " ${LOCAL_REPOS[*]} " == *" ${repo} "* ]]; then
                log "INFO" "$(align_repo_name "$repo"): Skipping uninstalled package removal for local repository" "\e[33m"
                continue
            fi
            
            if [[ -d "$repo_path" ]]; then
                if ! compgen -G "$repo_path/*.rpm" >/dev/null; then
                    log "INFO" "$(align_repo_name "$repo"): No RPM files found in $repo_path, skipping removal process."
                    continue
                fi
                remove_uninstalled_packages "$repo_path"
            else
                log "INFO" "$(align_repo_name "$repo"): Repository path $repo_path does not exist, skipping."
            fi
        done
        while true; do
            running_jobs=$(jobs -rp | wc -l)
            if ((running_jobs > 0)); then
                log "INFO" "Still removing uninstalled packages, ${running_jobs} jobs remaining..."
                sleep 10
            else
                break
            fi
        done
        wait
    fi # End of SYNC_ONLY condition
}

function update_and_sync_repos() {
    # Update and sync the repositories
    if [ "$MAX_PACKAGES" -eq 0 ]; then
        log "INFO" "Updating repository metadata..."

        # If SYNC_ONLY is set, we need to determine which directories to update
        if ((SYNC_ONLY == 1)); then
            # Find all repositories under LOCAL_REPO_PATH
            while IFS= read -r -d '' dir; do
                repo_name=$(basename "$dir")
                used_directories["$repo_name"]="$dir/getPackage"
            done < <(find "$LOCAL_REPO_PATH" -mindepth 1 -maxdepth 1 -type d -print0)
        fi

        for repo in "${!used_directories[@]}"; do
            package_path="${used_directories[$repo]}"
            repo_path=$(dirname "$package_path")
            repo_name=$(basename "$repo_path")

            if ((DRY_RUN)); then
                log "INFO" "$(align_repo_name "$repo_name"): Would run 'createrepo_c --update $repo_path'"
            else
                log "INFO" "$(align_repo_name "$repo_name"): Updating metadata for $repo_path"
                if ! createrepo_c --update "$repo_path" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                    log "ERROR" "$(align_repo_name "$repo_name"): Error updating metadata for $repo_path"
                fi
            fi
        done

        log "INFO" "Creating sanitized symlinks for synchronization..."

        # Create persistent symlinks for repositories with non-Windows-compatible names
        for repo in "${!used_directories[@]}"; do
            original_path="${used_directories[$repo]}"
            # Skip if original_path is empty
            if [[ -z "$original_path" ]]; then
                log "WARN" "Skipping symlink creation for '$repo' because path is empty"
                continue
            fi

            sanitized_name=$(sanitize_repo_name "$repo")
            sanitized_path="$LOCAL_REPO_PATH/$sanitized_name"

            # Ensure symlink exists and points to the correct path
            if [[ "$sanitized_name" != "$repo" ]]; then
                if [[ -e "$sanitized_path" && ! -L "$sanitized_path" ]]; then
                    log "WARN" "Symlink $sanitized_path exists but is not a symlink, skipping."
                elif [[ ! -e "$sanitized_path" ]]; then
                    ln -s "$original_path" "$sanitized_path"
                fi
            fi
        done

        log "INFO" "Synchronizing repositories..."

        for repo in "$LOCAL_REPO_PATH"/*; do
            repo_name=$(basename "$repo")

            # Skip repositories with non-standard characters
            if [[ "$repo_name" =~ [^a-zA-Z0-9._-] ]]; then
                log "INFO" "$(align_repo_name "$repo_name"): Skipping repository with non-standard characters: $repo_name"
                continue
            fi

            # Define the destination path
            dest_path="$SHARED_REPO_PATH/$repo_name"

            if ((DRY_RUN)); then
                log "INFO" "$(align_repo_name "$repo_name"): Would run 'rsync -av --delete $repo/ $dest_path/'"
            else
                if ! rsync -av --delete "$repo/" "$dest_path/" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                    log "ERROR" "$(align_repo_name "$repo_name"): Error synchronizing repository: $repo_name"
                fi
            fi
        done
    fi
}

# Function to validate configuration and environment
function validate_config() {
    local error=0
    # Numeric checks
    if ! [[ "$BATCH_SIZE" =~ ^[0-9]+$ ]] || (( BATCH_SIZE < 1 )); then
        log "ERROR" "BATCH_SIZE must be a positive integer (got '$BATCH_SIZE')"; error=1
    fi
    if ! [[ "$PARALLEL" =~ ^[0-9]+$ ]] || (( PARALLEL < 1 )); then
        log "ERROR" "PARALLEL must be a positive integer (got '$PARALLEL')"; error=1
    fi
    if ! [[ "$MAX_PACKAGES" =~ ^[0-9]+$ ]]; then
        log "ERROR" "MAX_PACKAGES must be a non-negative integer (got '$MAX_PACKAGES')"; error=1
    fi
    if ! [[ "$CACHE_MAX_AGE_HOURS" =~ ^[0-9]+$ ]] || (( CACHE_MAX_AGE_HOURS < 1 )); then
        log "ERROR" "CACHE_MAX_AGE_HOURS must be a positive integer (got '$CACHE_MAX_AGE_HOURS')"; error=1
    fi
    if ! [[ "$CACHE_MAX_AGE_HOURS_NIGHT" =~ ^[0-9]+$ ]] || (( CACHE_MAX_AGE_HOURS_NIGHT < 1 )); then
        log "ERROR" "CACHE_MAX_AGE_HOURS_NIGHT must be a positive integer (got '$CACHE_MAX_AGE_HOURS_NIGHT')"; error=1
    fi
    if ! [[ "$REPOQUERY_PARALLEL" =~ ^[0-9]+$ ]] || (( REPOQUERY_PARALLEL < 1 )); then
        log "ERROR" "REPOQUERY_PARALLEL must be a positive integer (got '$REPOQUERY_PARALLEL')"; error=1
    fi
    # Directory checks
    if [[ ! -d "$LOCAL_REPO_PATH" ]]; then
        log "ERROR" "LOCAL_REPO_PATH does not exist or is not a directory: $LOCAL_REPO_PATH"; error=1
    fi
    if [[ ! -d "$SHARED_REPO_PATH" ]]; then
        log "WARN" "SHARED_REPO_PATH does not exist or is not a directory: $SHARED_REPO_PATH" # Not fatal
    fi
    if [[ ! -d "$RPMBUILD_PATH" ]]; then
        log "WARN" "RPMBUILD_PATH does not exist or is not a directory: $RPMBUILD_PATH" # Not fatal
    fi
    if [[ ! -d "$LOG_DIR" ]]; then
        log "WARN" "LOG_DIR does not exist or is not a directory: $LOG_DIR" # Will be created
    fi
    # Array checks
    if [[ ${#LOCAL_REPOS[@]} -eq 0 ]]; then
        log "ERROR" "LOCAL_REPOS is empty. At least one local repo must be specified."; error=1
    fi
    # Check that each local repo directory exists (warn only)
    for repo in "${LOCAL_REPOS[@]}"; do
        if [[ ! -d "$LOCAL_REPO_PATH/$repo" ]]; then
            log "WARN" "Local repo directory missing: $LOCAL_REPO_PATH/$repo"
        fi
    done
    # Log summary if debug
    if [[ $DEBUG_MODE -ge 1 ]]; then
        log "DEBUG" "Config summary: BATCH_SIZE=$BATCH_SIZE, PARALLEL=$PARALLEL, LOCAL_REPO_PATH=$LOCAL_REPO_PATH, LOCAL_REPOS=(${LOCAL_REPOS[*]}), LOG_DIR=$LOG_DIR"
    fi
    if (( error )); then
        log "ERROR" "Configuration validation failed. Please fix the above errors."
        exit 2
    fi
}

# Improved function to wait for background jobs with timeout detection
function wait_for_jobs() {
    local current_jobs
    local previous_jobs=0
    local wait_count=0
    local report_interval=60  # Report potentially slow jobs after this many seconds
    
    while true; do
        current_jobs=$(jobs -rp | wc -l)
        
        # Break out if below parallel limit
        if ((current_jobs < PARALLEL)); then
            break
        fi
        
        # Check if job count is changing
        if ((current_jobs == previous_jobs)); then
            ((wait_count++))
            
            # After waiting, just report progress but don't kill
            if ((wait_count % report_interval == 0)); then
                log "INFO" "Some DNF operations are taking longer than expected (${wait_count}s). This is normal for large packages or slow repositories."
                
                # Optionally show what's running for debugging but don't kill anything
                if ((DEBUG_MODE >= 1)); then
                    log "DEBUG" "Current running jobs:"
                    jobs -l | grep -i "dnf\|download"
                fi
            fi
        else
            # Reset counter if job count changes (progress is happening)
            wait_count=0
            previous_jobs=$current_jobs
        fi
        
        log "INFO" "Waiting for jobs in $0 ... Currently running: ${current_jobs}/${PARALLEL}"
        sleep 1
    done
}

# Trap EXIT signal to ensure cleanup is called
exit_code=0
trap '
exit_code=$?
if [[ $exit_code -ne 0 ]]; then
    log "ERROR" "Script exited with status $exit_code at line $LINENO while executing: $BASH_COMMAND"
fi
' EXIT

### Main processing section ###
load_config "$@"
parse_args "$@"
validate_config
check_user_mode
prepare_log_files
log "INFO" "Starting myrepo.sh Version $VERSION"
create_helper_files
load_processed_packages
populate_repo_cache
set_parallel_downloads
remove_excluded_repos
traverse_local_repos
update_and_sync_repos
cleanup_metadata_cache
cleanup

# Generate and display summary table
generate_summary_table

log "INFO" "myrepo.sh Version $VERSION completed."
