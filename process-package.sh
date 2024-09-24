#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT-4
# Date: 2024-09-28

# MIT licensing
# Purpose:
# This script processes packages in batches and handles updates and cleanup of older package versions.

# Script version
VERSION=2.55

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${BATCH_SIZE:=10}"
: "${DRY_RUN:=0}"

PACKAGES=""
LOCAL_REPOS=""
PARALLEL_DOWNLOADS=1 # Default parallel downloads for dnf
PROCESSED_PACKAGES_FILE="/tmp/processed_packages.share"
LOCK_DIR="/tmp/package_process.lock.d"
LONGEST_REPO_NAME=22

# Parse arguments
while [[ "$1" =~ ^-- ]]; do
    case "$1" in
    --debug-level)
        shift
        DEBUG_MODE=$1
        ;;
    --dry-run)
        DRY_RUN=1
        ;;
    --packages)
        shift
        PACKAGES=$1
        ;;
    --local-repos)
        shift
        LOCAL_REPOS=$1
        ;;
    --lock-file)
        shift
        LOCK_FILE=$1
        ;;
    --no-sudo)
        NO_SUDO=1
        ;;
    --parallel)
        shift
        PARALLEL_DOWNLOADS=$1
        ;;
    --processed-file)
        shift
        PROCESSED_PACKAGES_FILE=$1
        ;;
    --temp-file)
        shift
        TEMP_FILE=$1
        ;;
    --version)
        echo "process-package.sh Version $VERSION"
        exit 0
        ;;
    --help)
        echo "Usage: process-package.sh [--debug-level LEVEL] --packages \"PACKAGES\" --local-repos \"REPOS\" --parallel NUM --processed-file FILE --lock-file FILE"
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

# Lock functions using atomic directory creation
acquire_lock() {
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        echo "Lock directory already exists. Another process may be running."
        exit 1
    fi
}

release_lock() {
    rmdir "$LOCK_DIR"
}

# Use trap to ensure release_lock is always called
# trap release_lock EXIT

# Acquiring the lock
# acquire_lock


# truncate PROCESSED_PACKAGES_FILE for debug level ==3
if [[ $DEBUG_MODE -eq 3 ]]; then
    : >"$PROCESSED_PACKAGES_FILE"
    : >"$PROCESSED_PACKAGES_FILE"
fi

# Function to wait for background jobs to finish
wait_for_jobs() {
    while (($(jobs -rp | wc -l) >= MAX_PARALLEL_JOBS)); do
        echo "Waiting for jobs in process_package ... Currently running: $(jobs -rp | wc -l)" # Debugging line
        sleep 1
    done
}

IFS=' ' read -r -a packages <<<"$PACKAGES"
IFS=' ' read -r -a local_repos <<<"$LOCAL_REPOS"

# Ensure a temporary file is set for the thread
if [[ -z "$TEMP_FILE" ]]; then
    echo "Error: Temporary file not provided. Creating one." >&2
    TEMP_FILE=$(mktemp)
    TEMP_FILE=$(mktemp)
fi

# Function to write log to the specific temporary file
log_to_temp_file() {
    echo "$1" >>"$TEMP_FILE"
}

# Example: Write debug information to the temp file
if [[ $DEBUG_MODE -ge 1 ]]; then
    log_to_temp_file "Debug Mode Active - Process PID: $$"
fi

# Function to safely track a processed package
track_processed_package() {
    local pkg_key="$1"
    (
        flock -x 200 # Exclusive lock
        echo "$pkg_key" >>"$PROCESSED_PACKAGES_FILE"
    ) 200>"$LOCK_FILE"
}

# Function to check if the package has already been processed
is_package_processed() {
    local pkg_key="$1"
    grep -Fxq "$pkg_key" "$PROCESSED_PACKAGES_FILE"
}

PADDING_LENGTH=$((LONGEST_REPO_NAME > MIN_REPO_NAME_LENGTH ? LONGEST_REPO_NAME : MIN_REPO_NAME_LENGTH))

# Function to align the output by padding the repo_name
align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

# Function to determine the status of a package
get_package_status() {
    local repo_name="$1"
    local package_name="$2"
    local epoch="$3"
    local package_version="$4"
    local package_release="$5"
    local package_arch="$6"
    local repo_path="$7"

    [ "$DEBUG_MODE" -ge 1 ] && echo "repo=$repo_name name=$package_name epoch=$epoch version=$package_version release=$package_release arch=$package_arch path=$repo_path" >&2

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

# Function to remove existing package files (ensures only older versions are removed)
remove_existing_packages() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local repo_path="$4"

    [ "$DEBUG_MODE" -ge 1 ] && echo "$(align_repo_name "$repo_name"): Removing older versions of $package_name from $repo_path" >&2

    # Find all RPM files for the package
    for file in "$repo_path/${package_name}"-*.rpm; do
        [ -e "$file" ] || continue
        local filename
        filename=$(basename "$file")

        # Extract the version-release
        file_version_release=$(rpm -qp --queryformat '%{EPOCH}:%{VERSION}-%{RELEASE}' "$file" 2>/dev/null)
        current_version_release="$epoch:$package_version-$package_release"

        # Compare versions
        if [[ "$file_version_release" < "$current_version_release" ]]; then
            if ((DRY_RUN)); then
                echo -e "\e[34m$(align_repo_name "$repo_name"): $filename would be removed (dry-run)\e[0m"
            else
                echo -e "\e[34m$(align_repo_name "$repo_name"): $filename removed\e[0m"
                rm -f "$file"
            fi
        fi
    done
}

# Download packages with parallel downloads
download_packages() {
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
        if [ -n "$epoch" ]; then
            package_version="${epoch}:${package_version}"
        fi
        if [ -n "$repo_path" ]; then
            if [[ ! " ${local_repos[*]} " =~ ${repo_name} ]]; then
            if [[ ! " ${local_repos[*]} " =~ ${repo_name} ]]; then
                repo_packages["$repo_path"]+="$package_name-$package_version-$package_release.$package_arch "
            fi
        fi
    done

    for repo_path in "${!repo_packages[@]}"; do
        mkdir -p "$repo_path" || {
            log_to_temp_file "Failed to create directory: $repo_path"
            exit 1
        }

        # Run download in background and wait for jobs if parallel limit is reached
        if ((DRY_RUN)); then
            log_to_temp_file "Dry Run: Would download packages to $repo_path: ${repo_packages[$repo_path]}"
        else
            {
                log_to_temp_file "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
                if ! dnf --setopt=max_parallel_downloads="$PARALLEL_DOWNLOADS" download --arch=x86_64,noarch --destdir="$repo_path" --resolve "${repo_packages[$repo_path]}" 1>>process_package.log 2>>myrepo.err; then
                    log_to_temp_file "Failed to download packages: ${repo_packages[$repo_path]}"
                    return 1
                fi
            } &
            wait_for_jobs # Control the number of parallel jobs
        fi
    done
}

# Handle the packages based on their status
for pkg in "${packages[@]}"; do
    IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<<"$pkg"

    pkg_key="${package_name}-${package_version}-${package_release}.${package_arch}"

    # Skip if already processed
    if is_package_processed "$pkg_key"; then
        [[ $DEBUG_MODE -ge 1 ]] && echo "Package $pkg_key already processed, skipping."
        continue
    fi

    if [[ -z "$repo_path" ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping package with empty repo_path: $package_name" >&2
        continue
    fi

    if ! package_status=$(get_package_status "$repo_name" "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch" "$repo_path"); then
        echo "Failed to determine status for package: $package_name-$package_version-$package_release" >&2
        exit 1
    fi

    case $package_status in
    "NEW" | "UPDATE")
        # Run download_packages in the background and control parallel jobs
        download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path" &
        # wait_for_jobs # Control the number of parallel jobs
        ;;
    esac
done

# Wait for all background jobs to complete before finishing the script
wait 


