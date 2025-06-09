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
VERSION=2.1.2

# Default values for environment variables if not set
: "${BATCH_SIZE:=10}"
: "${CONTINUE_ON_ERROR:=0}"
: "${DEBUG_MODE:=0}"
: "${DRY_RUN:=0}"
: "${FULL_REBUILD:=0}"
: "${IS_USER_MODE:=0}"
: "${LOG_LEVEL:=INFO}"
: "${MAX_PACKAGES:=0}"
: "${PARALLEL:=2}"
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
: "${JOB_STATUS_CHECK_INTERVAL:=10}"
: "${JOB_WAIT_REPORT_INTERVAL:=60}"
: "${XARGS_BATCH_SIZE:=50}"
: "${MAX_PARALLEL_DOWNLOADS:=20}"

# Log directory
LOG_DIR="/var/log/myrepo"

# create a temporary file for logging
TEMP_FILE=$(mktemp /tmp/myrepo_main_$$.XXXXXX)

# Initialize temporary files array for cleanup
TEMP_FILES=()

# Load configuration file if it exists (allowing comment lines)
CONFIG_FILE="myrepo.cfg"

# Set constant padding length for alignment
#PADDING_LENGTH=22

# Declare associative array for used_directories
declare -A used_directories
# Declare associative array for available packages in enabled repos
declare -A available_repo_packages

# Declare map for already processed packages
# shellcheck disable=SC2034  # Variable used in functions, not a false positive
declare -A PROCESSED_PACKAGE_MAP

# Declare array for enabled repositories
declare -A repo_cache


######################################
### Functions section in abc order ###
######################################

# Function to align the output by padding the repo_name
function align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

# Function to check if the script is run as root or with sudo privileges
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
    # Define temporary files paths
    INSTALLED_PACKAGES_FILE="$TMP_DIR/installed_packages.lst"
    PROCESSED_PACKAGES_FILE="$TMP_DIR/processed_packages.share"
}

# Cleanup function to remove temporary files
function cleanup() {
    rm -f "$TEMP_FILE" "$INSTALLED_PACKAGES_FILE" "$PROCESSED_PACKAGES_FILE"
    rm -f "${TEMP_FILES[@]}"
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

# Function to create a unique temporary file and track it for cleanup
function create_temp_file() {
    local tmp_file
    tmp_file=$(mktemp /tmp/myrepo_"$(date +%s)"_$$.XXXXXX)
    TEMP_FILES+=("$tmp_file")
    echo "$tmp_file"
}

# Function to determine the repository source of a package based on available packages
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
                DNF_COMMAND="dnf --setopt=max_parallel_downloads=$PARALLEL download --arch=x86_64,noarch --destdir=$repo_path --resolve ${repo_packages[$repo_path]}"

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

# Function to download repository metadata and store in memory with intelligent caching
function download_repo_metadata() {
    local cache_valid=1
    local cache_max_age=$((CACHE_MAX_AGE_HOURS * 3600))  # Convert hours to seconds
    local cache_dir="$HOME/.cache/myrepo"
    mkdir -p "$cache_dir"
    
    # Extend cache validity period based on time of day
    local hour
    hour=$(date +%H)
    if (( hour >= NIGHT_START_HOUR || hour <= NIGHT_END_HOUR )); then
        cache_max_age=$((CACHE_MAX_AGE_HOURS_NIGHT * 3600))  # Convert night hours to seconds
    fi
    
    # Check if cache exists and is fresh
    for repo in "${ENABLED_REPOS[@]}"; do
        local cache_file="$cache_dir/${repo}_metadata.cache"
        if [[ ! -f "$cache_file" || $(( $(date +%s) - $(stat -c %Y "$cache_file") )) -gt $cache_max_age ]]; then
            cache_valid=0
            break
        fi
    done
    
    # Add cache invalidation based on upstream changes
    if [[ -f "/var/cache/dnf/last_makecache.timestamp" ]]; then
        local last_system_update
        local cache_timestamp
        last_system_update=$(stat -c %Y "/var/cache/dnf/last_makecache.timestamp" 2>/dev/null || echo 0)
        cache_timestamp=$(stat -c %Y "$cache_dir/timestamp" 2>/dev/null || echo 0)
        
        if (( last_system_update > cache_timestamp )); then
            cache_valid=0
            log "INFO" "System repository metadata updated since last cache - refreshing"
            touch "$cache_dir/timestamp"
        fi
    fi
    
    if [[ $cache_valid -eq 1 ]]; then
        log "INFO" "Using cached repository metadata (less than $((cache_max_age/60)) minutes old)"
        # Load cached data
        for repo in "${ENABLED_REPOS[@]}"; do
            local cache_file="$cache_dir/${repo}_metadata.cache"
            if [[ -f "$cache_file" ]]; then
                available_repo_packages["$repo"]=$(cat "$cache_file")
                log "DEBUG" "Loaded ${#available_repo_packages[$repo]} packages from cache for $repo"
            fi
        done
        return 0
    fi
    
    # Regular metadata download with caching
    log "INFO" "Downloading repository metadata..."
    for repo in "${ENABLED_REPOS[@]}"; do
        if [[ " ${EXCLUDED_REPOS[*]} " =~ $repo ]]; then
            continue
        fi
        
        log "INFO" "Fetching metadata for $repo..."
        local repo_data
        if repo_data=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>"$MYREPO_ERR_FILE"); then
            available_repo_packages["$repo"]="$repo_data"
            
            # Cache the results
            local cache_file="$cache_dir/${repo}_metadata.cache"
            echo "$repo_data" > "$cache_file"
            log "DEBUG" "Cached metadata for $repo ($(echo "$repo_data" | wc -l) packages)"
        else
            log "WARN" "Failed to fetch metadata for repository: $repo"
            # Keep existing cache if available
            local cache_file="$cache_dir/${repo}_metadata.cache"
            if [[ -f "$cache_file" ]]; then
                log "INFO" "Using stale cache for $repo due to fetch failure"
                available_repo_packages["$repo"]=$(cat "$cache_file")
            fi
        fi
    done
    
    # Update the timestamp file
    touch "$cache_dir/timestamp"
}

# Function to determine the status of a package
function get_package_status() {
    local repo_name="$1"
    local package_name="$2"
    local epoch="$3"
    local package_version="$4"
    local package_release="$5"
    local package_arch="$6"
    local repo_path="$7"

    [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Checking package status: repo=$repo_name name=$package_name epoch=$epoch version=$package_version release=$package_release arch=$package_arch path=$repo_path"

    local package_pattern="${repo_path}/${package_name}-${package_version}-${package_release}.${package_arch}.rpm"

    if compgen -G "$package_pattern" >/dev/null; then
        echo "EXISTS"
        return
    elif [[ -n "$epoch" ]]; then
        local package_pattern_with_epoch="${repo_path}/${package_name}-${epoch}:${package_version}-${package_release}.${package_arch}.rpm"
        if compgen -G "$package_pattern_with_epoch" >/dev/null; then
            echo "EXISTS"
            return
        fi
    fi

    # Check if there are any packages with this name in the repo_path
    if compgen -G "${repo_path}/${package_name}-*.rpm" >/dev/null; then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Function to get the repository name (left here for consistency)
function get_repo_name() {
    local package_repo=$1
    echo "$package_repo"
}

# Function to get the repository path
function get_repo_path() {
    local package_repo=$1
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi

    # Construct the path based on repository name
    echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
}

# Function to check if a package exists in local sources
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

# Function to check if the package has already been processed
function is_package_processed() {
    [[ "${PROCESSED_PACKAGE_MAP[$1]}" == 1 ]]
}

# Function to load configuration from the config file, searching in standard locations
function load_config() {
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

    log "DEBUG" "Searching for config file '${CONFIG_FILE}'"
    log "DEBUG" "Checking current directory: ${config_path_current}"

    # --- Search Logic ---
    # 1. Check Current Directory
    if [[ -f "$config_path_current" ]]; then
        log "INFO" "Found configuration file in current directory: ${config_path_current}"
        found_config_path="$config_path_current"
    else
        # 2. Check Script Directory (only if different from current and not found above)
        #    Use -ef to check if paths resolve to the same file/directory inode, robust way to compare paths
        if ! [[ "$config_path_current" -ef "$config_path_script" ]]; then
            log "DEBUG" "Checking script directory: ${config_path_script}"
            if [[ -f "$config_path_script" ]]; then
                log "INFO" "Found configuration file in script directory: ${config_path_script}"
                found_config_path="$config_path_script"
            fi
        fi
    fi

    # --- Load Configuration ---
    if [[ -n "$found_config_path" ]]; then
        log "INFO" "Loading configuration from ${found_config_path}"
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
            case "$key" in
            BATCH_SIZE) BATCH_SIZE="$value" ;;
            CONTINUE_ON_ERROR) CONTINUE_ON_ERROR="$value" ;;
            DEBUG_MODE) DEBUG_MODE="$value" ;;
            DRY_RUN) DRY_RUN="$value" ;;
            EXCLUDED_REPOS) IFS=',' read -r -a EXCLUDED_REPOS <<<"$value" ;;
            FULL_REBUILD) FULL_REBUILD="$value" ;;
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
            JOB_STATUS_CHECK_INTERVAL) JOB_STATUS_CHECK_INTERVAL="$value" ;;
            JOB_WAIT_REPORT_INTERVAL) JOB_WAIT_REPORT_INTERVAL="$value" ;;
            XARGS_BATCH_SIZE) XARGS_BATCH_SIZE="$value" ;;
            MAX_PARALLEL_DOWNLOADS) MAX_PARALLEL_DOWNLOADS="$value" ;;
            *) log "WARN" "Unknown configuration option in '$found_config_path': $key" ;; # Changed from ERROR to WARN
            esac
        done < <(grep -v '^\s*#' "$found_config_path") # Use grep to filter comments before the loop
    else
        log "INFO" "Configuration file '${CONFIG_FILE}' not found in current ('${current_dir}') or script ('${script_dir}') directory. Using defaults and command-line arguments."
        # No exit here - defaults defined earlier will be used.
    fi
}

# Function to locate RPM from local cache if available
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

# Load once, at start‑up the processed packages into memory
function load_processed_packages() {
    if [[ -f "$PROCESSED_PACKAGES_FILE" ]]; then
        while IFS= read -r line; do
            PROCESSED_PACKAGE_MAP["$line"]=1
        done <"$PROCESSED_PACKAGES_FILE"
        log "DEBUG" "Loaded ${#PROCESSED_PACKAGE_MAP[@]} processed keys into RAM"
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

# Function to write log to the specific temporary file
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
            echo "  --batch-size NUM          Number of packages per batch (default: $BATCH_SIZE)"
            echo "  --debug-level LEVEL       Set debug level (default: $DEBUG_MODE)"
            echo "  --dry-run                 Perform a dry run without making changes"
            echo "  --exclude-repos REPOS     Comma-separated list of repos to exclude (default: none)"
            echo "  --full-rebuild            Perform a full rebuild of the repository"
            echo "  --local-repo-path PATH    Set local repository path (default: $LOCAL_REPO_PATH)"
            echo "  --local-repos REPOS       Comma-separated list of local repos (default: ${LOCAL_REPOS[*]})"
            echo "  --log-dir PATH            Set log directory (default: $LOG_DIR)"
            echo "  --max-packages NUM        Maximum number of packages to process (default: $MAX_PACKAGES)"
            echo "  --parallel NUM            Number of parallel processes (default: $PARALLEL)"
            echo "  --shared-repo-path PATH   Set shared repository path (default: $SHARED_REPO_PATH)"
            echo "  --sync-only               Only perform createrepo and rsync steps"
            echo "  --user-mode                 Run without sudo privileges"
            exit 0
            ;;
        --clear-cache)
            rm -rf "$HOME/.cache/myrepo"
            log "INFO" "Cleared metadata cache"
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

# Function to prepare log files and directories
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

# Function to process a package batch
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
            log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch exists." "\e[32m" # Green
            mark_processed "$pkg_key"
            ;;
        "NEW")
            if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is new." "\e[33m" # Yellow
                download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                mark_processed "$pkg_key"
            else
                log "INFO" "$(align_repo_name "$repo_name"): Skipping download for local package $package_name-$package_version-$package_release.$package_arch." "\e[33m" # Yellow
            fi
            ;;
        "UPDATE")
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

    # Wait for all background jobs to complete before finishing the script
    wait
}

# Function to process RPM files for uninstallation check
function process_rpm_file() {
    local rpm_file="$1"

    # Debug line to check what rpm_file is being received
    if [[ -z "$rpm_file" ]]; then
        log "ERROR" "Received empty rpm_file argument." "\e[90m" # Gray
        return 1
    fi

    # Extract repo name from the path
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

# Function to remove excluded repositories from the local repository path
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

# Function to remove existing package files (ensures only older versions are removed)
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
    for file in "$repo_path/${package_name}"-[0-9]*.rpm; do
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

    log "INFO" "$(align_repo_name "$repo_name"): Checking for removed packages in $repo_path" "\e[90m"

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
    log "INFO" "Found $total_rpms RPM packages to check in $repo_path"
    
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
        shift 3
        
        for rpm_file in "$@"; do
            # Get all metadata in a single rpm call
            if ! rpm_data=$(rpm -qp --queryformat "%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}" "$rpm_file" 2>/dev/null); then
                echo "Error reading $rpm_file, skipping" >&2
                continue
            fi
            
            # Handle (none) epoch
            rpm_data=${rpm_data//(none)/0}
            
            # Check if package is installed using grep (much faster than awk)
            if ! grep -qF "$rpm_data" "$installed_file"; then
                if [ "$dry_run" -eq 1 ]; then
                    echo "Would remove: $rpm_file" >&2
                else
                    # Add to remove list instead of removing immediately
                    echo "$rpm_file" >> "$remove_file"
                fi
            fi
        done
    ' _ "$installed_pkgs_file" "$remove_list" "$DRY_RUN"
    
    # Now remove files in bulk (much faster than one at a time)
    if [[ -s "$remove_list" && "$DRY_RUN" -eq 0 ]]; then
        local count
        count=$(wc -l < "$remove_list")
        log "INFO" "$(align_repo_name "$repo_name"): Removing $count uninstalled packages"
        
        # Remove in parallel but with controlled batches
        xargs -a "$remove_list" -P "$PARALLEL" -n 20 rm -f
        
        log "INFO" "$(align_repo_name "$repo_name"): Removed $count packages"
    elif [[ -s "$remove_list" && "$DRY_RUN" -eq 1 ]]; then
        local count
        count=$(wc -l < "$remove_list")
        log "INFO" "$(align_repo_name "$repo_name"): Would remove $count uninstalled packages (dry run)"
    else
        log "INFO" "$(align_repo_name "$repo_name"): No packages to remove"
    fi
}


# Function to sanitize repository names (replace invalid characters)
function sanitize_repo_name() {
    local repo_name="$1"
    echo "${repo_name//[^a-zA-Z0-9._-]/_}"
}

# Function to set the number of parallel downloads
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
            if [[ " ${EXCLUDED_REPOS[*]} " == *" ${package_repo} "* ]]; then
                log "INFO" "Skipping package $package_name from excluded repository: $package_repo"
                continue
            fi

            # If the package repo is System, @System, or @commandline, find the corresponding repo
            if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "@commandline" ]]; then
                package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
                if [[ $DEBUG_MODE -ge 1 ]]; then
                    log "DEBUG" "Determined repo for $package_name: $package_repo"
                fi
            fi

            # Handle the case where epoch is '0' or empty (skip it in the filename)
            if [[ "$epoch_version" == "0" || -z "$epoch_version" ]]; then
                package_version_full="$package_version-$package_release.$package_arch"
            else
                package_version_full="$epoch_version:$package_version-$package_release.$package_arch"
            fi

            pkg_key="${package_name}-${package_version_full}"

            # Skip if the package has already been processed
            if is_package_processed "$pkg_key"; then
                [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Package $pkg_key already processed, skipping."
                continue
            fi

            # Debugging: Print captured fields
            if [[ $DEBUG_MODE -ge 2 ]]; then
                log "DEBUG" "Captured: package_name=$package_name, epoch_version=$epoch_version, package_version=$package_version, package_release=$package_release, package_arch=$package_arch, package_repo=$package_repo" >&2
            fi

            # Determine repository source
            if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
                package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
                if [[ $DEBUG_MODE -ge 1 ]]; then
                    log "DEBUG" "Determined repo for $package_name: $package_repo" >&2
                fi
            fi

            # Skip if repository is invalid or commandline
            if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
                [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Skipping package $package_name as it is marked as $package_repo" >&2
                continue
            fi

            # Get repository path and name
            repo_path=$(get_repo_path "$package_repo")
            repo_name=$(get_repo_name "$package_repo")

            if [[ -n "$repo_path" ]]; then
                used_directories["$repo_name"]="$repo_path"
                # Pass 7 fields: repo_name|package_name|epoch_version|package_version|package_release|package_arch|repo_path
                batch_packages+=("$repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path")
                # Debugging: Print the package being added
                if [[ $DEBUG_MODE -ge 2 ]]; then
                    log "DEBUG" "Adding to batch: $repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path" >&2
                fi
            else
                [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Skipping package $package_name as it has no valid repository path" >&2
                continue
            fi

            ((package_counter++))
            if ((MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES)); then
                break
            fi

            # If batch size reached, process the batch
            if ((${#batch_packages[@]} >= BATCH_SIZE)); then
                process_batch "${batch_packages[@]}"
                batch_packages=()
            fi
        done

        # Process any remaining packages in the last batch
        if ((${#batch_packages[@]} > 0)); then
            process_batch "${batch_packages[@]}"
        fi

        wait

        log "INFO" "Removing uninstalled packages..."
        for repo in "${!used_directories[@]}"; do
            repo_path="${used_directories[$repo]}"

            # Check if the repository directory exists and contains any RPM files
            if [[ -d "$repo_path" ]]; then
                # If no RPM files are found, skip this repository
                if ! compgen -G "$repo_path/*.rpm" >/dev/null; then
                    log "INFO" "$(align_repo_name "$repo"): No RPM files found in $repo_path, skipping removal process."
                    continue
                fi

                # Run remove_uninstalled_packages if RPM files are present
                remove_uninstalled_packages "$repo_path"
            else
                log "INFO" "$(align_repo_name "$repo"): Repository path $repo_path does not exist, skipping."
            fi
        done

        # Periodically check the status of running background jobs
        while true; do
            running_jobs=$(jobs -rp | wc -l)
            if ((running_jobs > 0)); then
                log "INFO" "$(align_repo_name "$repo"): Still removing uninstalled packages, ${running_jobs} jobs remaining..."
                sleep 10 # Adjust the interval as needed to avoid excessive output
            else
                break
            fi
        done

        # Wait for all background jobs to finish
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
                log "INFO" "$(align_repo_name "$repo_name"): Would run 'createrepo --update $repo_path'"
            else
                log "INFO" "$(align_repo_name "$repo_name"): Updating metadata for $repo_path"
                if ! createrepo --update "$repo_path" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
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

# Function to clean old cache files
function cleanup_metadata_cache() {
    local cache_dir="$HOME/.cache/myrepo"
    local max_age_days=7
    
    if [[ -d "$cache_dir" ]]; then
        # Remove cache files older than max_age_days
        find "$cache_dir" -name "*.cache" -type f -mtime +$max_age_days -delete 2>/dev/null
        log "DEBUG" "Cleaned old metadata cache files (older than $max_age_days days)"
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
load_config
parse_args "$@"
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
cleanup

cleanup_metadata_cache

log "INFO" "myrepo.sh Version $VERSION completed."
