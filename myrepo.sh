#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with different AI support models
# AI flock: ChatGPT, Claude, Gemini
# Last Updated: 2025-07-09

# MIT licensing
# Purpose:
# This script replicates and updates a local repository from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of

# NOTE: Function order should be alphabetized in a future refactoring effort.
# Current function order has some inconsistencies but reordering would be a large change.
# All shellcheck issues have been resolved as of 2025-07-09.
# older package versions.

# Script version
VERSION=2.1.19
# Default values for environment variables if not set
: "${BATCH_SIZE:=50}"                  # Optimized starting point based on performance analysis
: "${CONTINUE_ON_ERROR:=0}"
: "${DEBUG_MODE:=0}"
: "${DRY_RUN:=0}"
: "${FULL_REBUILD:=0}"
: "${GROUP_OUTPUT:=1}"
: "${IS_USER_MODE:=0}"
: "${LOG_LEVEL:=INFO}"
: "${MAX_PACKAGES:=0}"
: "${PARALLEL:=6}"                     # Increased from 4
: "${SYNC_ONLY:=0}"

# Repository filtering (empty means process all enabled repos)
FILTER_REPOS=()

# Package name filtering (empty means process all packages)
NAME_FILTER=""

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
: "${JOB_WAIT_REPORT_INTERVAL:=60}"
: "${REPOQUERY_PARALLEL:=2}"               # Reduced from 8 to prevent DNF contention
: "${DNF_SERIAL_MODE:=0}"                  # Set to 1 to disable all DNF parallelism for problem environments
: "${REFRESH_METADATA:=0}"
: "${IO_BUFFER_SIZE:=8192}"                # Buffer size for file operations
: "${USE_PARALLEL_COMPRESSION:=1}"         # Enable parallel compression for createrepo

# Adaptive performance tuning variables
: "${ADAPTIVE_TUNING:=1}"                  # Enable adaptive batch/parallel tuning
: "${MIN_BATCH_SIZE:=20}"                  # Increased for better baseline performance
: "${MAX_BATCH_SIZE:=100}"                 # Increased from 50
: "${MIN_PARALLEL:=2}"                     # Increased from 1
: "${MAX_PARALLEL:=16}"                    # Increased from 8
: "${PERFORMANCE_SAMPLE_SIZE:=5}"          # Reduced from 10 for faster adaptation
: "${TUNE_INTERVAL:=3}"                    # Reduced from 5 for more frequent tuning
: "${EFFICIENCY_THRESHOLD:=60}"            # Reduced from 80 for more aggressive tuning

# Local repository management defaults
: "${LOCAL_REPO_CHECK_METHOD:=FAST}"       # FAST (timestamp) or ACCURATE (content) detection
: "${AUTO_UPDATE_LOCAL_REPOS:=1}"          # Enable automatic detection and update of local repo changes

# Debug mode default
: "${DEBUG_MODE:=0}"

# Log directory
LOG_DIR="/var/log/myrepo"

# create a temporary file for logging
TEMP_FILE=$(mktemp /tmp/myrepo_main_$$.XXXXXX)

TEMP_FILES=()

CONFIG_FILE="myrepo.cfg"

# Summary table formatting constants
PADDING_LENGTH=26
TABLE_REPO_WIDTH=$PADDING_LENGTH  # Repository name column width
TABLE_NEW_WIDTH=6                 # New packages column width
TABLE_UPDATE_WIDTH=6              # Update packages column width  
TABLE_EXISTS_WIDTH=6              # Existing packages column width
TABLE_SKIPPED_WIDTH=7             # Skipped packages column width
TABLE_MODULE_WIDTH=8              # Module packages column width
TABLE_STATUS_WIDTH=8              # Status column width

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
declare -A stats_module_count   # Track module packages per repo

# Module package tracking arrays
declare -A module_packages      # repo_name -> list of module packages
declare -A module_info          # module_key -> "name:stream:version:context:arch"

# Performance tracking variables
declare -a batch_times          # Array to store batch processing times
declare -a batch_sizes          # Array to store batch sizes
declare -a parallel_counts      # Array to store parallel process counts
batch_counter=0                 # Counter for processed batches
total_packages_processed=0      # Total packages processed
performance_start_time=0        # Script start time for overall performance


######################################
### Functions section in abc order ###
######################################

# Adaptive performance tuning functions
function adaptive_initialize_performance_tracking() {
    performance_start_time=$(date +%s%3N)
    batch_counter=0
    total_packages_processed=0
    batch_times=()
    batch_sizes=()
    parallel_counts=()
    
    if [[ $ADAPTIVE_TUNING -eq 1 ]]; then
        log "INFO" "Adaptive performance tuning enabled (batch: $MIN_BATCH_SIZE-$MAX_BATCH_SIZE, parallel: $MIN_PARALLEL-$MAX_PARALLEL)"
    fi
}

function adaptive_track_batch_performance() {
    local batch_start_time="$1"
    local batch_package_count="$2"
    
    local batch_end_time
    batch_end_time=$(date +%s%3N)  # milliseconds
    local batch_duration=$((batch_end_time - batch_start_time))
    
    # Store performance data
    batch_times+=("$batch_duration")
    batch_sizes+=("$batch_package_count")
    parallel_counts+=("$PARALLEL")
    
    # Keep only recent performance data (sliding window)
    if [[ ${#batch_times[@]} -gt $((PERFORMANCE_SAMPLE_SIZE * 2)) ]]; then
        # Remove oldest half of the data
        local keep_count=$PERFORMANCE_SAMPLE_SIZE
        batch_times=("${batch_times[@]: -$keep_count}")
        batch_sizes=("${batch_sizes[@]: -$keep_count}")
        parallel_counts=("${parallel_counts[@]: -$keep_count}")
    fi
    
    ((total_packages_processed += batch_package_count))
    ((batch_counter++))
    
    [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "Batch performance: ${batch_package_count} packages in ${batch_duration}ms"
    
    # Trigger adaptive tuning every TUNE_INTERVAL batches
    if [[ $((batch_counter % TUNE_INTERVAL)) -eq 0 ]]; then
        adaptive_tune_performance
    fi
}

function adaptive_tune_performance() {
    # Only tune if adaptive tuning is enabled and we have enough samples
    if [[ $ADAPTIVE_TUNING -eq 0 ]] || [[ ${#batch_times[@]} -lt $PERFORMANCE_SAMPLE_SIZE ]]; then
        return 0
    fi
    
    # Calculate average batch processing time and efficiency
    local total_time=0
    local total_packages=0
    local samples_to_analyze=$PERFORMANCE_SAMPLE_SIZE
    
    # Use the last N samples for analysis
    local start_index=$((${#batch_times[@]} - samples_to_analyze))
    [[ $start_index -lt 0 ]] && start_index=0
    
    for ((i = start_index; i < ${#batch_times[@]}; i++)); do
        total_time=$((total_time + batch_times[i]))
        total_packages=$((total_packages + batch_sizes[i]))
    done
    
    if [[ $total_packages -eq 0 ]]; then
        return 0
    fi
    
    local avg_time_per_package=$((total_time / total_packages))
    local current_efficiency=$((total_packages * 100 / total_time))  # packages per second * 100
    
    [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Performance analysis: avg_time_per_package=${avg_time_per_package}ms, efficiency=${current_efficiency}, batch_size=$BATCH_SIZE, parallel=$PARALLEL"
    
    # Adaptive logic: adjust batch size and parallel processes
    local new_batch_size=$BATCH_SIZE
    local new_parallel=$PARALLEL
    # Use EFFICIENCY_THRESHOLD directly (already scaled to match current_efficiency)
    local efficiency_threshold=$EFFICIENCY_THRESHOLD
    
    if [[ $current_efficiency -lt $efficiency_threshold ]]; then
        # Performance is below threshold, try to optimize
        if [[ $avg_time_per_package -gt 100 ]]; then
            # Slow processing - reduce batch size, potentially increase parallelism
            new_batch_size=$((BATCH_SIZE > MIN_BATCH_SIZE ? BATCH_SIZE - 2 : MIN_BATCH_SIZE))
            new_parallel=$((PARALLEL < MAX_PARALLEL ? PARALLEL + 1 : MAX_PARALLEL))
        else
            # Fast processing but low efficiency - increase batch size more aggressively
            new_batch_size=$((BATCH_SIZE < MAX_BATCH_SIZE ? BATCH_SIZE + 10 : MAX_BATCH_SIZE))
        fi
    else
        # Good performance, try to optimize further
        if [[ $avg_time_per_package -lt 50 ]]; then
            # Very fast processing - increase batch size aggressively
            new_batch_size=$((BATCH_SIZE < MAX_BATCH_SIZE ? BATCH_SIZE + 8 : MAX_BATCH_SIZE))
        fi
    fi
    
    # Apply changes if they make sense
    if [[ $new_batch_size -ne $BATCH_SIZE ]] || [[ $new_parallel -ne $PARALLEL ]]; then
        log "INFO" "Adaptive tuning: batch_size $BATCH_SIZE→$new_batch_size, parallel $PARALLEL→$new_parallel (efficiency: $current_efficiency)"
        BATCH_SIZE=$new_batch_size
        PARALLEL=$new_parallel
        
        # Update parallel downloads based on new settings
        set_parallel_downloads
    fi
}

function align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

# Performance analysis and recommendations
function analyze_performance() {
    if [[ $SYNC_ONLY -eq 1 ]]; then
        return 0
    fi
    
    local total_time=$(( $(date +%s%3N) - performance_start_time ))
    local avg_packages_per_sec=0
    
    if [[ $total_time -gt 0 && $total_packages_processed -gt 0 ]]; then
        avg_packages_per_sec=$(( (total_packages_processed * 1000) / total_time ))
        
        # Performance recommendations
        echo
        log "INFO" "Performance Analysis & Recommendations:"
        
        if [[ $avg_packages_per_sec -lt 10 ]]; then
            log "WARN" "Low throughput detected (${avg_packages_per_sec} pkg/sec). Consider:"
            log "INFO" "  - Increasing PARALLEL (current: $PARALLEL, max: $MAX_PARALLEL)"
            log "INFO" "  - Increasing BATCH_SIZE (current: $BATCH_SIZE, max: $MAX_BATCH_SIZE)"
            log "INFO" "  - Checking disk I/O performance"
            log "INFO" "  - Enabling USE_PARALLEL_COMPRESSION (current: $USE_PARALLEL_COMPRESSION)"
        elif [[ $avg_packages_per_sec -lt 50 ]]; then
            log "INFO" "Moderate throughput (${avg_packages_per_sec} pkg/sec). Potential optimizations:"
            log "INFO" "  - Fine-tune PARALLEL and BATCH_SIZE values"
            log "INFO" "  - Consider SSD storage for better I/O performance"
        else
            log "INFO" "Good throughput achieved (${avg_packages_per_sec} pkg/sec)"
        fi
        
        # Resource utilization recommendations
        local cpu_cores
        cpu_cores=$(nproc)
        if [[ $PARALLEL -lt $((cpu_cores / 2)) ]]; then
            log "INFO" "  - CPU utilization: Consider increasing PARALLEL (current: $PARALLEL, available cores: $cpu_cores)"
        fi
        
        # Memory usage estimation
        local memory_usage_mb=$((BATCH_SIZE * PARALLEL * 2))  # Rough estimate: 2MB per package*process
        if [[ $memory_usage_mb -gt 1024 ]]; then
            log "WARN" "  - High memory usage estimated (~${memory_usage_mb}MB). Monitor system resources."
        fi
    fi
}

# Check if a local repository needs metadata update using ACCURATE (content) method
function check_repo_needs_metadata_update_accurate() {
    local repo_name="$1"
    local repo_path="$2"
    local repo_dir
    repo_dir=$(dirname "$repo_path")
    
    # Check if metadata exists at all
    if [[ ! -d "$repo_dir/repodata" ]]; then
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): No metadata directory found"
        return 0  # No metadata, needs update
    fi
    
    # Get current RPM count
    local current_rpms
    current_rpms=$(find "$repo_path" -name "*.rpm" -type f | wc -l)
    
    # Get RPM count from metadata using a quick repoquery check
    local metadata_rpms
    if metadata_rpms=$(repoquery --repofrompath="temp_$repo_name,$repo_dir" --repoid="temp_$repo_name" --all 2>/dev/null | wc -l); then
        [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Current RPMs: $current_rpms, Metadata RPMs: $metadata_rpms"
        
        if [[ $current_rpms -ne $metadata_rpms ]]; then
            [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): RPM count mismatch ($current_rpms vs $metadata_rpms)"
            return 0  # Count mismatch, needs update
        fi
    else
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Failed to query metadata"
        return 0  # Can't read metadata, assume update needed
    fi
    
    [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Content appears consistent"
    return 1  # Probably up to date
}

# Unified function to check if a repository needs metadata update
function check_repo_needs_metadata_update() {
    local repo_name="$1"
    local repo_path="$2"
    
    case "$LOCAL_REPO_CHECK_METHOD" in
        "FAST")
            check_repo_needs_metadata_update_fast "$repo_name" "$repo_path"
            ;;
        "ACCURATE")
            check_repo_needs_metadata_update_accurate "$repo_name" "$repo_path"
            ;;
        *)
            log "WARN" "Unknown LOCAL_REPO_CHECK_METHOD: $LOCAL_REPO_CHECK_METHOD, using FAST"
            check_repo_needs_metadata_update_fast "$repo_name" "$repo_path"
            ;;
    esac
}

# Check if a local repository needs metadata update using FAST (timestamp) method
function check_repo_needs_metadata_update_fast() {
    local repo_name="$1"
    local repo_path="$2"
    local repo_dir
    repo_dir=$(dirname "$repo_path")
    
    # Compare newest RPM timestamp with metadata timestamp
    local newest_rpm
    newest_rpm=$(find "$repo_path" -name "*.rpm" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
    if [[ -n "$newest_rpm" && -d "$repo_dir/repodata" ]]; then
        local metadata_time
        metadata_time=$(stat -c %Y "$repo_dir/repodata" 2>/dev/null || echo 0)
        local rpm_time
        rpm_time=$(stat -c %Y "$newest_rpm" 2>/dev/null || echo 0)
        
        [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Comparing times - RPM: $rpm_time, Metadata: $metadata_time"
        
        if [[ $rpm_time -gt $metadata_time ]]; then
            [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): RPM newer than metadata ($(basename "$newest_rpm"))"
            return 0  # Needs update
        fi
    elif [[ -n "$newest_rpm" && ! -d "$repo_dir/repodata" ]]; then
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): No metadata exists but RPMs found"
        return 0  # No metadata exists but RPMs do
    fi
    
    [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Metadata appears up to date"
    return 1  # No update needed
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

function detect_module_info() {
    local package_name="$1"
    local package_release="$2"
    local package_arch="$3"
    local package_version="$4"  # Add package version parameter
    
    # Check if package release contains module pattern: .module+
    if [[ "$package_release" =~ \.module\+([^+]+)\+([^+]+)\+([^.]+) ]]; then
        # Extract module components including platform
        local platform="${BASH_REMATCH[1]}"    # e.g., "el9.6.0"
        local version="${BASH_REMATCH[2]}"     # e.g., "90614"
        local context="${BASH_REMATCH[3]}"     # e.g., "f11b29ab"
        
        # Extract module name and stream from package name and version
        # For nodejs-18.20.8-1.module+..., extract nodejs:18
        local module_name stream
        if [[ "$package_name" =~ ^([^-]+) ]]; then
            module_name="${BASH_REMATCH[1]}"
            # Extract major version as stream from package version (e.g., 18 from 18.20.8)
            if [[ "$package_version" =~ ^([0-9]+)\. ]]; then
                stream="${BASH_REMATCH[1]}"
            else
                stream="default"
            fi
        else
            return 1  # Not a recognizable module pattern
        fi
        
        # Return module info as colon-separated string: name:stream:platform:version:context:arch
        echo "${module_name}:${stream}:${platform}:${version}:${context}:${package_arch}"
        return 0
    fi
    
    return 1  # Not a module package
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
        # Create directory with proper permissions
        if [[ "$IS_USER_MODE" -eq 0 ]]; then
            # Use sudo to create directory and set permissions for multi-user access
            sudo mkdir -p "$repo_path" || {
                log_to_temp_file "Failed to create directory: $repo_path"
                exit 1
            }
            # Set permissions to allow the current user to write to the directory
            sudo chown "$USER:$USER" "$repo_path" || {
                log_to_temp_file "Failed to set ownership for directory: $repo_path"
                exit 1
            }
            # Ensure the directory is writable by the owner and group
            sudo chmod 755 "$repo_path" || {
                log_to_temp_file "Failed to set permissions for directory: $repo_path"
                exit 1
            }
        else
            mkdir -p "$repo_path" || {
                log_to_temp_file "Failed to create directory: $repo_path"
                exit 1
            }
        fi

        # Run download in background
        if ((DRY_RUN)); then
            log_to_temp_file "Dry Run: Would download packages to $repo_path: ${repo_packages[$repo_path]}"
        else
            {
                log_to_temp_file "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
                # Check if sudo is required and set the appropriate command prefix
                # Enhanced DNF command with better performance options
                DNF_COMMAND="dnf --setopt=max_parallel_downloads=$PARALLEL_DOWNLOADS --setopt=fastestmirror=1 --setopt=deltarpm=0 download --arch=x86_64,noarch --destdir=$repo_path --resolve ${repo_packages[$repo_path]}"

                if [[ "$IS_USER_MODE" -eq 0 ]]; then
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
    
    # Initialize temp file for tracking slow operations across subshells
    TEMP_SLOW_OPS_FILE=$(mktemp) || {
        log "ERROR" "Failed to create temporary slow operations tracking file"
        exit 1
    }
    TEMP_FILES+=("$TEMP_SLOW_OPS_FILE")
    
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
    
    # Determine which repositories to process
    local repos_to_process=()
    if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
        repos_to_process=("${FILTER_REPOS[@]}")
        log "INFO" "Repository filtering enabled: caching metadata for ${#repos_to_process[@]} filtered repositories (${repos_to_process[*]})"
    else
        repos_to_process=("${ENABLED_REPOS[@]}")
        if [[ -n "$NAME_FILTER" ]]; then
            log "INFO" "Name filtering enabled: caching metadata for all ${#repos_to_process[@]} enabled repositories (name filter: $NAME_FILTER)"
        else
            log "INFO" "Caching metadata for all ${#repos_to_process[@]} enabled repositories"
        fi
    fi

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

    for repo in "${repos_to_process[@]}"; do
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

    # Fetch metadata in parallel for repos that need update (unless serial mode is enabled)
    local max_parallel=$((DNF_SERIAL_MODE ? 1 : REPOQUERY_PARALLEL))
    local running=0
    local slow_operations=0
    
    if ((DNF_SERIAL_MODE)); then
        log "INFO" "DNF serial mode enabled - processing repositories sequentially to avoid contention"
    fi
    
    for repo in "${repos_to_process[@]}"; do
        if [[ ${repo_needs_update["$repo"]} -eq 1 ]]; then
            log "INFO" "Fetching metadata for $repo in background..."
            (
                local repo_start_time
                repo_start_time=$(date +%s)
                local fetch_success=false
                local retry_count=0
                local max_retries=3
                
                # Retry logic for DNF contention issues
                while [[ $retry_count -lt $max_retries ]] && [[ $fetch_success == false ]]; do
                    if [[ $retry_count -gt 0 ]]; then
                        local wait_time=$((retry_count * 3 + RANDOM % 10))  # Add some randomness to avoid thundering herd
                        log "DEBUG" "DNF retry $retry_count/$max_retries for $repo, waiting ${wait_time}s..."
                        sleep $wait_time
                    fi
                    
                    # Use timeout to prevent hanging DNF processes and add lock contention detection
                    if timeout 180 dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>"$MYREPO_ERR_FILE" > "${cache_dir}/${repo}.cache.tmp"; then
                        # Success - move temp file to final location
                        mv "${cache_dir}/${repo}.cache.tmp" "${cache_dir}/${repo}.cache"
                        repo_data=$(cat "${cache_dir}/${repo}.cache")
                        
                        # Save version if available
                        if [[ -n "${repo_versions[$repo]}" ]]; then
                            echo "${repo_versions[$repo]}" > "$cache_dir/${repo}.version"
                        fi
                        
                        local repo_end_time
                        repo_end_time=$(date +%s)
                        local repo_duration=$((repo_end_time - repo_start_time))
                        
                        if [[ -n "${repo_versions[$repo]}" ]]; then
                            log "INFO" "Cached metadata for $repo ($(echo "$repo_data" | wc -l) packages) in ${repo_duration}s [version: ${repo_versions[$repo]}]"
                        else
                            log "INFO" "Cached metadata for $repo ($(echo "$repo_data" | wc -l) packages) in ${repo_duration}s"
                        fi
                        
                        # Track slow operations for adaptive parallelism using a temp file
                        if (( repo_duration > 60 )); then
                            echo "slow" >> "$TEMP_SLOW_OPS_FILE"
                        fi
                        
                        fetch_success=true
                    else
                        ((retry_count++))
                        rm -f "${cache_dir}/${repo}.cache.tmp"  # Clean up failed attempt
                        if [[ $retry_count -lt $max_retries ]]; then
                            log "WARN" "DNF fetch failed for $repo (attempt $retry_count/$max_retries), retrying..."
                        fi
                    fi
                done
                
                if [[ $fetch_success == false ]]; then
                    log "ERROR" "Failed to fetch metadata for $repo after $max_retries attempts"
                fi
            ) &
            ((++running))
            if (( running >= max_parallel )); then
                local wait_start
                wait_start=$(date +%s)
                wait -n 2>/dev/null || wait
                local wait_end
                wait_end=$(date +%s)
                local wait_duration=$((wait_end - wait_start))
                
                # Adaptive parallelism: reduce if operations are consistently slow
                local slow_operations=0
                if [[ -f "$TEMP_SLOW_OPS_FILE" ]]; then
                    slow_operations=$(wc -l < "$TEMP_SLOW_OPS_FILE" 2>/dev/null || echo 0)
                fi
                if (( wait_duration > 90 && slow_operations > 2 && max_parallel > 1 )); then
                    max_parallel=$((max_parallel - 1))
                    log "DEBUG" "Reducing DNF parallelism to $max_parallel due to contention (slow operations: $slow_operations)"
                fi
                
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
    
    # Performance summary
    local total_enabled=${#ENABLED_REPOS[@]}
    local total_processed=${#repos_to_process[@]}
    local skipped_repos=$((total_enabled - total_processed))
    
    if [[ ${#FILTER_REPOS[@]} -gt 0 && $skipped_repos -gt 0 ]]; then
        log "INFO" "Repository filtering: processed $total_processed/$total_enabled repositories (skipped $skipped_repos for performance)"
    fi
    
    log "INFO" "All metadata fetch jobs finished."
    # Load metadata into available_repo_packages
    for repo in "${repos_to_process[@]}"; do
        local cache_file="$cache_dir/${repo}.cache"
        if [[ -f "$cache_file" ]]; then
            available_repo_packages["$repo"]=$(cat "$cache_file")
        fi
    done
}

# Flexible table border drawing function that accepts border type
function draw_table_border_flex() {
    local border_type="${1:-top}"  # top, middle, bottom
    local column_widths=("$TABLE_REPO_WIDTH" "$TABLE_NEW_WIDTH" "$TABLE_UPDATE_WIDTH" "$TABLE_EXISTS_WIDTH" "$TABLE_SKIPPED_WIDTH" "$TABLE_MODULE_WIDTH" "$TABLE_STATUS_WIDTH")
    
    # Define border characters based on type (double outer, single inner)
    local left middle right horizontal
    case "$border_type" in
        "top")
            left="╔" middle="╤" right="╗" horizontal="═"
            ;;
        "middle")
            left="╟" middle="┼" right="╢" horizontal="─"
            ;;
        "bottom")
            left="╚" middle="╧" right="╝" horizontal="═"
            ;;
        *)
            left="╟" middle="┼" right="╢" horizontal="─"
            ;;
    esac
    
    printf "%s" "$left"
    for i in "${!column_widths[@]}"; do
        # Create horizontal line by repeating the character
        # Add 2 extra characters for padding (space before and after content)
        local total_width=$((column_widths[i] + 2))
        local line=""
        for ((j=0; j<total_width; j++)); do
            line+="$horizontal"
        done
        printf "%s" "$line"
        if [[ $i -lt $((${#column_widths[@]} - 1)) ]]; then
            printf "%s" "$middle"
        fi
    done
    printf "%s\n" "$right"
}

# Flexible table header drawing function
function draw_table_header_flex() {
    local headers=("Repository" "New" "Update" "Exists" "Skipped" "Module" "Status")
    local column_widths=("$TABLE_REPO_WIDTH" "$TABLE_NEW_WIDTH" "$TABLE_UPDATE_WIDTH" "$TABLE_EXISTS_WIDTH" "$TABLE_SKIPPED_WIDTH" "$TABLE_MODULE_WIDTH" "$TABLE_STATUS_WIDTH")
    local alignments=("left" "right" "right" "right" "right" "right" "left")  # left or right
    
    printf "║"
    for i in "${!headers[@]}"; do
        if [[ "${alignments[i]}" == "right" ]]; then
            printf " %*s " "${column_widths[i]}" "${headers[i]}"
        else
            printf " %-*s " "${column_widths[i]}" "${headers[i]}"
        fi
        if [[ $i -lt $((${#headers[@]} - 1)) ]]; then
            printf "│"
        fi
    done
    printf "║\n"
}

# Flexible table row drawing function
function draw_table_row_flex() {
    local repo="$1"
    local new="$2"
    local update="$3"
    local exists="$4"
    local skipped="$5"
    local module="$6"
    local status="$7"
    
    local values=("$repo" "$new" "$update" "$exists" "$skipped" "$module" "$status")
    local column_widths=("$TABLE_REPO_WIDTH" "$TABLE_NEW_WIDTH" "$TABLE_UPDATE_WIDTH" "$TABLE_EXISTS_WIDTH" "$TABLE_SKIPPED_WIDTH" "$TABLE_MODULE_WIDTH" "$TABLE_STATUS_WIDTH")
    local alignments=("left" "right" "right" "right" "right" "right" "left")  # left or right
    
    # Truncate repository name if it's longer than the allocated width
    if [[ ${#repo} -gt $TABLE_REPO_WIDTH ]]; then
        values[0]="${repo:0:$((TABLE_REPO_WIDTH-3))}..."
    fi
    
    printf "║"
    for i in "${!values[@]}"; do
        if [[ "${alignments[i]}" == "right" ]]; then
            printf " %*s " "${column_widths[i]}" "${values[i]}"
        else
            printf " %-*s " "${column_widths[i]}" "${values[i]}"
        fi
        if [[ $i -lt $((${#values[@]} - 1)) ]]; then
            printf "│"
        fi
    done
    printf "║\n"
}

# Efficient batch RPM metadata extraction
function extract_rpm_metadata_batch() {
    local repo_path="$1"
    local output_file="$2"
    
    # Use find + xargs for efficient batch processing
    find "$repo_path" -type f -name "*.rpm" -print0 | \
    xargs -0 -r -P "$PARALLEL" -n 20 sh -c "
        for rpm_file in \"\$@\"; do
            if meta=\$(rpm -qp --queryformat \"%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\" \"\$rpm_file\" 2>/dev/null); then
                echo \"\$meta\"
            fi
        done
    " _ >> "$output_file"
}

# Generate module.yaml file for a repository based on detected module packages
function generate_module_yaml() {
    local repo_name="$1"
    local repo_path="$2"
    
    # Check if we have any module packages for this repository
    if [[ -z "${module_packages[$repo_name]}" ]]; then
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "No module packages found for $repo_name, skipping module.yaml generation"
        return 0
    fi
    
    local module_yaml_file="$repo_path/module.yaml"
    local temp_yaml
    temp_yaml=$(mktemp)
    TEMP_FILES+=("$temp_yaml")
    
    log "INFO" "$(align_repo_name "$repo_name"): Generating module.yaml with ${stats_module_count[$repo_name]:-0} module packages"
    
    # Start building the module.yaml content
    {
        echo "---"
        echo "document: modulemd"
        echo "version: 2"
        echo "data:"
        echo "  name: auto-generated"
        echo "  stream: default"
        echo "  version: 1"
        echo "  context: auto"
        echo "  summary: Auto-generated module metadata"
        echo "  description: >"
        echo "    This module was automatically generated from detected module packages."
        echo "  license:"
        echo "    module:"
        echo "      - MIT"
        echo "  dependencies:"
        echo "    - buildrequires:"
        echo "        platform: []"
        echo "      requires:"
        echo "        platform: []"
        echo "  profiles:"
        echo "    default:"
        echo "      rpms: []"
        echo "  artifacts:"
        echo "    rpms:"
    } > "$temp_yaml"
    
    # Add each module package to the artifacts section
    local pkg_list="${module_packages[$repo_name]}"
    for pkg_key in $pkg_list; do
        # Initialize module variables
        local mod_name="" mod_stream="" _mod_platform="" _mod_version="" _mod_context="" _mod_arch=""
        
        # Get the module info for this package
        local module_info_string="${module_info[$pkg_key]}"
        if [[ -n "$module_info_string" ]]; then
            # Parse module info: name:stream:platform:version:context:arch
            IFS ':' read -r mod_name mod_stream _mod_platform _mod_version _mod_context _mod_arch <<< "$module_info_string"
            
            # Add to artifacts list (using the package key which is name-version-release.arch format)
            echo "      - $pkg_key" >> "$temp_yaml"
            
            [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "Added to module.yaml: $pkg_key (module: $mod_name:$mod_stream)"
        fi
    done
    
    # Move the temporary file to the final location
    if ((DRY_RUN)); then
        log "INFO" "$(align_repo_name "$repo_name"): Would create module.yaml with $(wc -l < "$temp_yaml") lines (dry-run)"
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Module.yaml content preview:" && head -20 "$temp_yaml" | sed 's/^/  /'
    else
        if mv "$temp_yaml" "$module_yaml_file"; then
            log "INFO" "$(align_repo_name "$repo_name"): Created module.yaml with $(wc -l < "$module_yaml_file") lines"
            
            # Update repository metadata with the new module.yaml
            if update_module_metadata "$repo_name" "$repo_path" "$module_yaml_file"; then
                log "INFO" "$(align_repo_name "$repo_name"): Module metadata updated successfully"
            else
                log "ERROR" "$(align_repo_name "$repo_name"): Failed to update module metadata"
                return 1
            fi
        else
            log "ERROR" "$(align_repo_name "$repo_name"): Failed to create module.yaml file"
            return 1
        fi
    fi
    
    return 0
}

function generate_summary_table() {
    # Skip summary table in sync-only mode
    if [[ $SYNC_ONLY -eq 1 ]]; then
        return 0
    fi
    
    local total_new=0 total_update=0 total_exists=0 total_skipped=0 total_module=0
    
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
    if [[ ${#stats_module_count[@]} -gt 0 ]]; then
        for repo in "${!stats_module_count[@]}"; do
            ((total_module += stats_module_count[$repo]))
        done
    fi
    
    # Collect all unique repo names and sort them
    local all_repos=()
    
    # Only iterate over arrays that have content
    if [[ ${#stats_new_count[@]} -gt 0 ]]; then
        for repo in "${!stats_new_count[@]}"; do
            if [[ -n "$repo" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_update_count[@]} -gt 0 ]]; then
        for repo in "${!stats_update_count[@]}"; do
            if [[ -n "$repo" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_exists_count[@]} -gt 0 ]]; then
        for repo in "${!stats_exists_count[@]}"; do
            if [[ -n "$repo" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_skipped_count[@]} -gt 0 ]]; then
        for repo in "${!stats_skipped_count[@]}"; do
            if [[ -n "$repo" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_module_count[@]} -gt 0 ]]; then
        for repo in "${!stats_module_count[@]}"; do
            if [[ -n "$repo" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    
    # Sort repositories alphabetically
    mapfile -t all_repos < <(printf '%s\n' "${all_repos[@]}" | sort)
    
    # Debug: show what repositories were collected
    [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "Collected repositories for summary: ${all_repos[*]}"
    
    # Print summary table
    echo
    log "INFO" "Package Processing Summary:"
    echo
    draw_table_border_flex "top"
    draw_table_header_flex
    draw_table_border_flex "middle"
    
    for repo in "${all_repos[@]}"; do
        # Skip empty repository names
        if [[ -z "$repo" ]]; then
            continue
        fi
        
        local new_count=${stats_new_count[$repo]:-0}
        local update_count=${stats_update_count[$repo]:-0}  
        local exists_count=${stats_exists_count[$repo]:-0}
        local skipped_count=${stats_skipped_count[$repo]:-0}
        local module_count=${stats_module_count[$repo]:-0}
        local total_repo=$((new_count + update_count + exists_count + skipped_count))
        
        # Determine status based on activity
        local status
        if ((new_count > 0 || update_count > 0)); then
            status="Modified"
        elif ((exists_count > 0)); then
            status="Clean"
        elif ((skipped_count > 0)); then
            status="Skipped"
        else
            status="Empty"
        fi
        
        # Only show repos that had some activity
        if ((total_repo > 0)); then
            draw_table_row_flex "$repo" "$new_count" "$update_count" "$exists_count" "$skipped_count" "$module_count" "$status"
        fi
    done
    
    draw_table_border_flex "middle"
    draw_table_row_flex "TOTAL" "$total_new" "$total_update" "$total_exists" "$total_skipped" "$total_module" "Summary"
    draw_table_border_flex "bottom"
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

    # Performance timing for package status checks
    local status_start_time
    status_start_time=$(date +%s%3N)

    [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Checking package status: repo=$repo_name name=$package_name epoch=$epoch version=$package_version release=$package_release arch=$package_arch path=$repo_path"

    # Find all matching RPMs for this package name and arch in the repo_path
    local found_exact=0
    local found_other=0
    local found_existing=0
    shopt -s nullglob
    for rpm_file in "$repo_path"/"${package_name}"-*."$package_arch".rpm; do
        [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Examining RPM file: $rpm_file"
        
        # Get all metadata in one rpm call for efficiency
        local rpm_metadata
        rpm_metadata=$(rpm -qp --queryformat '%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}' "$rpm_file" 2>/dev/null)
        if [[ -z "$rpm_metadata" ]]; then
            continue
        fi
        
        local rpm_name rpm_epoch rpm_version rpm_release rpm_arch
        IFS='|' read -r rpm_name rpm_epoch rpm_version rpm_release rpm_arch <<< "$rpm_metadata"
        [[ "$rpm_epoch" == "(none)" || -z "$rpm_epoch" ]] && rpm_epoch="0"
        
        # Skip if the RPM name doesn't exactly match what we're looking for
        if [[ "$rpm_name" != "$package_name" ]]; then
            continue
        fi

        [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "RPM details: name=$rpm_name epoch=$rpm_epoch version=$rpm_version release=$rpm_release arch=$rpm_arch"
        [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Comparing with: name=$package_name epoch=$epoch version=$package_version release=$package_release arch=$package_arch"

        # Compare all fields for exact match
        if [[ "$package_name" == "$rpm_name" \
           && "$epoch" == "$rpm_epoch" \
           && "$package_version" == "$rpm_version" \
           && "$package_release" == "$rpm_release" \
           && "$package_arch" == "$rpm_arch" ]]; then
            [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Found exact match!"
            found_exact=1
            break
        elif [[ "$package_name" == "$rpm_name" \
              && "$package_arch" == "$rpm_arch" ]]; then
            [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Found name/arch match but different version/release/epoch"
            found_other=1
        else
            found_existing=1
        fi
    done
    shopt -u nullglob
    
    # Performance timing for package status checks
    local status_end_time
    status_end_time=$(date +%s%3N)
    local status_duration=$((status_end_time - status_start_time))
    
    # Log slow package status checks (over 500ms)
    if ((status_duration > 500)); then
        log "DEBUG" "$(align_repo_name "$repo_name"): Slow package status check for $package_name took ${status_duration}ms"
    fi
    
    if ((found_exact)); then
        echo "EXISTS"
    elif ((found_other)); then
        echo "UPDATE"
    elif ((found_existing)); then
        echo "EXISTING"
    else
        echo "NEW"
    fi
}

# Left here for consistency
function get_repo_name() {
    local package_repo=$1
    # Normalize repo name by removing @ prefix if present
    echo "${package_repo#@}"
}

function get_repo_path() {
    local package_repo=$1
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi

    # Normalize repo name by removing @ prefix if present
    local normalized_repo="${package_repo#@}"
    
    # Construct the path based on normalized repository name
    echo "$LOCAL_REPO_PATH/$normalized_repo/getPackage"
}

# Check if a package is already installed with exact same version
function is_exact_package_installed() {
    local package_name="$1"
    local epoch="$2"
    local package_version="$3"
    local package_release="$4"
    local package_arch="$5"
    
    [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Checking if exact package is installed: $package_name-$package_version-$package_release.$package_arch (epoch: $epoch)"
    
    # Normalize epoch for comparison
    [[ "$epoch" == "(none)" || -z "$epoch" ]] && epoch="0"
    
    # Check if the exact package is installed using rpm query
    if rpm -q --qf '%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\n' "$package_name" 2>/dev/null | while IFS='|' read -r installed_epoch installed_version installed_release installed_arch; do
        [[ "$installed_epoch" == "(none)" || -z "$installed_epoch" ]] && installed_epoch="0"
        
        if [[ "$epoch" == "$installed_epoch" && "$package_version" == "$installed_version" && "$package_release" == "$installed_release" && "$package_arch" == "$installed_arch" ]]; then
            [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Found exact match installed: $package_name-$package_version-$package_release.$package_arch (epoch: $epoch)"
            exit 0
        fi
    done | head -1; then
        return 0
    else
        [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "No exact match found for: $package_name-$package_version-$package_release.$package_arch (epoch: $epoch)"
        return 1
    fi
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
            FILTER_REPOS) IFS=',' read -r -a FILTER_REPOS <<<"$value" ;;
            FULL_REBUILD) FULL_REBUILD="$value" ;;
            GROUP_OUTPUT) GROUP_OUTPUT="$value" ;;
            IS_USER_MODE) IS_USER_MODE="$value" ;;
            LOCAL_REPO_PATH) LOCAL_REPO_PATH="$value" ;;
            LOCAL_REPOS) IFS=',' read -r -a LOCAL_REPOS <<<"$value" ;;
            LOG_DIR) LOG_DIR="$value" ;;
            LOG_LEVEL) LOG_LEVEL="$value" ;;
            MAX_PACKAGES) MAX_PACKAGES="$value" ;;
            NAME_FILTER) NAME_FILTER="$value" ;;
            PARALLEL) PARALLEL="$value" ;;
            RPMBUILD_PATH) RPMBUILD_PATH="$value" ;;
            SHARED_REPO_PATH) SHARED_REPO_PATH="$value" ;;
            SYNC_ONLY) SYNC_ONLY="$value" ;;
            CACHE_MAX_AGE_HOURS) CACHE_MAX_AGE_HOURS="$value" ;;
            CACHE_MAX_AGE_HOURS_NIGHT) CACHE_MAX_AGE_HOURS_NIGHT="$value" ;;
            NIGHT_START_HOUR) NIGHT_START_HOUR="$value" ;;
            NIGHT_END_HOUR) NIGHT_END_HOUR="$value" ;;
            CACHE_CLEANUP_DAYS) CACHE_CLEANUP_DAYS="$value" ;;
            JOB_WAIT_REPORT_INTERVAL) JOB_WAIT_REPORT_INTERVAL="$value" ;;
            DNF_SERIAL_MODE) DNF_SERIAL_MODE="$value" ;;
            MAX_PARALLEL_DOWNLOADS) MAX_PARALLEL_DOWNLOADS="$value" ;;  # Backward compatibility
            REPOQUERY_PARALLEL) REPOQUERY_PARALLEL="$value" ;;
            REFRESH_METADATA) REFRESH_METADATA="$value" ;;
            # Adaptive performance tuning variables
            ADAPTIVE_TUNING) ADAPTIVE_TUNING="$value" ;;
            MIN_BATCH_SIZE) MIN_BATCH_SIZE="$value" ;;
            MAX_BATCH_SIZE) MAX_BATCH_SIZE="$value" ;;
            MIN_PARALLEL) MIN_PARALLEL="$value" ;;
            MAX_PARALLEL) MAX_PARALLEL="$value" ;;
            PERFORMANCE_SAMPLE_SIZE) PERFORMANCE_SAMPLE_SIZE="$value" ;;
            TUNE_INTERVAL) TUNE_INTERVAL="$value" ;;
            EFFICIENCY_THRESHOLD) EFFICIENCY_THRESHOLD="$value" ;;
            # Local repository management variables
            LOCAL_REPO_CHECK_METHOD) LOCAL_REPO_CHECK_METHOD="$value" ;;
            AUTO_UPDATE_LOCAL_REPOS) AUTO_UPDATE_LOCAL_REPOS="$value" ;;
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

    # Search in multiple locations in order of preference
    local search_paths=(
        "/var/cache/dnf"          # DNF cache
        "/var/cache/yum"          # YUM cache (legacy)
        "$RPMBUILD_PATH"          # Local build directory
        "/tmp"                    # Temporary directory
        "$HOME/Downloads"         # User downloads directory
    )

    # Try each search path
    for search_path in "${search_paths[@]}"; do
        if [[ -d "$search_path" ]]; then
            # Search recursively to find RPMs in subdirectories (like x86_64/)
            rpm_path=$(find "$search_path" -type f -name "${package_name}-${package_version}-${package_release}.${package_arch}.rpm" 2>/dev/null | head -n 1)
            if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
                [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Found local RPM at: $rpm_path"
                echo "$rpm_path"
                return 0
            fi
        fi
    done

    # If not found in standard locations, try to get the file from the installed package location
    # This is a fallback - check if we can get the original source
    if command -v repoquery >/dev/null 2>&1; then
        local repo_info
        repo_info=$(repoquery --installed --qf "%{ui_from_repo}" "$package_name-$package_version-$package_release.$package_arch" 2>/dev/null | head -1)
        if [[ -n "$repo_info" && "$repo_info" != "@System" ]]; then
            [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "Package $package_name originally from repo: $repo_info"
            # Could potentially download from the original repo if needed
        fi
    fi

    [ "$DEBUG_MODE" -ge 2 ] && log "DEBUG" "No local RPM found for: ${package_name}-${package_version}-${package_release}.${package_arch}"
    echo ""
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
        --debug)
            shift
            # Check if next argument is a number, otherwise default to 1
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                DEBUG_MODE=$1
            else
                DEBUG_MODE=1
                # Put back the argument that wasn't a debug level
                set -- "$1" "$@"
            fi
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
        --repos)
            shift
            IFS=',' read -r -a FILTER_REPOS <<<"$1"
            ;;
        --name-filter)
            shift
            NAME_FILTER="$1"
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
        --refresh-metadata)
            REFRESH_METADATA=1
            ;;
        --dnf-serial)
            DNF_SERIAL_MODE=1
            ;;
        --version)
            echo "myrepo.sh Version $VERSION"
            exit 0
            ;;
        --help)
            echo "Usage: myrepo.sh [OPTIONS]"
            echo "Options:"
            echo "  --batch-size NUM          Number of packages per batch (default: 50)"
            echo "  --debug LEVEL             Set debug level (default: 0)"
            echo "  --dry-run                 Perform a dry run without making changes"
            echo "  --exclude-repos REPOS     Comma-separated list of repos to exclude (default: none)"
            echo "  --full-rebuild            Perform a full rebuild of the repository"
            echo "  --no-group-output         Disable grouping of EXISTS package outputs (show individual messages)"
            echo "  --local-repo-path PATH    Set local repository path (default: /repo)"
            echo "  --local-repos REPOS       Comma-separated list of local repos (default: ol9_edge,pgdg-common,pgdg16)"
            echo "  --log-dir PATH            Set log directory (default: /var/log/myrepo)"
            echo "  --max-packages NUM        Maximum number of packages to process (default: 0)"
            echo "  --name-filter REGEX       Filter packages by name using regex pattern (default: none)"
            echo "  --repos REPOS             Comma-separated list of repos to process (default: all enabled)"
            echo "  --parallel NUM            Number of parallel processes (default: 2)"
            echo "  --shared-repo-path PATH   Set shared repository path (default: /mnt/hgfs/ForVMware/ol9_repos)"
            echo "  --sync-only               Only perform rsync steps (skip package processing and metadata updates)"
            echo "  --user-mode               Run without sudo privileges"
            echo "  --refresh-metadata        Force a refresh of DNF metadata cache"
            echo "  --dnf-serial              Use serial DNF mode to prevent database lock contention"
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
        
        # Normalize repo name by removing @ prefix if present  
        local normalized_repo="${repo#@}"
        repo_path="$LOCAL_REPO_PATH/$normalized_repo/getPackage"
        if [[ -d "$repo_path" ]]; then
            # Create a temporary file to store package information
            local tmp_file
            tmp_file=$(mktemp)
            TEMP_FILES+=("$tmp_file")
            
            # Use the efficient batch metadata extraction
            extract_rpm_metadata_batch "$repo_path" "$tmp_file"
            
            # Handle (none) epoch values in the cached data
            sed -i 's/|(none)|/|0|/g' "$tmp_file"
            
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
        # Track batch start time for adaptive performance
        local batch_start_time
        batch_start_time=$(date +%s%3N)
        
        log "INFO" "Processing batch of ${#batch_packages[@]} packages..."
        process_packages \
            "$DEBUG_MODE" \
            "${batch_packages[*]}" \
            "${LOCAL_REPOS[*]}" \
            "$PROCESSED_PACKAGES_FILE" \
            "$PARALLEL" &
        # Wait for background jobs to finish before starting a new batch
        wait_for_jobs
        
        # Track batch performance timing
        local batch_end_time
        batch_end_time=$(date +%s%3N)  # milliseconds
        local batch_duration=$((batch_end_time - batch_start_time))
        local packages_per_sec=$(( ${#batch_packages[@]} * 1000 / (batch_duration + 1) ))
        log "INFO" "Batch completed: ${#batch_packages[@]} packages in ${batch_duration}ms (${packages_per_sec} pkg/sec)"
        
        # Track batch performance for adaptive tuning
        adaptive_track_batch_performance "$batch_start_time" "${#batch_packages[@]}"
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
    local package_count=0
    local last_feedback_time
    last_feedback_time=$(date +%s)
    
    for pkg in "${packages[@]}"; do
        IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<<"$pkg"

        PADDING_LENGTH=22 # Set constant padding length

        pkg_key="${package_name}-${package_version}-${package_release}.${package_arch}"
        
        # Progress feedback every 10 seconds or 50 packages
        ((package_count++))
        local current_time
        current_time=$(date +%s)
        if ((current_time - last_feedback_time >= 10)) || ((package_count % 50 == 0)); then
            log "INFO" "Processing package $package_count/${#packages[@]}: $package_name..."
            last_feedback_time=$current_time
        fi
        
        # Detect and store module information if this is a module package
        if module_info_string=$(detect_module_info "$package_name" "$package_release" "$package_arch" "$package_version"); then
            # Store module info: module_key -> "name:stream:platform:version:context:arch"
            # shellcheck disable=SC2034  # module_info array used globally for module metadata storage
            module_info["$pkg_key"]="$module_info_string"
            
            # Add package to module packages list for this repo
            if [[ -z "${module_packages[$repo_name]}" ]]; then
                module_packages["$repo_name"]="$pkg_key"
            else
                module_packages["$repo_name"]+=" $pkg_key"
            fi
            
            # Track module statistics
            ((stats_module_count["$repo_name"]++))
            
            [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "Detected module package: $pkg_key -> $module_info_string"
        fi

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
            # First, try to find a local cached copy before attempting download
            local rpm_path
            rpm_path=$(locate_local_rpm "$package_name" "$package_version" "$package_release" "$package_arch")
            
            if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
                # Found local copy - use it instead of downloading
                [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Found local cached RPM at: $rpm_path for NEW package $package_name-$package_version-$package_release.$package_arch"
                
                if ((DRY_RUN)); then
                    log "INFO" "$(align_repo_name "$repo_name"): Would copy $package_name-$package_version-$package_release.$package_arch from local cache (dry-run)." "\e[36m" # Cyan
                    ((stats_new_count["$repo_name"]++))
                else
                    # Ensure target directory exists with proper permissions
                    if [[ "$IS_USER_MODE" -eq 0 ]]; then
                        sudo mkdir -p "$repo_path" && sudo chown "$USER:$USER" "$repo_path" && sudo chmod 755 "$repo_path"
                    else
                        mkdir -p "$repo_path"
                    fi
                    
                    # Use sudo for copy if not in user mode
                    local copy_cmd="cp"
                    [[ "$IS_USER_MODE" -eq 0 ]] && copy_cmd="sudo cp"
                    
                    if $copy_cmd "$rpm_path" "$repo_path/"; then
                        log "INFO" "$(align_repo_name "$repo_name"): Copied $package_name-$package_version-$package_release.$package_arch from local cache." "\e[36m" # Cyan
                        ((stats_new_count["$repo_name"]++))
                    else
                        log "WARN" "$(align_repo_name "$repo_name"): Failed to copy $package_name-$package_version-$package_release.$package_arch from local cache, will try download" "\e[33m" # Yellow
                        # Fall back to download if copy fails
                        if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                            log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is new (fallback to download)." "\e[33m" # Yellow
                            download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                        fi
                        ((stats_new_count["$repo_name"]++))
                    fi
                fi
                mark_processed "$pkg_key"
            # Check if the exact same package is already installed to avoid conflicts
            elif is_exact_package_installed "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch"; then
                [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Package $package_name-$package_version-$package_release.$package_arch is already installed with exact same version, no local cache found"
                # No local copy available but package is installed, treat as exists since it's installed
                ((stats_exists_count["$repo_name"]++))
                log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch already installed (no local copy)." "\e[32m" # Green
                mark_processed "$pkg_key"
            else
                # No local copy found and not installed - proceed with download
                ((stats_new_count["$repo_name"]++))
                
                if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                    log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is new (no local cache)." "\e[33m" # Yellow
                    download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                    mark_processed "$pkg_key"
                else
                    log "INFO" "$(align_repo_name "$repo_name"): Skipping download for local package $package_name-$package_version-$package_release.$package_arch." "\e[33m" # Yellow
                fi
            fi
            ;;
        "UPDATE")
            # Track statistics
            ((stats_update_count["$repo_name"]++))
            
            if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                # First, try to find a local cached copy before downloading the update
                local rpm_path
                rpm_path=$(locate_local_rpm "$package_name" "$package_version" "$package_release" "$package_arch")
                
                if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
                    # Found local copy of the updated package - use it instead of downloading
                    [ "$DEBUG_MODE" -ge 1 ] && log "DEBUG" "Found local cached RPM at: $rpm_path for UPDATE package $package_name-$package_version-$package_release.$package_arch"
                    
                    # Remove existing packages first
                    remove_existing_packages "$package_name" "$package_version" "$package_release" "$repo_path"
                    
                    if ((DRY_RUN)); then
                        log "INFO" "$(align_repo_name "$repo_name"): Would copy updated $package_name-$package_version-$package_release.$package_arch from local cache (dry-run)." "\e[36m" # Cyan
                    else
                        # Ensure target directory exists with proper permissions
                        if [[ "$IS_USER_MODE" -eq 0 ]]; then
                            sudo mkdir -p "$repo_path" && sudo chown "$USER:$USER" "$repo_path" && sudo chmod 755 "$repo_path"
                        else
                            mkdir -p "$repo_path"
                        fi
                        
                        # Use sudo for copy if not in user mode
                        local copy_cmd="cp"
                        [[ "$IS_USER_MODE" -eq 0 ]] && copy_cmd="sudo cp"
                        
                        if $copy_cmd "$rpm_path" "$repo_path/"; then
                            log "INFO" "$(align_repo_name "$repo_name"): Copied updated $package_name-$package_version-$package_release.$package_arch from local cache." "\e[36m" # Cyan
                        else
                            log "WARN" "$(align_repo_name "$repo_name"): Failed to copy updated $package_name-$package_version-$package_release.$package_arch from local cache, will try download" "\e[33m" # Yellow
                            # Fall back to download if copy fails
                            log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is updated (fallback to download)." "\e[34m" # Blue
                            download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                        fi
                    fi
                    mark_processed "$pkg_key"
                else
                    # No local copy found - proceed with standard download
                    remove_existing_packages "$package_name" "$package_version" "$package_release" "$repo_path"
                    log "INFO" "$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch is updated (no local cache)." "\e[34m" # Blue
                    download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
                    mark_processed "$pkg_key"
                fi
            else
                log "INFO" "$(align_repo_name "$repo_name"): Skipping update for local package $package_name-$package_version-$package_release.$package_arch." "\e[34m" # Blue
            fi
            ;;
        "EXISTING")
            # Track statistics - treat as skipped since it's not an exact match
            ((stats_skipped_count["$repo_name"]++))
            
            [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Package $package_name-$package_version-$package_release.$package_arch has different version in repository." "\e[90m" # Gray
            mark_processed "$pkg_key"
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

# Refresh DNF metadata cache if requested
function refresh_metadata() {
    if ((REFRESH_METADATA == 1)); then
        log "INFO" "Forcing DNF metadata refresh as requested (--refresh-metadata)"
        if ((DRY_RUN)); then
            log "INFO" "Would run 'dnf clean all && dnf makecache' (dry-run)"
        else
            if ! dnf clean all >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                log "WARN" "Failed to clean DNF cache, proceeding anyway..."
            fi
            if ! dnf makecache >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                log "WARN" "Failed to make DNF cache, proceeding anyway..."
            else
                log "INFO" "DNF metadata cache refreshed successfully."
            fi
        fi
    fi
}

function remove_excluded_repos() {
    for repo in "${EXCLUDED_REPOS[@]}"; do
        # Normalize repo name by removing @ prefix if present
        local normalized_repo="${repo#@}"
        repo_path="$LOCAL_REPO_PATH/$normalized_repo"

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

# Optimized function to remove uninstalled packages with enhanced caching
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
    
    # Create a cache file for RPM metadata to avoid repeated rpm calls
    local rpm_cache_file
    rpm_cache_file=$(mktemp)
    TEMP_FILES+=("$rpm_cache_file")
    
    # Pre-extract all RPM metadata in optimized batches
    local metadata_start
    metadata_start=$(date +%s)
    find "$repo_path" -type f -name "*.rpm" -print0 | \
    xargs -0 -r -P "$PARALLEL" -n 30 sh -c "
        cache_file=\"\$1\"
        shift
        for rpm_file in \"\$@\"; do
            if rpm_data=\$(rpm -qp --queryformat \"%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\" \"\$rpm_file\" 2>/dev/null); then
                rpm_data=\${rpm_data//(none)/0}
                echo \"\$rpm_file|\$rpm_data\" >> \"\$cache_file\"
            fi
        done
    " _ "$rpm_cache_file"
    
    local metadata_end
    metadata_end=$(date +%s)
    local metadata_duration=$((metadata_end - metadata_start))
    log "INFO" "$(align_repo_name "$repo_name"): RPM metadata extraction completed in ${metadata_duration}s" "\e[90m"
    
    # Sort cache file for faster processing
    sort -t'|' -k2,6 "$rpm_cache_file" > "$rpm_cache_file.sorted"
    
    # Use the cached metadata to check for uninstalled packages
    while IFS='|' read -r rpm_file rpm_data; do
        if ! grep -qF "$rpm_data" "$installed_pkgs_file"; then
            if ((DRY_RUN)); then
                echo "$rpm_file" >> "$remove_list.dryrun"
            else
                echo "$rpm_file" >> "$remove_list"
            fi
        fi
    done < "$rpm_cache_file.sorted"
    
    local removed_count=0
    local dryrun_count=0
    if [[ -s "$remove_list" && "$DRY_RUN" -eq 0 ]]; then
        removed_count=$(wc -l < "$remove_list")
        if ((DEBUG_MODE >= 1)); then
            while IFS= read -r pkg; do
                log "DEBUG" "$(align_repo_name "$repo_name"): Removed $(basename "$pkg")" "\e[31m"
            done < "$remove_list"
        fi
        # Use optimized parallel removal with better batching
        local removal_start
        removal_start=$(date +%s)
        xargs -a "$remove_list" -P "$PARALLEL" -n 50 rm -f
        local removal_end
        removal_end=$(date +%s)
        local removal_duration=$((removal_end - removal_start))
        log "INFO" "$(align_repo_name "$repo_name"): $removed_count uninstalled packages removed in ${removal_duration}s." "\e[32m"
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
        if [[ -n "$NAME_FILTER" ]]; then
            log "INFO" "Fetching list of installed packages (filtered by name pattern: $NAME_FILTER)..."
            local filter_fetch_start
            filter_fetch_start=$(date +%s)
            
            # Use retry logic for filtered package fetch to handle DNF contention
            local fetch_success=false
            local retry_count=0
            local max_retries=3
            
            while [[ $retry_count -lt $max_retries ]] && [[ $fetch_success == false ]]; do
                if [[ $retry_count -gt 0 ]]; then
                    local wait_time=$((retry_count * 5))
                    log "INFO" "Retrying filtered package fetch (attempt $((retry_count + 1))/$max_retries) after ${wait_time}s..."
                    sleep $wait_time
                fi
                
                # Use timeout and better error handling for filtered queries
                if timeout 300 dnf repoquery --installed --qf '%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{repoid}' 2>>"$MYREPO_ERR_FILE" | grep -E "^[^|]*${NAME_FILTER}[^|]*\|" >"$INSTALLED_PACKAGES_FILE.tmp"; then
                    mv "$INSTALLED_PACKAGES_FILE.tmp" "$INSTALLED_PACKAGES_FILE"
                    fetch_success=true
                    
                    local filter_fetch_end
                    filter_fetch_end=$(date +%s)
                    local filter_fetch_duration=$((filter_fetch_end - filter_fetch_start))
                    local package_count
                    package_count=$(wc -l < "$INSTALLED_PACKAGES_FILE")
                    log "INFO" "Found $package_count installed packages matching filter '$NAME_FILTER' in ${filter_fetch_duration}s"
                else
                    # Check if dnf failed or if grep simply found no matches
                    local dnf_exit_code=${PIPESTATUS[0]}
                    if [[ $dnf_exit_code -ne 0 ]]; then
                        ((retry_count++))
                        rm -f "$INSTALLED_PACKAGES_FILE.tmp"  # Clean up failed attempt
                        if [[ $retry_count -lt $max_retries ]]; then
                            log "WARN" "DNF filtered package fetch failed, retrying..."
                        fi
                    else
                        # No packages matched the filter - this is not an error, but we still need to create the file
                        mv "$INSTALLED_PACKAGES_FILE.tmp" "$INSTALLED_PACKAGES_FILE" 2>/dev/null || echo -n > "$INSTALLED_PACKAGES_FILE"
                        log "INFO" "No installed packages match the name filter '$NAME_FILTER'"
                        fetch_success=true
                    fi
                fi
            done
            
            if [[ $fetch_success == false ]]; then
                log "ERROR" "DNF command failed while fetching installed packages list after $max_retries attempts."
                exit 1
            fi
        else
            log "INFO" "Fetching list of installed packages..."
            local package_fetch_start
            package_fetch_start=$(date +%s)
            
            # Use timeout and retry logic for the main package query to handle contention
            local fetch_success=false
            local retry_count=0
            local max_retries=3
            
            while [[ $retry_count -lt $max_retries ]] && [[ $fetch_success == false ]]; do
                if [[ $retry_count -gt 0 ]]; then
                    local wait_time=$((retry_count * 5))
                    log "INFO" "Retrying package list fetch (attempt $((retry_count + 1))/$max_retries) after ${wait_time}s..."
                    sleep $wait_time
                fi
                
                # Use timeout to prevent hanging and add better error handling
                if timeout 300 dnf repoquery --installed --qf '%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{repoid}' >"$INSTALLED_PACKAGES_FILE.tmp" 2>>"$MYREPO_ERR_FILE"; then
                    mv "$INSTALLED_PACKAGES_FILE.tmp" "$INSTALLED_PACKAGES_FILE"
                    fetch_success=true
                    
                    local package_fetch_end
                    package_fetch_end=$(date +%s)
                    local package_fetch_duration=$((package_fetch_end - package_fetch_start))
                    local package_count
                    package_count=$(wc -l < "$INSTALLED_PACKAGES_FILE")
                    log "INFO" "Fetched $package_count installed packages in ${package_fetch_duration}s"
                else
                    ((retry_count++))
                    rm -f "$INSTALLED_PACKAGES_FILE.tmp"  # Clean up failed attempt
                    if [[ $retry_count -lt $max_retries ]]; then
                        log "WARN" "DNF package list fetch failed, retrying..."
                    fi
                fi
            done
            
            if [[ $fetch_success == false ]]; then
                log "ERROR" "Failed to fetch installed packages list after $max_retries attempts."
                exit 1
            fi
        fi

        # Fetch the list of enabled repositories
        log "INFO" "Fetching list of enabled repositories..."

        mapfile -t ENABLED_REPOS < <(dnf repolist enabled | awk 'NR>1 {print $1}')

        if [[ ${#ENABLED_REPOS[@]} -eq 0 ]]; then
            log "ERROR" "No enabled repositories found."
            exit 1
        fi

        # Download repository metadata for enabled repos
        log "INFO" "Downloading repository metadata..."
        if ((DNF_SERIAL_MODE)); then
            log "INFO" "Using serial DNF mode to prevent database lock contention"
        else
            log "INFO" "Using parallel DNF mode with max $REPOQUERY_PARALLEL concurrent processes"
        fi
        local metadata_start_time
        metadata_start_time=$(date +%s)
        download_repo_metadata
        local metadata_end_time
        metadata_end_time=$(date +%s)
        local metadata_duration=$((metadata_end_time - metadata_start_time))
        log "INFO" "Repository metadata download completed in ${metadata_duration}s"

        # Validate repository filtering if specified
        if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
            log "INFO" "Validating specified repositories..."
            local invalid_repos=()
            for repo in "${FILTER_REPOS[@]}"; do
                if [[ ! " ${ENABLED_REPOS[*]} " =~ \ ${repo}\  ]]; then
                    invalid_repos+=("$repo")
                fi
            done
            
            if [[ ${#invalid_repos[@]} -gt 0 ]]; then
                log "ERROR" "The following repositories are not enabled or do not exist: ${invalid_repos[*]}"
                log "INFO" "Available enabled repositories: ${ENABLED_REPOS[*]}"
                exit 1
            fi
            log "INFO" "All specified repositories are valid and enabled."
        fi

        # Read the installed packages list
        mapfile -t package_lines <"$INSTALLED_PACKAGES_FILE"

        # Show repository filtering status
        if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
            log "INFO" "Repository filtering enabled. Processing only: ${FILTER_REPOS[*]}"
        else
            log "INFO" "Processing packages from all enabled repositories"
        fi

        # Show name filtering status
        if [[ -n "$NAME_FILTER" ]]; then
            log "INFO" "Package name filtering enabled. Filter pattern: $NAME_FILTER"
        fi

        # Processing installed packages
        log "INFO" "Processing installed packages..."
        package_counter=0
        batch_packages=()
        local main_loop_start_time
        main_loop_start_time=$(date +%s)
        local last_main_feedback_time=$main_loop_start_time

        # Main loop processing the lines
        for line in "${package_lines[@]}"; do
            # Expected format: name|epoch|version|release|arch|repoid
            IFS='|' read -r package_name epoch_version package_version package_release package_arch package_repo <<<"$line"

            # Determine actual repository for @System packages first
            if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "@commandline" ]]; then
                package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
                if [[ $DEBUG_MODE -ge 1 ]]; then
                    log "DEBUG" "Determined repo for $package_name: $package_repo"
                fi
            fi
            
            # Skip if the package is in the excluded list
            # Normalize the repository name for comparison
            local normalized_package_repo="${package_repo#@}"
            if [[ " ${EXCLUDED_REPOS[*]} " == *" ${package_repo} "* ]] || [[ " ${EXCLUDED_REPOS[*]} " == *" ${normalized_package_repo} "* ]]; then
                [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "Skipping package $package_name from excluded repository: $package_repo"
                continue
            fi
            
            # Skip if repository filtering is enabled and this repo is not in the filter list
            if [[ ${#FILTER_REPOS[@]} -gt 0 ]] && [[ ! " ${FILTER_REPOS[*]} " =~ \ ${package_repo}\  ]] && [[ ! " ${FILTER_REPOS[*]} " =~ \ ${normalized_package_repo}\  ]]; then
                [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "Skipping package $package_name from non-filtered repository: $package_repo"
                continue
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
            
            # Progress feedback every 30 seconds or 100 packages
            local current_main_time
            current_main_time=$(date +%s)
            if ((current_main_time - last_main_feedback_time >= 30)) || ((package_counter % 100 == 0)); then
                local elapsed_main=$((current_main_time - main_loop_start_time))
                local rate=$((package_counter * 60 / (elapsed_main + 1)))  # packages per minute
                log "INFO" "Main loop progress: $package_counter packages processed, $rate pkg/min, batch size: ${#batch_packages[@]}"
                last_main_feedback_time=$current_main_time
            fi
            
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
        local removal_start_time
        removal_start_time=$(date +%s)
        local removal_jobs_running=0
        local max_removal_parallel=$((PARALLEL < 4 ? PARALLEL : 4))  # Cap removal parallelism
        
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
                
                # Run removal in background for parallel processing
                (
                    local repo_removal_start
                    repo_removal_start=$(date +%s)
                    remove_uninstalled_packages "$repo_path"
                    local repo_removal_end
                    repo_removal_end=$(date +%s)
                    local repo_removal_duration=$((repo_removal_end - repo_removal_start))
                    log "INFO" "$(align_repo_name "$repo"): Removal check completed in ${repo_removal_duration}s"
                ) &
                
                ((removal_jobs_running++))
                
                # Control parallel removal jobs
                if ((removal_jobs_running >= max_removal_parallel)); then
                    wait -n  # Wait for any job to finish
                    ((removal_jobs_running--))
                fi
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
        local removal_end_time
        removal_end_time=$(date +%s)
        local total_removal_time=$((removal_end_time - removal_start_time))
        log "INFO" "All package removal operations completed in ${total_removal_time}s"
    fi # End of SYNC_ONLY condition
}

function update_and_sync_repos() {
    # Update and sync the repositories
    if [ "$MAX_PACKAGES" -eq 0 ]; then
        # Skip metadata updates in sync-only mode since no packages were processed
        if ((SYNC_ONLY == 1)); then
            log "INFO" "Skipping metadata updates in sync-only mode (no packages processed)"
        else
            log "INFO" "Updating repository metadata..."

            # PHASE 1: Update metadata for repositories that had packages processed
            for repo in "${!used_directories[@]}"; do
                package_path="${used_directories[$repo]}"
                repo_path=$(dirname "$package_path")
                repo_name=$(basename "$repo_path")

                if ((DRY_RUN)); then
                    if ((USE_PARALLEL_COMPRESSION)); then
                        log "INFO" "$(align_repo_name "$repo_name"): Would run 'createrepo_c --update --workers $PARALLEL $repo_path'"
                    else
                        log "INFO" "$(align_repo_name "$repo_name"): Would run 'createrepo_c --update $repo_path'"
                    fi
                    # Check if module.yaml would be generated
                    generate_module_yaml "$repo_name" "$repo_path"
                else
                    log "INFO" "$(align_repo_name "$repo_name"): Updating metadata for $repo_path"
                    
                    # Fix permissions on repository directory and metadata before createrepo
                    if [[ "$IS_USER_MODE" -eq 0 ]]; then
                        # Ensure proper ownership and permissions for metadata creation
                        if [[ -d "$repo_path/repodata" ]]; then
                            sudo chown -R "$USER:$USER" "$repo_path/repodata" 2>/dev/null || true
                        fi
                        # Ensure the main directory is writable
                        sudo chown "$USER:$USER" "$repo_path" 2>/dev/null || true
                        sudo chmod 755 "$repo_path" 2>/dev/null || true
                    fi
                    
                    local createrepo_cmd="createrepo_c --update"
                    if ((USE_PARALLEL_COMPRESSION)); then
                        createrepo_cmd+=" --workers $PARALLEL"
                    fi
                    createrepo_cmd+=" \"$repo_path\""
                    
                    if ! eval "$createrepo_cmd" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                        log "ERROR" "$(align_repo_name "$repo_name"): Error updating metadata for $repo_path"
                    else
                        log "INFO" "$(align_repo_name "$repo_name"): Metadata updated successfully"
                        # Generate module.yaml if module packages were detected for this repository
                        generate_module_yaml "$repo_name" "$repo_path"
                    fi
                fi
            done

            # PHASE 2: Check local repositories for manual changes (if enabled)
            if ((AUTO_UPDATE_LOCAL_REPOS == 1)); then
                [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "Checking local repositories for manual changes (method: $LOCAL_REPO_CHECK_METHOD)..."
                
                for local_repo in "${LOCAL_REPOS[@]}"; do
                    # Skip if already processed in Phase 1
                    if [[ -n "${used_directories[$local_repo]}" ]]; then
                        [[ $DEBUG_MODE -ge 2 ]] && log "DEBUG" "$(align_repo_name "$local_repo"): Already processed in Phase 1, skipping manual check"
                        continue
                    fi
                    
                    local repo_path="$LOCAL_REPO_PATH/$local_repo/getPackage"
                    if [[ -d "$repo_path" ]]; then
                        if check_repo_needs_metadata_update "$local_repo" "$repo_path"; then
                            log "INFO" "$(align_repo_name "$local_repo"): Manual changes detected, updating metadata"
                            
                            local repo_dir
                            repo_dir=$(dirname "$repo_path")
                            if ((DRY_RUN)); then
                                if ((USE_PARALLEL_COMPRESSION)); then
                                    log "INFO" "$(align_repo_name "$local_repo"): Would run 'createrepo_c --update --workers $PARALLEL $repo_dir'"
                                else
                                    log "INFO" "$(align_repo_name "$local_repo"): Would run 'createrepo_c --update $repo_dir'"
                                fi
                            else
                                # Fix permissions
                                if [[ "$IS_USER_MODE" -eq 0 ]]; then
                                    if [[ -d "$repo_dir/repodata" ]]; then
                                        sudo chown -R "$USER:$USER" "$repo_dir/repodata" 2>/dev/null || true
                                    fi
                                    sudo chown "$USER:$USER" "$repo_dir" 2>/dev/null || true
                                    sudo chmod 755 "$repo_dir" 2>/dev/null || true
                                fi
                                
                                local createrepo_cmd="createrepo_c --update"
                                if ((USE_PARALLEL_COMPRESSION)); then
                                    createrepo_cmd+=" --workers $PARALLEL"
                                fi
                                createrepo_cmd+=" \"$repo_dir\""
                                
                                if ! eval "$createrepo_cmd" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                                    log "ERROR" "$(align_repo_name "$local_repo"): Error updating metadata for $repo_dir"
                                else
                                    log "INFO" "$(align_repo_name "$local_repo"): Metadata updated successfully"
                                fi
                            fi
                            
                            # Add to used_directories for syncing
                            used_directories["$local_repo"]="$repo_path"
                        else
                            [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$local_repo"): No metadata update needed"
                            # Still add to used_directories for syncing (even without metadata update)
                            used_directories["$local_repo"]="$repo_path"
                        fi
                    fi
                done
            fi
        fi

        # If SYNC_ONLY is set, we need to determine which directories to sync
        if ((SYNC_ONLY == 1)); then
            # Determine which repositories to process for syncing only
            if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
                # Use filtered repositories
                for repo_name in "${FILTER_REPOS[@]}"; do
                    local repo_dir="$LOCAL_REPO_PATH/$repo_name"
                    if [[ -d "$repo_dir" ]]; then
                        used_directories["$repo_name"]="$repo_dir/getPackage"
                    fi
                done
            else
                # Find all repositories under LOCAL_REPO_PATH
                while IFS= read -r -d '' dir; do
                    repo_name=$(basename "$dir")
                    used_directories["$repo_name"]="$dir/getPackage"
                done < <(find "$LOCAL_REPO_PATH" -mindepth 1 -maxdepth 1 -type d -print0)
            fi
        fi

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

        # Determine which repositories to sync
        local repos_to_sync=()
        if [[ ${#FILTER_REPOS[@]} -gt 0 ]]; then
            repos_to_sync=("${FILTER_REPOS[@]}")
        else
            # Get all repository directories
            for repo in "$LOCAL_REPO_PATH"/*; do
                if [[ -d "$repo" ]]; then
                    repos_to_sync+=("$(basename "$repo")")
                fi
            done
        fi

        for repo_name in "${repos_to_sync[@]}"; do
            local repo="$LOCAL_REPO_PATH/$repo_name"
            
            # Skip if repository directory doesn't exist
            if [[ ! -d "$repo" ]]; then
                log "WARN" "$(align_repo_name "$repo_name"): Repository directory does not exist: $repo"
                continue
            fi

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

function update_module_metadata() {
    local repo_name="$1"
    local repo_path="$2"
    local module_yaml_file="$3"
    
    # Path to the repodata directory
    local repodata_dir
    repodata_dir="$(dirname "$repo_path")/repodata"
    
    if [[ ! -d "$repodata_dir" ]]; then
        log "WARN" "$(align_repo_name "$repo_name"): No repodata directory found at $repodata_dir"
        return 1
    fi
    
    # Remove any existing module metadata first
    if find "$repodata_dir" -name "*modules*" -type f -delete 2>/dev/null; then
        [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Removed existing module metadata"
    fi
    
    # Add the new module metadata using modifyrepo_c (preferred) or modifyrepo
    local modifyrepo_cmd
    if command -v modifyrepo_c >/dev/null 2>&1; then
        modifyrepo_cmd="modifyrepo_c"
    elif command -v modifyrepo >/dev/null 2>&1; then
        modifyrepo_cmd="modifyrepo"
    else
        log "ERROR" "$(align_repo_name "$repo_name"): Neither modifyrepo_c nor modifyrepo found"
        return 1
    fi
    
    [[ $DEBUG_MODE -ge 1 ]] && log "DEBUG" "$(align_repo_name "$repo_name"): Using $modifyrepo_cmd to update module metadata"
    
    # Add the module.yaml to repository metadata
    if $modifyrepo_cmd --mdtype=modules "$module_yaml_file" "$repodata_dir" \
        2>>"$MYREPO_ERR_FILE"; then
        return 0
    else
        log "ERROR" "$(align_repo_name "$repo_name"): $modifyrepo_cmd failed to update module metadata"
        return 1
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

# Improved function to wait for background jobs with reduced verbosity
function wait_for_jobs() {
    local current_jobs
    local previous_jobs=0
    local wait_count=0
    local report_interval=60  # Report every 60 seconds
    local last_report=0

    while true; do
        current_jobs=$(jobs -rp | wc -l)
        
        # Break out if below parallel limit
        if ((current_jobs < PARALLEL)); then
            break
        fi
        
        # Check if job count is changing
        if ((current_jobs == previous_jobs)); then
            ((wait_count++))
        else
            # Reset counter if job count changes (progress is happening)
            wait_count=0
            previous_jobs=$current_jobs
            last_report=0  # Reset last report time when jobs change
        fi

        # Only report once per interval, and only after some waiting time
        if ((wait_count > 10 && wait_count % report_interval == 0 && wait_count != last_report)); then
            log "INFO" "Waiting for jobs in $0 ... Currently running: ${current_jobs}/${PARALLEL}"
            last_report=$wait_count
            
            # Only show detailed info for very long waits
            if ((wait_count >= 120)); then
                log "INFO" "Some DNF operations are taking longer than expected (${wait_count}s). This is normal for large packages or slow repositories."
                
                # Optionally show what's running for debugging but don't kill anything
                if ((DEBUG_MODE >= 1)); then
                    log "DEBUG" "Current running jobs:"
                    jobs -l | grep -i "dnf\|download" || true
                fi
            fi
        fi
        
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
refresh_metadata
create_helper_files
load_processed_packages
adaptive_initialize_performance_tracking
populate_repo_cache
set_parallel_downloads
remove_excluded_repos
traverse_local_repos
update_and_sync_repos
cleanup_metadata_cache
cleanup

# Show final adaptive performance statistics and summary table
adaptive_show_final_performance

# Generate and display summary table
generate_summary_table

log "INFO" "myrepo.sh Version $VERSION completed."
