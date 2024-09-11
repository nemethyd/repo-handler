#!/bin/bash

# Script version
VERSION=2.28

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${MAX_PACKAGES:=0}"
: "${BATCH_SIZE:=10}"
: "${MAX_PARALLEL_JOBS:=1}"

#truncate working files
echo "" > locally_found.lst
echo "" > myrepo.err
echo "" > process_package.log

# Configuration
SCRIPT_DIR=$(dirname "$0")
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
INSTALLED_PACKAGES_FILE=$(mktemp)
LOCAL_REPOS=("ol9_edge" "pgdg-common" "pgdg16")
RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Parse options
while [[ "$1" =~ ^-- ]]; do
    case "$1" in
        --debug-level)
            shift
            DEBUG_MODE=$1
        ;;
        --max-packages)
            shift
            MAX_PACKAGES=$1
        ;;
        --batch-size)
            shift
            BATCH_SIZE=$1
        ;;
        --parallel)
            shift
            MAX_PARALLEL_JOBS=$1
        ;;
        --version)
            echo "myrepo.sh Version $VERSION"
            exit 0
        ;;
        --help)
            echo "Usage: myrepo.sh [--debug-level LEVEL] [--max-packages NUM] [--batch-size NUM] [--parallel NUM]"
            echo "Options:"
            echo "  --debug-level LEVEL  Set the debug level (default: 0)"
            echo "  --max-packages NUM   Set the maximum number of packages to process (default: 0)"
            echo "  --batch-size NUM     Set the batch size for processing packages (default: 10)"
            echo "  --parallel NUM       Set the number of parallel jobs (default: 1)"
            echo "  --version            Show script version"
            echo "  --help               Show this help message"
            exit 0
        ;;
        *)
            echo "Unknown option: $1"
            exit 1
        ;;
    esac
    shift
done

# Function to wait for background jobs to finish
wait_for_jobs() {
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL_JOBS )); do
        sleep 1
    done
}

# Function to download repository metadata and store in memory
download_repo_metadata() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Downloading repository metadata..."
    declare -gA repo_cache
    for repo in "${ENABLED_REPOS[@]}"; do
        echo "Fetching metadata for $repo..."
        repo_cache["$repo"]=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}-%{epoch}:%{version}-%{release}.%{arch}" 2>>myrepo.err)
    done
}

# Fetch installed packages list
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE"

# Fetch the list of enabled repositories
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of enabled repositories..."
ENABLED_REPOS=($(dnf repolist enabled | awk 'NR>1 {print $1}'))

# Download repository metadata for enabled repos
download_repo_metadata

# Function to check if a package is available in the local repos or rpmbuild directory
is_package_in_local_sources() {
    local package_name=$1
    local package_version=$2
    local package_arch=$3
    
    # Check in local repos metadata
    for repo in "${LOCAL_REPOS[@]}"; do
        if echo "${repo_cache[$repo]}" | grep -q "${package_name}-${package_version}.${package_arch}"; then
            echo "$repo"
            return
        fi
    done
    
    # Check in rpmbuild directory
    if find "$RPMBUILD_PATH" -name "${package_name}-${package_version}*.rpm" | grep -q .; then
        echo "${package_name}-${package_version}*.rpm" >> "locally_found.lst" #locally found packages
    fi
    
    echo "no"
}

# Function to determine the repository source of a package
determine_repo_source() {
    local package_name=$1
    local package_version=$2
    local package_arch=$3
    
    # Check if the package exists in any of the local sources
    local_repo=$(is_package_in_local_sources "$package_name" "$package_version" "$package_arch")
    if [[ "$local_repo" != "no" ]]; then
        echo "$local_repo"
        return
    fi
    
    # If the package is not found in the local sources, determine the original repository
    for repo in "${ENABLED_REPOS[@]}"; do
        if [[ $DEBUG_MODE -ge 1 ]]; then
            echo "Checking ${repo} for ${package_name}-${package_version}.${package_arch}" >&2
            # echo "${repo_cache[$repo]}" > "$repo.cache"
        fi
        if echo "${repo_cache[$repo]}" | grep -qE "${package_name}(-[0-9]+:)?${package_version}.${package_arch}"; then
            echo "$repo"
            return
        fi
        
    done
    
    echo "Invalid"  # Default to Invalid if not found elsewhere
}

# Collect initial list of RPM files
echo "$(date '+%Y-%m-%d %H:%M:%S') - Collecting initial list of RPM files..."
initial_rpm_files=($(find "$LOCAL_REPO_PATH"/ol9_* -type f -path "*/getPackage/*.rpm"))

# Read the installed packages list
mapfile -t package_lines < "$INSTALLED_PACKAGES_FILE"

# Processing installed packages
echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."
package_counter=0
batch_packages=()

# Function to get the repository path
get_repo_path() {
    local package_repo=$1
    
    # Handle System and invalid cases
    if [[ "$package_repo" == "System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi
    
    local repo_key="${virtual_repo_map[$package_repo]}"
    if [[ -n "$repo_key" && "$repo_key" != "@commandline" ]]; then
        echo "$LOCAL_REPO_PATH/$repo_key/getPackage"
    else
        echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
    fi
}

# Function to get the repository name
get_repo_name() {
    local package_repo=$1
    local repo_key="${virtual_repo_map[$package_repo]}"
    if [[ -n "$repo_key" ]]; then
        echo "$repo_key"
    else
        echo "$package_repo"
    fi
}

#main loop processing the lines
for line in "${package_lines[@]}"; do
    [ "$DEBUG_MODE" -ge 1 ] && echo "Processing line: $line"
    
    if [[ "$line" =~ ^Installed\ Packages$ ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping line: $line"
        continue
    fi
    
if [[ $line =~ ^([^.]+)\.([^\ ]+)\ +([^\ ]+)\ +@([^\ ]+)[[:space:]]*$ ]]; then
    package_name=${BASH_REMATCH[1]}    # Package name (before the first dot)
    package_arch=${BASH_REMATCH[2]}    # Package architecture (after the dot)
    full_version=${BASH_REMATCH[3]}    # Full version string (can include epoch)
    package_repo=${BASH_REMATCH[4]}    # Package repository (after the second group of spaces and @ symbol)
    
    # Ensure $full_version is set correctly
    if [[ "$full_version" =~ ^([0-9]+):(.*)$ ]]; then
        epoch_version=${BASH_REMATCH[1]}    # Epoch (part before the colon)
        package_version=${BASH_REMATCH[2]}  # Package version (part after the colon)
    else
        epoch_version=""                    # No epoch, set to empty
        package_version=$full_version       # Entire version is the package_version
    fi
        
        # Determine the actual repository source
        if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
            package_repo=$(determine_repo_source "$package_name" "$package_version" "$package_arch")
        fi
        
        # Skip @commandline packages and those from invalid repos
        if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
            [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping $package_repo package: $package_name"
            continue
        fi
        
        [ "$DEBUG_MODE" -ge 1 ] && echo "Matched package: $package_name, Version: $package_version, Epoch: $epoch_version, Repo: $package_repo"
        
        repo_path=$(get_repo_path "$package_repo")
        repo_name=$(get_repo_name "$package_repo")
        
        # Add debugging information about repo_path and repo_name
        [ "$DEBUG_MODE" -ge 1 ] && echo "Determined repo_path: $repo_path, repo_name: $repo_name for package: $package_name"
        
        if [[ -n "$repo_path" ]]; then
            used_directories["$repo_name"]="$repo_path"
            batch_packages+=("$repo_name|$package_name|$epoch_version|$package_version|$package_arch|$repo_path")
        else
            [ "$DEBUG_MODE" -ge 1 ] && echo "Invalid or non-existent repo path: $repo_path for package: $package_name"
            continue
        fi
        
        ((package_counter++))
        
        if (( MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES )); then
            echo "Processed $MAX_PACKAGES packages. Stopping."
            break
        fi
        
        # Check if we have reached the batch size
        if (( ${#batch_packages[@]} >= BATCH_SIZE )); then
            [ $DEBUG_MODE -gt 0 ] && echo '$SCRIPT_DIR/process-package.sh --debug-level $DEBUG_MODE --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}"'
            "$SCRIPT_DIR"/process-package.sh --debug-level "$DEBUG_MODE" --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}" &
            batch_packages=()
            wait_for_jobs
        fi
    fi
    
    
done

# Process any remaining packages in the last batch
if (( ${#batch_packages[@]} > 0 )); then
    [ "$DEBUG_MODE" -gt 0 ] && echo '$SCRIPT_DIR/process-package.sh --debug-level $DEBUG_MODE --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}"'
    "$SCRIPT_DIR/process-package.sh" --debug-level "$DEBUG_MODE" --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}"
fi

# If MAX_PACKAGES is set and greater than zero, skip repository updates and syncing
if (( MAX_PACKAGES == 0 )); then
    echo "Updating repositories in used directories..."
    for dir in "${!used_directories[@]}"; do
        parent_dir=$(dirname "$dir")
        echo "Updating repository at $parent_dir..."
        createrepo --update "$parent_dir"
    done
    
    echo "Syncing $SHARED_REPO_PATH with $LOCAL_REPO_PATH..."
    rsync -av --delete "$LOCAL_REPO_PATH/" "$SHARED_REPO_PATH/"
    if [ $? -eq 0 ]; then
        echo "Sync completed successfully."
    else
        echo "Error occurred during sync." >&2
        exit 1
    fi
else
    echo "Skipping repository updates and sync due to MAX_PACKAGES setting."
fi

# Clean up
rm "$INSTALLED_PACKAGES_FILE"

echo "All packages have been processed."
echo "myrepo.sh Version $VERSION completed."

