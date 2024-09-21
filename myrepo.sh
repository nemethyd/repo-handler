#!/bin/bash

# Version: 2.32
# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT-4
# Date: 2024-09-21
#
# MIT licensing
# Purpose: 
# This script replicates and updates a local repository from installed packages 
# and synchronizes it with a shared repository, handling updates and cleanup of 
# older package versions.
#
# Usage:
# - Set the appropriate local and shared repo paths.
# - This script processes packages installed on the system and replicates them 
#   to the local repository, ensuring the latest versions are always kept.
# - Finally, it syncs the cleaned local repository with the shared repository.

# Script version
VERSION=2.32

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

# Main loop processing the lines
for line in "${package_lines[@]}"; do
    if [[ "$line" =~ ^([^.]+)\.([^\ ]+)\ +([^\ ]+)\ +@([^\ ]+)[[:space:]]*$ ]]; then
        package_name=${BASH_REMATCH[1]}    
        package_arch=${BASH_REMATCH[2]}    
        full_version=${BASH_REMATCH[3]}    
        package_repo=${BASH_REMATCH[4]}    

        if [[ "$full_version" =~ ^([0-9]+):(.*)$ ]]; then
            epoch_version=${BASH_REMATCH[1]}    
            package_version=${BASH_REMATCH[2]}  
        else
            epoch_version=""                    
            package_version=$full_version       
        fi

        if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
            package_repo=$(determine_repo_source "$package_name" "$package_version" "$package_arch")
        fi

        if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
            continue
        fi

        repo_path=$(get_repo_path "$package_repo")
        repo_name=$(get_repo_name "$package_repo")

        if [[ -n "$repo_path" ]]; then
            used_directories["$repo_name"]="$repo_path"
            batch_packages+=("$repo_name|$package_name|$epoch_version|$package_version|$package_arch|$repo_path")
        else
            continue
        fi

        ((package_counter++))
        if (( MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES )); then
            break
        fi

        if (( ${#batch_packages[@]} >= BATCH_SIZE )); then
            "$SCRIPT_DIR"/process-package.sh --debug-level "$DEBUG_MODE" --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}" &
            batch_packages=()
            wait_for_jobs
        fi
    fi
done

# Process any remaining packages in the last batch
if (( ${#batch_packages[@]} > 0 )); then
    "$SCRIPT_DIR/process-package.sh" --debug-level "$DEBUG_MODE" --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}"
fi

# Function to remove uninstalled packages from the repo
remove_uninstalled_packages() {
    local repo_path="$1"
    
    echo "Checking for uninstalled packages in: $repo_path"
    
    # Find all RPM files in the repo
    find "$repo_path" -type f -name "*.rpm" | while read -r rpm_file; do
        package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file")
        package_version=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm_file")
        package_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file")
        
        # Check if the package is installed on the golden copy machine
        if ! grep -q "${package_name}.${package_arch}" "$INSTALLED_PACKAGES_FILE"; then
            echo "Removing uninstalled package: $package_name-$package_version.$package_arch from $repo_path"
            rm -f "$rpm_file"
        fi
    done
}

# Remove uninstalled packages from each repo
for repo in "${LOCAL_REPOS[@]}"; do
    local_repo_path="$LOCAL_REPO_PATH/$repo"
    
    if [[ -d "$local_repo_path" ]]; then
        remove_uninstalled_packages "$local_repo_path"
    else
        echo "Repository path $local_repo_path does not exist, skipping."
    fi
done

# Update and sync the repositories
if (( MAX_PACKAGES == 0 )); then
    for dir in "${!used_directories[@]}"; do
        parent_dir=$(dirname "$dir")
        createrepo --update "$parent_dir"
    done

    rsync -av --delete "$LOCAL_REPO_PATH/" "$SHARED_REPO_PATH/"
fi

# Clean up
rm "$INSTALLED_PACKAGES_FILE"

echo "myrepo.sh Version $VERSION completed."

