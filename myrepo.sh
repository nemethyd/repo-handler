#!/bin/bash

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${MAX_PACKAGES:=0}"

# Configuration
MAX_PARALLEL_JOBS=2
BATCH_SIZE=10
SCRIPT_DIR=$(dirname "$0")
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
INSTALLED_PACKAGES_FILE=$(mktemp)

# Fetch installed packages list
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE"

# Virtual repository map
declare -A virtual_repo_map
virtual_repo_map=(["baseos"]="ol9_baseos_latest" ["appstream"]="ol9_appstream" ["epel"]="ol9_developer_EPEL")

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
        echo ""
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
batch_counter=0
batch_packages=()

for line in "${package_lines[@]}"; do
    [ "$DEBUG_MODE" -ge 1 ] && echo "Processing line: $line"
    
    if [[ "$line" =~ ^Installed\ Packages$ ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping line: $line"
        continue
    fi
    
    if [[ "$line" =~ ^([^[:space:]]+)\.([^[:space:]]+)[[:space:]]+([^[:space:]]+)[[:space:]]+@([^[:space:]]+)$ ]]; then
        package_name=${BASH_REMATCH[1]}
        package_arch=${BASH_REMATCH[2]}
        package_version=${BASH_REMATCH[3]}
        package_repo=${BASH_REMATCH[4]}

        [ "$DEBUG_MODE" -ge 1 ] && echo "Matched package: $package_name, Version: $package_version, Repo: $package_repo"

        repo_path=$(get_repo_path "$package_repo")
        if [[ -n "$repo_path" ]]; then
            used_directories["$repo_path"]=1
            batch_packages+=("$package_name||$package_version|$package_arch|$repo_path")
        fi

        [ "$DEBUG_MODE" -ge 1 ] && echo "Before incrementing batch_counter: $batch_counter"
        ((batch_counter++))
        [ "$DEBUG_MODE" -ge 1 ] && echo "After incrementing batch_counter: $batch_counter"

        if (( MAX_PACKAGES > 0 )); then
            ((package_counter++))
            if (( package_counter >= MAX_PACKAGES )); then
                echo "Processed $MAX_PACKAGES packages. Stopping."
                break
            fi
        fi

        if (( batch_counter >= BATCH_SIZE )); then
            break
        fi
    fi
done

# Wait for any background jobs to finish
wait_for_jobs() {
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL_JOBS )); do
        sleep 1
    done
}

if (( batch_counter > 0 )); then
    for batch in "${batch_packages[@]}"; do
        ./process-package.sh "$DEBUG_MODE" "$batch" &
        wait_for_jobs
    done
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
