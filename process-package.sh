#!/bin/bash

# Version: 2.45
# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT-4
# Date: 2024-09-26
#
# MIT licensing
# Purpose:
# This script processes packages in batches and checks their status within a local
# repository. If a package is outdated, it removes the older versions and downloads
# the latest version from the enabled repositories.
#
# Usage:
# - This script is called by the main `myrepo.sh` script with package and repository details.

# Script version
VERSION=2.45

# Parse options
DEBUG_MODE=0
DRY_RUN=0
PACKAGES=""
LOCAL_REPOS=""
LONGEST_REPO_NAME=0

# Minimum length for repo_name alignment
MIN_REPO_NAME_LENGTH=22  # Set a minimum length; adjust as needed
LONGEST_REPO_NAME=0

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
        --version)
            echo "process-package.sh Version $VERSION"
            exit 0
        ;;
        --help)
            echo "Usage: process-package.sh [--debug-level LEVEL] --packages \"PACKAGES\" --local-repos \"REPOS\" --dry-run"
            exit 0
        ;;
        *)
            echo "Unknown option: $1"
            exit 1
        ;;
    esac
    shift
done

IFS=' ' read -r -a packages <<< "$PACKAGES"
IFS=' ' read -r -a local_repos <<< "$LOCAL_REPOS"

# Determine the longest repo_name dynamically
for pkg in "${packages[@]}"; do
    IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<< "$pkg"
    repo_name_length=${#repo_name}
    if (( repo_name_length > LONGEST_REPO_NAME )); then
        LONGEST_REPO_NAME=$repo_name_length
    fi
done

# Set the final padding length (either the longest repo name or the minimum length)
PADDING_LENGTH=$(( LONGEST_REPO_NAME > MIN_REPO_NAME_LENGTH ? LONGEST_REPO_NAME : MIN_REPO_NAME_LENGTH ))

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

    if compgen -G "$package_pattern" > /dev/null; then
        echo "EXISTS"
        return
    elif [[ -n "$epoch" ]]; then
        local package_pattern_with_epoch="${repo_path}/${package_name}-${epoch}:${package_version}-${package_release}.${package_arch}.rpm"
        if compgen -G "$package_pattern_with_epoch" > /dev/null; then
            echo "EXISTS"
            return
        fi
    fi

    # Check if there are any packages with this name in the repo_path
    if compgen -G "${repo_path}/${package_name}-*.rpm" > /dev/null; then
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
    for file in "$repo_path/${package_name}-*.rpm"; do
        [ -e "$file" ] || continue
        local filename=$(basename "$file")

        # Extract the version-release
        file_version_release=$(rpm -qp --queryformat '%{EPOCH}:%{VERSION}-%{RELEASE}' "$file" 2>/dev/null)
        current_version_release="$epoch:$package_version-$package_release"

        # Compare versions
        if [[ "$file_version_release" < "$current_version_release" ]]; then
            if (( DRY_RUN )); then
                echo -e "\e[34m$(align_repo_name "$repo_name"): $filename would be removed (dry-run)\e[0m"
            else
                echo -e "\e[34m$(align_repo_name "$repo_name"): $filename removed\e[0m"
                rm -f "$file"
            fi
        fi
    done
}

# Function to download packages
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
        IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<< "$pkg"
        if [ -n "$epoch" ]; then
            package_version="${epoch}:${package_version}"
        fi
        if [ -n "$repo_path" ]; then
            if [[ ! " ${local_repos[*]} " =~ " ${repo_name} " ]]; then
                repo_packages["$repo_path"]+="$package_name-$package_version-$package_release.$package_arch "
            fi
        fi
    done

    for repo_path in "${!repo_packages[@]}"; do
        mkdir -p "$repo_path" || { echo "Failed to create directory: $repo_path" >&2; exit 1; }

        if (( DRY_RUN )); then
            echo "Dry Run: Would download packages to $repo_path: ${repo_packages[$repo_path]}"
        else
            [ "$DEBUG_MODE" -ge 1 ] && echo "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
            if ! dnf download --arch=x86_64,noarch --destdir="$repo_path" --resolve ${repo_packages[$repo_path]} 2>&1 | grep -v "metadata expiration check"; then
                echo "Failed to download packages: ${repo_packages[$repo_path]}" >&2
                return 1
            fi
        fi
    done
}

# Handle the packages based on their status
for pkg in "${packages[@]}"; do
    IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<< "$pkg"

    if [[ -z "$repo_path" ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping package with empty repo_path: $package_name" >&2
        continue
    fi

    package_status=$(get_package_status "$repo_name" "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch" "$repo_path")
    [ $? -ne 0 ] && { echo "Failed to determine status for package: $package_name-$package_version-$package_release" >&2; exit 1; }

    case $package_status in
        "EXISTS")
            echo -e "\e[32m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch exists.\e[0m"
            ;;
        "NEW")
            if [[ ! " ${local_repos[*]} " =~ " ${repo_name} " ]]; then
                echo -e "\e[33m$(align_repo_name "$repo_name"): Downloading $package_name-$package_version-$package_release.$package_arch\e[0m"
                download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
            else
                echo -e "\e[33m$(align_repo_name "$repo_name"): Skipping download for local package $package_name-$package_version-$package_release.$package_arch.\e[0m"
            fi
            ;;
        "UPDATE")
            if [[ ! " ${local_repos[*]} " =~ " ${repo_name} " ]]; then
                remove_existing_packages "$package_name" "$package_version" "$package_release" "$repo_path"
                echo -e "\e[34m$(align_repo_name "$repo_name"): Downloading $package_name-$package_version-$package_release.$package_arch\e[0m"
                download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
            else
                echo -e "\e[34m$(align_repo_name "$repo_name"): Skipping download for local package $package_name-$package_version-$package_release.$package_arch.\e[0m"
            fi
            ;;
        *)
            echo -e "\e[31mError: Unknown package status '$package_status' for $(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch.\e[0m"
            ;;
    esac
done
