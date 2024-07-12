#!/bin/bash

# Script version
VERSION=1.8

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${MAX_PACKAGES:=0}"

# Configuration
MAX_PARALLEL_JOBS=1
BATCH_SIZE=10
SCRIPT_DIR=$(dirname "$0")
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
INSTALLED_PACKAGES_FILE=$(mktemp)
LOCAL_REPOS=("ol9_edge" "pgdg-common" "pgdg16")  # Add more local repos if needed

# Function to wait for background jobs to finish
wait_for_jobs() {
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL_JOBS )); do
        sleep 1
    done
}

# Fetch installed packages list
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE"

# Virtual repository map
declare -A virtual_repo_map
virtual_repo_map=(["baseos"]="ol9_baseos_latest" ["appstream"]="ol9_appstream" ["epel"]="ol9_developer_EPEL" \
        ["System"]="ol9_edge" ["@commandline"]="ol9_edge")

# Arrays to hold used directories and identified packages
declare -A used_directories
declare -A identified_packages

# Function to get the repository path
get_repo_path() {
    local package_repo=$1
    local repo_key="${virtual_repo_map[$package_repo]}"
    if [[ -n "$repo_key" ]]; then
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

# Collect initial list of RPM files
echo "$(date '+%Y-%m-%d %H:%M:%S') - Collecting initial list of RPM files..."
initial_rpm_files=($(find "$LOCAL_REPO_PATH"/ol9_* -type f -path "*/getPackage/*.rpm"))

# Read the installed packages list
mapfile -t package_lines < "$INSTALLED_PACKAGES_FILE"

# Processing installed packages
echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."
package_counter=0
batch_packages=()

for line in "${package_lines[@]}"; do
    [ "$DEBUG_MODE" -ge 1 ] && echo "Processing line: $line"
    
    if [[ "$line" =~ ^Installed\ Packages$ ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping line: $line"
        continue
    fi
    
    if [[ $line =~ ^([^\ ]+)\.([^\ ]+)\ +([^\ ]+)\ +@([^\ ]+) ]]; then
        package_name=${BASH_REMATCH[1]}
        package_arch=${BASH_REMATCH[2]}
        package_version=${BASH_REMATCH[3]}
        package_repo=${BASH_REMATCH[4]}
        
        # Extract epoch if present
        if [[ $package_version =~ ([0-9]+):(.+) ]]; then
            epoch=${BASH_REMATCH[1]}
            version=${BASH_REMATCH[2]}
        else
            epoch=""
            version=$package_version
        fi
        
        [ "$DEBUG_MODE" -ge 1 ] && echo "Matched package: $package_name, Version: $version, Epoch: $epoch, Repo: $package_repo"
        
        repo_path=$(get_repo_path "$package_repo")
        repo_name=$(get_repo_name "$package_repo")
        if [[ -n "$repo_path" ]]; then
            used_directories["$repo_path"]=1
            batch_packages+=("$repo_name|$package_name|$epoch|$version|$package_arch|$repo_path")
        fi
        
        ((package_counter++))
        
        if (( MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES )); then
            echo "Processed $MAX_PACKAGES packages. Stopping."
            break
        fi

        # Check if we have reached the batch size
        if (( ${#batch_packages[@]} >= BATCH_SIZE )); then
            [ "$DEBUG_MODE" -gt 0 ] && echo "$SCRIPT_DIR/process-package.sh $DEBUG_MODE ${batch_packages[*]} ${LOCAL_REPOS[*]}"
            "$SCRIPT_DIR/process-package.sh" "$DEBUG_MODE" "${batch_packages[@]}" "${LOCAL_REPOS[@]}" &
            batch_packages=()
            wait_for_jobs
        fi
    fi
done

# Process any remaining packages in the last batch
if (( ${#batch_packages[@]} > 0 )); then
    [ "$DEBUG_MODE" -gt 0 ] && echo "$SCRIPT_DIR/process-package.sh $DEBUG_MODE ${batch_packages[*]} ${LOCAL_REPOS[*]}"
    "$SCRIPT_DIR/process-package.sh" "$DEBUG_MODE" "${batch_packages[@]}" "${LOCAL_REPOS[@]}"
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
