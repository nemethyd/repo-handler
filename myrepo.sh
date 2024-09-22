#!/bin/bash

# Version: 2.40
# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT-4
# Date: 2024-09-25

# MIT licensing
# Purpose:
# This script replicates and updates a local repository from installed packages 
# and synchronizes it with a shared repository, handling updates and cleanup of 
# older package versions.

# Script version
VERSION=2.40
echo "$0 Version $VERSION"

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${MAX_PACKAGES:=0}"
: "${BATCH_SIZE:=10}"
: "${MAX_PARALLEL_JOBS:=1}"
: "${DRY_RUN:=0}"

# Truncate working files
> locally_found.lst
> myrepo.err
> process_package.log

# Configuration
SCRIPT_DIR=$(dirname "$0")
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
INSTALLED_PACKAGES_FILE=$(mktemp)
# Update LOCAL_REPOS to include all relevant local repositories
LOCAL_REPOS=("ol9_baseos_latest" "ol9_appstream" "ol9_addons" "ol9_UEKR7" "ol9_codeready_builder" "ol9_developer" "ol9_developer_EPEL" "ol9_edge" "pgdg-common" "pgdg16")
RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Parse options
while [[ "$1" =~ ^-- ]]; do
    case "$1" in
        --debug-level)
            shift
            DEBUG_MODE=$1
        ;;
        --max-packages)
            shift
            MAX_PACKAGES=$1
        ;;
        --batch-size)
            shift
            BATCH_SIZE=$1
        ;;
        --parallel)
            shift
            MAX_PARALLEL_JOBS=$1
        ;;
        --dry-run)
            DRY_RUN=1
        ;;
        --version)
            echo "myrepo.sh Version $VERSION"
            exit 0
        ;;
        --help)
            echo "Usage: myrepo.sh [--debug-level LEVEL] [--max-packages NUM] [--batch-size NUM] [--parallel NUM] [--dry-run]"
            exit 0
        ;;
        *)
            echo "Unknown option: $1"
            exit 1
        ;;
    esac
    shift
done

# Function to wait for background jobs to finish
wait_for_jobs() {
    while (( $(jobs -rp | wc -l) >= MAX_PARALLEL_JOBS )); do
        sleep 1
    done
}

# Function to escape regex metacharacters
escape_regex() {
    printf '%s\n' "$1" | sed 's/[][\\.^$*+?|(){}]/\\&/g'
}

# Function to download repository metadata and store in memory
download_repo_metadata() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Downloading repository metadata..."
    declare -gA repo_cache
    for repo in "${ENABLED_REPOS[@]}"; do
        echo "Fetching metadata for $repo..."
        repo_cache["$repo"]=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}-%{epoch}:%{version}-%{release}.%{arch}" 2>>myrepo.err)
        if [[ $? -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching metadata for $repo" >> myrepo.err
        fi
    done
}

# Fetch installed packages list
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."
dnf list --installed > "$INSTALLED_PACKAGES_FILE" 2>>myrepo.err
if [[ $? -ne 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching installed packages list." >> myrepo.err
    exit 1
fi

# Fetch the list of enabled repositories
echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of enabled repositories..."
ENABLED_REPOS=($(dnf repolist enabled | awk 'NR>1 {print $1}'))
if [[ ${#ENABLED_REPOS[@]} -eq 0 ]]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - No enabled repositories found." >> myrepo.err
    exit 1
fi

# Download repository metadata for enabled repos
download_repo_metadata

# Declare associative arrays
declare -A used_directories

# Function to check if a package is available in the local repos or rpmbuild directory
is_package_in_local_sources() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_arch=$4

    # Check in local repos metadata
    for repo in "${LOCAL_REPOS[@]}"; do
        if [[ -n "$epoch_version" ]]; then
            # Include epoch in the search
            if echo "${repo_cache[$repo]}" | grep -q "^${package_name}-${epoch_version}:${package_version}-${package_release}.${package_arch}$"; then
                [[ $DEBUG_MODE -ge 1 ]] && echo "Package $package_name with epoch $epoch_version found in $repo" >&2
                echo "$repo"
                return
            fi
        else
            if echo "${repo_cache[$repo]}" | grep -q "^${package_name}-${package_version}-${package_release}.${package_arch}$"; then
                [[ $DEBUG_MODE -ge 1 ]] && echo "Package $package_name found in $repo" >&2
                echo "$repo"
                return
            fi
        fi
    done

    # Check in rpmbuild directory
    if find "$RPMBUILD_PATH" -name "${package_name}-${package_version}*.rpm" | grep -q .; then
        echo "${package_name}-${package_version}*.rpm" >> "locally_found.lst" # Locally found packages
        [[ $DEBUG_MODE -ge 1 ]] && echo "Package $package_name found in rpmbuild directory" >&2
    fi

    echo "no"
}

# Function to determine the repository source of a package
determine_repo_source() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_arch=$4

    # Check if the package exists in any of the local sources
    local_repo=$(is_package_in_local_sources "$package_name" "$epoch_version" "$package_version" "$package_arch")
    if [[ "$local_repo" != "no" ]]; then
        echo "$local_repo"
        return
    fi

    # Attempt to find the repository ID using dnf repoquery
    # This will return the repository from which the package was installed
    repoid=$(dnf repoquery --installed --qf "%{repoid}" "$package_name" 2>>myrepo.err | head -n1)

    if [[ -n "$repoid" && "$repoid" != "System" ]]; then
        echo "$repoid"
        return
    fi

    # If repoid is empty or 'System', attempt to find the repository from metadata
    for repo in "${ENABLED_REPOS[@]}"; do
        if [[ $DEBUG_MODE -ge 1 ]]; then
            echo "Checking ${repo} for ${package_name}-${package_version}.${package_arch}" >&2
        fi

        # Reconstruct the exact package string
        if [[ -n "$epoch_version" ]]; then
            expected_package="${package_name}-${epoch_version}:${package_version}.${package_arch}"
        else
            expected_package="${package_name}-${package_version}.${package_arch}"
        fi

        if echo "${repo_cache[$repo]}" | grep -Fxq "$expected_package"; then
            echo "$repo"
            return
        fi
    done

    echo "Invalid"  # Default to Invalid if not found elsewhere
}

# Collect initial list of RPM files
echo "$(date '+%Y-%m-%d %H:%M:%S') - Collecting initial list of RPM files..."
initial_rpm_files=($(find "$LOCAL_REPO_PATH"/ol9_* -type f -path "*/getPackage/*.rpm"))

# Read the installed packages list
mapfile -t package_lines < "$INSTALLED_PACKAGES_FILE"

# Processing installed packages
echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."
package_counter=0
batch_packages=()

# Function to get the repository path
get_repo_path() {
    local package_repo=$1
    if [[ "$package_repo" == "System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi

    # Construct the path based on repository name
    echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
}

# Function to get the repository name
get_repo_name() {
    local package_repo=$1
    echo "$package_repo"
}

# Main loop processing the lines
for line in "${package_lines[@]}"; do
    # Adjusted regex to handle multiple spaces and package names with special characters
    if [[ "$line" =~ ^([^\ ]+)\.([^\ ]+)[[:space:]]+([^\ ]+)[[:space:]]+@([^\ ]+)[[:space:]]*$ ]]; then
        package_name=${BASH_REMATCH[1]}
        package_arch=${BASH_REMATCH[2]}
        full_version=${BASH_REMATCH[3]}
        package_repo=${BASH_REMATCH[4]}

        if [[ "$full_version" =~ ^([0-9]+):(.*)$ ]]; then
            epoch_version=${BASH_REMATCH[1]}
            package_version=${BASH_REMATCH[2]}
        else
            epoch_version=""
            package_version=$full_version
        fi

        if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
            package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_arch")
        fi

        if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
            [[ $DEBUG_MODE -ge 1 ]] && echo "Skipping package $package_name as it is marked as $package_repo" >&2
            continue
        fi

        repo_path=$(get_repo_path "$package_repo")
        repo_name=$(get_repo_name "$package_repo")

        if [[ -n "$repo_path" ]]; then
            used_directories["$repo_name"]="$repo_path"
            batch_packages+=("$repo_name|$package_name|$epoch_version|$package_version|$package_arch|$repo_path")
        else
            [[ $DEBUG_MODE -ge 1 ]] && echo "Package $package_name does not have a valid repository path" >&2
            continue
        fi

        ((package_counter++))
        if (( MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES )); then
            break
        fi

        if (( ${#batch_packages[@]} >= BATCH_SIZE )); then
            "$SCRIPT_DIR"/process-package.sh --debug-level "$DEBUG_MODE" --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}" &
            batch_packages=()
            wait_for_jobs
        fi
    else
        [[ $DEBUG_MODE -ge 1 ]] && echo "Line skipped due to unmatched format: $line" >&2
    fi
done

# Process any remaining packages in the last batch
if (( ${#batch_packages[@]} > 0 )); then
    "$SCRIPT_DIR/process-package.sh" --debug-level "$DEBUG_MODE" --packages "${batch_packages[*]}" --local-repos "${LOCAL_REPOS[*]}"
fi

# Function to remove uninstalled or removed packages from the repo
remove_uninstalled_packages() {
    local repo_path="$1"
    local repo_name=$(basename "$repo_path")  # Extract repository name from path

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking for uninstalled or removed packages in: $repo_path"

    # Find all RPM files in the repo
    find "$repo_path" -type f -name "*.rpm" | while read -r rpm_file; do
        package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file")
        package_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file")
        package_epoch=$(rpm -qp --queryformat '%{EPOCH}' "$rpm_file")
        package_version=$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}' "$rpm_file")

        # Escape regex metacharacters in package_name
        escaped_package_name=$(escape_regex "$package_name")

        # Check if the package is installed on the system
        if ! grep -qE "^[[:space:]]*${escaped_package_name}\.${package_arch}[[:space:]]" "$INSTALLED_PACKAGES_FILE"; then
            rpm_filename=$(basename "$rpm_file")
            if (( DRY_RUN )); then
                echo "$repo_name: $rpm_filename would be removed."
            else
                echo "$repo_name: $rpm_filename removed."
                rm -f "$rpm_file" && echo "Successfully removed $rpm_file" || echo "Failed to remove $rpm_file" >> myrepo.err
            fi
        else
            [[ $DEBUG_MODE -ge 1 ]] && echo "$repo_name: $(basename "$rpm_file") exists." >&2
        fi
    done
}

# Remove uninstalled packages from each repo in parallel
echo "$(date '+%Y-%m-%d %H:%M:%S') - Removing uninstalled packages..."
for repo in "${!used_directories[@]}"; do
    repo_path="${used_directories[$repo]}"

    if [[ -d "$repo_path" ]]; then
        # Run remove_uninstalled_packages in the background
        remove_uninstalled_packages "$repo_path" &
        wait_for_jobs
    else
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Repository path $repo_path does not exist, skipping."
    fi
done

# Wait for all background jobs to finish
wait

# Update and sync the repositories
if (( MAX_PACKAGES == 0 )); then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Updating repository metadata..."
    for repo in "${!used_directories[@]}"; do
        repo_path="${used_directories[$repo]}"
        parent_dir=$(dirname "$repo_path")
        if (( DRY_RUN )); then
            echo "Dry Run: Would run 'createrepo --update $parent_dir'"
        else
            createrepo --update "$parent_dir" >> process_package.log 2>>myrepo.err
            if [[ $? -ne 0 ]]; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Error updating metadata for $repo" >> myrepo.err
            fi
        fi
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Synchronizing repositories..."
    if (( DRY_RUN )); then
        echo "Dry Run: Would run 'rsync -av --delete $LOCAL_REPO_PATH/ $SHARED_REPO_PATH/'"
    else
        rsync -av --delete "$LOCAL_REPO_PATH/" "$SHARED_REPO_PATH/" >> process_package.log 2>>myrepo.err
        if [[ $? -ne 0 ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error synchronizing repositories." >> myrepo.err
        fi
    fi
fi

# Clean up
rm "$INSTALLED_PACKAGES_FILE"

echo "myrepo.sh Version $VERSION completed."
