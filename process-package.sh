#!/bin/bash

DEBUG_MODE=$1
[ "$DEBUG_MODE" -gt 0 ] && echo "process-package.sh started with parameters: $*"  # Add debug output to see parameters

shift
packages=("$@")

# If debug mode is 2, start bashdb
[ "$DEBUG_MODE" -eq 2 ] && exec bashdb "$0" "$DEBUG_MODE" "${packages[@]}"

# If debug mode is 3, enable tracing
[ "$DEBUG_MODE" -ge 3 ] && set -x

# Function to determine the status of a package
get_package_status() {
    local package_name=$1
    local epoch=$2
    local package_version=$3
    local repo_path=$4

    [ "$DEBUG_MODE" -ge 1 ] && echo "name=$package_name epoch=$epoch version=$package_version path=$repo_path" >&2

    if [[ -n "$epoch" ]]; then
        local package_pattern="${repo_path}/${package_name}-${epoch}:${package_version}*.rpm"
    else
        local package_pattern="${repo_path}/${package_name}-${package_version}*.rpm"
    fi

    if compgen -G "$package_pattern" > /dev/null; then
        echo "EXISTS"
    elif compgen -G "${repo_path}/${package_name}-*.rpm" > /dev/null; then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Function to remove existing package files
remove_existing_packages() {
    local package_name=$1
    local repo_path=$2

    echo "Removing existing packages for $package_name from $repo_path"
    rm -f "$repo_path/${package_name}-*.rpm"
}

# Function to download packages
download_packages() {
    local packages=("$@")
    local repo_path
    local package_name
    local package_version
    local epoch

    declare -A repo_packages

    for pkg in "${packages[@]}"; do
        IFS="@" read -r pkg_info repo_path <<< "$pkg"
        IFS="|" read -r package_name epoch package_version <<< "$pkg_info"
        if [[ -n "$epoch" ]]; then
            repo_packages["$repo_path"]+="$package_name-$epoch:$package_version "
        else
            repo_packages["$repo_path"]+="$package_name-$package_version "
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
    IFS="@" read -r pkg_info repo_path <<< "$pkg"
    IFS="|" read -r package_name epoch package_version <<< "$pkg_info"

    package_status=$(get_package_status "$package_name" "$epoch" "$package_version" "$repo_path")
    [ $? -ne 0 ] && { echo "Failed to determine status for package: $package_name-$epoch:$package_version" >&2; exit 1; }

    case $package_status in
        "EXISTS")
            echo -e "\e[32m$repo_path: $package_name-$epoch:$package_version exists.\e[0m"
            ;;
        "NEW")
            echo -e "\e[33mDownloading new package: $package_name-$epoch:$package_version...\e[0m"
            if ! download_packages "$pkg"; then
                echo "Failed to download new package: $package_name-$epoch:$package_version" >&2
                exit 1
            fi
            ;;
        "UPDATE")
            echo -e "\e[34mUpdating package: $package_name-$epoch:$package_version...\e[0m"
            if ! remove_existing_packages "$package_name" "$repo_path" || ! download_packages "$pkg"; then
                echo "Failed to update package: $package_name-$epoch:$package_version" >&2
                exit 1
            fi
            ;;
        *)
            echo -e "\e[31mError: Unknown package status '$package_status' for $package_name-$epoch:$package_version.\e[0m"
            ;;
    esac
done

# Download all packages in batch
if ! download_packages "${packages[@]}"; then
    echo "Failed to download packages in batch." >&2
    exit 1
fi
