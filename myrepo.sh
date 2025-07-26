#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with different AI support models
# AI flock: ChatGPT, Claude, Gemini
# Last Updated: 2025-07-26

# MIT licensing
# Purpose:
# This script replicates and updates repositories from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# local repositories. Optimized for performance with intelligent caching.

# NOTE: This version has been optimized for performance while maintaining core functionality.
# Complex adaptive features have been simplified in favor of reliable, fast operation.

# Script version
VERSION="2.2.0"

# Default Configuration (can be overridden by myrepo.cfg)
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
MANUAL_REPOS=("ol9_edge")
DEBUG_LEVEL=${DEBUG_LEVEL:-1}
DRY_RUN=${DRY_RUN:-0}
MAX_PACKAGES=${MAX_PACKAGES:-0}
MAX_NEW_PACKAGES=${MAX_NEW_PACKAGES:-0}
SYNC_ONLY=${SYNC_ONLY:-0}
BATCH_SIZE=${BATCH_SIZE:-50}
PARALLEL=${PARALLEL:-6}
EXCLUDE_REPOS=""
REPOS=""
NAME_FILTER=""
FULL_REBUILD=${FULL_REBUILD:-0}
LOG_DIR=${LOG_DIR:-"/var/log/myrepo"}
SET_PERMISSIONS=${SET_PERMISSIONS:-0}
REFRESH_METADATA=${REFRESH_METADATA:-0}
DNF_SERIAL=${DNF_SERIAL:-0}
USER_MODE=${USER_MODE:-0}
CACHE_MAX_AGE=${CACHE_MAX_AGE:-14400}  # 4 hours cache validity (in seconds)

# Formatting constants (matching original script)
PADDING_LENGTH=28

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
    
    echo -e "${color}[$(date '+%H:%M:%S')] [$level] $message\e[0m"
}

# Align repository names like the original script
function align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
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
            all_repos+=("$repo")
        done
    fi
    if [[ ${#stats_update_count[@]} -gt 0 ]]; then
        for repo in "${!stats_update_count[@]}"; do
            if [[ ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
                all_repos+=("$repo")
            fi
        done
    fi
    if [[ ${#stats_exists_count[@]} -gt 0 ]]; then
        for repo in "${!stats_exists_count[@]}"; do
            if [[ ! " ${all_repos[*]} " =~ \ ${repo}\  ]]; then
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
        local new_count="${stats_new_count[$repo]:-0}"
        local update_count="${stats_update_count[$repo]:-0}"
        local exists_count="${stats_exists_count[$repo]:-0}"
        local status="Active"
        
        # Only draw row if there's any activity for this repo
        if [[ $new_count -gt 0 || $update_count -gt 0 || $exists_count -gt 0 ]]; then
            draw_table_row_flex "$repo" "$new_count" "$update_count" "$exists_count" "$status"
        fi
    done
    
    draw_table_border_flex "middle"
    draw_table_row_flex "TOTAL" "$total_new" "$total_update" "$total_exists" "Summary"
    draw_table_border_flex "bottom"
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
                DEBUG_LEVEL) DEBUG_LEVEL="$value" ;;
                DRY_RUN) DRY_RUN="$value" ;;
                MAX_PACKAGES) MAX_PACKAGES="$value" ;;
                MAX_NEW_PACKAGES) MAX_NEW_PACKAGES="$value" ;;
                BATCH_SIZE) BATCH_SIZE="$value" ;;
                PARALLEL) PARALLEL="$value" ;;
                EXCLUDED_REPOS) EXCLUDE_REPOS="$value" ;;
                FULL_REBUILD) FULL_REBUILD="$value" ;;
                LOG_DIR) LOG_DIR="$value" ;;
                SET_PERMISSIONS) SET_PERMISSIONS="$value" ;;
                REFRESH_METADATA) REFRESH_METADATA="$value" ;;
                DNF_SERIAL) DNF_SERIAL="$value" ;;
                USER_MODE) USER_MODE="$value" ;;
                CACHE_MAX_AGE) CACHE_MAX_AGE="$value" ;;
            esac
            
            # Limit config file reading to prevent hanging on large files
            if [[ $line_count -gt 500 ]]; then
                log "W" "Config file too large, stopping at line $line_count"
                break
            fi
        done < "$config_file"
        
        log "I" "Configuration loaded: LOCAL_REPO_PATH=$LOCAL_REPO_PATH"
        [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "MANUAL_REPOS: ${MANUAL_REPOS[*]}"
    else
        log "I" "No configuration file found, using defaults"
    fi
}

# Cache for repository package metadata (like original script)
declare -A available_repo_packages

# Build repository metadata cache (optimized - only for installed packages)
function build_repo_cache() {
    log "I" "Building repository metadata cache for installed packages..."
    local cache_dir="/tmp/myrepo_cache"
    mkdir -p "$cache_dir"
    
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
        enabled_repos=$(dnf repolist --enabled --quiet | awk 'NR>1 {print $1}' | grep -v "^$")
        
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
    installed_packages=$(timeout 60 dnf repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{ui_from_repo}" 2>/dev/null)
    
    if [[ -z "$installed_packages" ]]; then
        log "W" "No installed packages found"
        return 1
    fi
    
    # Get unique package names for efficient querying
    local unique_packages
    unique_packages=$(echo "$installed_packages" | cut -d'|' -f1 | sort -u)
    
    # Get list of enabled repositories
    local enabled_repos
    enabled_repos=$(dnf repolist --enabled --quiet | awk 'NR>1 {print $1}' | grep -v "^$")
    
    if [[ -z "$enabled_repos" ]]; then
        log "W" "No enabled repositories found"
        return 1
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
        if timeout 120 dnf repoquery -y --disablerepo="*" --enablerepo="$repo" \
            --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" \
            "${package_list[@]}" 2>/dev/null > "$cache_file.tmp"; then
            mv "$cache_file.tmp" "$cache_file"
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
            rm -f "$cache_file.tmp"
        fi
    done <<< "$enabled_repos"
    
    # Save cache timestamp
    echo "$current_time" > "$cache_timestamp_file"
    
    log "I" "Repository metadata cache built successfully (optimized for installed packages)"
}

# Check if repository is enabled (to exclude disabled repos from sync)
function is_repo_enabled() {
    local repo_name="$1"
    
    # Check if repo is in enabled list
    local enabled_repos
    enabled_repos=$(dnf repolist --enabled --quiet | awk 'NR>1 {print $1}' | grep -v "^$")
    
    while IFS= read -r enabled_repo; do
        if [[ "$repo_name" == "$enabled_repo" ]]; then
            return 0  # Repository is enabled
        fi
    done <<< "$enabled_repos"
    
    return 1  # Repository is not enabled
}

# Handle packages from disabled repositories (update local but don't sync)
function handle_disabled_repo_package() {
    local package_name="$1"
    local epoch="$2" 
    local package_version="$3"
    local package_release="$4"
    local package_arch="$5"
    local original_repo="$6"
    
    # Use the original repository name (cleaned up)
    local repo_name="${original_repo#@}"
    local repo_path
    repo_path=$(get_repo_path "$repo_name")
    
    # Ensure repository directory exists (for disabled repos too)
    mkdir -p "$repo_path" 2>/dev/null
    
    # Get package status
    local status
    status=$(get_package_status "$package_name" "$package_version" "$package_release" "$package_arch" "$repo_path")
    
    # Handle the package but mark it as disabled repo
    case "$status" in
        "EXISTS")
            ((stats_exists_count["$repo_name (disabled)"]++))
            [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[90m$(align_repo_name "$repo_name (disabled)"): $package_name-$package_version-$package_release.$package_arch\e[0m"
            ;;
        "UPDATE")
            ((stats_update_count["$repo_name (disabled)"]++))
            echo -e "\e[95m$(align_repo_name "$repo_name (disabled)"): $package_name-$package_version-$package_release.$package_arch\e[0m"
            
            if [[ $DRY_RUN -eq 0 ]]; then
                # For disabled repos, try to download from any available source
                if dnf download --destdir="$repo_path" "${package_name}-${package_version}-${package_release}.${package_arch}" >/dev/null 2>&1; then
                    echo -e "\e[32m   ✓ Downloaded from available source\e[0m"
                else
                    echo -e "\e[33m   ⚠️ Package not available for download (disabled repo)\e[0m"
                fi
            fi
            ;;
        "NEW")
            ((stats_new_count["$repo_name (disabled)"]++))
            echo -e "\e[95m$(align_repo_name "$repo_name (disabled)"): $package_name-$package_version-$package_release.$package_arch\e[0m"
            
            if [[ $DRY_RUN -eq 0 ]]; then
                # For disabled repos, try to download from any available source
                if dnf download --destdir="$repo_path" "${package_name}-${package_version}-${package_release}.${package_arch}" >/dev/null 2>&1; then
                    echo -e "\e[32m   ✓ Downloaded from available source\e[0m"
                else
                    echo -e "\e[33m   ⚠️ Package not available for download (disabled repo)\e[0m"
                fi
            fi
            ;;
    esac
    
    return 0
}

# Determine actual repository source for @System packages (like original script)
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
    
    # Check for exact match first (EXISTS)
    if [[ -f "$repo_path/$exact_filename" ]]; then
        echo "EXISTS"
        return 0
    fi
    
    # Check for same package name/arch but different version (UPDATE needed)
    local existing_files
    existing_files=$(find "$repo_path" -maxdepth 1 -name "$name_arch_pattern" -type f 2>/dev/null | head -1)
    
    if [[ -n "$existing_files" ]]; then
        # Found same package with different version - need UPDATE
        echo "UPDATE"
        return 0
    fi
    
    # No existing package found - this is NEW
    echo "NEW"
    return 0
}

# Get repository path for a repository name
function get_repo_path() {
    local repo_name="$1"
    
    # Check if it's a manual repo
    for manual_repo in "${MANUAL_REPOS[@]}"; do
        if [[ "$repo_name" == "$manual_repo" ]]; then
            echo "$LOCAL_REPO_PATH/$repo_name/getPackage"
            return 0
        fi
    done
    
    # It's a regular repo
    echo "$LOCAL_REPO_PATH/$repo_name"
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

# Fast batch download with parallel processing and better DNF options
function batch_download_packages() {
    local -A repo_packages
    
    # Group packages by repository for batch downloading
    while IFS='|' read -r repo_name package_name epoch package_version package_release package_arch; do
        local repo_path
        repo_path=$(get_repo_path "$repo_name")
        
        # Build package spec (handle epoch properly)
        local package_spec
        if [[ -n "$epoch" && "$epoch" != "0" && "$epoch" != "(none)" ]]; then
            package_spec="${package_name}-${epoch}:${package_version}-${package_release}.${package_arch}"
        else
            package_spec="${package_name}-${package_version}-${package_release}.${package_arch}"
        fi
        
        repo_packages["$repo_path"]+="$package_spec "
    done
    
    # Download batches per repository with optimized DNF settings
    for repo_path in "${!repo_packages[@]}"; do
        local packages="${repo_packages[$repo_path]}"
        if [[ -n "$packages" ]]; then
            local repo_name
            repo_name=$(basename "$repo_path")
            echo -e "\e[36m📦 Fast downloading packages to $repo_name...\e[0m"
            
            # Debug: show what we're trying to download
            [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[37m   Packages: $packages\e[0m"
            
            # Use optimized DNF with parallel downloads and performance settings
            local dnf_output
            # shellcheck disable=SC2086 # Intentional word splitting for package list
            if dnf_output=$(dnf download \
                --setopt=max_parallel_downloads=8 \
                --setopt=fastestmirror=1 \
                --setopt=deltarpm=0 \
                --setopt=timeout=60 \
                --setopt=retries=2 \
                --destdir="$repo_path" \
                $packages 2>&1); then
                echo -e "\e[32m✓ Downloads completed for $repo_name\e[0m"
            else
                echo -e "\e[31m✗ Some downloads failed for $repo_name\e[0m"
                [[ $DEBUG_LEVEL -ge 1 ]] && echo -e "\e[31m   Error: $dnf_output\e[0m"
                
                # Try downloading packages one by one as fallback
                echo -e "\e[33m   Trying individual downloads as fallback...\e[0m"
                local success_count=0
                local total_count=0
                # shellcheck disable=SC2086 # Intentional word splitting for package list
                for pkg in $packages; do
                    ((total_count++))
                    if dnf download --destdir="$repo_path" "$pkg" >/dev/null 2>&1; then
                        ((success_count++))
                        echo -e "\e[32m   ✓ $pkg\e[0m"
                    else
                        echo -e "\e[31m   ✗ $pkg\e[0m"
                    fi
                done
                echo -e "\e[33m   Fallback result: $success_count/$total_count packages downloaded\e[0m"
            fi
        fi
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
    echo -e "\e[32m🚀 MyRepo Simple v3.0.0 - Starting package processing...\e[0m"
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    
    # Get installed packages using dnf (like original script) - this includes repo info!
    echo -e "\e[33m📦 Getting list of installed packages with repository information...\e[0m"
    local package_list
    
    # Use the original script's efficient method with timeout
    if [[ -n "$NAME_FILTER" ]]; then
        package_list=$(timeout 60 dnf repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{ui_from_repo}" 2>/dev/null | grep -E "^[^|]*${NAME_FILTER}[^|]*\|")
    else
        package_list=$(timeout 60 dnf repoquery --installed --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{ui_from_repo}" 2>/dev/null)
    fi
    
    if [[ -z "$package_list" ]]; then
        log "E" "Failed to get installed packages list"
        return 1
    fi
    
    # Count total packages
    total_packages=$(echo "$package_list" | wc -l)
    echo -e "\e[32m✓ Found $total_packages installed packages\e[0m"
    echo
    
    # First pass: analyze what needs to be done (fast)
    local start_time
    start_time=$(date +%s)
    
    while IFS='|' read -r package_name epoch package_version package_release package_arch repo_name; do
        ((processed_packages++))
        
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
        
        # Progress reporting every 200 packages (less frequent for speed)
        if (( processed_packages % 200 == 0 )); then
            local elapsed=$(($(date +%s) - start_time))
            local rate=0
            if [[ $elapsed -gt 0 ]]; then
                rate=$((processed_packages / elapsed))
            fi
            echo -e "\e[36m⏱️  Progress: $processed_packages/$total_packages packages ($rate pkg/sec)\e[0m"
        fi
        
        # Normalize epoch
        [[ "$epoch" == "(none)" || -z "$epoch" ]] && epoch="0"
        
        # Determine actual repository for @System packages (like original script)
        if [[ "$repo_name" == "System" || "$repo_name" == "@System" || "$repo_name" == "@commandline" ]]; then
            repo_name=$(determine_repo_source "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch")
            [[ $DEBUG_LEVEL -ge 3 ]] && echo -e "\e[37m   Determined repo for $package_name: $repo_name\e[0m"
            
            # If package not found in enabled repos, handle as disabled repo package
            if [[ "$repo_name" == "Invalid" ]]; then
                [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[90m   Package from disabled/unavailable repository: $package_name\e[0m"
                # Try to determine original repo from package release string or use heuristic
                local fallback_repo="unknown_disabled"
                
                # Smart guessing based on package release patterns
                if [[ "$package_release" =~ PGDG ]]; then
                    fallback_repo="pgdg-common"
                elif [[ "$package_release" =~ el9 ]]; then
                    fallback_repo="unknown_disabled_el9"
                fi
                
                handle_disabled_repo_package "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch" "$fallback_repo"
                continue
            fi
        else
            # For non-@System repositories, check if repository is enabled
            local clean_repo_name="${repo_name#@}"  # Remove @ prefix if present
            
            if ! is_repo_enabled "$clean_repo_name"; then
                [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[90m   Package from disabled repository: $package_name ($clean_repo_name)\e[0m"
                handle_disabled_repo_package "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch" "$clean_repo_name"
                continue
            fi
            
            repo_name="$clean_repo_name"
        fi
        
        # Skip invalid packages (like original script)
        if [[ "$repo_name" == "@commandline" || "$repo_name" == "Invalid" ]]; then
            [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[90m   Skipping invalid package: $package_name ($repo_name)\e[0m"
            continue
        fi
        
        local repo_path
        repo_path=$(get_repo_path "$repo_name")
        
        # Ensure repository directory exists
        mkdir -p "$repo_path" 2>/dev/null
        
        # Get package status using our simple, reliable method
        local status
        status=$(get_package_status "$package_name" "$package_version" "$package_release" "$package_arch" "$repo_path")
        
        # Handle based on status with colorful, aligned reporting
        case "$status" in
            "EXISTS")
                ((exists_count++))
                ((stats_exists_count["$repo_name"]++))
                [[ $DEBUG_LEVEL -ge 2 ]] && echo -e "\e[32m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch\e[0m"
                ;;
            "UPDATE")
                ((update_count++))
                ((stats_update_count["$repo_name"]++))
                echo -e "\e[36m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch\e[0m"
                
                if [[ $DRY_RUN -eq 0 ]]; then
                    # Remove old version(s) first
                    find "$repo_path" -name "${package_name}-*-*.${package_arch}.rpm" -delete 2>/dev/null
                    # Add to update batch
                    update_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                fi
                ;;
            "NEW")
                ((new_count++))
                ((stats_new_count["$repo_name"]++))
                echo -e "\e[33m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch\e[0m"
                
                if [[ $DRY_RUN -eq 0 ]]; then
                    # Check if we've hit the MAX_NEW_PACKAGES limit
                    if [[ $MAX_NEW_PACKAGES -gt 0 && $new_packages_found -ge $MAX_NEW_PACKAGES ]]; then
                        echo -e "\e[33m🔢 Reached new packages limit ($MAX_NEW_PACKAGES), stopping\e[0m"
                        break
                    else
                        ((new_packages_found++))
                        # Add to new batch
                        new_packages+=("$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch")
                    fi
                fi
                ;;
            *)
                echo -e "\e[31m$(align_repo_name "$repo_name"): ✗ Unknown status '$status' for $package_name\e[0m"
                ;;
        esac
        
    done <<< "$package_list"
    
    # Second pass: batch download all NEW packages
    if [[ ${#new_packages[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        echo -e "\e[33m📥 Batch downloading ${#new_packages[@]} new packages...\e[0m"
        printf '%s\n' "${new_packages[@]}" | batch_download_packages
    fi
    
    # Third pass: batch download all UPDATE packages
    if [[ ${#update_packages[@]} -gt 0 && $DRY_RUN -eq 0 ]]; then
        echo -e "\e[36m🔄 Batch downloading ${#update_packages[@]} updated packages...\e[0m"
        printf '%s\n' "${update_packages[@]}" | batch_download_packages
    fi
    
    # Final statistics with colors
    local elapsed=$(($(date +%s) - start_time))
    local rate=0
    if [[ $elapsed -gt 0 ]]; then
        rate=$((processed_packages / elapsed))
    fi
    
    echo
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    echo -e "\e[32m✓ Processing completed in ${elapsed}s\e[0m"
    echo -e "\e[36m  Processed: $processed_packages packages at $rate pkg/sec\e[0m"
    echo -e "\e[33m  Results: \e[32m$new_count new\e[0m, \e[33m$update_count updates\e[0m, \e[90m$exists_count existing\e[0m"
    echo -e "\e[36m═══════════════════════════════════════════════════════════════\e[0m"
    
    if [[ $DRY_RUN -eq 1 ]]; then
        echo -e "\e[35m🔍 DRY RUN mode - no actual downloads performed\e[0m"
    fi
    
    # Generate the beautiful summary table
    generate_summary_table
}

# Sync local repositories to shared location (excluding disabled repos)
function sync_to_shared_repos() {
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
            
            # Skip manual repos directory structure
            if [[ "$repo_name" == "getPackage" ]]; then
                continue
            fi
            
            # Check if this repository should be synced (only enabled repos)
            if ! is_repo_enabled "$repo_name"; then
                [[ $DEBUG_LEVEL -ge 2 ]] && log "D" "Skipping sync for disabled repository: $repo_name"
                echo -e "\e[90m$(align_repo_name "$repo_name"): Skipped (disabled repository)\e[0m"
                continue
            fi
            
            local shared_repo_dir="$SHARED_REPO_PATH/$repo_name"
            
            log "I" "Syncing $repo_name..."
            
            # Create shared repo directory if it doesn't exist
            mkdir -p "$shared_repo_dir" 2>/dev/null
            
            # Use rsync for efficient sync
            if command -v rsync >/dev/null 2>&1; then
                rsync -av --delete "$repo_dir/" "$shared_repo_dir/"
            else
                # Fallback to cp
                cp -r "$repo_dir/"* "$shared_repo_dir/" 2>/dev/null
            fi
            
            echo -e "\e[32m$(align_repo_name "$repo_name"): Synced to shared repository\e[0m"
        fi
    done
    
    log "I" "Repository sync completed (disabled repositories excluded)"
}

# Main execution
function main() {
    # Check if script is run as root first
    if [[ $EUID -ne 0 ]]; then
        log "E" "This script must be run as root or with sudo privileges."
        exit 1
    fi
    
    # Load configuration first
    load_config
    
    log "I" "Starting myrepo simple version $VERSION"
    
    # Handle refresh metadata option
    if [[ $REFRESH_METADATA -eq 1 ]]; then
        log "I" "Refreshing DNF metadata cache..."
        dnf clean metadata >/dev/null 2>&1 || true
        log "I" "DNF metadata cache refreshed"
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
    if [[ $USER_MODE -eq 1 ]]; then
        log "I" "User mode enabled - assuming elevated privileges"
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
    
    # Validate basic requirements
    if [[ ! -d "$LOCAL_REPO_PATH" ]]; then
        log "E" "Local repository path does not exist: $LOCAL_REPO_PATH"
        exit 1
    fi
    
    if [[ $DRY_RUN -eq 1 ]]; then
        log "I" "DRY RUN mode enabled - no changes will be made"
    fi
    
    if [[ $SYNC_ONLY -eq 1 ]]; then
        log "I" "SYNC ONLY mode - skipping package processing, only syncing to shared repos"
        sync_to_shared_repos
        log "I" "Sync completed successfully"
        return 0
    fi
    
    if [[ $MAX_PACKAGES -gt 0 ]]; then
        log "I" "Package limit: $MAX_PACKAGES packages"
    fi
    
    if [[ $MAX_NEW_PACKAGES -gt 0 ]]; then
        log "I" "New packages limit: $MAX_NEW_PACKAGES packages"
    fi
    
    # Perform full rebuild if requested
    full_rebuild_repos
    
    # Build repository metadata cache (like original script)
    if ! build_repo_cache; then
        log "E" "Failed to build repository metadata cache"
        exit 1
    fi
    
    # Start processing
    process_packages
    
    # Sync to shared repositories after processing (if not in dry run mode)
    if [[ $DRY_RUN -eq 0 && -d "$SHARED_REPO_PATH" ]]; then
        sync_to_shared_repos
    fi
    
    log "I" "Script completed successfully"
}

# Handle command line arguments
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
        --debug)
            DEBUG_LEVEL="$2"
            shift 2
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
        --test-limit)
            MAX_PACKAGES="$2"
            shift 2
            ;;
        --user-mode)
            USER_MODE=1
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
            echo "  --batch-size INT       Number of packages per batch (default: $BATCH_SIZE)"
            echo "  --cache-max-age SEC    Cache validity in seconds (default: $CACHE_MAX_AGE = 4h)"
            echo "  --debug 0-4           Debug level (0=critical, 1=important, 2=normal, 3=verbose, 4=very verbose)"
            echo "  --dnf-serial          Use serial DNF mode to prevent database lock contention"
            echo "  --dry-run             Dry run mode (no changes)"
            echo "  --exclude-repos CSV   Comma-separated list of repositories to exclude"
            echo "  --full-rebuild        Perform a full rebuild of the repository"
            echo "  --local-repo-path PATH Set local repository path (default: $LOCAL_REPO_PATH)"
            echo "  --log-dir PATH        Where to write log files (default: $LOG_DIR)"
            echo "  --manual-repos CSV    Comma-separated list of manual repositories"
            echo "  --max-packages INT    Limit number of packages processed (0 = no limit)"
            echo "  --max-new-packages INT Limit number of new packages to download (0 = no limit)"
            echo "  --name-filter REGEX   Filter packages by name using regex pattern"
            echo "  --parallel INT        Maximum concurrent jobs (default: $PARALLEL)"
            echo "  --refresh-metadata    Force a refresh of DNF metadata cache and rebuild repository cache"
            echo "  --repos CSV          Comma-separated list of repositories to process"
            echo "  --set-permissions     Automatically fix permission issues when detected"
            echo "  --shared-repo-path PATH Set shared repository path (default: $SHARED_REPO_PATH)"
            echo "  -s, --sync-only      Only sync to shared repos, skip package processing"
            echo "  --test-limit NUM     Limit to NUM packages for testing (same as --max-packages)"
            echo "  --user-mode          Run entire script with sudo (advanced mode)"
            echo "  -v, --verbose        Verbose output (same as --debug 2)"
            echo "  -h, --help           Show this help"
            echo
            echo "Cache Management:"
            echo "  The script caches repository metadata for performance. Cache is valid for"
            echo "  $CACHE_MAX_AGE seconds (4 hours) by default. Use --refresh-metadata to force rebuild."
            echo
            echo "Examples:"
            echo "  $0 --repos ol9_appstream --name-filter 'firefox.*' --dry-run"
            echo "  $0 --exclude-repos code,copr --max-packages 100"
            echo "  $0 --debug 3 --batch-size 25 --parallel 4"
            echo "  $0 --full-rebuild --set-permissions --debug 2"
            echo "  $0 --refresh-metadata --dnf-serial"
            echo "  $0 --cache-max-age 3600  # 1 hour cache validity"
            echo "  $0 --test-limit 50 --dry-run  # Test with 50 packages"
            exit 0
            ;;
        *)
            log "E" "Unknown option: $1"
            echo "Use -h or --help for usage information"
            exit 1
            ;;
    esac
done

# Run the main function
main
