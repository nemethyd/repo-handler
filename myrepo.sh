#!/bin/bash

# Set debugging mode based on DEBUG_MODE environment variable
DEBUG_MODE=${DEBUG_MODE:-0}

# Enable tracing if in tracing mode
if [ "$DEBUG_MODE" -ge 3 ]; then
    set -x
fi

# Set the maximum number of packages to process
MAX_PACKAGES=${MAX_PACKAGES:-0}

# Set the maximum number of parallel jobs
MAX_PARALLEL_JOBS=4

# Break at any error
set -e

# Reset echo
echo -e "\e[0m"

# Determine the directory of the current script
SCRIPT_DIR=$(dirname "$BASH_SOURCE")

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
    local package_repo=$1

    if [[ -n "${virtual_repo_map[$package_repo]}" ]]; then
        echo "$LOCAL_REPO_PATH/${virtual_repo_map[$package_repo]}/getPackage"
    else
        echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
    fi
}

# Initialize an array to track used directories and identified packages
declare -A used_directories
declare -A identified_packages

# Collect the initial list of RPM files in the repository directories
echo "Collecting initial list of RPM files..."
initial_rpm_files=($(find "$LOCAL_REPO_PATH"/ol9_* -type f -path "*/getPackage/*.rpm"))

# Read all lines into an array
mapfile -t package_lines < "$INSTALLED_PACKAGES_FILE"

# Iterate over the installed packages list
echo "Processing installed packages..."

# Counter to limit the number of packages processed, only if MAX_PACKAGES is set
package_counter=0

# Function to wait for jobs if the number of jobs exceeds MAX_PARALLEL_JOBS
wait_for_jobs() {
    while (( $(jobs | wc -l) >= MAX_PARALLEL_JOBS )); do
        sleep 1
    done
}

for line in "${package_lines[@]}"; do
    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "Processing line: $line" >&2  # Debugging output
    fi

    # Skip lines that do not contain package information
    if [[ $line =~ ^Installed\ Packages$ || $line =~ ^Waiting ]]; then
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Skipping line: $line" >&2  # Debugging output
        fi
        continue
    fi

    # Extract package name, version, and repository
    if [[ $line =~ ^([^\ ]+)\.([^\ ]+)\ +([^\ ]+)\ +@([^\ ]+) ]]; then
        package_name=${BASH_REMATCH[1]}
        package_version=${BASH_REMATCH[3]}
        package_repo=${BASH_REMATCH[4]}

        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Matched package: $package_name, Version: $package_version, Repo: $package_repo" >&2  # Debugging output
        fi

        # Determine the actual repository path
        repo_path=$(get_repo_path "$package_repo")

        # Track the used directory
        used_directories["$repo_path"]=1

        # Wait for jobs if needed
        wait_for_jobs

        # Run the processing script in the background
        "$SCRIPT_DIR/process-package.sh" "$DEBUG_MODE" "$package_name" "$package_version" "$package_repo" "$repo_path" "$LOCAL_REPO_PATH" &

        # Increment the package counter if MAX_PACKAGES is set
        if (( MAX_PACKAGES > 0 )); then
            package_counter=$((package_counter + 1))
            if (( package_counter >= MAX_PACKAGES )); then
                echo "Processed $MAX_PACKAGES packages. Stopping." >&2  # Debugging output
                break
            fi
        fi
    else
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "No match for line: $line" >&2  # Debugging output
        fi
    fi
done

# Wait for all background jobs to finish
wait

echo "All packages have been processed."

# Remove obsolete packages
echo "Removing obsolete packages..."
for file in "${initial_rpm_files[@]}"; do
    if [[ -z "${identified_packages["$file"]}" ]]; then
        echo "Removing obsolete package $file"
        rm -f "$file"
    fi
done

# Echo the used directories
echo "Updating repositories in used directories..."
for dir in "${!used_directories[@]}"; do
    # Get the parent directory of getPackage to update the repository
    parent_dir=$(dirname "$dir")
    echo "Updating repository at $parent_dir..."
    createrepo --update "$parent_dir"
done

# Cleanup
rm "$INSTALLED_PACKAGES_FILE"

echo "All packages have been processed and repositories have been updated."
