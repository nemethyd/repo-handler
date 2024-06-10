#!/bin/bash

MAX_PACKAGES=3
MAX_PARALLEL_JOBS=2
BATCH_SIZE=10
SCRIPT_DIR=$(dirname "$0")
LOCAL_REPO_PATH=/repo
SHARED_REPO_PATH=/mnt/hgfs/ForVMware/ol9_repos
INSTALLED_PACKAGES_FILE=$(mktemp)

echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE"

declare -A virtual_repo_map
virtual_repo_map=(["baseos"]="ol9_baseos_latest" ["appstream"]="ol9_appstream" ["epel"]="ol9_developer_EPEL")

declare -A used_directories
declare -A identified_packages

echo "$(date '+%Y-%m-%d %H:%M:%S') - Collecting initial list of RPM files..."
initial_rpm_files=($(find "$LOCAL_REPO_PATH"/ol9_* -type f -path "*/getPackage/*.rpm"))

mapfile -t package_lines < "$INSTALLED_PACKAGES_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."
package_counter=0
batch_counter=0
batch_packages=()

get_repo_path() {
    local package_repo=$1
    local repo_dir

    repo_dir=${virtual_repo_map[$package_repo]}
    if [[ -n "$repo_dir" ]]; then
        echo "$LOCAL_REPO_PATH/$repo_dir/getPackage"
    else
        echo ""
    fi
}

for line in "${package_lines[@]}"; do
    [ "$DEBUG_MODE" -ge 1 ] && echo "Processing line: $line"

    if [[ "$line" =~ ^Installed\ Packages$ ]]; then
        [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping line: $line"
        continue
    fi

    if [[ "$line" =~ ^([^ ]+)\.([^ ]+)\ +([^ ]+)\ +@([^ ]+)\ *$ ]]; then
        package_name="${BASH_REMATCH[1]}"
        package_arch="${BASH_REMATCH[2]}"
        package_version="${BASH_REMATCH[3]}"
        package_repo="${BASH_REMATCH[4]}"

        [ "$DEBUG_MODE" -ge 1 ] && echo "Matched package: $package_name, Version: $package_version, Repo: $package_repo"

        repo_path=$(get_repo_path "$package_repo")
        if [[ -z "$repo_path" ]]; then
            [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping package due to unknown repo: $package_name-$package_version@$package_repo"
            continue
        fi

        if [[ "$package_version" =~ ([0-9]+):(.+) ]]; then
            epoch="${BASH_REMATCH[1]}"
            version="${BASH_REMATCH[2]}"
        else
            epoch=""
            version="$package_version"
        fi

        used_directories["$repo_path"]=1
        batch_packages+=("$package_name|$epoch|$version|$package_arch|$repo_path")

        [ "$DEBUG_MODE" -ge 1 ] && echo "Before incrementing batch_counter: $batch_counter"
        batch_counter=$((batch_counter + 1))
        [ "$DEBUG_MODE" -ge 1 ] && echo "After incrementing batch_counter: $batch_counter"

        (( package_counter++ ))
        (( batch_counter >= BATCH_SIZE )) && { wait_for_jobs; batch_counter=0; }
        (( package_counter >= MAX_PACKAGES )) && { echo "Processed $MAX_PACKAGES packages. Stopping."; break; }
    fi
done

if (( batch_counter > 0 )); then
    [ "$DEBUG_MODE" -ge 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting process-package.sh for remaining batch: ${batch_packages[*]}"
    ./process-package.sh "$DEBUG_MODE" "${batch_packages[@]}" &
    echo "Started process-package.sh with PID $!"
    wait
fi

rm "$INSTALLED_PACKAGES_FILE"
echo "Skipping metadata update and sync due to MAX_PACKAGES setting."
