#!/bin/bash

# Set debugging mode based on DEBUG_MODE environment variable
DEBUG_MODE=${DEBUG_MODE:-0}

# Enable tracing if in comprehensive debugging mode
if [ "$DEBUG_MODE" -ge 2 ]; then
    set -x
fi

# Set the maximum number of packages to process
MAX_PACKAGES=${MAX_PACKAGES:-0}

# Break at any error
set -e

# Set text color to default
echo -e "\e[0m"

# Determine the directory of the current script
SCRIPT_DIR="$(dirname "$BASH_SOURCE")"

# Local repository path
LOCAL_REPO_PATH="/mnt/hgfs/ForVMware"

# Temporary file to store the list of installed packages
INSTALLED_PACKAGES_FILE=$(mktemp)

# Get a list of all installed packages with their repository information
echo "Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE"

# Define the mapping of virtual repositories to actual repositories
declare -A virtual_repo_map
virtual_repo_map=( ["baseos"]="ol9_baseos_latest" ["appstream"]="ol9_appstream" )

# Function to determine the actual repository path
get_repo_path() {
    local package_repo="$1"
    if [[ -n "${virtual_repo_map[$package_repo]}" ]]; then
        echo "$LOCAL_REPO_PATH/${virtual_repo_map[$package_repo]}/getPackage"
    else
        echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
    fi
}

# Function to determine the status of a package
get_package_status() {
    local package_name="$1"
    local package_version="$2"
    local repo_path="$3"

    # Extract the epoch if present
    if [[ "$package_version" =~ ([0-9]+):(.+) ]]; then
        local version="${BASH_REMATCH[2]}"
    else
        local version="$package_version"
    fi

    # Construct the full package filename pattern
    local package_pattern="${repo_path}/${package_name}-${version}*.rpm"

    # Debug output for package pattern
    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "DEBUG: Package pattern: $package_pattern" >&2
    fi

    # Determine package status
    if ls "$package_pattern" >/dev/null 2>&1; then
        echo "EXISTS"
    else
        local update_pattern="${repo_path}/${package_name}*.rpm"
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "DEBUG: Update pattern: $update_pattern" >&2
        fi
        if ls "$update_pattern" >/dev/null 2>&1; then
            echo "UPDATE"
        else
            echo "NEW"
        fi
    fi
}

# Function to download a package
download_package() {
    local package_name="$1"
    local package_version="$2"
    local repo_path="$3"

    # Debug output for package downloading
    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "DEBUG: Downloading $package_name-$package_version to $repo_path" >&2
    fi
    # Suppress metadata expiration message by filtering it out
    dnf download --arch=x86_64,noarch --destdir="$repo_path" --resolve "$package_name-$package_version" | grep -v "metadata expiration check"

    if [[ $? -eq 0 ]]; then
        # Debug output for package downloading
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "DEBUG: Download successful for $package_name-$package_version" >&2
        fi
        for file in "$repo_path/${package_name}-${package_version}"*.rpm; do
            identified_packages["$file"]=1
        done
    else
        echo "Download failed for $package_name-$package_version"
    fi
}

# Function to remove existing package files
remove_existing_packages() {
    local package_name="$1"
    local repo_path="$2"

    echo "Removing existing packages for $package_name from $repo_path"
    rm -f "$repo_path/${package_name}"*.rpm
}

# Function to process a single package line (used by GNU Parallel)
process_package() {
    local line="$1"

    # Skip lines that do not contain package information
    if [[ "$line" =~ ^Installed\ Packages$ || "$line" =~ ^Waiting ]]; then
        return
    fi

    # Extract package name, version, and repository
    if [[ "$line" =~ ^([^\ ]+)\.([^\ ]+)\ +([^\ ]+)\ +@([^\ ]+) ]]; then
        local package_name="${BASH_REMATCH[1]}"
        local package_version="${BASH_REMATCH[3]}"
        local package_repo="${BASH_REMATCH[4]}"

        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "DEBUG: Package: $package_name, Version: $package_version, Repo: $package_repo" >&2
        fi

        # Determine the actual repository path
        local repo_path
        repo_path="$(get_repo_path "$package_repo")"

        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "DEBUG: Repository path: $repo_path" >&2
        fi

        # Track the used directory
        used_directories["$repo_path"]=1

        # Determine the package status
        local package_status
        package_status=$(get_package_status "$package_name" "$package_version" "$repo_path")

        # Handle the package based on its status
        case $package_status in
            "EXISTS")
                echo -e "\e[32m$package_repo: $package_name-$package_version is already there.\e[0m"
                for file in "$repo_path/${package_name}-${version}"*.rpm; do
                    if [ -f "$file" ]; then
                        identified_packages["$file"]=1
                        if [ "$DEBUG_MODE" -ge 1 ]; then
                            echo "DEBUG: Marked as identified: $file" >&2
                        fi
                    fi
                done
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

        # Increment the package counter if MAX_PACKAGES is set
        if (( MAX_PACKAGES > 0 )); then
            package_counter=$((package_counter + 1))
            if (( package_counter >= MAX_PACKAGES )); then
                echo "Processed $MAX_PACKAGES packages. Stopping."
                return
            fi
        fi
    else
        echo "DEBUG: No match for line: $line" >&2
    fi
}

# Initialize an array to track used directories and identified packages
declare -A used_directories
declare -A identified_packages

# Initialize package counter
package_counter=0

# Collect the initial list of RPM files in the repository directories
echo "Collecting initial list of RPM files..."
initial_rpm_files=()

# Find directories matching the pattern and then search for RPM files within them
echo "Look up directories:"
for dir in "$LOCAL_REPO_PATH"/ol9_*; do
    if [ -d "$dir" ]; then
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "DEBUG: Looking in directory $dir" >&2
        else
            echo "Look up: $dir" >&2
        fi
        while IFS= read -r -d $'\0' file; do
            initial_rpm_files+=("$file")
        done < <(find "$dir" -type f -path "*/getPackage/*.rpm" -print0)
    fi
done

# Export functions and variables needed by parallel jobs
export -f get_repo_path get_package_status download_package remove_existing_packages process_package
export LOCAL_REPO_PATH DEBUG_MODE

# Process packages in parallel using GNU Parallel
grep -v '^Installed Packages$' "$INSTALLED_PACKAGES_FILE" | grep -v '^Waiting' | parallel -j "$(nproc)" --env LOCAL_REPO_PATH --env DEBUG_MODE process_package

# Update repositories in used directories
echo "Updating repositories in used directories..."
for dir in "${!used_directories[@]}"; do
    # Get the parent directory to update the repository
    parent_dir=$(dirname "$dir")
    echo "Updating repository at $parent_dir..."
    createrepo --update "$parent_dir"
done

# Remove obsolete packages
echo "Removing obsolete packages..."
for file in "${initial_rpm_files[@]}"; do
    if [[ -z "${identified_packages["$file"]}" ]]; then
        echo "Removing obsolete package $file"
        rm -f "$file"
    fi
done

# Cleanup
rm "$INSTALLED_PACKAGES_FILE"

echo "All packages have been processed and repositories have been updated."

