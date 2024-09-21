#!/bin/bash

# Version: 1.1
# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT 4o
# Date: 2024-09-21
#
# MIT licensing
# Script purpose:
# This script cleans up local repositories by removing older versions of packages,
# regenerates metadata using createrepo, and synchronizes the cleaned repositories
# with a shared repository location.
#
# Usage:
# - Make sure you have the required permissions to modify the local and shared repo paths.
# - Adjust the LOCAL_REPO_BASE and SHARED_REPO_BASE if your repository paths are different.
# - Ensure the rsync command uses the --delete flag to remove old files from the shared repository.

# Base directory for local repositories
LOCAL_REPO_BASE="/repo"
SHARED_REPO_BASE="/mnt/hgfs/VMware/ol9_repos"

# List of repositories to clean and sync
REPOS=("ol9_addons" "ol9_baseos_latest" "ol9_developer_EPEL" 
       "ol9_appstream" "ol9_codeready_builder" "ol9_distro_builder" "ol9_UEKR7")

# Function to remove old versions of packages and keep only the latest version
clean_repo() {
    local repo_path=$1

    echo "Cleaning repository: $repo_path"

    # Find all RPM files in the repo
    find "$repo_path" -type f -name "*.rpm" | while read -r rpm_file; do
        # Extract package name and version info from the RPM file
        package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file")
        package_version=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm_file")

        # Find all versions of the same package
        package_files=$(find "$repo_path" -name "${package_name}-*.rpm")

        # Sort package files by version (latest version should come last)
        sorted_files=$(printf "%s\n" $package_files | sort -V)

        # Get the latest file
        latest_file=$(echo "$sorted_files" | tail -n 1)

        # Remove all older versions, except the latest
        for file in $sorted_files; do
            if [ "$file" != "$latest_file" ]; then
                echo "Removing old version: $file"
                rm -f "$file"
            fi
        done
    done

    echo "Cleanup complete for $repo_path."
}

# Function to regenerate repository metadata with createrepo
update_repo_metadata() {
    local repo_path=$1
    echo "Updating repository metadata for: $repo_path"
    createrepo --update "$repo_path"
}

# Function to sync the local repo with the shared repo
sync_repo() {
    local repo_path=$1
    local shared_repo_path=$2

    # Create the target directory if it doesn't exist
    if [ ! -d "$shared_repo_path" ]; then
        echo "Creating directory $shared_repo_path"
        mkdir -p "$shared_repo_path"
    fi

    echo "Syncing $repo_path with $shared_repo_path"
    # Use rsync to synchronize local repo with the shared repo
    rsync -av --delete "$repo_path/" "$shared_repo_path/"
}

# Main loop to clean, update metadata, and sync each repository
for repo in "${REPOS[@]}"; do
    local_repo_path="$LOCAL_REPO_BASE/$repo"
    shared_repo_path="$SHARED_REPO_BASE/$repo"

    # Check if the local repo directory exists
    if [[ -d "$local_repo_path" ]]; then
        # Clean the repository
        clean_repo "$local_repo_path"

        # Update repository metadata
        update_repo_metadata "$local_repo_path"

        # Sync with the shared repository
        sync_repo "$local_repo_path" "$shared_repo_path"
    else
        echo "Repository path $local_repo_path does not exist, skipping."
    fi
done

echo "All repositories have been cleaned, updated, and synced."

