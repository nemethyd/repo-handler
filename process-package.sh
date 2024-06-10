#!/bin/bash

DEBUG_MODE=$1
shift
packages=("$@")

# If debug mode is 2, start bashdb
if [ "$DEBUG_MODE" -eq 2 ]; then
    exec bashdb "$0" "$DEBUG_MODE" "${packages[@]}"
fi

# If debug mode is 3, enable tracing
if [ "$DEBUG_MODE" -ge 3 ]; then
    set -x
fi

# Function to determine the status of a package
get_package_status() {
    local package_name=$1
    local package_version=$2
    local repo_path=$3

    if [[ $package_version =~ ([0-9]+):(.+) ]]; then
        local version=${BASH_REMATCH[2]}
    else
        local version=$package_version
    fi

    local package_pattern="${repo_path}/${package_name}-${version}*.rpm"

    if compgen -G "$package_pattern" > /dev/null; then
        echo "EXISTS"
    elif compgen -G "$repo_path/${package_name}"*.rpm > /dev/null; then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Function to download packages
download_packages() {
    local packages=("$@")
    local repo_path
    local package_name
    local package_version

    declare -A repo_packages

    for pkg in "${packages[@]}"; do
        IFS="@" read -r pkg_info repo_path <<< "$pkg"
        IFS="-" read -r package_name package_version <<< "$pkg_info"

        repo_packages["$repo_path"]+="$package_name-$package_version "
    done

    for repo_path in "${!repo_packages[@]}"; do
        # Ensure the getPackage subdirectory exists
        mkdir -p "$repo_path"
        if [ $? -ne 0 ]; then
            echo "Failed to create directory: $repo_path" >&2
            exit 1
        fi

        # Download packages
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
        fi
        dnf download --arch=x86_64,noarch --destdir="$repo_path" --resolve ${repo_packages[$repo_path]} 2>&1 | grep -v "metadata expiration check"
        if [ $? -ne 0 ]; then
            echo "Failed to download packages: ${repo_packages[$repo_path]}" >&2
            exit 1
        fi
    done
}

# Handle the packages based on their status
for pkg in "${packages[@]}"; do
    IFS="@" read -r pkg_info repo_path <<< "$pkg"
    IFS="-" read -r package_name package_version <<< "$pkg_info"

    package_status=$(get_package_status "$package_name" "$package_version" "$repo_path")
    if [ $? -ne 0 ]; then
        echo "Failed to determine status for package: $package_name-$package_version" >&2
        exit 1
    fi

    case $package_status in
        "EXISTS")
            echo -e "\e[32m$repo_path: $package_name-$package_version is already there.\e[0m"
            ;;
        "NEW")
            echo -e "\e[33mDownloading new package: $package_name-$package_version...\e[0m"
            ;;
        "UPDATE")
            echo -e "\e[34mUpdating package: $package_name-$package_version...\e[0m"
            remove_existing_packages "$package_name" "$repo_path"
            if [ $? -ne 0 ]; then
                echo "Failed to remove existing packages for: $package_name" >&2
                exit 1
            fi
            ;;
        *)
            echo -e "\e[31mError: Unknown package status '$package_status' for $package_name-$package_version.\e[0m"
            ;;
    esac
done

# Download all packages in batch
download_packages "${packages[@]}"
if [ $? -ne 0 ]; then
    echo "Failed to download packages in batch." >&2
    exit 1
fi
