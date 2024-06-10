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

# Set the batch size for processing packages
BATCH_SIZE=10

# Break at any error
set -e

# Reset echo
echo -e "\e[0m"

# Determine the directory of the current script
SCRIPT_DIR=$(dirname "$BASH_SOURCE")

# Local and shared repository paths
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"

# Temporary file to store the list of installed packages
INSTALLED_PACKAGES_FILE=$(mktemp)

echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to fetch the list of installed packages." >&2
    exit 1
fi

# Define the mapping of virtual repositories to actual repositories
declare -A virtual_repo_map
virtual_repo_map=(["baseos"]="ol9_baseos_latest" ["appstream"]="ol9_appstream" ["epel"]="ol9_developer_EPEL")

get_repo_path() {
    local package_repo=$1
    if [[ -n "${virtual_repo_map[$package_repo]}" ]]; then
        echo "$LOCAL_REPO_PATH/${virtual_repo_map[$package_repo]}/getPackage"
    else
        echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
    fi
}

declare -A used_directories
declare -A identified_packages

echo "$(date '+%Y-%m-%d %H:%M:%S') - Collecting initial list of RPM files..."
initial_rpm_files=($(find "$LOCAL_REPO_PATH"/ol9_* -type f -path "*/getPackage/*.rpm"))
if [ $? -ne 0 ]; then
    echo "Failed to collect the initial list of RPM files." >&2
    exit 1
fi

mapfile -t package_lines < "$INSTALLED_PACKAGES_FILE"
if [ $? -ne 0 ]; then
    echo "Failed to read the installed packages file." >&2
    exit 1
fi

echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."

package_counter=0
batch_counter=0
batch_packages=()

wait_for_jobs() {
    while (( $(jobs -r | wc -l) >= MAX_PARALLEL_JOBS )); do
        sleep 1
    done
}

for line in "${package_lines[@]}"; do
    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "Processing line: $line" >&2
    fi

    if [[ $line =~ ^Installed\ Packages$ || $line =~ ^Waiting ]]; then
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Skipping line: $line" >&2
        fi
        continue
    fi

    if [[ $line =~ ^([^\ ]+)\.([^\ ]+)\ +([^\ ]+)\ +@([^\ ]+) ]]; then
        package_name=${BASH_REMATCH[1]}
        package_version=${BASH_REMATCH[3]}
        package_repo=${BASH_REMATCH[4]}

        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Matched package: $package_name, Version: $package_version, Repo: $package_repo" >&2
        fi

        repo_path=$(get_repo_path "$package_repo")
        used_directories["$repo_path"]=1

        batch_packages+=("$package_name-$package_version@$repo_path")

        let batch_counter++
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "Batch counter: $batch_counter" >&2
        fi

        if (( batch_counter >= BATCH_SIZE )); then
            wait_for_jobs

            if [ "$DEBUG_MODE" -ge 1 ]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting process-package.sh for batch: ${batch_packages[@]}" >&2
            fi

            "$SCRIPT_DIR/process-package.sh" "$DEBUG_MODE" "${batch_packages[@]}" &> "process-package-${batch_counter}.log" &
            if [ $? -ne 0 ]; then
                echo "Failed to start process-package.sh for batch." >&2
                exit 1
            fi

            batch_packages=()
            batch_counter=0
        fi

        if (( MAX_PACKAGES > 0 )); then
            let package_counter++
            if (( package_counter >= MAX_PACKAGES )); then
                echo "Processed $MAX_PACKAGES packages. Stopping." >&2
                break
            fi
        fi
    else
        if [ "$DEBUG_MODE" -ge 1 ]; then
            echo "No match for line: $line" >&2
        fi
    fi
done

# Process any remaining packages in the batch
if (( batch_counter > 0 )); then
    wait_for_jobs

    if [ "$DEBUG_MODE" -ge 1 ]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting process-package.sh for remaining batch: ${batch_packages[@]}" >&2
    fi

    "$SCRIPT_DIR/process-package.sh" "$DEBUG_MODE" "${batch_packages[@]}" &> "process-package-final.log" &
    if [ $? -ne 0 ]; then
        echo "Failed to start process-package.sh for remaining batch." >&2
        exit 1
    fi
fi

# Wait for all background jobs to finish
wait

echo "$(date '+%Y-%m-%d %H:%M:%S') - All packages have been processed."

echo "Removing obsolete packages..."
for file in "${initial_rpm_files[@]}"; do
    if [[ -z "${identified_packages["$file"]}" ]]; then
        echo "Removing obsolete package $file"
        rm -f "$file"
    fi
done

echo "Updating repositories in used directories..."
for dir in "${!used_directories[@]}"; do
    parent_dir=$(dirname "$dir")
    echo "Updating repository at $parent_dir..."
    createrepo --update "$parent_dir"
done

rm "$INSTALLED_PACKAGES_FILE"

echo "Syncing $SHARED_REPO_PATH with $LOCAL_REPO_PATH..."
rsync -av --delete "$LOCAL_REPO_PATH/" "$SHARED_REPO_PATH/"
if [ $? -eq 0 ]; then
    echo "Sync completed successfully."
else
    echo "Error occurred during sync." >&2
    exit 1
fi

echo "All packages have been processed and repositories have been updated."
