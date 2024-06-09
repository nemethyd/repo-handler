#!/bin/bash

DEBUG_MODE=$1
package_name=$2
package_version=$3
package_repo=$4
repo_path=$5
LOCAL_REPO_PATH=$6

# If debug mode is 2, start bashdb
if [ "$DEBUG_MODE" -eq 2 ]; then
    exec bashdb "$0" "$DEBUG_MODE" "$package_name" "$package_version" "$package_repo" "$repo_path" "$LOCAL_REPO_PATH"
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

    # Extract the epoch if present
    if [[ $package_version =~ ([0-9]+):(.+) ]]; then
        local version=${BASH_REMATCH[2]}
    else
        local version=$package_version
    fi

    # Construct the full package filename pattern
    local package_pattern="${repo_path}/getPackage/${package_name}-${version}*.rpm"

    # Debug output for package pattern
    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "Package: $package_name, Version: $package_version, Epoch: ${BASH_REMATCH[1]}, Pattern: $package_pattern" >&2
    fi

    # Determine package status
    if compgen -G "$package_pattern" > /dev/null; then
        echo "EXISTS"
    elif compgen -G "$repo_path/getPackage/${package_name}"*.rpm > /dev/null; then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Function to download a package
download_package() {
    local package_name=$1
    local package_version=$2
    local repo_path=$3

    # Ensure the getPackage subdirectory exists
    mkdir -p "$repo_path/getPackage"

    # Debug output for package downloading
    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "Downloading $package_name-$package_version to $repo_path/getPackage"
    fi

    # Suppress metadata expiration message by filtering it out
    dnf download --arch=x86_64,noarch --destdir="$repo_path/getPackage" --resolve "$package_name-$package_version" | grep -v "metadata expiration check"

    if [[ $? -eq 0 ]]; then
        # Debug output for package downloading
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Download successful for $package_name-$package_version"
        fi
        for file in "$repo_path/getPackage/${package_name}-${package_version}"*.rpm; do
            echo "$file"
        done
    else
        echo "Download failed for $package_name-$package_version"
    fi
}

# Function to remove existing package files
remove_existing_packages() {
    local package_name=$1
    local repo_path=$2

    echo "Removing existing packages for $package_name from $repo_path/getPackage"
    rm -f "$repo_path/getPackage/${package_name}"*.rpm
}

# Main processing logic
repo_path=$(dirname "$repo_path")  # Ensure repo_path points to the correct directory

# Determine the package status
package_status=$(get_package_status "$package_name" "$package_version" "$repo_path")

# Handle the package based on its status
case $package_status in
    "EXISTS")
        echo "$repo_path: $package_name-$package_version is already there."
        ;;
    "NEW")
        echo -n -e "\e[33m"
        download_package "$package_name" "$package_version" "$repo_path"
        echo -n -e "\e[0m"
        ;;
    "UPDATE")
        echo -n -e "\e[34m"
        remove_existing_packages "$package_name" "$repo_path"
        download_package "$package_name" "$package_version" "$repo_path"
        echo -n -e "\e[0m"
        ;;
    *)
        echo -e "\e[31mError: Unknown package status '$package_status' for $package_name-$package_version.\e[0m"
        ;;
esac
