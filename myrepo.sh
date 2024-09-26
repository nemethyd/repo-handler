#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT-4
# Date: 2024-09-28

# MIT licensing
# Purpose:
# This script replicates and updates a local repository from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# older package versions.

# Script version
VERSION=2.57
echo "$0 Version $VERSION"

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${MAX_PACKAGES:=0}"
: "${BATCH_SIZE:=10}"
: "${MAX_PARALLEL_JOBS:=1}"
: "${DRY_RUN:=0}"
: "${NO_SUDO}"

# Configuration
SCRIPT_DIR=$(dirname "$0")
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
INSTALLED_PACKAGES_FILE="/tmp/installed_packages.lst"
# Declare a file to keep track of processed packages
PROCESSED_PACKAGES_FILE="/tmp/processed_packages.share"
[[ $DEBUG_MODE -ge 1 ]] && echo "PROCESSED_PACKAGES_FILE=$PROCESSED_PACKAGES_FILE"

# Ensure that the files exist, then truncate them
touch locally_found.lst myrepo.err process_package.log "$PROCESSED_PACKAGES_FILE" "$INSTALLED_PACKAGES_FILE"

: >locally_found.lst
: >myrepo.err
: >process_package.log
: >"$PROCESSED_PACKAGES_FILE"
: >"$INSTALLED_PACKAGES_FILE"

# Local repos updated to contain only the required ones
LOCAL_REPOS=("ol9_edge" "pgdg-common" "pgdg16")
RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Parse options
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
    --max-packages)
        shift
        MAX_PACKAGES=$1
        ;;
    --no-sudo)
        NO_SUDO=1
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
        echo "Usage: myrepo.sh [--debug-level LEVEL] [--max-packages NUM] [--batch-size NUM] [--parallel NUM] [--dry-run] [--no-sudo]"
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
    shift
done

# Check if script is run as root
if [[ -z $NO_SUDO && $EUID -ne 0 ]]; then
    echo "This script must be run as root or with sudo privileges." >&2
    exit 1
fi


# Calculate the parallel download factor by multiplying MAX_PARALLEL_JOBS and BATCH_SIZE
PARALLEL_DOWNLOADS=$((MAX_PARALLEL_JOBS * BATCH_SIZE))
# Cap the parallel downloads at a maximum of 20
if ((PARALLEL_DOWNLOADS > 20)); then
    PARALLEL_DOWNLOADS=20
fi

# Declare associative array for used_directories
declare -A used_directories
# Declare associative array for available packages in enabled repos
declare -A available_repo_packages

### Functions section in abc order ###

# Function to create a unique temporary file for each thread
create_temp_file() {
    mktemp /tmp/myrepo_"$(date +%s)"_$$.XXXXXX
}

# Function to determine the repository source of a package based on available packages
determine_repo_source() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_release=$4
    local package_arch=$5

    for repo in "${ENABLED_REPOS[@]}"; do
        # Reconstruct the expected package string
        local expected_package
        if [[ -n "$epoch_version" ]]; then
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

    echo "Invalid"  # Default to Invalid if no matching repo is found
}

# Function to download repository metadata and store in memory
download_repo_metadata() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Downloading repository metadata..."

    # For enabled repositories
    for repo in "${ENABLED_REPOS[@]}"; do
        echo "Fetching metadata for $repo..."
        available_repo_packages["$repo"]=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>myrepo.err)
        if [[ -z "${available_repo_packages[$repo]}" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching metadata for $repo" >>myrepo.err
        fi
    done

    # For local repositories
    declare -gA repo_cache  # Declare repo_cache globally to be used later
    for local_repo in "${LOCAL_REPOS[@]}"; do
        echo "Fetching metadata for local repo $local_repo..."
        repo_cache["$local_repo"]=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$local_repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>myrepo.err)
        if [[ -z "${repo_cache[$local_repo]}" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching metadata for local repo $local_repo" >>myrepo.err
        fi
    done
}

# Function to get the repository name
get_repo_name() {
    local package_repo=$1
    echo "$package_repo"
}

# Function to get the repository path
get_repo_path() {
    local package_repo=$1
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi

    # Construct the path based on repository name
    echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
}

# Function to check if a package exists in local sources
is_package_in_local_sources() {
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
# Function to remove uninstalled or removed packages from the repo
remove_uninstalled_packages() {
    local repo_path="$1"
    local repo_name
    repo_name=$(basename "$repo_path") # Extract repository name from path

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking for uninstalled or removed packages in: $repo_name"

    # Find all RPM files for the repository
    find "$repo_path" -type f -name "*.rpm" | while read -r rpm_file; do
        package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file" 2>>myrepo.err)
        package_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>>myrepo.err)

        # Check if the package is installed on the system using awk
        if ! awk -F'|' -v name="$package_name" -v arch="$package_arch" '$1 == name && $5 == arch' "$INSTALLED_PACKAGES_FILE" >/dev/null; then
            rpm_filename=$(basename "$rpm_file")
            if ((DRY_RUN)); then
                echo "$repo_name: $rpm_filename would be removed."
            else
                echo "$repo_name: $rpm_filename removed."
                rm -f "$rpm_file" && echo "Successfully removed $rpm_file" || echo "Failed to remove $rpm_file" >>myrepo.err
            fi
        else
            [[ $DEBUG_MODE -ge 1 ]] && echo "$repo_name: $(basename "$rpm_file") exists." >&2
        fi
    done
}

# Function to wait for background jobs to finish
wait_for_jobs() {
    local current_jobs

    while true; do
        current_jobs=$(jobs -rp | wc -l)  # Assign the number of running jobs
        if (( current_jobs >= MAX_PARALLEL_JOBS )); then
            echo "Waiting for jobs in $0 ... Currently running: ${current_jobs}/${MAX_PARALLEL_JOBS}" # Debugging line
            sleep 1
        else
            break
        fi
    done
}

### Main processing section ###

# Fetch installed packages list with detailed information
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."

if ! dnf repoquery --installed --qf '%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{repoid}' >"$INSTALLED_PACKAGES_FILE" 2>>myrepo.err; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching installed packages list." >>myrepo.err
    exit 1
fi

# Fetch the list of enabled repositories
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of enabled repositories..."
mapfile -t ENABLED_REPOS < <(dnf repolist enabled | awk 'NR>1 {print $1}')

if [[ ${#ENABLED_REPOS[@]} -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No enabled repositories found." >>myrepo.err
    exit 1
fi

# Download repository metadata for enabled repos
download_repo_metadata

# Read the installed packages list
mapfile -t package_lines <"$INSTALLED_PACKAGES_FILE"

# Processing installed packages
echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."
package_counter=0
batch_packages=()

# Main loop processing the lines
for line in "${package_lines[@]}"; do
    # Expected format: name|epoch|version|release|arch|repoid
    IFS='|' read -r package_name epoch_version package_version package_release package_arch package_repo <<<"$line"

    # If the package repo is System, @System, or @commandline, find the corresponding repo
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "@commandline" ]]; then
        package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
        if [[ $DEBUG_MODE -ge 1 ]]; then
            echo "Mapped $package_name to repo: $package_repo"
        fi
    fi

    pkg_key="${package_name}-${package_version}-${package_release}.${package_arch}"

    # Skip if the package has already been processed
    if grep -Fxq "$pkg_key" "$PROCESSED_PACKAGES_FILE"; then
        [[ $DEBUG_MODE -ge 1 ]] && echo "Package $pkg_key already processed, skipping."
        continue
    fi

    # Create a temporary file for this thread
    temp_file=$(create_temp_file)

    # Debugging: Print captured fields
    if [[ $DEBUG_MODE -ge 2 ]]; then
        echo "Captured: package_name=$package_name, epoch_version=$epoch_version, package_version=$package_version, package_release=$package_release, package_arch=$package_arch, package_repo=$package_repo" >&2
    fi

    # Determine repository source
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
        package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
        if [[ $DEBUG_MODE -ge 1 ]]; then
            echo "Determined repo for $package_name: $package_repo" >&2
        fi
    fi

    # Skip if repository is invalid or commandline
    if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
        [[ $DEBUG_MODE -ge 1 ]] && echo "Skipping package $package_name as it is marked as $package_repo" >&2
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
            echo "Adding to batch: $repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path" >&2
        fi
    else
        [[ $DEBUG_MODE -ge 1 ]] && echo "Package $package_name does not have a valid repository path" >&2
        continue
    fi

    ((package_counter++))
    if ((MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES)); then
        break
    fi

    # If batch size reached, process the batch
    if ((${#batch_packages[@]} >= BATCH_SIZE)); then
        [[ DEBUG_MODE -ge 1 ]] && echo "batch: ${batch_packages[*]}"
        "$SCRIPT_DIR"/process-package.sh --debug-level "$DEBUG_MODE" \
            --packages "${batch_packages[*]}" \
            --local-repos "${LOCAL_REPOS[*]}" \
            --processed-file "$PROCESSED_PACKAGES_FILE" \
            --temp-file "$temp_file" &

        batch_packages=()

        # Wait for background jobs to finish before starting a new batch
        # wait_for_jobs
    fi

done

# Process any remaining packages in the last batch
if ((${#batch_packages[@]} > 0)); then
    [[ DEBUG_MODE -ge 1 ]] && echo "batch: ${batch_packages[*]}"
    "$SCRIPT_DIR"/process-package.sh --debug-level "$DEBUG_MODE" \
        --packages "${batch_packages[*]}" \
        --local-repos "${LOCAL_REPOS[*]}" \
        --processed-file "$PROCESSED_PACKAGES_FILE" \
        --parallel "$MAX_PARALLEL_JOBS" \
        --temp-file "$temp_file" &
fi

# Remove uninstalled packages from each repo in parallel
echo "$(date '+%Y-%m-%d %H:%M:%S') - Removing uninstalled packages..."
for repo in "${!used_directories[@]}"; do
    repo_path="${used_directories[$repo]}"

    if [[ -d "$repo_path" ]]; then
        # Run remove_uninstalled_packages in the background
        remove_uninstalled_packages "$repo_path" &
        # wait_for_jobs
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Repository path $repo_path does not exist, skipping."
    fi
done

# Wait for all background jobs to finish
wait

# Update and sync the repositories
if [ "$MAX_PACKAGES" -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Updating repository metadata..."
    for repo in "${!used_directories[@]}"; do
        package_path="${used_directories[$repo]}"
        repo_path=$(dirname "$package_path")
        repo_name=$(basename "$repo_path")

        if ((DRY_RUN)); then
            echo "Dry Run: Would run 'createrepo --update $repo_path'"
        else
            [[ $DEBUG_MODE -ge 1 ]] && echo "Creating $repo_name repository indexes"

            if ! createrepo --update "$repo_path" >>process_package.log 2>>myrepo.err; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Error updating metadata for $repo" >>myrepo.err
            fi
        fi
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Synchronizing repositories..."
    if ((DRY_RUN)); then
        echo "Dry Run: Would run 'rsync -av --delete $LOCAL_REPO_PATH/ $SHARED_REPO_PATH/'"
    else
        if ! rsync -av --delete "$LOCAL_REPO_PATH/" "$SHARED_REPO_PATH/" >>process_package.log 2>>myrepo.err; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error synchronizing repositories." >>myrepo.err
        fi
    fi
fi

# Clean up
rm "$INSTALLED_PACKAGES_FILE"

echo "myrepo.sh Version $VERSION completed."
