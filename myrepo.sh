#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with different AI support models
# AI flock: ChatGPT, Claude, Gemini
# Last Updated: 2025-07-27

# MIT licensing
# Purpose:
# This script replicates and updates repositories from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# local repositories. Optimized for performance with intelligent caching.

# NOTE: This version has been optimized for performance while maintaining core functionality.
# Complex adaptive features have been simplified in favor of reliable, fast operation.

# Script version
VERSION="2.3.4"

# Default Configuration (can be overridden by myrepo.cfg)
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
MANUAL_REPOS=("ol9_edge")
LOCAL_RPM_SOURCES=()  # Array for local RPM source directories
DEBUG_LEVEL=${DEBUG_LEVEL:-1}
DRY_RUN=${DRY_RUN:-0}
MAX_PACKAGES=${MAX_PACKAGES:-0}
MAX_NEW_PACKAGES=${MAX_NEW_PACKAGES:--1}
SYNC_ONLY=${SYNC_ONLY:-0}
PARALLEL=${PARALLEL:-6}
EXCLUDE_REPOS=""
REPOS=""
NAME_FILTER=""
FULL_REBUILD=${FULL_REBUILD:-0}
LOG_DIR=${LOG_DIR:-"/var/log/myrepo"}
SET_PERMISSIONS=${SET_PERMISSIONS:-0}
REFRESH_METADATA=${REFRESH_METADATA:-0}
DNF_SERIAL=${DNF_SERIAL:-0}
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

# Timeout configuration (in seconds)
DNF_QUERY_TIMEOUT=${DNF_QUERY_TIMEOUT:-60}    # Timeout for basic DNF queries
DNF_CACHE_TIMEOUT=${DNF_CACHE_TIMEOUT:-120}   # Timeout for DNF cache building operations
DNF_DOWNLOAD_TIMEOUT=${DNF_DOWNLOAD_TIMEOUT:-1800}  # Timeout for DNF download operations (30 minutes)
SUDO_TEST_TIMEOUT=${SUDO_TEST_TIMEOUT:-10}    # Timeout for sudo test commands

# Performance and monitoring configuration
BATCH_SIZE=${BATCH_SIZE:-50}                              # Batch size for processing RPMs (cleanup operations)
PROGRESS_REPORT_INTERVAL=${PROGRESS_REPORT_INTERVAL:-50}  # Report progress every N packages
CONFIG_FILE_MAX_LINES=${CONFIG_FILE_MAX_LINES:-500}       # Maximum lines to read from config file
MAX_PARALLEL_DOWNLOADS=${MAX_PARALLEL_DOWNLOADS:-8}       # DNF parallel downloads
DNF_RETRIES=${DNF_RETRIES:-2}                             # DNF retry attempts
DEBUG_FILE_LIST_THRESHOLD=${DEBUG_FILE_LIST_THRESHOLD:-10} # Show file list if repo has fewer RPMs than this
DEBUG_FILE_LIST_COUNT=${DEBUG_FILE_LIST_COUNT:-5}          # Number of files to show in debug list

# PERFORMANCE OPTIMIZATION 5: Repository Performance Tracking and Load Balancing
REPO_PERF_CACHE_FILE="${SHARED_CACHE_PATH:-/var/cache/myrepo}/repo_performance.cache"
REPO_PERF_MAX_AGE=${REPO_PERF_MAX_AGE:-86400}            # Performance data valid for 24 hours
MIN_DOWNLOAD_RATE=${MIN_DOWNLOAD_RATE:-50}                # Minimum KB/s for "fast" repositories
LOAD_BALANCE_THRESHOLD=${LOAD_BALANCE_THRESHOLD:-10}      # Start load balancing after this many packages per repo
ADAPTIVE_BATCH_SIZE_MIN=${ADAPTIVE_BATCH_SIZE_MIN:-3}     # Minimum batch size for slow repos
ADAPTIVE_BATCH_SIZE_MAX=${ADAPTIVE_BATCH_SIZE_MAX:-20}    # Maximum batch size for fast repos

# Common Oracle Linux 9 repositories (for fallback repository detection)
declare -a REPOSITORIES=(
    "ol9_baseos_latest"
    "ol9_appstream"
    "ol9_codeready_builder"
    "ol9_developer_EPEL"
    "ol9_developer"
    "ol9_oraclelinux_developer_EPEL"
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

# Failed downloads tracking arrays
declare -A failed_downloads
declare -A failed_download_reasons

# PERFORMANCE OPTIMIZATION 5: Repository Performance Tracking
declare -A repo_download_speeds       # Track download speeds per repository  
declare -A repo_success_rates         # Track success rates per repository
declare -A repo_last_batch_sizes      # Track optimal batch sizes per repository

# Cache for repository package metadata (like original script)
declare -A available_repo_packages

# Align repository names like the original script
function align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

# PERFORMANCE OPTIMIZATION 5: Repository Performance Tracking Functions

# Load repository performance data from cache
function load_repo_performance_cache() {
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Loading repository performance cache from $REPO_PERF_CACHE_FILE"
    
    if [[ ! -f "$REPO_PERF_CACHE_FILE" ]]; then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "No repository performance cache found, starting fresh"
        return 0
    fi
    
    # Check if cache is too old
    local cache_age
    cache_age=$(( $(date +%s) - $(stat -c %Y "$REPO_PERF_CACHE_FILE" 2>/dev/null || echo 0) ))
    if [[ $cache_age -gt $REPO_PERF_MAX_AGE ]]; then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Repository performance cache is stale (${cache_age}s old), starting fresh"
        return 0
    fi
    
    # Load performance data
    local loaded_count=0
    while IFS='|' read -r repo_name download_speed success_rate last_batch_size; do
        [[ -z "$repo_name" || "$repo_name" =~ ^[[:space:]]*# ]] && continue
        
        repo_download_speeds["$repo_name"]="$download_speed"
        repo_success_rates["$repo_name"]="$success_rate"
        repo_last_batch_sizes["$repo_name"]="$last_batch_size"
        ((loaded_count++))
    done < "$REPO_PERF_CACHE_FILE"
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Loaded performance data for $loaded_count repositories"
}

# Save repository performance data to cache
function save_repo_performance_cache() {
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Saving repository performance cache to $REPO_PERF_CACHE_FILE"
    
    # Ensure cache directory exists
    local cache_dir
    cache_dir=$(dirname "$REPO_PERF_CACHE_FILE")
    if [[ ! -d "$cache_dir" ]]; then
        mkdir -p "$cache_dir" 2>/dev/null || {
            if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                sudo mkdir -p "$cache_dir"
                sudo chown "$USER:$USER" "$cache_dir" 2>/dev/null || true
            fi
        }
    fi
    
    # Save performance data
    local saved_count=0
    {
        echo "# Repository Performance Cache - Generated $(date)"
        echo "# Format: repo_name|download_speed_kbps|success_rate_percent|last_batch_size"
        
        for repo_name in "${!repo_download_speeds[@]}"; do
            local speed="${repo_download_speeds[$repo_name]:-0}"
            local success="${repo_success_rates[$repo_name]:-100}"
            local batch_size="${repo_last_batch_sizes[$repo_name]:-10}"
            echo "$repo_name|$speed|$success|$batch_size"
            ((saved_count++))
        done
    } > "$REPO_PERF_CACHE_FILE" 2>/dev/null || {
        if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
            {
                echo "# Repository Performance Cache - Generated $(date)"
                echo "# Format: repo_name|download_speed_kbps|success_rate_percent|last_batch_size"
                
                for repo_name in "${!repo_download_speeds[@]}"; do
                    local speed="${repo_download_speeds[$repo_name]:-0}"
                    local success="${repo_success_rates[$repo_name]:-100}"
                    local batch_size="${repo_last_batch_sizes[$repo_name]:-10}"
                    echo "$repo_name|$speed|$success|$batch_size"
                done
            } | sudo tee "$REPO_PERF_CACHE_FILE" >/dev/null
        fi
    }
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Saved performance data for $saved_count repositories"
}

# Calculate adaptive batch size based on repository performance
function get_adaptive_batch_size() {
    local repo_name="$1"
    local package_count="$2"
    
    # Get cached performance data
    local download_speed="${repo_download_speeds[$repo_name]:-0}"
    local success_rate="${repo_success_rates[$repo_name]:-100}"
    local last_batch_size="${repo_last_batch_sizes[$repo_name]:-10}"
    
    # Start with last known good batch size or default
    local adaptive_size="$last_batch_size"
    
    # Adjust based on download speed
    if [[ $download_speed -gt $((MIN_DOWNLOAD_RATE * 3)) ]]; then
        # Very fast repository - use larger batches
        adaptive_size=$ADAPTIVE_BATCH_SIZE_MAX
    elif [[ $download_speed -gt $MIN_DOWNLOAD_RATE ]]; then
        # Fast repository - use medium batches
        adaptive_size=$(( (ADAPTIVE_BATCH_SIZE_MAX + ADAPTIVE_BATCH_SIZE_MIN) / 2 ))
    elif [[ $download_speed -gt 0 ]]; then
        # Slow repository - use smaller batches
        adaptive_size=$ADAPTIVE_BATCH_SIZE_MIN
    fi
    
    # Adjust based on success rate
    if [[ $success_rate -lt 80 ]]; then
        # Low success rate - reduce batch size
        adaptive_size=$(( adaptive_size / 2 ))
        [[ $adaptive_size -lt $ADAPTIVE_BATCH_SIZE_MIN ]] && adaptive_size=$ADAPTIVE_BATCH_SIZE_MIN
    fi
    
    # Don't exceed available packages
    [[ $adaptive_size -gt $package_count ]] && adaptive_size="$package_count"
    
    echo "$adaptive_size"
}

# Prioritize repositories based on performance metrics
function get_repository_priority() {
    local repo_name="$1"
    
    local download_speed="${repo_download_speeds[$repo_name]:-0}"
    local success_rate="${repo_success_rates[$repo_name]:-100}"
    
    # Calculate priority score (higher is better)
    # Formula: (download_speed_factor * 10) + (success_rate_factor * 5)
    local speed_factor=0
    if [[ $download_speed -gt $((MIN_DOWNLOAD_RATE * 3)) ]]; then
        speed_factor=10
    elif [[ $download_speed -gt $((MIN_DOWNLOAD_RATE * 2)) ]]; then
        speed_factor=7
    elif [[ $download_speed -gt $MIN_DOWNLOAD_RATE ]]; then
        speed_factor=5
    elif [[ $download_speed -gt 0 ]]; then
        speed_factor=2
    fi
    
    local success_factor=0
    if [[ $success_rate -ge 95 ]]; then
        success_factor=5
    elif [[ $success_rate -ge 85 ]]; then
        success_factor=4
    elif [[ $success_rate -ge 70 ]]; then
        success_factor=3
    elif [[ $success_rate -ge 50 ]]; then
        success_factor=2
    else
        success_factor=1
    fi
    
    local priority_score=$(( (speed_factor * 10) + (success_factor * 5) ))
    echo "$priority_score"
}

# Log function with improved formatting and severity levels
function batch_download_packages() {
    local -A repo_packages
    local -A repo_status  # Track which repos are enabled/disabled
    local -A repo_priorities  # Repository priority scores for load balancing
    
    # Group packages by repository for batch downloading
    while IFS='|' read -r repo_name package_name epoch package_version package_release package_arch; do
        local repo_path
        repo_path=$(get_repo_path "$repo_name")
        
        # Ensure repository directory exists with proper permissions
        if [[ ! -d "$repo_path" ]]; then
            mkdir -p "$repo_path" 2>/dev/null || {
                if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                    sudo mkdir -p "$repo_path"
                    sudo chown "$USER:$USER" "$repo_path" 2>/dev/null || true
                    chmod 755 "$repo_path" 2>/dev/null || true
                fi
            }
        fi
        if [[ -d "$repo_path" ]]; then
            local old_packages
            old_packages=$(find "$repo_path" -maxdepth 1 -name "${package_name}-*-*.${package_arch}.rpm" -type f 2>/dev/null)
            if [[ -n "$old_packages" ]]; then
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Removing old versions of $package_name from $repo_name before batch download"
                if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                    echo "$old_packages" | xargs sudo rm -f 2>/dev/null
                else
                    echo "$old_packages" | xargs rm -f 2>/dev/null
                fi
            fi
        fi
        
        # Build package spec (handle epoch properly for DNF download)
        local package_spec
        # DNF download typically works better without epoch prefix
        # The epoch is handled internally by DNF when resolving package names
        package_spec="${package_name}-${package_version}-${package_release}.${package_arch}"
        
        repo_packages["$repo_path"]+="$package_spec "
        
        # Check if repository is enabled
        if is_repo_enabled "$repo_name"; then
            repo_status["$repo_path"]="enabled"
        else
            repo_status["$repo_path"]="disabled"
        fi
        
        # Calculate repository priority for load balancing
        repo_priorities["$repo_path"]=$(get_repository_priority "$repo_name")
    done
    
    # PERFORMANCE OPTIMIZATION 5: Load-balanced batch downloading with repository prioritization
    log "I" "🔄 Applying intelligent repository prioritization and load balancing..."
    
    # Count total packages for progress tracking
    local total_packages_to_download=0
    for repo_path in "${!repo_packages[@]}"; do
        local package_count
        package_count=$(echo "${repo_packages[$repo_path]}" | wc -w)
        total_packages_to_download=$((total_packages_to_download + package_count))
    done
    
    log "I" "📦 Processing $total_packages_to_download packages across ${#repo_packages[@]} repositories..."
    
    # Sort repositories by priority (highest first) for optimal download order
    local -a sorted_repos
    while IFS= read -r repo_path; do
        sorted_repos+=("$repo_path")
    done < <(
        for repo_path in "${!repo_packages[@]}"; do
            echo "${repo_priorities[$repo_path]}|$repo_path"
        done | sort -rn -t'|' | cut -d'|' -f2
    )
    
    # Track download performance for each repository
    local load_balance_active=0
    local total_repos=${#sorted_repos[@]}
    
    # Check if we need load balancing (repositories with many packages)
    for repo_path in "${sorted_repos[@]}"; do
        local package_count
        package_count=$(echo "${repo_packages[$repo_path]}" | wc -w)
        if [[ $package_count -gt $LOAD_BALANCE_THRESHOLD ]]; then
            load_balance_active=1
            break
        fi
    done
    
    [[ $load_balance_active -eq 1 ]] && log "I" "⚖️  Load balancing activated for repositories with >$LOAD_BALANCE_THRESHOLD packages"
    
    # Calculate total packages across all repositories for global progress tracking
    local total_packages_to_download=0
    for repo_path in "${sorted_repos[@]}"; do
        local packages="${repo_packages[$repo_path]}"
        local package_count
        package_count=$(echo "$packages" | wc -w)
        total_packages_to_download=$((total_packages_to_download + package_count))
    done
    
    # Enhanced progress reporting for large batches
    if [[ $total_packages_to_download -gt 100 ]]; then
        log "I" "🔄 Large batch detected ($total_packages_to_download packages) - enhanced progress reporting enabled"
        log "I" "📊 Processing across $total_repos repositories with progress updates every 30s for large batches"
    fi
    
    # Track global progress
    local global_downloaded=0
    local current_repo=0
    
    # Download batches per repository with optimized DNF settings and performance tracking
    for repo_path in "${sorted_repos[@]}"; do
        local packages="${repo_packages[$repo_path]}"
        if [[ -n "$packages" ]]; then
            ((current_repo++))
            local repo_name
            repo_name=$(basename "$(dirname "$repo_path")")  # Get repo name from path
            
            # Count packages for better feedback
            local total_package_count
            total_package_count=$(echo "$packages" | wc -w)
            
            # Get adaptive batch size based on repository performance
            local batch_size
            batch_size=$(get_adaptive_batch_size "$repo_name" "$total_package_count")
            
            # Get repository priority for display
            local priority="${repo_priorities[$repo_path]:-0}"
            
            log "I" "📥 Repository $current_repo/${#sorted_repos[@]}: Downloading $total_package_count packages from $repo_name (priority: $priority, batch size: $batch_size)..."
            
            # Track performance metrics for this download session
            local repo_start_time
            local total_downloaded=0
            local total_failed=0
            local total_bytes=0
            repo_start_time=$(date +%s)
            
            # Split packages into batches if load balancing is active
            local -a package_array
            read -ra package_array <<< "$packages"
            
            local batch_num=1
            local processed_packages=0
            
            while [[ $processed_packages -lt $total_package_count ]]; do
                # Create batch
                local batch_packages=()
                local batch_end=$(( processed_packages + batch_size ))
                [[ $batch_end -gt $total_package_count ]] && batch_end=$total_package_count
                
                for ((i=processed_packages; i<batch_end; i++)); do
                    batch_packages+=("${package_array[i]}")
                done
                
                local batch_package_count=${#batch_packages[@]}
                
                if [[ $load_balance_active -eq 1 && $total_repos -gt 1 ]]; then
                    log "I" "   📦 Batch $batch_num: downloading $batch_package_count packages..."
                fi
                
                # Debug: show what we're trying to download
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "   Batch packages: ${batch_packages[*]}"
                
                # Use optimized DNF with parallel downloads and performance settings
                local dnf_cmd
                dnf_cmd=$(get_dnf_cmd)
                
                # Build DNF command with appropriate repository options
                local dnf_options=(
                    --setopt=max_parallel_downloads="$MAX_PARALLEL_DOWNLOADS"
                    --setopt=fastestmirror=1
                    --setopt=deltarpm=0
                    --setopt=timeout="$DNF_QUERY_TIMEOUT"
                    --setopt=retries="$DNF_RETRIES"
                    --destdir="$repo_path"
                )
                
                # If repository is disabled, enable it for this download
                if [[ "${repo_status[$repo_path]}" == "disabled" ]]; then
                    [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "   Enabling disabled repository: $repo_name"
                    dnf_options+=(--enablerepo="$repo_name")
                fi
                
                local batch_start_time
                batch_start_time=$(date +%s)
                
                if [[ $load_balance_active -eq 1 && $total_repos -gt 1 ]]; then
                    log "I" "⏳ Starting batch $batch_num DNF download for $repo_name..."
                else
                    log "I" "⏳ Starting DNF download for $repo_name..."
                fi
                
                # For large batches, show periodic progress during download
                local show_periodic_progress=0
                if [[ $batch_package_count -gt 50 || $total_packages_to_download -gt 200 ]]; then
                    show_periodic_progress=1
                fi
                
                # shellcheck disable=SC2086 # Intentional word splitting for dnf command and package list
                local download_success=0
                if [[ $show_periodic_progress -eq 1 ]]; then
                    # Start background progress monitor for large downloads
                    (
                        sleep 30
                        while kill -0 $$ 2>/dev/null; do
                            log "I" "🔄 Still downloading... ($batch_package_count packages from $repo_name, elapsed: $(($(date +%s) - batch_start_time))s)"
                            sleep 30
                        done
                    ) &
                    local progress_pid=$!
                    
                    if timeout "$DNF_DOWNLOAD_TIMEOUT" "${dnf_cmd}" download "${dnf_options[@]}" "${batch_packages[@]}" >/dev/null 2>&1; then
                        download_success=1
                    fi
                    
                    # Stop progress monitor
                    kill $progress_pid 2>/dev/null || true
                    wait $progress_pid 2>/dev/null || true
                else
                    # shellcheck disable=SC2086 # Intentional word splitting for dnf command (e.g., "sudo dnf")
                    if timeout "$DNF_DOWNLOAD_TIMEOUT" ${dnf_cmd} download "${dnf_options[@]}" "${batch_packages[@]}" >/dev/null 2>&1; then
                        download_success=1
                    fi
                fi
                
                if [[ $download_success -eq 1 ]]; then
                    local batch_end_time
                    local batch_duration
                    batch_end_time=$(date +%s)
                    batch_duration=$((batch_end_time - batch_start_time))
                    total_downloaded=$((total_downloaded + batch_package_count))
                    
                    # Estimate download size (rough approximation: 2MB per package average)
                    local estimated_bytes=$((batch_package_count * 2048))
                    total_bytes=$((total_bytes + estimated_bytes))
                    
                    if [[ $load_balance_active -eq 1 && $total_repos -gt 1 ]]; then
                        log "I" "✅ Batch $batch_num completed: $batch_package_count packages in ${batch_duration}s"
                    else
                        log "I" "✅ Successfully downloaded $batch_package_count packages for $repo_name in ${batch_duration}s"
                    fi
                    
                    # Update global progress
                    global_downloaded=$((global_downloaded + batch_package_count))
                    if [[ $total_packages_to_download -gt 100 ]]; then
                        local progress_percent=$(( (global_downloaded * 100) / total_packages_to_download ))
                        local remaining_packages=$((total_packages_to_download - global_downloaded))
                        
                        # Calculate estimated time remaining based on current pace
                        local elapsed_time=$(($(date +%s) - $(date -d "$(stat -c %Y "$PERFORMANCE_CACHE_FILE" 2>/dev/null || date)" +%s 2>/dev/null || echo 0)))
                        if [[ $elapsed_time -gt 0 && $global_downloaded -gt 0 ]]; then
                            local avg_time_per_package=$((elapsed_time / global_downloaded))
                            local eta_seconds=$((remaining_packages * avg_time_per_package))
                            local eta_minutes=$((eta_seconds / 60))
                            log "I" "🔄 Global progress: $global_downloaded/$total_packages_to_download packages (${progress_percent}%) - ETA: ${eta_minutes}m"
                        else
                            log "I" "🔄 Global progress: $global_downloaded/$total_packages_to_download packages (${progress_percent}%)"
                        fi
                    fi
                else
                    log "W" "✗ Some downloads failed in batch $batch_num for $repo_name (check dnf logs for details)"
                    
                    # Try downloading packages one by one as fallback
                    log "I" "   Trying individual downloads as fallback..."
                    local success_count=0
                    local failed_count=0
                    
                    for pkg in "${batch_packages[@]}"; do
                        # shellcheck disable=SC2086 # Intentional word splitting for dnf command
                        if timeout "$DNF_DOWNLOAD_TIMEOUT" ${dnf_cmd} download --destdir="$repo_path" "$pkg" >/dev/null 2>&1; then
                            ((success_count++))
                            ((total_downloaded++))
                            # Estimate download size
                            total_bytes=$((total_bytes + 2048))
                            [[ $DEBUG_LEVEL -ge 2 ]] && log "I" "   ✓ $pkg"
                        else
                            ((failed_count++))
                            ((total_failed++))
                            # Track failed download with detailed reason
                            failed_downloads["$pkg"]="$repo_name"
                            failed_download_reasons["$pkg"]="DNF download failed (package not available, network issue, or repository access denied)"
                            [[ $DEBUG_LEVEL -ge 1 ]] && log "W" "   ✗ Failed: $pkg"
                        fi
                    done
                    log "I" "   Fallback result: $success_count/$batch_package_count packages downloaded"
                fi
                
                processed_packages=$((processed_packages + batch_package_count))
                ((batch_num++))
                
                # Small delay between batches for load balancing (only if multiple repos and load balancing active)
                if [[ $load_balance_active -eq 1 && $total_repos -gt 1 && $processed_packages -lt $total_package_count ]]; then
                    sleep 0.5
                fi
            done
            
            # Calculate and store repository performance metrics
            local repo_end_time
            local total_repo_duration
            repo_end_time=$(date +%s)
            total_repo_duration=$((repo_end_time - repo_start_time))
            
            if [[ $total_repo_duration -gt 0 && $total_bytes -gt 0 ]]; then
                # Calculate download speed in KB/s
                local download_speed_kbps=$((total_bytes / total_repo_duration))
                repo_download_speeds["$repo_name"]="$download_speed_kbps"
                
                # Calculate success rate
                local total_attempted=$((total_downloaded + total_failed))
                if [[ $total_attempted -gt 0 ]]; then
                    local success_rate=$(( (total_downloaded * 100) / total_attempted ))
                    repo_success_rates["$repo_name"]="$success_rate"
                fi
                
                # Store optimal batch size
                repo_last_batch_sizes["$repo_name"]="$batch_size"
                
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Performance: $repo_name - Speed: ${download_speed_kbps}KB/s, Success: ${success_rate:-0}%, Batch: $batch_size"
            fi
        fi
    done
    
    # Save performance data for future runs
    save_repo_performance_cache
}

# Clean up old cache directories from filesystem
function cleanup_old_cache_directories() {
    local old_cache_patterns=(
        "/tmp/myrepo_cache_shared"
        "/tmp/myrepo_cache"
        "/tmp/myrepo_cache_*"
        "$HOME/.cache/myrepo"
        "$HOME/myrepo_cache_*"
    )
    
    # First pass: check if any old directories exist
    local old_dirs_found=0
    
    for pattern in "${old_cache_patterns[@]}"; do
        # Handle patterns with wildcards
        if [[ "$pattern" == *"*"* ]]; then
            # Use find to handle wildcards safely
            while IFS= read -r -d '' cache_dir; do
                if [[ -d "$cache_dir" && "$cache_dir" != "$SHARED_CACHE_PATH" ]]; then
                    ((old_dirs_found++))
                    break 2  # Break out of both loops - we found at least one
                fi
            done < <(find "${pattern%/*}" -maxdepth 1 -name "${pattern##*/}" -type d -print0 2>/dev/null)
        else
            # Handle exact paths
            if [[ -d "$pattern" && "$pattern" != "$SHARED_CACHE_PATH" ]]; then
                ((old_dirs_found++))
                break  # We found at least one
            fi
        fi
    done
    
    # If no old directories found, return without cleanup
    if [[ $old_dirs_found -eq 0 ]]; then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "No old cache directories detected, skipping cleanup"
        return 1  # No cleanup needed
    fi
    
    # Old directories found - perform cleanup
    log "I" "🧹 Cleaning up old cache directories from filesystem..."
    
    local cleaned_count=0
    
    for pattern in "${old_cache_patterns[@]}"; do
        # Handle patterns with wildcards
        if [[ "$pattern" == *"*"* ]]; then
            # Use find to handle wildcards safely
            while IFS= read -r -d '' cache_dir; do
                if [[ -d "$cache_dir" && "$cache_dir" != "$SHARED_CACHE_PATH" ]]; then
                    log "I" "🗑️  Removing old cache directory: $cache_dir"
                    if [[ $DRY_RUN -eq 1 ]]; then
                        log "I" "🔍 DRY RUN: Would remove $cache_dir"
                        ((cleaned_count++))
                    else
                        # Try removing without sudo first
                        if rm -rf "$cache_dir" 2>/dev/null; then
                            ((cleaned_count++))
                            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "✓ Successfully removed: $cache_dir"
                        elif [[ $ELEVATE_COMMANDS -eq 1 ]] && sudo rm -rf "$cache_dir" 2>/dev/null; then
                            ((cleaned_count++))
                            log "I" "✓ Successfully removed with sudo: $cache_dir"
                        else
                            log "W" "Failed to remove: $cache_dir (permission denied even with sudo)"
                        fi
                    fi
                fi
            done < <(find "${pattern%/*}" -maxdepth 1 -name "${pattern##*/}" -type d -print0 2>/dev/null)
        else
            # Handle exact paths
            if [[ -d "$pattern" && "$pattern" != "$SHARED_CACHE_PATH" ]]; then
                log "I" "🗑️  Removing old cache directory: $pattern"
                if [[ $DRY_RUN -eq 1 ]]; then
                    log "I" "🔍 DRY RUN: Would remove $pattern"
                    ((cleaned_count++))
                else
                    # Try removing without sudo first
                    if rm -rf "$pattern" 2>/dev/null; then
                        ((cleaned_count++))
                        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "✓ Successfully removed: $pattern"
                    elif [[ $ELEVATE_COMMANDS -eq 1 ]] && sudo rm -rf "$pattern" 2>/dev/null; then
                        ((cleaned_count++))
                        log "I" "✓ Successfully removed with sudo: $pattern"
                    else
                        log "W" "Failed to remove: $pattern (permission denied even with sudo)"
                    fi
                fi
            fi
        fi
    done
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log "I" "🔍 DRY RUN: Old cache cleanup simulation completed for $cleaned_count directories"
    elif [[ $cleaned_count -gt 0 ]]; then
        log "I" "✅ Old cache directories cleanup completed - cleaned up $cleaned_count directories"
    else
        log "W" "⚠️  Old directories detected but none could be cleaned (all permission attempts failed)"
    fi
    
    # Show current shared cache location
    log "I" "📁 Using shared cache: $SHARED_CACHE_PATH"
    
    return 0  # Cleanup was performed (or attempted)
}

# Build repository metadata cache (optimized - only for installed packages)
function build_repo_cache() {
    log "I" "Building repository metadata cache for installed packages..."
    
    # Use only the shared cache directory
    local cache_dir="$SHARED_CACHE_PATH"
    
    # Automatically handle shared cache directory creation and permissions
    if [[ ! -d "$cache_dir" ]]; then
        log "I" "Creating shared cache directory: $cache_dir"
        if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
            # Create with sudo and set proper shared permissions
            if sudo mkdir -p "$cache_dir" 2>/dev/null; then
                sudo chown root:root "$cache_dir" 2>/dev/null || true
                sudo chmod 1777 "$cache_dir" 2>/dev/null || true  # Sticky bit for shared temp-like access
                log "I" "✓ Created shared cache directory with proper permissions (1777)"
            else
                log "W" "Failed to create shared cache with sudo, trying fallback..."
                if mkdir -p "$HOME/.cache/myrepo" 2>/dev/null; then
                    cache_dir="$HOME/.cache/myrepo"
                    log "I" "✓ Using fallback cache directory: $cache_dir"
                else
                    log "E" "Cannot create any cache directory"
                    exit 1
                fi
            fi
        else
            # Create without sudo (running as root or no elevation)
            if mkdir -p "$cache_dir" 2>/dev/null; then
                chmod 755 "$cache_dir" 2>/dev/null || true
                log "I" "✓ Created cache directory: $cache_dir"
            else
                log "E" "Cannot create cache directory: $cache_dir"
                exit 1
            fi
        fi
    elif [[ ! -w "$cache_dir" ]]; then
        # Directory exists but not writable - try to fix permissions
        log "I" "Fixing permissions for existing cache directory: $cache_dir"
        if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
            if sudo chmod 1777 "$cache_dir" 2>/dev/null; then
                log "I" "✓ Fixed shared cache directory permissions"
            else
                log "W" "Failed to fix shared cache permissions, using fallback..."
                if mkdir -p "$HOME/.cache/myrepo" 2>/dev/null; then
                    cache_dir="$HOME/.cache/myrepo"
                    log "I" "✓ Using fallback cache directory: $cache_dir"
                else
                    log "E" "Cannot access any writable cache directory"
                    exit 1
                fi
            fi
        else
            if chmod 755 "$cache_dir" 2>/dev/null; then
                log "I" "✓ Fixed cache directory permissions"
            else
                log "E" "Cannot fix permissions for cache directory: $cache_dir"
                exit 1
            fi
        fi
    fi
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Using cache directory: $cache_dir"
    
    # Cache validity check (4 hours by default, configurable)
    local cache_max_age=${CACHE_MAX_AGE:-14400}  # 4 hours in seconds
    local cache_valid=true
    local current_time
    current_time=$(date +%s)
    
    # Check if we need to rebuild cache
    local cache_timestamp_file="$cache_dir/cache_timestamp"
    if [[ -f "$cache_timestamp_file" ]]; then
        local cache_time
        cache_time=$(cat "$cache_timestamp_file" 2>/dev/null || echo "0")
        local cache_age=$((current_time - cache_time))
        
        if [[ $cache_age -gt $cache_max_age ]]; then
            log "I" "Cache expired (${cache_age}s old, max age: ${cache_max_age}s)"
            cache_valid=false
        else
            log "I" "Using existing cache (${cache_age}s old, valid for $((cache_max_age - cache_age))s more)"
        fi
    else
        log "I" "No existing cache found"
        cache_valid=false
    fi
    
    # Force rebuild if --refresh-metadata is specified
    if [[ $REFRESH_METADATA -eq 1 ]]; then
        log "I" "Force cache rebuild requested via --refresh-metadata"
        cache_valid=false
    fi
    
    # If cache is valid, try to load existing cache
    if [[ $cache_valid == true ]]; then
        local loaded_repos=0
        local enabled_repos
        local dnf_cmd
        dnf_cmd=$(get_dnf_cmd)
        # shellcheck disable=SC2086 # Intentional word splitting for dnf command  
        enabled_repos=$(${dnf_cmd} repolist --enabled --quiet | awk 'NR>1 {print $1}' | grep -v "^$")
        
        while IFS= read -r repo; do
            local cache_file="$cache_dir/${repo}.cache"
            if [[ -f "$cache_file" ]]; then
                available_repo_packages["$repo"]=$(cat "$cache_file")
                local package_count
                package_count=$(wc -l < "$cache_file")
                ((loaded_repos++))
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Loaded $package_count packages from cached $repo"
            else
                log "W" "Cache file missing for $repo, forcing rebuild"
                cache_valid=false
                break
            fi
        done <<< "$enabled_repos"
        
        if [[ $cache_valid == true ]]; then
            log "I" "Successfully loaded cache for $loaded_repos repositories"
            return 0
        fi
    fi
    
    # Rebuild cache if needed
    log "I" "Rebuilding repository metadata cache..."
    
    # Clear old cache
    rm -f "$cache_dir"/*.cache 2>/dev/null || true
    
    # Get list of all installed packages first
    local installed_packages
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Using DNF command: $dnf_cmd"
    
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    if ! installed_packages=$(timeout "$DNF_QUERY_TIMEOUT" ${dnf_cmd} repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{ui_from_repo}" 2>&1); then
        log "E" "Failed to get installed packages list"
        [[ $DEBUG_LEVEL -ge 1 ]] && log "E" "DNF error: $installed_packages"
        log "E" "Failed to build repository metadata cache"
        exit 1
    fi
    
    if [[ -z "$installed_packages" ]]; then
        log "E" "No installed packages found in DNF query result"
        log "E" "Failed to build repository metadata cache"
        exit 1
    fi
    
    # Get unique package names for efficient querying
    local unique_packages
    unique_packages=$(echo "$installed_packages" | cut -d'|' -f1 | sort -u)
    
    # Get list of enabled repositories
    local enabled_repos
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    if ! enabled_repos=$(${dnf_cmd} repolist --enabled --quiet 2>&1 | awk 'NR>1 {print $1}' | grep -v "^$"); then
        log "E" "Failed to get enabled repositories list"
        [[ $DEBUG_LEVEL -ge 1 ]] && log "E" "DNF repolist error: $enabled_repos"
        log "E" "Failed to build repository metadata cache"
        exit 1
    fi
    
    if [[ -z "$enabled_repos" ]]; then
        log "W" "No enabled repositories found"
        log "E" "Failed to build repository metadata cache"
        exit 1
    fi
    
    local repo_count=0
    local total_repos
    total_repos=$(echo "$enabled_repos" | wc -l)
    
    # Only cache metadata for packages we actually have installed
    while IFS= read -r repo; do
        ((repo_count++))
        log "I" "⏳ Caching metadata for repository: $repo ($repo_count/$total_repos)"
        
        local cache_file="$cache_dir/${repo}.cache"
        local package_list=()
        
        # Build a targeted package list for this repository
        while IFS= read -r pkg_name; do
            package_list+=("$pkg_name")
        done <<< "$unique_packages"
        
        # Query only for our installed packages in this repository (much faster!)
        local dnf_result
        # shellcheck disable=SC2086 # Intentional word splitting for dnf command
        if dnf_result=$(timeout "$DNF_CACHE_TIMEOUT" ${dnf_cmd} repoquery -y --disablerepo="*" --enablerepo="$repo" \
            --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" \
            "${package_list[@]}" 2>&1); then
            
            # Write directly to cache file, handling permissions properly
            if echo "$dnf_result" > "$cache_file" 2>/dev/null; then
                # Successfully wrote as current user
                chmod 644 "$cache_file" 2>/dev/null || true
            elif [[ $ELEVATE_COMMANDS -eq 1 ]] && echo "$dnf_result" | sudo tee "$cache_file" >/dev/null 2>&1; then
                # Write with sudo and set proper permissions
                sudo chmod 644 "$cache_file" 2>/dev/null || true
            else
                # Fallback: write to temp file with unique name and try to move
                local temp_file="$cache_file.tmp.$$"
                if echo "$dnf_result" > "$temp_file" 2>/dev/null; then
                    if mv "$temp_file" "$cache_file" 2>/dev/null; then
                        chmod 644 "$cache_file" 2>/dev/null || true
                    elif [[ $ELEVATE_COMMANDS -eq 1 ]] && sudo mv "$temp_file" "$cache_file" 2>/dev/null; then
                        sudo chmod 644 "$cache_file" 2>/dev/null || true
                    else
                        # Clean up temp file if all attempts failed
                        rm -f "$temp_file" 2>/dev/null || true
                        log "W" "Failed to write cache file: $cache_file"
                        continue
                    fi
                else
                    log "W" "Failed to create temp cache file for: $repo"
                    continue
                fi
            fi
            
            local package_count
            package_count=$(wc -l < "$cache_file")
            if [[ $package_count -gt 0 ]]; then
                available_repo_packages["$repo"]=$(cat "$cache_file")
                log "I" "✓ Cached $package_count relevant packages from $repo"
            else
                log "I" "→ No relevant packages in $repo"
            fi
        else
            log "W" "⚠️  Failed to cache metadata for repository: $repo"
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "   Error: $dnf_result"
        fi
    done <<< "$enabled_repos"
    
    # Save cache timestamp
    local timestamp_written=false
    local timestamp_file="$cache_dir/cache_timestamp"
    
    # Try with sudo if needed for shared cache
    if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
        if echo "$current_time" | sudo tee "$timestamp_file" >/dev/null 2>&1; then
            sudo chmod 644 "$timestamp_file" 2>/dev/null || true
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Cache timestamp written to shared location: $timestamp_file"
            timestamp_written=true
        fi
    fi
    
    # Try direct write if sudo didn't work or wasn't used
    if [[ $timestamp_written == false ]] && echo "$current_time" > "$timestamp_file" 2>/dev/null; then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Cache timestamp written to: $timestamp_file"
        timestamp_written=true
    fi
    
    if [[ $timestamp_written == false ]]; then
        log "W" "Could not write cache timestamp to: $timestamp_file"
    fi
    
    # Inform user about shared cache behavior
    log "I" "✅ Repository metadata cache built successfully (shared cache: $cache_dir)"
    [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "✓ Cache is shared between root and user modes"
    
    return 0  # Success
}

# Check command elevation and privileges (with auto-detection)
function check_command_elevation() {
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Checking command elevation and privileges (ELEVATE_COMMANDS=$ELEVATE_COMMANDS, EUID=$EUID, SUDO_USER=${SUDO_USER:-unset})"
    
    # Enhanced auto-detection for elevated privileges
    if [[ $EUID -eq 0 ]] || [[ -n "$SUDO_USER" ]] || [[ -w /root ]]; then
        if [[ $EUID -eq 0 ]]; then
            log "I" "Running as root - DNF commands will run directly without sudo"
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Root privileges detected (EUID=0)"
        elif [[ -n "$SUDO_USER" ]]; then
            log "I" "Running under sudo - DNF commands will run directly without additional sudo"
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Sudo context detected (SUDO_USER=$SUDO_USER)"
        else
            log "I" "Elevated privileges detected - DNF commands will run directly"
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Write access to /root detected"
        fi
        return 0
    fi
    
    # Not running with elevated privileges - check if elevation is enabled
    if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
        log "I" "Running as user (EUID=$EUID) - DNF commands will use sudo for elevation"
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Auto-detected: user needs sudo for DNF operations"
        
        # Test if sudo works (optional test to avoid surprises later)
        local dnf_binary
        if command -v dnf >/dev/null 2>&1; then
            dnf_binary=$(command -v dnf)
        else
            dnf_binary="dnf"  # Let PATH resolve it
        fi
        
        if ! sudo -n "$dnf_binary" --version >/dev/null 2>&1; then
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Passwordless sudo not available, testing with prompt..."
            if ! timeout "$SUDO_TEST_TIMEOUT" sudo "$dnf_binary" --version >/dev/null 2>&1; then
                log "E" "Auto-detected sudo requirement but sudo access failed. Please ensure:"
                log "E" "1. Your user is in the sudoers group (wheel)"
                log "E" "2. You can run 'sudo $dnf_binary' commands"
                log "E" "3. Or run the script as root to avoid sudo requirement"
                exit 1
            fi
        fi
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Sudo privileges verified successfully"
        return 0
    else
        log "I" "Command elevation disabled - DNF commands will run directly"
        [[ $DEBUG_LEVEL -ge 1 ]] && log "W" "Running as user without elevation - some DNF operations may fail"
        
        # Test if user can run dnf directly
        if ! dnf --version >/dev/null 2>&1; then
            log "E" "Direct DNF execution failed. When running as non-root user, you usually need sudo."
            log "E" "Consider: 1. Running script as root, or 2. Enabling elevation (ELEVATE_COMMANDS=1)"
            exit 1
        fi
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Direct DNF access verified (running without sudo)"
        return 0
    fi
}

# Clean up uninstalled packages from local repositories (improved accuracy)
function cleanup_uninstalled_packages() {
    log "I" "🧹 Checking for uninstalled packages to clean up..."
    
    # Get comprehensive list of installed packages with full metadata (like original script)
    local installed_packages_file
    installed_packages_file=$(mktemp)
    
    log "I" "📋 Building comprehensive installed packages list..."
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    if ! timeout "$DNF_CACHE_TIMEOUT" ${dnf_cmd} repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>/dev/null | \
         sed 's/(none)/0/g' | sort -u > "$installed_packages_file"; then
        log "W" "Could not get comprehensive installed package list for cleanup"
        rm -f "$installed_packages_file"
        return 1
    fi
    
    local installed_count
    installed_count=$(wc -l < "$installed_packages_file")
    log "I" "📦 Found $installed_count installed packages to check against"
    
    if [[ $installed_count -eq 0 ]]; then
        log "W" "No installed packages found, skipping cleanup"
        rm -f "$installed_packages_file"
        return 1
    fi
    
    local total_removed=0
    local total_would_remove=0
    local repos_cleaned=0
    
    # Check each repository for packages that are no longer installed
    for repo_dir in "$LOCAL_REPO_PATH"/*; do
        if [[ -d "$repo_dir" ]]; then
            local repo_name
            repo_name=$(basename "$repo_dir")
            
            # Skip if this repo should not be processed
            if ! should_process_repo "$repo_name"; then
                continue
            fi
            
            # Skip manual repositories (like original script)
            local is_manual=false
            for manual_repo in "${MANUAL_REPOS[@]}"; do
                if [[ "$repo_name" == "$manual_repo" ]]; then
                    is_manual=true
                    break
                fi
            done
            
            if [[ $is_manual == true ]]; then
                [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "$(align_repo_name "$repo_name"): Skipping cleanup for manual repository"
                continue
            fi
            
            local repo_path
            repo_path=$(get_repo_path "$repo_name")
            
            if [[ ! -d "$repo_path" ]]; then
                continue
            fi
            
            local removed_count=0
            local would_remove_count=0
            local total_rpms
            total_rpms=$(find "$repo_path" -name "*.rpm" -type f 2>/dev/null | wc -l)
            
            if [[ $total_rpms -eq 0 ]]; then
                continue
            fi
            
            [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "$(align_repo_name "$repo_name"): Checking $total_rpms packages for removal"
            
            # Build list of RPM files for batch processing
            local rpm_files_array=()
            while IFS= read -r rpm_file; do
                [[ -n "$rpm_file" ]] && rpm_files_array+=("$rpm_file")
            done < <(find "$repo_path" -name "*.rpm" -type f 2>/dev/null)
            
            if [[ ${#rpm_files_array[@]} -eq 0 ]]; then
                continue
            fi
            
            # Process RPMs in batches for much better performance
            local batch_size="$BATCH_SIZE"
            local rpms_to_remove=()
            
            for ((i=0; i<${#rpm_files_array[@]}; i+=batch_size)); do
                local batch_files=("${rpm_files_array[@]:i:batch_size}")
                
                # Extract metadata from batch of RPM files in one command
                local batch_metadata
                if batch_metadata=$(rpm -qp --nosignature --nodigest --queryformat "%{NAME}|%{EPOCH}|%{VERSION}|%{RELEASE}|%{ARCH}\n" "${batch_files[@]}" 2>/dev/null); then
                    
                    # Process each line and corresponding file
                    local line_num=0
                    while IFS= read -r rpm_metadata; do
                        if [[ -n "$rpm_metadata" ]]; then
                            # Normalize epoch (replace (none) with 0)
                            rpm_metadata="${rpm_metadata//(none)/0}"
                            
                            [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Checking: $rpm_metadata"
                            
                            # Check if this exact package metadata is in the installed list
                            if ! grep -qxF "$rpm_metadata" "$installed_packages_file"; then
                                local rpm_file="${batch_files[line_num]}"
                                local package_name
                                package_name=$(echo "$rpm_metadata" | cut -d'|' -f1)
                                
                                if [[ $DRY_RUN -eq 1 ]]; then
                                    log "I" "🔍 Would remove uninstalled: $package_name (from $repo_name)"
                                    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "   Metadata: $rpm_metadata"
                                    ((would_remove_count++))
                                    ((total_would_remove++))
                                else
                                    log "I" "🗑️  Removing uninstalled: $package_name (from $repo_name)"
                                    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "   Metadata: $rpm_metadata"
                                    rpms_to_remove+=("$rpm_file")
                                    ((removed_count++))
                                    ((total_removed++))
                                fi
                            fi
                        fi
                        ((line_num++))
                    done <<< "$batch_metadata"
                fi
            done
            
            # Remove all flagged RPMs in one batch operation
            if [[ ${#rpms_to_remove[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
                if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                    sudo rm -f "${rpms_to_remove[@]}"
                else
                    rm -f "${rpms_to_remove[@]}"
                fi
            fi
            
            if [[ $DRY_RUN -eq 1 ]]; then
                if [[ $would_remove_count -gt 0 ]]; then
                    ((repos_cleaned++))
                    echo -e "\e[35m$(align_repo_name "$repo_name"): Would remove $would_remove_count uninstalled packages (dry-run)\e[0m"
                fi
            else
                if [[ $removed_count -gt 0 ]]; then
                    ((repos_cleaned++))
                    echo -e "\e[33m$(align_repo_name "$repo_name"): Removed $removed_count uninstalled packages\e[0m"
                fi
            fi
        fi
    done
    
    # Cleanup temporary file
    rm -f "$installed_packages_file"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        if [[ $total_would_remove -gt 0 ]]; then
            log "I" "🔍 DRY RUN: Would remove $total_would_remove uninstalled packages from $repos_cleaned repositories"
        else
            log "I" "🔍 DRY RUN: No uninstalled packages found to remove"
        fi
    else
        if [[ $total_removed -gt 0 ]]; then
            log "I" "✅ Cleanup completed: $total_removed uninstalled packages removed from $repos_cleaned repositories"
        else
            log "I" "✅ No uninstalled packages found to remove"
        fi
    fi
}

# Determine actual repository source for @System packages (like original script)
function determine_repo_from_installed() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local package_arch="$4"
    
    # Method 1: Use dnf list installed to get repo info
    local repo_info
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    repo_info=$(${dnf_cmd} list installed "$package_name" 2>/dev/null | grep -E "^${package_name}" | awk '{print $3}' | head -1)
    
    if [[ -n "$repo_info" && "$repo_info" != "@System" ]]; then
        # Clean up repo name (remove @ prefix)
        local clean_repo="${repo_info#@}"
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Found installed repo via DNF: $clean_repo"
        echo "$clean_repo"
        return 0
    fi
    
    # Method 2: Try rpm query for vendor/packager info
    local rpm_info
    rpm_info=$(rpm -qi "$package_name" 2>/dev/null | grep -E "^(Vendor|Packager|URL)" | head -1)
    
    if [[ "$rpm_info" == *"Oracle"* ]]; then
        # Try to guess Oracle repo based on package characteristics
        case "$package_name" in
            *kernel*|*glibc*|*systemd*) echo "ol9_baseos_latest" ;;
            *devel*|*headers*) echo "ol9_codeready_builder" ;;
            *EPEL*|*epel*) echo "ol9_developer_EPEL" ;;
            *) echo "ol9_appstream" ;;
        esac
        return 0
    fi
    
    # Method 3: Fallback - return empty to trigger repo search
    return 1
}

function determine_repo_source() {
    local package_name="$1"
    local epoch_version="$2"
    local package_version="$3"
    local package_release="$4"
    local package_arch="$5"
    
    # Reconstruct the expected package string (same logic as original)
    local expected_package
    if [[ -n "$epoch_version" && "$epoch_version" != "0" && "$epoch_version" != "(none)" ]]; then
        expected_package="${package_name}|${epoch_version}|${package_version}|${package_release}|${package_arch}"
    else
        expected_package="${package_name}|0|${package_version}|${package_release}|${package_arch}"
    fi
    
    # Search through cached repo metadata (same logic as original)
    for repo in "${!available_repo_packages[@]}"; do
        if echo "${available_repo_packages[$repo]}" | grep -Fxq "$expected_package"; then
            echo "$repo"
            return 0
        fi
    done
    
    # Default to Invalid if no matching repo is found (same as original)
    echo "Invalid"
    return 1
}

# Check and diagnose permission issues
function diagnose_permissions() {
    log "I" "🔍 Diagnosing permission setup..."
    
    # Check current user context
    log "I" "Current user: $(whoami) (EUID=$EUID)"
    if [[ -n "$SUDO_USER" ]]; then
        log "I" "Original user: $SUDO_USER (running under sudo)"
    fi
    
    # Check if we can write to common locations
    local locations=("/tmp" "$HOME" "/var/cache" "$LOCAL_REPO_PATH")
    for location in "${locations[@]}"; do
        if [[ -d "$location" ]]; then
            if [[ -w "$location" ]]; then
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "✓ Write access to: $location"
            else
                log "W" "✗ No write access to: $location"
            fi
        else
            log "W" "✗ Directory does not exist: $location"
        fi
    done
    
    # Check DNF access
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "DNF command will be: $dnf_cmd"
    
    # Test basic DNF access
    local test_result
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    if test_result=$(timeout 10 ${dnf_cmd} --version 2>&1); then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "✓ DNF access working"
    else
        log "E" "✗ DNF access failed: $test_result"
        log "E" "This may indicate permission issues or DNF configuration problems"
        return 1
    fi
    
    return 0
}

# Flexible table border drawing function that accepts border type
function draw_table_border_flex() {
    local border_type="${1:-top}"  # top, middle, bottom
    local column_widths=("$TABLE_REPO_WIDTH" "$TABLE_NEW_WIDTH" "$TABLE_UPDATE_WIDTH" "$TABLE_EXISTS_WIDTH" "$TABLE_STATUS_WIDTH")
    
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
    local headers=("Repository" "New" "Update" "Exists" "Status")
    local column_widths=("$TABLE_REPO_WIDTH" "$TABLE_NEW_WIDTH" "$TABLE_UPDATE_WIDTH" "$TABLE_EXISTS_WIDTH" "$TABLE_STATUS_WIDTH")
    local alignments=("left" "right" "right" "right" "left")  # left or right
    
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
    local status="$5"
    
    local values=("$repo" "$new" "$update" "$exists" "$status")
    local column_widths=("$TABLE_REPO_WIDTH" "$TABLE_NEW_WIDTH" "$TABLE_UPDATE_WIDTH" "$TABLE_EXISTS_WIDTH" "$TABLE_STATUS_WIDTH")
    local alignments=("left" "right" "right" "right" "left")  # left or right
    
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

# Perform full rebuild by removing all packages in local repositories
function full_rebuild_repos() {
    if [[ $FULL_REBUILD -ne 1 ]]; then
        return 0
    fi
    
    log "I" "Full rebuild requested - removing all packages from local repositories"
    
    # Remove all RPM files from each repository
    for repo_dir in "$LOCAL_REPO_PATH"/*; do
        if [[ -d "$repo_dir" ]]; then
            local repo_name
            repo_name=$(basename "$repo_dir")
            
            # Skip if this repo should not be processed
            if ! should_process_repo "$repo_name"; then
                continue
            fi
            
            log "I" "Cleaning repository: $repo_name"
            
            # Remove all RPM files
            find "$repo_dir" -name "*.rpm" -type f -delete 2>/dev/null || true
            
            # Also clean up old repodata
            find "$repo_dir" -name "repodata.old.*" -type d -exec rm -rf {} + 2>/dev/null || true
            
            echo -e "\e[33m$(align_repo_name "$repo_name"): Repository cleaned for full rebuild\e[0m"
        fi
    done
    
    log "I" "Full rebuild preparation completed"
}

# Generate the beautiful summary table
function generate_summary_table() {
    # Skip summary table in sync-only mode
    if [[ $SYNC_ONLY -eq 1 ]]; then
        return 0
    fi
    
    local total_new=0 total_update=0 total_exists=0
    
    # Calculate totals - check if arrays exist first
    if [[ ${#stats_new_count[@]} -gt 0 ]]; then
        for count in "${stats_new_count[@]}"; do
            ((total_new += count))
        done
    fi
    if [[ ${#stats_update_count[@]} -gt 0 ]]; then
        for count in "${stats_update_count[@]}"; do
            ((total_update += count))
        done
    fi
    if [[ ${#stats_exists_count[@]} -gt 0 ]]; then
        for count in "${stats_exists_count[@]}"; do
            ((total_exists += count))
        done
    fi
    
    # Collect all unique repo names and sort them
    local all_repos=()
    
    # Only iterate over arrays that have content
    if [[ ${#stats_new_count[@]} -gt 0 ]]; then
        for repo in "${!stats_new_count[@]}"; do
            # Skip empty or invalid repository names
            if [[ -n "$repo" && "$repo" != "getPackage" ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_update_count[@]} -gt 0 ]]; then
        for repo in "${!stats_update_count[@]}"; do
            # Skip empty or invalid repository names and duplicates
            if [[ -n "$repo" && "$repo" != "getPackage" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_exists_count[@]} -gt 0 ]]; then
        for repo in "${!stats_exists_count[@]}"; do
            # Skip empty or invalid repository names and duplicates
            if [[ -n "$repo" && "$repo" != "getPackage" && ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    
    # Sort repositories alphabetically
    mapfile -t all_repos < <(printf '%s\n' "${all_repos[@]}" | sort)
    
    # Print summary table
    echo
    log "I" "Package Processing Summary:"
    echo
    draw_table_border_flex "top"
    draw_table_header_flex
    draw_table_border_flex "middle"
    
    for repo in "${all_repos[@]}"; do
        # Additional safety check - skip empty repo names in summary
        if [[ -z "$repo" || "$repo" == "getPackage" ]]; then
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Skipping invalid repository name in summary: '$repo'"
            continue
        fi
        
        local new_count="${stats_new_count[$repo]:-0}"
        local update_count="${stats_update_count[$repo]:-0}"
        local exists_count="${stats_exists_count[$repo]:-0}"
        local status="Disabled"
        
        # Check if repository is enabled
        if is_repo_enabled "$repo"; then
            status="Active"
        fi
        
        # Only draw row if there's any activity for this repo
        if [[ $new_count -gt 0 || $update_count -gt 0 || $exists_count -gt 0 ]]; then
            draw_table_row_flex "$repo" "$new_count" "$update_count" "$exists_count" "$status"
        fi
    done
    
    draw_table_border_flex "middle"
    draw_table_row_flex "TOTAL" "$total_new" "$total_update" "$total_exists" "Summary"
    draw_table_border_flex "bottom"
}
# Helper function to get the correct DNF command (automatically detects elevation need)
function get_dnf_cmd() {
    # Auto-detect: check multiple ways to determine if we already have elevated privileges  
    # 1. Check if running as root (EUID=0)
    # 2. Check if already running under sudo (SUDO_USER is set)
    # 3. Check if we can write to root-only locations without sudo
    
    if [[ $EUID -eq 0 ]] || [[ -n "$SUDO_USER" ]] || [[ -w /root ]]; then
        # We already have elevated privileges, use dnf directly
        echo "dnf"
    elif [[ ${ELEVATE_COMMANDS:-1} -eq 1 ]]; then
        # We need sudo elevation - return space-separated command for unquoted expansion
        echo "sudo dnf"
    else
        # Manual override: no sudo
        echo "dnf"
    fi
}

# Simple but accurate package status determination - this is the critical function!
function get_package_status() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local package_arch="$4"
    local repo_path="$5"
    
    # Build expected filename patterns
    local exact_filename="${package_name}-${package_version}-${package_release}.${package_arch}.rpm"
    local name_arch_pattern="${package_name}-*-*.${package_arch}.rpm"
    
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Checking status for $exact_filename in $repo_path"
    
    # Ensure repo path exists - if not, it's definitely NEW
    if [[ ! -d "$repo_path" ]]; then
        [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Repository directory doesn't exist: $repo_path -> NEW"
        echo "NEW"
        return 0
    fi
    
    # Check for exact match first (EXISTS)
    if [[ -f "$repo_path/$exact_filename" ]]; then
        [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Found exact match: $exact_filename -> EXISTS"
        echo "EXISTS"
        return 0
    fi
    
    # Check for same package name/arch but different version (UPDATE needed)
    local existing_files
    existing_files=$(find "$repo_path" -maxdepth 1 -name "$name_arch_pattern" -type f 2>/dev/null)
    
    if [[ -n "$existing_files" ]]; then
        # Found same package with different version - need UPDATE
        local existing_count
        existing_count=$(echo "$existing_files" | wc -l)
        [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Found $existing_count existing version(s) of $package_name -> UPDATE"
        [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Example existing file: $(echo "$existing_files" | head -1 | xargs basename)"
        echo "UPDATE"
        return 0
    fi
    
    # Debug: Show what files ARE in the repository
    if [[ $DEBUG_LEVEL -ge 3 ]]; then
        local total_rpms
        total_rpms=$(find "$repo_path" -name "*.rpm" -type f 2>/dev/null | wc -l)
        log "D" "Repository $repo_path contains $total_rpms total RPM files"
        if [[ $total_rpms -gt 0 && $total_rpms -lt $DEBUG_FILE_LIST_THRESHOLD ]]; then
            log "D" "Files in repository: $(find "$repo_path" -name "*.rpm" -type f -print0 2>/dev/null | xargs -0 basename | head -"$DEBUG_FILE_LIST_COUNT")"
        fi
    fi
    
    # No existing package found - this is NEW
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "No existing package found for $package_name -> NEW"
    echo "NEW"
    return 0
}

# Get repository path for a repository name
function get_repo_path() {
    local repo_name="$1"
    
    # Validate repository name to prevent creating getPackage directly under LOCAL_REPO_PATH
    if [[ -z "$repo_name" || "$repo_name" == "getPackage" ]]; then
        log "E" "Invalid repository name: '$repo_name' - this would create getPackage directly under $LOCAL_REPO_PATH"
        return 1
    fi
    
    # All repositories use getPackage subdirectory (both regular and manual)
    echo "$LOCAL_REPO_PATH/$repo_name/getPackage"
    return 0
}

# Check if repository is enabled (to exclude disabled repos from sync)
function is_repo_enabled() {
    local repo_name="$1"
    
    # Check if repo is in enabled list
    local enabled_repos
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    enabled_repos=$(${dnf_cmd} repolist --enabled --quiet | awk 'NR>1 {print $1}' | grep -v "^$")
    
    while IFS= read -r enabled_repo; do
        if [[ "$repo_name" == "$enabled_repo" ]]; then
            return 0  # Repository is enabled
        fi
    done <<< "$enabled_repos"
    
    return 1  # Repository is not enabled
}

# Load configuration from myrepo.cfg if it exists - optimized version
function load_config() {
    local config_file="myrepo.cfg"
    
    if [[ -f "$config_file" ]]; then
        log "I" "Loading configuration from $config_file"
        
        # Use a more efficient method to read config
        local line_count=0
        while IFS='=' read -r key value || [[ -n "$key" ]]; do
            ((line_count++))
            # Skip comments and empty lines
            [[ "$key" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$key" ]] && continue
            
            # Remove leading/trailing whitespace and quotes - more efficiently
            key="${key// /}"
            value="${value#"${value%%[![:space:]]*}"}"  # Remove leading whitespace
            value="${value%"${value##*[![:space:]]}"}"  # Remove trailing whitespace
            value="${value#\"}"  # Remove leading quote
            value="${value%\"}"  # Remove trailing quote
            
            # Set configuration variables
            case "$key" in
                LOCAL_REPO_PATH) LOCAL_REPO_PATH="$value" ;;
                SHARED_REPO_PATH) SHARED_REPO_PATH="$value" ;;
                MANUAL_REPOS) 
                    # Convert comma-separated list to array
                    IFS=',' read -ra MANUAL_REPOS <<< "$value"
                    ;;
                LOCAL_RPM_SOURCES)
                    # Convert comma-separated list to array
                    IFS=',' read -ra LOCAL_RPM_SOURCES <<< "$value"
                    ;;
                DEBUG_LEVEL) DEBUG_LEVEL="$value" ;;
                DRY_RUN) DRY_RUN="$value" ;;
                MAX_PACKAGES) MAX_PACKAGES="$value" ;;
                MAX_NEW_PACKAGES) MAX_NEW_PACKAGES="$value" ;;
                PARALLEL) PARALLEL="$value" ;;
                EXCLUDED_REPOS) EXCLUDE_REPOS="$value" ;;
                FULL_REBUILD) FULL_REBUILD="$value" ;;
                LOG_DIR) LOG_DIR="$value" ;;
                SET_PERMISSIONS) SET_PERMISSIONS="$value" ;;
                REFRESH_METADATA) REFRESH_METADATA="$value" ;;
                DNF_SERIAL) DNF_SERIAL="$value" ;;
                ELEVATE_COMMANDS) ELEVATE_COMMANDS="$value" ;;
                CACHE_MAX_AGE) CACHE_MAX_AGE="$value" ;;
                SHARED_CACHE_PATH) SHARED_CACHE_PATH="$value" ;;
                CLEANUP_UNINSTALLED) CLEANUP_UNINSTALLED="$value" ;;
                USE_PARALLEL_COMPRESSION) USE_PARALLEL_COMPRESSION="$value" ;;
                DNF_QUERY_TIMEOUT) DNF_QUERY_TIMEOUT="$value" ;;
                DNF_CACHE_TIMEOUT) DNF_CACHE_TIMEOUT="$value" ;;
                SUDO_TEST_TIMEOUT) SUDO_TEST_TIMEOUT="$value" ;;
                BATCH_SIZE) BATCH_SIZE="$value" ;;
                PROGRESS_REPORT_INTERVAL) PROGRESS_REPORT_INTERVAL="$value" ;;
                CONFIG_FILE_MAX_LINES) CONFIG_FILE_MAX_LINES="$value" ;;
                MAX_PARALLEL_DOWNLOADS) MAX_PARALLEL_DOWNLOADS="$value" ;;
                DNF_RETRIES) DNF_RETRIES="$value" ;;
                DEBUG_FILE_LIST_THRESHOLD) DEBUG_FILE_LIST_THRESHOLD="$value" ;;
                DEBUG_FILE_LIST_COUNT) DEBUG_FILE_LIST_COUNT="$value" ;;
            esac
            
            # Limit config file reading to prevent hanging on large files
            if [[ $line_count -gt $CONFIG_FILE_MAX_LINES ]]; then
                log "W" "Config file too large, stopping at line $line_count"
                break
            fi
        done < "$config_file"
        
        log "I" "Configuration loaded: LOCAL_REPO_PATH=$LOCAL_REPO_PATH"
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "MANUAL_REPOS: ${MANUAL_REPOS[*]}"
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "LOCAL_RPM_SOURCES: ${LOCAL_RPM_SOURCES[*]}"
    else
        log "I" "No configuration file found, using defaults"
    fi
    
    # Set up default LOCAL_RPM_SOURCES if not configured
    if [[ ${#LOCAL_RPM_SOURCES[@]} -eq 0 ]]; then
        LOCAL_RPM_SOURCES=(
            "$HOME/rpmbuild/RPMS"
            "/var/cache/dnf"
            "/var/cache/yum"
            "/tmp"
        )
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Using default LOCAL_RPM_SOURCES: ${LOCAL_RPM_SOURCES[*]}"
    fi
}

# Locate local RPM files from configured sources
function locate_local_rpm() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local package_arch="$4"
    
    local target_filename="${package_name}-${package_version}-${package_release}.${package_arch}.rpm"
    
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Searching for local RPM: $target_filename"
    
    # Search in configured LOCAL_RPM_SOURCES directories
    for search_path in "${LOCAL_RPM_SOURCES[@]}"; do
        if [[ -d "$search_path" ]]; then
            [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "   Checking: $search_path"
            
            # Search recursively to find RPMs in subdirectories (like x86_64/, noarch/, etc.)
            local rpm_path
            rpm_path=$(find "$search_path" -type f -name "$target_filename" 2>/dev/null | head -n 1)
            
            if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Found local RPM: $rpm_path"
                echo "$rpm_path"
                return 0
            fi
        else
            [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "   Source directory not found: $search_path"
        fi
    done
    
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "No local RPM found for: $target_filename"
    return 1
}

# Simple logging function with colors
function log() {
    local level="$1"
    local message="$2"
    local color=""
    
    case "$level" in
        "E") color="\e[31m" ;;  # Red for errors
        "W") color="\e[33m" ;;  # Yellow for warnings  
        "I") color="\e[32m" ;;  # Green for info
        "D") color="\e[36m" ;;  # Cyan for debug
    esac
    
    # Send log output to stderr to avoid contaminating function return values
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message\e[0m" >&2
}

# Parse command-line arguments (like original script)
function parse_args() {
    [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "parse_args called with $# arguments: $*"
    
    # Parse command-line options (overrides config file and defaults)
    while [[ $# -gt 0 ]]; do
        case $1 in
            --batch-size)
                BATCH_SIZE="$2"
                shift 2
                ;;
            --cache-max-age)
                CACHE_MAX_AGE="$2"
                shift 2
                ;;
            --shared-cache-path)
                SHARED_CACHE_PATH="$2"
                shift 2
                ;;
            --cleanup-uninstalled)
                CLEANUP_UNINSTALLED=1
                shift
                ;;
            --no-cleanup-uninstalled)
                CLEANUP_UNINSTALLED=0
                shift
                ;;
            --parallel-compression)
                USE_PARALLEL_COMPRESSION=1
                shift
                ;;
            --no-parallel-compression)
                USE_PARALLEL_COMPRESSION=0
                shift
                ;;
            --debug)
                # If next argument starts with --, assume no value provided (use default level 2)
                if [[ -n "$2" && "$2" != --* ]]; then
                    DEBUG_LEVEL="$2"
                    shift 2
                else
                    DEBUG_LEVEL=2  # Default debug level when --debug is used without value
                    shift
                fi
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            --exclude-repos)
                EXCLUDE_REPOS="$2"
                shift 2
                ;;
            --full-rebuild)
                FULL_REBUILD=1
                shift
                ;;
            --local-repo-path)
                LOCAL_REPO_PATH="$2"
                shift 2
                ;;
            --log-dir)
                LOG_DIR="$2"
                shift 2
                ;;
            --manual-repos)
                # Convert comma-separated list to array
                IFS=',' read -ra MANUAL_REPOS <<< "$2"
                shift 2
                ;;
            --max-packages)
                MAX_PACKAGES="$2"
                shift 2
                ;;
            --max-new-packages)
                MAX_NEW_PACKAGES="$2"
                shift 2
                ;;
            --name-filter)
                NAME_FILTER="$2"
                shift 2
                ;;
            --parallel)
                PARALLEL="$2"
                shift 2
                ;;
            --repos)
                REPOS="$2"
                shift 2
                ;;
            --refresh-metadata)
                REFRESH_METADATA=1
                shift
                ;;
            --set-permissions)
                SET_PERMISSIONS=1
                shift
                ;;
            --shared-repo-path)
                SHARED_REPO_PATH="$2"
                shift 2
                ;;
            -s|--sync-only)
                SYNC_ONLY=1
                shift
                ;;
            --dnf-serial)
                DNF_SERIAL=1
                shift
                ;;
            -v|--verbose)
                DEBUG_LEVEL=2
                shift
                ;;
            -h|--help)
                echo "Usage: $0 [options]"
                echo "Options:"
                echo "  --batch-size INT       Batch size for processing RPMs (default: $BATCH_SIZE)"
                echo "  --cache-max-age SEC    Cache validity in seconds (default: $CACHE_MAX_AGE = 4h)"
                echo "  --shared-cache-path PATH Shared cache directory path (default: $SHARED_CACHE_PATH)"
                echo "  --cleanup-uninstalled  Enable cleanup of uninstalled packages (default: enabled)"
                echo "  --no-cleanup-uninstalled Disable cleanup of uninstalled packages"
                echo "  --parallel-compression Enable parallel compression for createrepo (default: enabled)"
                echo "  --no-parallel-compression Disable parallel compression"
                echo "  --debug LEVEL          Debug level 1-3 (default: $DEBUG_LEVEL)"
                echo "  --dry-run              Show what would be done without making changes"
                echo "  --exclude-repos LIST   Comma-separated list of repositories to exclude"
                echo "  --full-rebuild         Remove all packages first, then rebuild"
                echo "  --local-repo-path PATH Local repository path (default: $LOCAL_REPO_PATH)"
                echo "  --log-dir PATH         Log directory (default: $LOG_DIR)"
                echo "  --manual-repos LIST    Comma-separated list of manual repositories"
                echo "  --max-packages INT     Maximum packages to process total (includes existing, new, and updates - 0=unlimited)"
                echo "  --max-new-packages INT Maximum new packages to download only (limits [N] packages - 0=none, -1=unlimited)"
                echo "  --name-filter REGEX    Process only packages matching regex"
                echo "  --parallel INT         Number of parallel operations (default: $PARALLEL)"
                echo "  --repos LIST           Process only specified repositories"
                echo "  --refresh-metadata     Force refresh of DNF metadata cache"
                echo "  --set-permissions      Auto-fix file permissions"
                echo "  --shared-repo-path PATH Shared repository path (default: $SHARED_REPO_PATH)"
                echo "  -s, --sync-only        Only sync repositories to shared location"
                echo "  --dnf-serial           Force serial DNF operations"
                echo "  -v, --verbose          Enable verbose output (debug level 2)"
                echo "  -h, --help             Show this help message"
                echo ""
                echo "Local RPM Sources:"
                echo "  The script can use locally available RPM files before attempting downloads."
                echo "  Configure LOCAL_RPM_SOURCES in myrepo.cfg to include directories like:"
                echo "  - ~/rpmbuild/RPMS (your local builds)"
                echo "  - /var/cache/dnf (DNF cached packages)"
                echo "  - Custom build directories"
                echo "  This helps avoid downloading packages you already have locally (like zstd)."
                echo ""
                echo "Shared Cache:"
                echo "  The script uses a shared cache directory to avoid rebuilding cache when switching"
                echo "  between user and root modes. The default location is $SHARED_CACHE_PATH."
                echo "  - Permissions are automatically set for both root and user access"
                echo "  - Fallback locations are used if shared cache is not accessible"
                echo "  - Configure with SHARED_CACHE_PATH in myrepo.cfg or --shared-cache-path option"
                echo ""
                echo "Automatic Privilege Detection:"
                echo "  The script automatically detects if it's running as root (EUID=0) or as a regular user."
                echo "  - When running as root: Uses 'dnf' directly (no sudo needed)"
                echo "  - When running as user: Uses 'sudo dnf' automatically"
                echo "  - Override via config: Set ELEVATE_COMMANDS=0 in myrepo.cfg to disable auto-sudo"
                echo ""
                echo "Examples:"
                echo "  $0                     # Run as user (auto-detects and uses sudo dnf)"
                echo "  sudo $0                # Run as root (auto-detects and uses dnf directly)"
                echo "  $0 --dry-run --verbose # Preview changes with detailed output"
                exit 0
                ;;
            *)
                log "E" "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Simple package processing with efficient batch downloading
function process_packages() {
    local total_packages=0
    local processed_packages=0
    local new_count=0
    local update_count=0
    local exists_count=0
    local new_packages_found=0
    
    # Arrays to collect packages for batch downloading
    local new_packages=()
    local update_packages=()
    
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    echo -e "\e[32m🚀 MyRepo v$VERSION - Starting package processing...\e[0m"
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    
    # PERFORMANCE OPTIMIZATION 5: Load repository performance cache
    log "I" "⚡ Loading repository performance cache for intelligent prioritization..."
    load_repo_performance_cache
    
    # PERFORMANCE OPTIMIZATION: Cache enabled repositories once at start
    log "I" "📋 Building enabled repositories cache for performance..."
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    local enabled_repos_list
    # shellcheck disable=SC2086 # Intentional word splitting for dnf command
    if ! enabled_repos_list=$(${dnf_cmd} repolist --enabled --quiet | awk 'NR>1 {print $1}' | grep -v "^$"); then
        log "E" "Failed to get enabled repositories list for caching"
        return 1
    fi
    
    # Create associative array for O(1) repository enabled lookups
    declare -A enabled_repos_cache
    local cached_repo_count=0
    while IFS= read -r repo; do
        enabled_repos_cache["$repo"]=1
        ((cached_repo_count++))
    done <<< "$enabled_repos_list"
    
    log "I" "✓ Cached $cached_repo_count enabled repositories for fast lookup"
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Enabled repos: $(echo "$enabled_repos_list" | tr '\n' ' ')"

    # Show legend for status markers
    echo -e "\e[36m📋 Package Status Legend: \e[33m[N] New\e[0m, \e[36m[U] Update\e[0m, \e[32m[E] Exists\e[0m"
    echo

    # Get installed packages using dnf (like original script) - this includes repo info!
    echo -e "\e[33m📦 Getting list of installed packages with repository information...\e[0m"
    local package_list
    local dnf_cmd
    dnf_cmd=$(get_dnf_cmd)
    
    # Use the original script's efficient method with timeout
    if [[ -n "$NAME_FILTER" ]]; then
        # Get all packages first, then filter by package name (first field before |)
        # shellcheck disable=SC2086 # Intentional word splitting for dnf command
        package_list=$(timeout "$DNF_QUERY_TIMEOUT" ${dnf_cmd} repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{ui_from_repo}" 2>/dev/null | while IFS='|' read -r name rest; do
            if [[ "$name" =~ $NAME_FILTER ]]; then
                echo "$name|$rest"
            fi
        done)
    else
        # shellcheck disable=SC2086
        package_list=$(timeout "$DNF_QUERY_TIMEOUT" ${dnf_cmd} repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{ui_from_repo}" 2>/dev/null)
    fi
    
    if [[ -z "$package_list" ]]; then
        log "E" "Failed to get installed packages list"
        return 1
    fi
    
    # Count total packages
    total_packages=$(echo "$package_list" | wc -l)
    echo -e "\e[32m✓ Found $total_packages installed packages\e[0m"
    echo
    
    # PERFORMANCE OPTIMIZATION 4: Smart Package Filtering and Deduplication
    log "I" "🔍 Applying smart package filtering and deduplication..."
    local filter_start_time
    filter_start_time=$(date +%s)
    
    # Pre-filter the package list for optimal processing
    local filtered_packages
    local duplicates_removed=0
    local invalid_skipped=0
    local filtered_count=0
    
    # Create temporary files for processing
    local temp_raw
    local temp_filtered
    local temp_sorted
    temp_raw=$(mktemp)
    temp_filtered=$(mktemp)
    temp_sorted=$(mktemp)
    
    # Write package list to temp file for processing
    echo "$package_list" > "$temp_raw"
    
    # Step 1: Remove packages with invalid/problematic repository names
    while IFS='|' read -r package_name epoch package_version package_release package_arch repo_name; do
        # Skip invalid repository names early
        if [[ "$repo_name" == "@commandline" || "$repo_name" == "Invalid" || -z "$repo_name" || "$repo_name" == "getPackage" ]]; then
            ((invalid_skipped++))
            [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Skipped invalid repo: $package_name ($repo_name)"
            continue
        fi
        
        # Normalize epoch for consistent processing
        [[ "$epoch" == "(none)" || -z "$epoch" ]] && epoch="0"
        
        echo "${package_name}|${epoch}|${package_version}|${package_release}|${package_arch}|${repo_name}" >> "$temp_filtered"
        ((filtered_count++))
    done < "$temp_raw"
    
    # Step 2: Sort packages for optimal processing order (by repo, then name, then version)
    # This groups packages by repository for better batch processing efficiency
    sort -t'|' -k6,6 -k1,1 -k3,3V "$temp_filtered" > "$temp_sorted"
    
    # Step 3: Remove exact duplicates (same package-version-arch combination)
    local temp_deduped
    temp_deduped=$(mktemp)
    local previous_line=""
    
    while IFS= read -r line; do
        if [[ "$line" != "$previous_line" ]]; then
            echo "$line" >> "$temp_deduped"
            previous_line="$line"
        else
            ((duplicates_removed++))
            [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Removed duplicate: $line"
        fi
    done < "$temp_sorted"
    
    # Step 4: Apply name filter if specified (do this after deduplication for efficiency)
    if [[ -n "$NAME_FILTER" ]]; then
        local temp_name_filtered
        temp_name_filtered=$(mktemp)
        local name_filtered_count=0
        
        while IFS='|' read -r package_name epoch package_version package_release package_arch repo_name; do
            if [[ "$package_name" =~ $NAME_FILTER ]]; then
                echo "${package_name}|${epoch}|${package_version}|${package_release}|${package_arch}|${repo_name}" >> "$temp_name_filtered"
                ((name_filtered_count++))
            fi
        done < "$temp_deduped"
        
        # Use name-filtered list
        filtered_packages=$(cat "$temp_name_filtered")
        rm -f "$temp_name_filtered"
        log "I" "📝 Applied name filter '$NAME_FILTER': $name_filtered_count packages match"
    else
        # Use deduplicated list
        filtered_packages=$(cat "$temp_deduped")
    fi
    
    # Clean up temporary files
    rm -f "$temp_raw" "$temp_filtered" "$temp_sorted" "$temp_deduped"
    
    # Update counts and show optimization results
    local final_count
    final_count=$(echo "$filtered_packages" | wc -l)
    local filter_end_time
    local filter_duration
    filter_end_time=$(date +%s)
    filter_duration=$((filter_end_time - filter_start_time))
    
    local packages_saved=$((total_packages - final_count))
    
    log "I" "✅ Smart filtering completed in ${filter_duration}s:"
    [[ $invalid_skipped -gt 0 ]] && log "I" "   📋 Skipped $invalid_skipped packages with invalid repositories"
    [[ $duplicates_removed -gt 0 ]] && log "I" "   🔄 Removed $duplicates_removed duplicate packages"
    if [[ $packages_saved -gt 0 ]]; then
        local efficiency_gain
        efficiency_gain=$(awk "BEGIN {printf \"%.1f\", ($packages_saved * 100.0) / $total_packages}")
        log "I" "   ⚡ Processing efficiency improved by ${efficiency_gain}% ($packages_saved fewer packages to process)"
    fi
    log "I" "   📦 Processing $final_count optimized packages"
    
    # Show repository performance status summary
    local fast_repos=0
    local cached_repos=0
    for repo_name in $(printf '%s\n' "$filtered_packages" | cut -d'|' -f6 | sort -u); do
        [[ -z "$repo_name" ]] && continue
        if [[ -n "${repo_download_speeds[$repo_name]}" ]]; then
            ((cached_repos++))
            local speed="${repo_download_speeds[$repo_name]}"
            if [[ $speed -gt $MIN_DOWNLOAD_RATE ]]; then
                ((fast_repos++))
            fi
        fi
    done
    
    if [[ $cached_repos -gt 0 ]]; then
        log "I" "⚡ Repository performance data: $cached_repos repositories cached, $fast_repos classified as fast"
    else
        log "I" "⚡ No cached repository performance data - will establish baseline during downloads"
    fi

    # Update total packages count for accurate progress reporting
    total_packages=$final_count
    
    # PERFORMANCE OPTIMIZATION 2: Pre-create all repository directories upfront
    log "I" "📁 Pre-creating repository directories for performance..."
    local created_dirs=0
    local unique_repos
    unique_repos=$(printf '%s\n' "$filtered_packages" | cut -d'|' -f6 | sort -u)
    
    while IFS= read -r repo_name; do
        [[ -z "$repo_name" ]] && continue
        local repo_path
        repo_path=$(get_repo_path "$repo_name")
        
        # Skip invalid repository paths
        if [[ -z "$repo_path" || "$repo_path" == "$LOCAL_REPO_PATH/getPackage" ]]; then
            continue
        fi
        
        # Create directory if it doesn't exist
        if [[ ! -d "$repo_path" ]]; then
            if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                if sudo mkdir -p "$repo_path" 2>/dev/null; then
                    sudo chown "$USER:$USER" "$repo_path" 2>/dev/null || true
                    sudo chmod 755 "$repo_path" 2>/dev/null || true
                    ((created_dirs++))
                fi
            else
                if mkdir -p "$repo_path" 2>/dev/null; then
                    ((created_dirs++))
                fi
            fi
        fi
    done <<< "$unique_repos"
    
    log "I" "✓ Pre-created $created_dirs repository directories"

    # Start processing
    local start_time
    start_time=$(date +%s)
    
    while IFS='|' read -r package_name epoch package_version package_release package_arch repo_name; do
        # Skip if we've hit the package limit
        if [[ $MAX_PACKAGES -gt 0 && $processed_packages -gt $MAX_PACKAGES ]]; then
            echo -e "\e[33m🔢 Reached package limit ($MAX_PACKAGES), stopping\e[0m"
            break
        fi
        
        # Apply name filter (already filtered by dnf query, but double-check)
        if ! should_process_package "$package_name"; then
            continue
        fi
        
        # Apply repository filters
        if ! should_process_repo "$repo_name"; then
            continue
        fi
        
        # Only increment processed_packages AFTER all filtering is done
        ((processed_packages++))
        
        # Progress reporting every N packages (OPTIMIZATION 3: Improved progress with ETA)
        if (( processed_packages % PROGRESS_REPORT_INTERVAL == 0 )); then
            local elapsed=$(($(date +%s) - start_time))
            local rate_display=""
            local eta_display=""
            
            if [[ $elapsed -gt 0 ]]; then
                # Use awk for decimal precision in rate calculation
                local rate_decimal
                rate_decimal=$(awk "BEGIN {printf \"%.1f\", $processed_packages / $elapsed}")
                if (( $(awk "BEGIN {print ($processed_packages / $elapsed >= 1)}") )); then
                    rate_display="${rate_decimal} pkg/sec"
                else
                    # Show seconds per package when rate is less than 1 pkg/sec
                    local sec_per_pkg
                    sec_per_pkg=$(awk "BEGIN {printf \"%.1f\", $elapsed / $processed_packages}")
                    rate_display="${sec_per_pkg} sec/pkg"
                fi
                
                # Calculate ETA for remaining packages
                local remaining_packages=$((total_packages - processed_packages))
                if [[ $remaining_packages -gt 0 ]]; then
                    local eta_seconds
                    eta_seconds=$(awk "BEGIN {printf \"%.0f\", $remaining_packages / ($processed_packages / $elapsed)}")
                    if [[ $eta_seconds -gt 60 ]]; then
                        local eta_minutes=$((eta_seconds / 60))
                        eta_display=" - ETA: ${eta_minutes}m"
                    else
                        eta_display=" - ETA: ${eta_seconds}s"
                    fi
                fi
            else
                rate_display="calculating..."
            fi
            
            # Show processing statistics
            local progress_percent
            progress_percent=$(awk "BEGIN {printf \"%.1f\", ($processed_packages * 100) / $total_packages}")
            echo -e "\e[36m⏱️  Progress: $processed_packages/$total_packages packages (${progress_percent}% - $rate_display$eta_display)\e[0m"
            echo -e "\e[36m   📊 Stats: \e[33m$new_count new\e[0m, \e[36m$update_count updates\e[0m, \e[32m$exists_count existing\e[0m"
        fi
        
        # Normalize epoch
        [[ "$epoch" == "(none)" || -z "$epoch" ]] && epoch="0"
        
        # Determine actual repository for @System packages (like original script)
        if [[ "$repo_name" == "System" || "$repo_name" == "@System" || "$repo_name" == "@commandline" ]]; then
            local original_repo_name="$repo_name"
            repo_name=$(determine_repo_source "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch")
            [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[37m   $original_repo_name → $repo_name: $package_name\e[0m"
            
            # If package not found in enabled repos, try to determine from installed package
            if [[ "$repo_name" == "Invalid" ]]; then
                # First, try to determine repo from installed package info
                local discovered_repo
                discovered_repo=$(determine_repo_from_installed "$package_name" "$package_version" "$package_release" "$package_arch")
                
                if [[ -n "$discovered_repo" ]]; then
                    [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[93m   Found via installed package: $package_name ($discovered_repo - will enable for download)\e[0m"
                    repo_name="$discovered_repo"
                else
                    # Fallback to guessing based on package name patterns
                    local found_repo=""
                    case "$package_name" in
                        *SFCGAL*|*sfcgal*)
                            # SFCGAL is typically in developer/EPEL repos
                            for repo in "ol9_developer_EPEL" "ol9_developer" "ol9_oraclelinux_developer_EPEL"; do
                                if [[ " ${REPOSITORIES[*]} " == *" $repo "* ]]; then
                                    found_repo="$repo"
                                    break
                                fi
                            done
                            ;;
                        *)
                            # Try to guess the most likely disabled repository
                            for repo in "${REPOSITORIES[@]}"; do
                                if [[ ${enabled_repos_cache["$repo"]} != 1 ]]; then
                                    found_repo="$repo"
                                    break
                                fi
                            done
                            ;;
                    esac
                    
                    if [[ -n "$found_repo" ]]; then
                        [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[93m   Guessing repo: $package_name ($found_repo disabled, attempting download anyway)\e[0m"
                        repo_name="$found_repo"
                    else
                        [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[90m   Skipping unavailable: $package_name (not found in any repository)\e[0m"
                        continue
                    fi
                fi
            fi
        else
            # For non-@System repositories, check if repository is enabled
            local clean_repo_name="${repo_name#@}"  # Remove @ prefix if present
            
            if [[ ${enabled_repos_cache["$clean_repo_name"]} != 1 ]]; then
                [[ $DEBUG_LEVEL -ge 3 ]] && echo -e "\e[90m   Skipping disabled: $package_name ($clean_repo_name disabled)\e[0m"
                continue
            fi
            
            repo_name="$clean_repo_name"
        fi
        
        # Skip invalid packages (like original script)
        if [[ "$repo_name" == "@commandline" || "$repo_name" == "Invalid" ]]; then
            [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[90m   Skipping invalid package: $package_name ($repo_name)\e[0m"
            continue
        fi
        
        # Additional validation to prevent empty repo names that could cause getPackage under LOCAL_REPO_PATH
        if [[ -z "$repo_name" || "$repo_name" == "getPackage" ]]; then
            [[ $DEBUG_LEVEL -ge 2 ]] && log "W" "Invalid repository name detected for package $package_name: '$repo_name' - skipping"
            continue
        fi
        
        # Ensure repository directory exists for each package
        local repo_path
        repo_path=$(get_repo_path "$repo_name")
        
        # Additional safety check - ensure repo_path is valid
        if [[ -z "$repo_path" || "$repo_path" == "$LOCAL_REPO_PATH/getPackage" ]]; then
            [[ $DEBUG_LEVEL -ge 1 ]] && log "W" "Invalid repository path generated for $package_name: '$repo_path' - skipping"
            continue
        fi
        
        # Directory is already pre-created - no need to create it here
        
        # Get package status using simple, reliable method
        local status
        status=$(get_package_status "$package_name" "$package_version" "$package_release" "$package_arch" "$repo_path")
        
        # Handle based on status with colorful, aligned reporting
        case "$status" in
            "EXISTS")
                ((exists_count++))
                # Validate repo_name before using as array key
                if [[ -n "$repo_name" && "$repo_name" != "getPackage" ]]; then
                    ((stats_exists_count["$repo_name"]++))
                fi
                [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[32m$(align_repo_name "$repo_name"): [E] $package_name-$package_version-$package_release.$package_arch\e[0m"
                ;;
            "UPDATE")
                ((update_count++))
                # Validate repo_name before using as array key
                if [[ -n "$repo_name" && "$repo_name" != "getPackage" ]]; then
                    ((stats_update_count["$repo_name"]++))
                fi
                echo -e "\e[36m$(align_repo_name "$repo_name"): [U] $package_name-$package_version-$package_release.$package_arch\e[0m"
                
                if [[ $DRY_RUN -eq 0 ]]; then
                    # Try to find local RPM first
                    local rpm_path
                    rpm_path=$(locate_local_rpm "$package_name" "$package_version" "$package_release" "$package_arch")
                    
                    if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
                        # Found local copy of the updated package - use it instead of downloading
                        [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[36m   📋 Using local RPM for update: $(basename "$rpm_path")\e[0m"
                        [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[37m   Source: $rpm_path\e[0m"
                        
                        # Remove old version(s) first
                        local old_packages
                        old_packages=$(find "$repo_path" -maxdepth 1 -name "${package_name}-*-*.${package_arch}.rpm" -type f 2>/dev/null)
                        if [[ -n "$old_packages" ]]; then
                            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Removing old versions of $package_name from $repo_name"
                            if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                                echo "$old_packages" | xargs sudo rm -f 2>/dev/null
                            else
                                echo "$old_packages" | xargs rm -f 2>/dev/null
                            fi
                        fi
                        
                        # Copy the local RPM to the repository
                        if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                            if sudo cp "$rpm_path" "$repo_path/"; then
                                [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[32m   ✓ Updated from local source\e[0m"
                            else
                                echo -e "\e[31m   ✗ Failed to copy local RPM, will try download\e[0m"
                                update_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                            fi
                        else
                            if cp "$rpm_path" "$repo_path/"; then
                                [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[32m   ✓ Updated from local source\e[0m"
                            else
                                echo -e "\e[31m   ✗ Failed to copy local RPM, will try download\e[0m"
                                update_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                            fi
                        fi
                    else
                        # No local copy found - add to update batch for download
                        update_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                    fi
                fi
                ;;
            "NEW")
                # Check if we've hit the MAX_NEW_PACKAGES limit BEFORE processing
                # NEW LOGIC: 0 = no new packages, -1 = unlimited, >0 = specific limit
                if [[ $DRY_RUN -eq 0 ]]; then
                    if [[ $MAX_NEW_PACKAGES -eq 0 ]]; then
                        # 0 means no new packages allowed
                        [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[90m   Skipping new package (MAX_NEW_PACKAGES=0): $package_name\e[0m"
                        continue
                    elif [[ $MAX_NEW_PACKAGES -gt 0 && $new_packages_found -ge $MAX_NEW_PACKAGES ]]; then
                        # Positive number means specific limit reached
                        echo -e "\e[33m🔢 Reached new packages limit ($MAX_NEW_PACKAGES), stopping\e[0m"
                        break
                    fi
                    # -1 or any negative number means unlimited (no limit check needed)
                fi
                
                # Process the new package
                ((new_count++))
                # Validate repo_name before using as array key
                if [[ -n "$repo_name" && "$repo_name" != "getPackage" ]]; then
                    ((stats_new_count["$repo_name"]++))
                fi
                echo -e "\e[33m$(align_repo_name "$repo_name"): [N] $package_name-$package_version-$package_release.$package_arch\e[0m"
                
                if [[ $DRY_RUN -eq 0 ]]; then
                    ((new_packages_found++))
                    
                    # Try to find local RPM first
                    local rpm_path
                    rpm_path=$(locate_local_rpm "$package_name" "$package_version" "$package_release" "$package_arch")
                    
                    if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
                        # Found local copy - use it instead of downloading
                        [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[36m   📋 Using local RPM: $(basename "$rpm_path")\e[0m"
                        [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[37m   Source: $rpm_path\e[0m"
                        
                        # Copy the local RPM to the repository
                        if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
                            if sudo cp "$rpm_path" "$repo_path/"; then
                                [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[32m   ✓ Copied from local source\e[0m"
                            else
                                echo -e "\e[31m   ✗ Failed to copy local RPM, will try download\e[0m"
                                new_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                            fi
                        else
                            if cp "$rpm_path" "$repo_path/"; then
                                [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[32m   ✓ Copied from local source\e[0m"
                            else
                                echo -e "\e[31m   ✗ Failed to copy local RPM, will try download\e[0m"
                                new_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                            fi
                        fi
                    else
                        # No local copy found - add to new batch for download
                        new_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                    fi
                fi
                ;;
            *)
                echo -e "\e[31m$(align_repo_name "$repo_name"): [?] Unknown status '$status' for $package_name\e[0m"
                ;;
        esac
        
    done <<< "$filtered_packages"
    
    # Second pass: batch download all NEW packages
    if [[ ${#new_packages[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        local total_new_packages=${#new_packages[@]}
        
        # Enhanced progress reporting for large downloads
        if [[ $total_new_packages -gt 100 ]]; then
            log "I" "📥 Batch downloading $total_new_packages new packages..."
            log "I" "🔄 Large download detected - enhanced progress reporting will activate during processing"
            log "I" "� Expect periodic progress updates every 30 seconds during large batch operations"
        else
            log "I" "�📥 Batch downloading $total_new_packages new packages..."
        fi
        
        local batch_start_time
        local batch_end_time
        local batch_duration
        batch_start_time=$(date +%s)
        # Use here-document to avoid subshell issue with pipeline
        batch_download_packages <<< "$(printf '%s\n' "${new_packages[@]}")"
        batch_end_time=$(date +%s)
        batch_duration=$((batch_end_time - batch_start_time))
        
        if [[ $total_new_packages -gt 100 ]]; then
            log "I" "✅ New packages download completed in ${batch_duration}s ($total_new_packages packages processed)"
        else
            log "I" "✅ New packages download completed in ${batch_duration}s"
        fi
    fi
    
    # Third pass: batch download all UPDATE packages
    if [[ ${#update_packages[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        local total_update_packages=${#update_packages[@]}
        
        # Enhanced progress reporting for large downloads
        if [[ $total_update_packages -gt 100 ]]; then
            log "I" "🔄 Batch downloading $total_update_packages updated packages..."
            log "I" "🔄 Large update batch detected - enhanced progress reporting active"
        else
            log "I" "🔄 Batch downloading $total_update_packages updated packages..."
        fi
        
        local batch_start_time
        local batch_end_time
        local batch_duration
        batch_start_time=$(date +%s)
        # Use here-document to avoid subshell issue with pipeline
        batch_download_packages <<< "$(printf '%s\n' "${update_packages[@]}")"
        batch_end_time=$(date +%s)
        batch_duration=$((batch_end_time - batch_start_time))
        
        if [[ $total_update_packages -gt 100 ]]; then
            log "I" "✅ Updated packages download completed in ${batch_duration}s ($total_update_packages packages processed)"
        else
            log "I" "✅ Updated packages download completed in ${batch_duration}s"
        fi
    fi
    
    # Final statistics with colors
    local elapsed=$(($(date +%s) - start_time))
    local rate_display=""
    if [[ $elapsed -gt 0 ]]; then
        # Use awk for decimal precision in rate calculation
        local rate_decimal
        rate_decimal=$(awk "BEGIN {printf \"%.1f\", $processed_packages / $elapsed}")
        if (( $(awk "BEGIN {print ($processed_packages / $elapsed >= 1)}") )); then
            rate_display="${rate_decimal} pkg/sec"
        else
            # Show seconds per package when rate is less than 1 pkg/sec
            local sec_per_pkg
            sec_per_pkg=$(awk "BEGIN {printf \"%.1f\", $elapsed / $processed_packages}")
            rate_display="${sec_per_pkg} sec/pkg"
        fi
    else
        rate_display="N/A"
    fi
    
    echo
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    echo -e "\e[32m✓ Processing completed in ${elapsed}s\e[0m"
    echo -e "\e[36m  Processed: $processed_packages packages at $rate_display\e[0m"
    echo -e "\e[33m  Results: \e[33m$new_count new [N]\e[0m, \e[36m$update_count updates [U]\e[0m, \e[32m$exists_count existing [E]\e[0m"
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "\e[35m🔍 DRY RUN mode - no actual downloads performed\e[0m"
    fi
    
    # Generate the beautiful summary table
    generate_summary_table
    
    # Clean up uninstalled packages after processing (if enabled)
    if [[ $CLEANUP_UNINSTALLED -eq 1 ]]; then
        cleanup_uninstalled_packages
    else
        log "I" "Cleanup of uninstalled packages disabled"
    fi
    
    # Update repository metadata for all modified repositories
    update_all_repository_metadata
    
    # Update metadata for manual repositories if they have changes
    update_manual_repository_metadata
}

# Report failed downloads at the end of script execution
function report_failed_downloads() {
    # Debug: Show array sizes
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Failed downloads array size: ${#failed_downloads[@]}"
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Failed download reasons array size: ${#failed_download_reasons[@]}"
    
    # Skip if no failures recorded
    if [[ ${#failed_downloads[@]} -eq 0 ]]; then
        log "I" "✅ All package downloads were successful - no failures to report"
        return 0
    fi
    
    echo
    echo -e "\e[31m═══════════════════════════════════════════════════════════════\e[0m"
    echo -e "\e[31m⚠️  FAILED DOWNLOADS REPORT\e[0m"
    echo -e "\e[31m═══════════════════════════════════════════════════════════════\e[0m"
    
    local total_failures=0
    
    # Group failures by repository for better organization
    declare -A repo_failures
    for package_key in "${!failed_downloads[@]}"; do
        local repo_name="${failed_downloads[$package_key]}"
        repo_failures["$repo_name"]+="$package_key "
        ((total_failures++))
    done
    
    # Report failures by repository
    for repo_name in $(printf '%s\n' "${!repo_failures[@]}" | sort); do
        echo -e "\e[33m📦 Repository: $repo_name\e[0m"
        
        # Process each failed package in this repository
        local packages="${repo_failures[$repo_name]}"
        for package_key in $packages; do
            local reason="${failed_download_reasons[$package_key]:-Unknown error}"
            echo -e "\e[31m   ✗ $package_key\e[0m"
            echo -e "\e[37m     Reason: $reason\e[0m"
        done
        echo
    done
    
    echo -e "\e[31m📊 Total failed downloads: $total_failures packages\e[0m"
    echo -e "\e[36m💡 Tip: Check if these packages are available in enabled repositories or if network connectivity is working.\e[0m"
    echo -e "\e[31m═══════════════════════════════════════════════════════════════\e[0m"
}

# Check if package should be processed based on name filter
function should_process_package() {
    local package_name="$1"
    
    # Apply name filter if specified
    if [[ -n "$NAME_FILTER" ]]; then
        if [[ ! "$package_name" =~ $NAME_FILTER ]]; then
            [[ $DEBUG_LEVEL -ge 3 ]] && log "D" "Skipping package (name filter): $package_name"
            return 1
        fi
    fi
    
    return 0
}

# Check if repository should be processed based on filters
function should_process_repo() {
    local repo_name="$1"
    
    # Check if repo is in exclude list
    if [[ -n "$EXCLUDE_REPOS" ]]; then
        IFS=',' read -ra exclude_array <<< "$EXCLUDE_REPOS"
        for excluded in "${exclude_array[@]}"; do
            if [[ "$repo_name" == "$excluded" ]]; then
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Excluding repository: $repo_name"
                return 1
            fi
        done
    fi
    
    # Check if specific repos are requested
    if [[ -n "$REPOS" ]]; then
        IFS=',' read -ra repos_array <<< "$REPOS"
        for requested in "${repos_array[@]}"; do
            if [[ "$repo_name" == "$requested" ]]; then
                return 0
            fi
        done
        # If specific repos requested but this isn't one of them, skip
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Skipping repository (not in --repos list): $repo_name"
        return 1
    fi
    
    # Default: process all repos (except excluded ones)
    return 0
}

# Show runtime status and configuration
function show_runtime_status() {
    log "I" "Starting MyRepo version $VERSION"

    # Handle refresh metadata option
    if [[ $REFRESH_METADATA -eq 1 ]]; then
        log "I" "Refreshing DNF metadata cache..."
        local dnf_cmd
        dnf_cmd=$(get_dnf_cmd)
        # shellcheck disable=SC2086 # Intentional word splitting for dnf command
        ${dnf_cmd} clean metadata >/dev/null 2>&1 || true
        log "I" "DNF metadata cache refreshed"
    fi

    # Show elevation status
    if [[ $EUID -eq 0 ]]; then
        log "I" "Privilege escalation: Running as root (auto-detected)"
    elif [[ $ELEVATE_COMMANDS -eq 1 ]]; then
        log "I" "Privilege escalation: Using sudo for DNF operations (auto-detected)"
    else
        log "I" "Privilege escalation: Disabled - running DNF directly as user"
    fi

    # Show active options
    if [[ $FULL_REBUILD -eq 1 ]]; then
        log "I" "Full rebuild mode enabled - all packages will be removed first"
    fi
    if [[ $SET_PERMISSIONS -eq 1 ]]; then
        log "I" "Permission auto-fix enabled"
    fi
    if [[ $DNF_SERIAL -eq 1 ]]; then
        log "I" "DNF serial mode enabled"
    fi
    if [[ $CLEANUP_UNINSTALLED -eq 1 ]]; then
        log "I" "Cleanup of uninstalled packages enabled"
    else
        log "I" "Cleanup of uninstalled packages disabled"
    fi
    if [[ $USE_PARALLEL_COMPRESSION -eq 1 ]]; then
        log "I" "Parallel compression for metadata updates enabled"
    else
        log "I" "Parallel compression for metadata updates disabled"
    fi

    # Show active filters if any
    if [[ -n "$REPOS" ]]; then
        log "I" "Processing specific repositories: $REPOS"
    fi
    if [[ -n "$EXCLUDE_REPOS" ]]; then
        log "I" "Excluding repositories: $EXCLUDE_REPOS"
    fi
    if [[ -n "$NAME_FILTER" ]]; then
        log "I" "Package name filter: $NAME_FILTER"
    fi
}

# Sync local repositories to shared location (excluding disabled repos)
function sync_to_shared_repos() {
    # Only sync if not in dry run mode and shared repo path exists
    if [[ $DRY_RUN -eq 1 ]]; then
        log "I" "🔍 DRY RUN: Would sync repositories to shared location if enabled"
        return 0
    fi
    
    if [[ ! -d "$SHARED_REPO_PATH" ]]; then
        log "W" "Shared repository path does not exist: $SHARED_REPO_PATH"
        return 1
    fi
    
    log "I" "Syncing repositories to shared location: $SHARED_REPO_PATH"
    log "I" "Note: Disabled repositories will be excluded from sync"
    
    # Sync each repository (but only enabled ones)
    for repo_dir in "$LOCAL_REPO_PATH"/*; do
        if [[ -d "$repo_dir" ]]; then
            local repo_name
            repo_name=$(basename "$repo_dir")
            
            # Skip and warn about invalid getPackage directory directly under LOCAL_REPO_PATH
            if [[ "$repo_name" == "getPackage" ]]; then
                log "W" "Found invalid getPackage directory directly under $LOCAL_REPO_PATH - this is a bug!"
                log "W" "   getPackage should only exist as subdirectories under repository directories"
                log "W" "   Skipping sync for this invalid directory"
                continue
            fi
            
            # Check if this repository should be synced (only enabled repos)
            if ! is_repo_enabled "$repo_name"; then
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Skipping sync for disabled repository: $repo_name"
                echo -e "\e[90m$(align_repo_name "$repo_name"): Skipped (disabled repository)\e[0m"
                continue
            fi
            
            local shared_repo_dir="$SHARED_REPO_PATH/$repo_name"
            
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Syncing $repo_name..."
            
            # Create shared repo directory if it doesn't exist
            mkdir -p "$shared_repo_dir" 2>/dev/null
            
            # Use rsync for efficient sync
            if command -v rsync >/dev/null 2>&1; then
                if [[ $DEBUG_LEVEL -ge 2 ]]; then
                    # Verbose sync for debug mode
                    rsync -av --delete "$repo_dir/" "$shared_repo_dir/"
                else
                    # Quiet sync for normal operation
                    rsync -a --delete "$repo_dir/" "$shared_repo_dir/" >/dev/null 2>&1
                fi
            else
                # Fallback to cp
                cp -r "$repo_dir/"* "$shared_repo_dir/" 2>/dev/null
            fi
            
            echo -e "\e[32m$(align_repo_name "$repo_name"): Synced to shared repository\e[0m"
        fi
    done
    
    log "I" "Repository sync completed (disabled repositories excluded)"
}

# Update metadata for all repositories that had package changes
function update_all_repository_metadata() {
    if [[ $SYNC_ONLY -eq 1 ]]; then
        [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "Sync-only mode: skipping metadata updates"
        return 0
    fi
    
    log "I" "🔄 Updating repository metadata for all modified repositories..."
    
    local updated_repos=0
    local failed_repos=0
    
    # Get list of all repositories that should have metadata updated
    for repo_dir in "$LOCAL_REPO_PATH"/*; do
        if [[ -d "$repo_dir" ]]; then
            local repo_name
            repo_name=$(basename "$repo_dir")
            
            # Skip if this repo should not be processed
            if ! should_process_repo "$repo_name"; then
                continue
            fi
            
            local repo_path
            repo_path=$(get_repo_path "$repo_name")
            
            if [[ -d "$repo_path" ]]; then
                if update_repository_metadata "$repo_name" "$repo_path"; then
                    ((updated_repos++))
                else
                    ((failed_repos++))
                fi
            fi
        fi
    done
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log "I" "🔍 DRY RUN: Would update metadata for $((updated_repos + failed_repos)) repositories"
    else
        log "I" "✅ Metadata update completed: $updated_repos successful, $failed_repos failed"
        if [[ $failed_repos -gt 0 ]]; then
            log "W" "Some repositories failed metadata update - they may not function correctly"
        fi
    fi
}

# Update metadata for manual repositories that may have had manual changes
function update_manual_repository_metadata() {
    if [[ ${#MANUAL_REPOS[@]} -eq 0 ]]; then
        return 0
    fi
    
    log "I" "🔍 Checking manual repositories for metadata updates..."
    
    local updated_manual=0
    
    for manual_repo in "${MANUAL_REPOS[@]}"; do
        local repo_dir="$LOCAL_REPO_PATH/$manual_repo"
        
        if [[ ! -d "$repo_dir" ]]; then
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "$(align_repo_name "$manual_repo"): Manual repository directory not found"
            continue
        fi
        
        # Check if there are RPM files
        local rpm_count
        rpm_count=$(find "$repo_dir" -name "*.rpm" -type f 2>/dev/null | wc -l)
        
        if [[ $rpm_count -eq 0 ]]; then
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "$(align_repo_name "$manual_repo"): No RPM files in manual repository"
            continue
        fi
        
        # Simple timestamp-based check: if any RPM is newer than metadata, update
        local needs_update=false
        
        if [[ ! -d "$repo_dir/repodata" ]]; then
            needs_update=true
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "$(align_repo_name "$manual_repo"): No metadata directory found"
        else
            # Find newest RPM file
            local newest_rpm
            newest_rpm=$(find "$repo_dir" -name "*.rpm" -type f -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -1 | cut -d' ' -f2-)
            
            if [[ -n "$newest_rpm" ]]; then
                local rpm_time
                rpm_time=$(stat -c %Y "$newest_rpm" 2>/dev/null || echo 0)
                local metadata_time
                metadata_time=$(stat -c %Y "$repo_dir/repodata" 2>/dev/null || echo 0)
                
                if [[ $rpm_time -gt $metadata_time ]]; then
                    needs_update=true
                    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "$(align_repo_name "$manual_repo"): RPM files newer than metadata"
                fi
            fi
        fi
        
        if [[ $needs_update == true ]]; then
            log "I" "🔄 $(align_repo_name "$manual_repo"): Manual repository needs metadata update"
            if update_repository_metadata "$manual_repo" "$repo_dir"; then
                ((updated_manual++))
            fi
        else
            [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "$(align_repo_name "$manual_repo"): Manual repository metadata is up to date"
        fi
    done
    
    if [[ $updated_manual -gt 0 ]]; then
        log "I" "✅ Updated metadata for $updated_manual manual repositories"
    else
        [[ $DEBUG_LEVEL -ge 1 ]] && log "I" "✅ All manual repository metadata is up to date"
    fi
}

# Update repository metadata using createrepo_c
function update_repository_metadata() {
    local repo_name="$1"
    local repo_path="$2"
    
    if [[ ! -d "$repo_path" ]]; then
        log "W" "Repository path does not exist: $repo_path"
        return 1
    fi
    
    # Check if there are any RPM files to create metadata for
    local rpm_count
    rpm_count=$(find "$repo_path" -name "*.rpm" -type f 2>/dev/null | wc -l)
    
    if [[ $rpm_count -eq 0 ]]; then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "$(align_repo_name "$repo_name"): No RPM files found, skipping metadata update"
        return 0
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log "I" "🔍 $(align_repo_name "$repo_name"): Would update repository metadata (createrepo_c --update)"
        return 0
    fi
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "I" "🔄 $(align_repo_name "$repo_name"): Updating repository metadata..."
    
    # Automatically fix permissions when needed (improved from original script)
    if [[ $ELEVATE_COMMANDS -eq 1 && -n "$USER" ]]; then
        if [[ -d "$repo_path/repodata" ]]; then
            sudo chown -R "$USER:$USER" "$repo_path/repodata" 2>/dev/null || true
        fi
        sudo chown "$USER:$USER" "$repo_path" 2>/dev/null || true
        chmod 755 "$repo_path" 2>/dev/null || true
    fi
    
    # Build createrepo command with parallel compression
    local createrepo_cmd=""
    if command -v createrepo_c >/dev/null 2>&1; then
        createrepo_cmd="createrepo_c --update"
        # Use parallel workers if enabled and available
        if [[ $USE_PARALLEL_COMPRESSION -eq 1 ]]; then
            createrepo_cmd+=" --workers $PARALLEL"
        fi
    elif command -v createrepo >/dev/null 2>&1; then
        log "W" "createrepo_c not found, falling back to createrepo (slower)"
        createrepo_cmd="createrepo --update"
    else
        log "E" "Neither createrepo_c nor createrepo found - cannot update repository metadata"
        return 1
    fi
    createrepo_cmd+=" \"$repo_path\""
    
    # Add sudo if elevation is enabled
    if [[ $ELEVATE_COMMANDS -eq 1 ]]; then
        createrepo_cmd="sudo $createrepo_cmd"
    fi
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Running: $createrepo_cmd"
    
    # Execute createrepo command
    if eval "$createrepo_cmd" >/dev/null 2>&1; then
        [[ $DEBUG_LEVEL -ge 2 ]] && log "I" "✅ $(align_repo_name "$repo_name"): Repository metadata updated successfully"
        return 0
    else
        log "E" "❌ $(align_repo_name "$repo_name"): Failed to update repository metadata"
        return 1
    fi
}

# Validate requirements and handle special execution modes
function validate_and_handle_modes() {
    # Validate basic requirements
    if [[ ! -d "$LOCAL_REPO_PATH" ]]; then
        log "E" "Local repository path does not exist: $LOCAL_REPO_PATH"
        exit 1
    fi

    if [[ $DRY_RUN -eq 1 ]]; then
        log "I" "DRY RUN mode enabled - no changes will be made"
    fi

    # Handle sync-only mode (exits early if enabled)
    if [[ $SYNC_ONLY -eq 1 ]]; then
        log "I" "SYNC ONLY mode - skipping package processing, only syncing to shared repos"
        sync_to_shared_repos
        log "I" "Sync completed successfully"
        exit 0
    fi

    # Show package limits if configured
    if [[ $MAX_PACKAGES -gt 0 ]]; then
        log "I" "Package limit: $MAX_PACKAGES packages"
    fi

    # Show new package limit with new logic: 0=none, -1=unlimited, >0=specific limit
    if [[ $MAX_NEW_PACKAGES -eq 0 ]]; then
        log "I" "New packages limit: No new packages allowed"
    elif [[ $MAX_NEW_PACKAGES -gt 0 ]]; then
        log "I" "New packages limit: $MAX_NEW_PACKAGES packages"
    fi
    # -1 or negative means unlimited, no message needed
}

# Validate repository structure and detect common issues
function validate_repository_structure() {
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Validating repository structure..."
    
    # Check for invalid getPackage directory directly under LOCAL_REPO_PATH
    if [[ -d "$LOCAL_REPO_PATH/getPackage" ]]; then
        log "W" "⚠️  DETECTED BUG: Invalid getPackage directory found at $LOCAL_REPO_PATH/getPackage"
        log "W" "   This is incorrect - getPackage should only exist as subdirectories under repository directories"
        log "W" "   Example: $LOCAL_REPO_PATH/ol9_appstream/getPackage/ (correct)"
        log "W" "   NOT: $LOCAL_REPO_PATH/getPackage/ (incorrect - this is the detected issue)"
        
        # Count files in the invalid directory
        local file_count=0
        if [[ -d "$LOCAL_REPO_PATH/getPackage" ]]; then
            file_count=$(find "$LOCAL_REPO_PATH/getPackage" -name "*.rpm" -type f 2>/dev/null | wc -l)
            if [[ $file_count -gt 0 ]]; then
                log "W" "   The invalid directory contains $file_count RPM files that may need to be moved"
                log "W" "   Manual intervention required to fix this issue"
            else            
                log "I" "   The invalid directory appears to be empty - safe to remove"
            fi
        fi
        
        return 1  # Structure validation failed
    fi
    
    [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Repository structure validation passed"
    return 0
}

### Main execution section ###
load_config
parse_args "$@" 
check_command_elevation
validate_repository_structure
show_runtime_status
validate_and_handle_modes
full_rebuild_repos
cleanup_old_cache_directories
build_repo_cache
process_packages
sync_to_shared_repos
report_failed_downloads

log "I" "Script completed successfully"
