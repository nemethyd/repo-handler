#!/bin/bash

# Script version
VERSION=2.26

# Parse options
DEBUG_MODE=0
PACKAGES=""
LOCAL_REPOS=""

while [[ "$1" =~ ^-- ]]; do
    case "$1" in
        --debug-level)
            shift
            DEBUG_MODE=$1
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
            echo "Usage: process-package.sh [--debug-level LEVEL] --packages \"PACKAGES\" --local-repos \"REPOS\""
            echo "Options:"
            echo "  --debug-level LEVEL  Set the debug level (default: 0)"
            echo "  --packages \"PACKAGES\"  Set the packages to process (required)"
            echo "  --local-repos \"REPOS\"   Set the local repositories (required)"
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

[ "$DEBUG_MODE" -gt 0 ] && echo "process-package.sh started with packages: $PACKAGES and local repos: $LOCAL_REPOS"

IFS=' ' read -r -a packages <<< "$PACKAGES"
IFS=' ' read -r -a local_repos <<< "$LOCAL_REPOS"

# If debug mode is 2, start bashdb
[ "$DEBUG_MODE" -eq 2 ] && exec bashdb "$0" "$DEBUG_MODE" "${packages[@]}"

# If debug mode is 3, enable tracing
[ "$DEBUG_MODE" -ge 3 ] && set -x

# Function to determine the status of a package
get_package_status() {
    local repo_name=$1
    local package_name=$2
    local epoch=$3
    local package_version=$4
    local package_arch=$5
    local repo_path=$6

    [ "$DEBUG_MODE" -ge 1 ] && echo "repo=$repo_name name=$package_name epoch=$epoch version=$package_version arch=$package_arch path=$repo_path" >&2

    local package_pattern="${repo_path}/${package_name}-${package_version}.${package_arch}.rpm"

    if compgen -G "$package_pattern" >> process_package.log; then
        echo "EXISTS"
    elif compgen -G "${repo_path}/${package_name}-${epoch}:${package_version}.${package_arch}.rpm" >> process_package.log; then
        echo "EXISTS"
    elif compgen -G "${repo_path}/${package_name}-*.rpm" >> process_package.log; then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Function to remove existing package files
remove_existing_packages() {
    local package_name=$1
    local repo_path=$2

    #echo "Removing existing packages for $package_name from $repo_path"
    rm -f "$repo_path/${package_name}-*.rpm"
}

# Function to download packages
download_packages() {
    local packages=("$@")
    local repo_path
    local package_name
    local package_version
    local package_arch
    local epoch

    declare -A repo_packages

    for pkg in "${packages[@]}"; do
        IFS='|' read -r repo_name package_name epoch package_version package_arch repo_path <<< "$pkg"
        [ -n "$epoch" ] && package_version="${epoch}:${package_version}"
        if [ -n "$repo_path" ]; then
            if [[ ! " ${local_repos[*]} " =~ " ${repo_name} " ]]; then
                repo_packages["$repo_path"]+="$package_name-$package_version.$package_arch "
            fi
        fi
    done

    for repo_path in "${!repo_packages[@]}"; do
        mkdir -p "$repo_path" || { echo "Failed to create directory: $repo_path" >&2; exit 1; }

        [ "$DEBUG_MODE" -ge 1 ] && echo "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
        if ! dnf download --arch=x86_64,noarch --destdir="$repo_path" --resolve ${repo_packages[$repo_path]} 2>&1 | grep -v "metadata expiration check"; then
            echo "Failed to download packages: ${repo_packages[$repo_path]}" >&2
            return 1
        fi
    done
}

# Handle the packages based on their status
for pkg in "${packages[@]}"; do
    IFS='|' read -r repo_name package_name epoch package_version package_arch repo_path <<< "$pkg"

    # Skip processing if repo_path is empty
    if [[ -z "$repo_path" ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping package with empty repo_path: $package_name"
        continue
    fi

    package_status=$(get_package_status "$repo_name" "$package_name" "$epoch" "$package_version" "$package_arch" "$repo_path")
    [ $? -ne 0 ] && { echo "Failed to determine status for package: $package_name-$package_version" >&2; exit 1; }

    case $package_status in
        "EXISTS")
            echo -e "\e[32m$repo_name: $package_name-$package_version.$package_arch exists.\e[0m"
            ;;
        "NEW")
            if [[ ! " ${local_repos[*]} " =~ " ${repo_name} " ]]; then
                echo -e "\e[33m$repo_name:$(download_packages "$pkg")\e[0m"
            else
                echo -e "\e[33m$repo_name: Skipping download for local package $package_name-$package_version.$package_arch.\e[0m"
            fi
            ;;
        "UPDATE")
            if [[ ! " ${local_repos[*]} " =~ " ${repo_name} " ]]; then
                remove_existing_packages "$package_name" "$repo_path"
                echo -e "\e[34m$repo_name:$(download_packages "$pkg")\e[0m"
            else
                echo -e "\e[34m$repo_name: Skipping download for local package $package_name-$package_version.$package_arch.\e[0m"
            fi
            ;;
        *)
            echo -e "\e[31mError: Unknown package status '$package_status' for $repo_name::$package_name-$package_version.$package_arch.\e[0m"
            ;;
    esac
done
