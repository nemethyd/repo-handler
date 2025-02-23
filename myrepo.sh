#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with AI support model ChatGPT-4
# Last Updated: 2023-11-24

# MIT licensing
# Purpose:
# This script replicates and updates a local repository from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# older package versions.

# Script version
VERSION=2.89
echo "$0 Version $VERSION"

# Default values for environment variables if not set
: "${DEBUG_MODE:=0}"
: "${MAX_PACKAGES:=0}"
: "${BATCH_SIZE:=10}"
: "${PARALLEL:=2}"
: "${DRY_RUN:=0}"
: "${USER_MODE:=0}"
: "${SYNC_ONLY:=0}"

# Default configuration values
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
LOCAL_REPOS=("ol9_edge" "pgdg-common" "pgdg16")
RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Log directory
LOG_DIR="/var/log/myrepo"

# Initialize temporary files array for cleanup
TEMP_FILES=()

# Load configuration file if it exists (allowing comment lines)
CONFIG_FILE="myrepo.cfg"
if [[ -f "$CONFIG_FILE" ]]; then
    echo "Loading configuration from $CONFIG_FILE"
    while IFS='=' read -r key value; do
        # Ignore empty lines and lines starting with #
        if [[ -z "$key" || "$key" =~ ^\s*# ]]; then
            continue
        fi
        key=$(echo "$key" | tr -d ' ')
        value=$(echo "$value" | sed 's/^ *//;s/ *$//; s/^["'\'']\|["'\'']$//g')

        case "$key" in
        LOCAL_REPO_PATH) LOCAL_REPO_PATH="$value" ;;
        SHARED_REPO_PATH) SHARED_REPO_PATH="$value" ;;
        LOCAL_REPOS) IFS=',' read -r -a LOCAL_REPOS <<<"$value" ;;
        RPMBUILD_PATH) RPMBUILD_PATH="$value" ;;
        DEBUG_MODE) DEBUG_MODE="$value" ;;
        MAX_PACKAGES) MAX_PACKAGES="$value" ;;
        BATCH_SIZE) BATCH_SIZE="$value" ;;
        PARALLEL) PARALLEL="$value" ;;
        DRY_RUN) DRY_RUN="$value" ;;
        USER_MODE) USER_MODE="$value" ;;
        LOG_DIR) LOG_DIR="$value" ;;
        SYNC_ONLY) SYNC_ONLY="$value" ;;
        *) echo "Unknown configuration option: $key" ;;
        esac
    done < <(grep -v '^\s*#' "$CONFIG_FILE")
fi

[[ DEBUG_MODE -ge 1 ]] && echo "LOCAL_REPOS is set to:" "${LOCAL_REPOS[@]}"

# Parse command-line options (overrides config file and defaults)
while [[ "$1" =~ ^-- ]]; do
    case "$1" in
    --batch-size)
        shift
        BATCH_SIZE=$1
        ;;
    --debug-level)
        shift
        DEBUG_MODE=$1
        ;;
    --dry-run)
        DRY_RUN=1
        ;;
    --max-packages)
        shift
        MAX_PACKAGES=$1
        ;;
    --user-mode)
        USER_MODE=1
        ;;
    --parallel)
        shift
        PARALLEL=$1
        ;;
    --local-repo-path)
        shift
        LOCAL_REPO_PATH=$1
        ;;
    --shared-repo-path)
        shift
        SHARED_REPO_PATH=$1
        ;;
    --local-repos)
        shift
        IFS=',' read -r -a LOCAL_REPOS <<<"$1"
        ;;
    --log-dir)
        shift
        LOG_DIR=$1
        ;;
    --sync-only)
        SYNC_ONLY=1
        ;;
    --version)
        echo "myrepo.sh Version $VERSION"
        exit 0
        ;;
    --help)
        echo "Usage: myrepo.sh [OPTIONS]"
        echo "Options:"
        echo "  --debug-level LEVEL       Set debug level (default: $DEBUG_MODE)"
        echo "  --max-packages NUM        Maximum number of packages to process (default: $MAX_PACKAGES)"
        echo "  --batch-size NUM          Number of packages per batch (default: $BATCH_SIZE)"
        echo "  --parallel NUM            Number of parallel processes (default: $PARALLEL)"
        echo "  --dry-run                 Perform a dry run without making changes"
        echo "  --user-mode                 Run without sudo privileges"
        echo "  --local-repo-path PATH    Set local repository path (default: $LOCAL_REPO_PATH)"
        echo "  --shared-repo-path PATH   Set shared repository path (default: $SHARED_REPO_PATH)"
        echo "  --local-repos REPOS       Comma-separated list of local repos (default: ${LOCAL_REPOS[*]})"
        echo "  --log-dir PATH            Set log directory (default: $LOG_DIR)"
        echo "  --sync-only               Only perform createrepo and rsync steps"
        exit 0
        ;;
    *)
        echo "Unknown option: $1"
        exit 1
        ;;
    esac
    shift
done

# Check if script is run as root
if [[ -z $USER_MODE && $EUID -ne 0 ]]; then
    echo "This script must be run as root or with sudo privileges." >&2
    exit 1
fi

# Set the base directory for temporary files depending on USER_MODE
if [[ $USER_MODE -eq 1 ]]; then
    TMP_DIR="$HOME/tmp"
    mkdir -p "$TMP_DIR" || {
        echo "Failed to create temporary directory $TMP_DIR for user mode." >&2
        exit 1
    }
else
    TMP_DIR="/tmp"
fi

# Define temporary files paths
INSTALLED_PACKAGES_FILE="$TMP_DIR/installed_packages.lst"
PROCESSED_PACKAGES_FILE="$TMP_DIR/processed_packages.share"

# Create the temporary files and ensure they have correct permissions
touch "$INSTALLED_PACKAGES_FILE" "$PROCESSED_PACKAGES_FILE" || {
    echo "Failed to create temporary files in $TMP_DIR." >&2
    exit 1
}

# Ensure that the log directory exists and is writable
if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR" || {
        echo "Failed to create log directory: $LOG_DIR" >&2
        exit 1
    }
fi

# Ensure the log directory is writable by the user running the script
if [[ ! -w "$LOG_DIR" ]]; then
    echo "Log directory $LOG_DIR is not writable by the current user." >&2
    echo "Attempting to set permissions..."

    if [[ $USER_MODE -eq 1 ]]; then
        sudo chown -R "$USER" "$LOG_DIR" || {
            echo "Failed to change ownership of $LOG_DIR to $USER" >&2
            exit 1
        }
    fi
    sudo chmod u+w "$LOG_DIR" || {
        echo "Failed to set write permissions on $LOG_DIR for the current user." >&2
        exit 1
    }
fi

# Define log file paths
LOCALLY_FOUND_FILE="$LOG_DIR/locally_found.lst"
MYREPO_ERR_FILE="$LOG_DIR/myrepo.err"
PROCESS_LOG_FILE="$LOG_DIR/process_package.log"

# Ensure the log directory is writable by the user running the script
if [[ ! -w "$LOG_DIR" ]]; then
    echo "Log directory $LOG_DIR is not writable by the current user." >&2
    echo "Attempting to set permissions..."

    if [[ $USER_MODE -eq 0 ]]; then
        sudo chown -R "$USER" "$LOG_DIR" || {
            echo "Failed to change ownership of $LOG_DIR to $USER" >&2
            exit 1
        }
    fi

    # In both USER_MODE and non-USER_MODE, attempt to change permissions to allow writing
    chmod u+w "$LOG_DIR" || {
        echo "Failed to set write permissions on $LOG_DIR for the current user." >&2
        exit 1
    }
fi

# Ensure that the log files exist, then truncate them
touch "$LOCALLY_FOUND_FILE" "$MYREPO_ERR_FILE" "$PROCESS_LOG_FILE" || {
    echo "Failed to create log files in $LOG_DIR." >&2
    exit 1
}

: >"$LOCALLY_FOUND_FILE"
: >"$MYREPO_ERR_FILE"
: >"$PROCESS_LOG_FILE"
: >"$PROCESSED_PACKAGES_FILE"
: >"$INSTALLED_PACKAGES_FILE"

# Calculate the parallel download factor by multiplying PARALLEL and BATCH_SIZE
PARALLEL_DOWNLOADS=$((PARALLEL * BATCH_SIZE))
# Cap the parallel downloads at a maximum of 20
if ((PARALLEL_DOWNLOADS > 20)); then
    PARALLEL_DOWNLOADS=20
fi

# Declare associative array for used_directories
declare -A used_directories
# Declare associative array for available packages in enabled repos
declare -A available_repo_packages

######################################
### Functions section in abc order ###
######################################

# Function to align the output by padding the repo_name
align_repo_name() {
    local repo_name="$1"
    printf "%-${PADDING_LENGTH}s" "$repo_name"
}

# Cleanup function to remove temporary files
cleanup() {
    rm -f "${TEMP_FILES[@]}"
}

# Function to create a unique temporary file and track it for cleanup
create_temp_file() {
    local tmp_file
    tmp_file=$(mktemp /tmp/myrepo_"$(date +%s)"_$$.XXXXXX)
    TEMP_FILES+=("$tmp_file")
    echo "$tmp_file"
}

# Function to determine the repository source of a package based on available packages
determine_repo_source() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_release=$4
    local package_arch=$5

    for repo in "${ENABLED_REPOS[@]}"; do
        # Reconstruct the expected package string without epoch if it's '0'
        local expected_package
        if [[ -n "$epoch_version" && "$epoch_version" != "0" ]]; then
            expected_package="${package_name}|${epoch_version}|${package_version}|${package_release}|${package_arch}"
        else
            expected_package="${package_name}|0|${package_version}|${package_release}|${package_arch}"
        fi

        # Compare with cached repo metadata
        if echo "${available_repo_packages[$repo]}" | grep -Fxq "$expected_package"; then
            echo "$repo"
            return
        fi
    done

    echo "Invalid" # Default to Invalid if no matching repo is found
}

# Download packages with parallel downloads or use local cached RPMs
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
        IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<<"$pkg"

        # Only include epoch if it's not '0'
        if [[ -n "$epoch" && "$epoch" != "0" ]]; then
            package_version_full="${epoch}:${package_version}-${package_release}.$package_arch"
        else
            package_version_full="${package_version}-${package_release}.$package_arch"
        fi

        if [ -n "$repo_path" ]; then
            if [[ ! " ${LOCAL_REPOS[*]} " == *" ${repo_name} "* ]]; then
                # Check if RPM is available locally
                local rpm_path
                rpm_path=$(locate_local_rpm "$package_name" "$package_version" "$package_release" "$package_arch")

                if [[ -n "$rpm_path" ]]; then
                    echo -e "\e[32m$(align_repo_name "$repo_name"): Using local RPM for $package_name-$package_version-$package_release.$package_arch\e[0m"
                    cp "$rpm_path" "$repo_path"
                else
                    # Add to repo_packages for downloading
                    repo_packages["$repo_path"]+="$package_name-$package_version_full "
                fi
            fi
        fi
    done

    for repo_path in "${!repo_packages[@]}"; do
        mkdir -p "$repo_path" || {
            log_to_temp_file "Failed to create directory: $repo_path"
            exit 1
        }

        # Run download in background
        if ((DRY_RUN)); then
            log_to_temp_file "Dry Run: Would download packages to $repo_path: ${repo_packages[$repo_path]}"
        else
            {
                log_to_temp_file "Downloading packages to $repo_path: ${repo_packages[$repo_path]}"
                # Check if sudo is required and set the appropriate command prefix
                DNF_COMMAND="dnf --setopt=max_parallel_downloads=$PARALLEL download --arch=x86_64,noarch --destdir=$repo_path --resolve ${repo_packages[$repo_path]}"
                if [[ -z "$USER_MODE" ]]; then
                    DNF_COMMAND="sudo $DNF_COMMAND"
                fi

                [[ DEBUG_MODE -ge 2 ]] && echo "$DNF_COMMAND"
                if ! $DNF_COMMAND 1>>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                    log_to_temp_file "Failed to download packages: ${repo_packages[$repo_path]}"
                    return 1
                fi
            } &
        fi
        wait_for_jobs # Control the number of parallel jobs
    done
}

# Function to download repository metadata and store in memory
download_repo_metadata() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Downloading repository metadata..."

    # For enabled repositories
    for repo in "${ENABLED_REPOS[@]}"; do
        echo "Fetching metadata for $repo..."
        available_repo_packages["$repo"]=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>"$MYREPO_ERR_FILE")
        if [[ -z "${available_repo_packages[$repo]}" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching metadata for $repo" >>"$MYREPO_ERR_FILE"
        fi
    done

    # For local repositories
    declare -gA repo_cache # Declare repo_cache globally to be used later
    for local_repo in "${LOCAL_REPOS[@]}"; do
        echo "Fetching metadata for local repo $local_repo..."
        repo_cache["$local_repo"]=$(dnf repoquery -y --arch=x86_64,noarch --disablerepo="*" --enablerepo="$local_repo" --qf "%{name}|%{epoch}|%{version}|%{release}|%{arch}" 2>>"$MYREPO_ERR_FILE")
        if [[ -z "${repo_cache[$local_repo]}" ]]; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching metadata for local repo $local_repo" >>"$MYREPO_ERR_FILE"
        fi
    done
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

    if compgen -G "$package_pattern" >/dev/null; then
        echo "EXISTS"
        return
    elif [[ -n "$epoch" ]]; then
        local package_pattern_with_epoch="${repo_path}/${package_name}-${epoch}:${package_version}-${package_release}.${package_arch}.rpm"
        if compgen -G "$package_pattern_with_epoch" >/dev/null; then
            echo "EXISTS"
            return
        fi
    fi

    # Check if there are any packages with this name in the repo_path
    if compgen -G "${repo_path}/${package_name}-*.rpm" >/dev/null; then
        echo "UPDATE"
    else
        echo "NEW"
    fi
}

# Function to get the repository name (left here for consistency)
get_repo_name() {
    local package_repo=$1
    echo "$package_repo"
}

# Function to get the repository path
get_repo_path() {
    local package_repo=$1
    if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "Invalid" ]]; then
        echo ""
        return
    fi

    # Construct the path based on repository name
    echo "$LOCAL_REPO_PATH/$package_repo/getPackage"
}

# Function to check if a package exists in local sources
is_package_in_local_sources() {
    local package_name=$1
    local epoch_version=$2
    local package_version=$3
    local package_release=$4
    local package_arch=$5

    for repo in "${LOCAL_REPOS[@]}"; do
        if [[ -n "$epoch_version" ]]; then
            if echo "${repo_cache[$repo]}" | grep -Fxq "$package_name|$epoch_version|$package_version|$package_release|$package_arch"; then
                echo "$repo"
                return
            fi
        else
            if echo "${repo_cache[$repo]}" | grep -Fxq "$package_name|0|$package_version|$package_release|$package_arch"; then
                echo "$repo"
                return
            fi
        fi
    done

    # Check in rpmbuild directory
    if find "$RPMBUILD_PATH" -name "${package_name}-${package_version}-${package_release}.${package_arch}.rpm" | grep -q .; then
        echo "no"
        return
    fi

    echo "no"
}

# Function to check if the package has already been processed
is_package_processed() {
    local pkg_key="$1"
    while IFS= read -r line; do
        if [[ "$line" == "$pkg_key" ]]; then
            return 0
        fi
    done <"$PROCESSED_PACKAGES_FILE"
    return 1
}

# Function to locate RPM from local cache if available
locate_local_rpm() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local package_arch="$4"

    local rpm_path

    # Search in dnf cache directory
    rpm_path=$(find /var/cache/dnf -name "${package_name}-${package_version}-${package_release}.${package_arch}.rpm" 2>/dev/null | head -n 1)

    if [[ -n "$rpm_path" && -f "$rpm_path" ]]; then
        echo "$rpm_path"
    else
        echo ""
    fi
}

# Function to write log to the specific temporary file
log_to_temp_file() {
    [[ DEBUG_MODE -ge 1 ]] && echo "$1"
    echo "$1" >>"$TEMP_FILE"
}

#Function for batch processing subprocess
process_batch() {
    local batch_packages=("$@")

    if ((${#batch_packages[@]} > 0)); then
        [[ DEBUG_MODE -ge 1 ]] && echo "local-repos: ${LOCAL_REPOS[*]} batch: ${batch_packages[*]}"
        process_packages \
            "$DEBUG_MODE" \
            "${batch_packages[*]}" \
            "${LOCAL_REPOS[*]}" \
            "$PROCESSED_PACKAGES_FILE" \
            "$PARALLEL" \
            "$temp_file" &
        # Wait for background jobs to finish before starting a new batch
        wait_for_jobs
    fi
}

# Function to process a package batch
process_packages() {
    local DEBUG_MODE
    local PACKAGES
    local LOCAL_REPOS
    local PROCESSED_PACKAGES_FILE
    local PARALLEL
    local TEMP_FILE

    DEBUG_MODE=$1
    PACKAGES=("$2")
    LOCAL_REPOS=("$3")
    PROCESSED_PACKAGES_FILE=$4
    PARALLEL=$5
    TEMP_FILE=$6

    if [ ${#PACKAGES[@]} -eq 0 ]; then
        echo "No packages to process."
        return
    fi

    ### Main processing section ###

    IFS=' ' read -r -a packages <<<"${PACKAGES[@]}"
    local_repos=("${LOCAL_REPOS[@]}")

    # Ensure a temporary file is set for the thread
    if [[ -z "$TEMP_FILE" ]]; then
        echo "Error: Temporary file not provided. Creating one." >&2
        TEMP_FILE=$(create_temp_file)
    fi

    # Handle the packages based on their status
    for pkg in "${packages[@]}"; do
        IFS='|' read -r repo_name package_name epoch package_version package_release package_arch repo_path <<<"$pkg"

        PADDING_LENGTH=22 # Set constant padding length

        pkg_key="${package_name}-${package_version}-${package_release}.${package_arch}"

        # Skip if already processed
        if is_package_processed "$pkg_key"; then
            [[ $DEBUG_MODE -ge 1 ]] && echo "Package $pkg_key already processed, skipping."
            continue
        fi

        if [[ -z "$repo_path" ]]; then
            [ "$DEBUG_MODE" -ge 1 ] && echo "Skipping package with empty repo_path: $package_name" >&2
            continue
        fi

        if ! package_status=$(get_package_status "$repo_name" "$package_name" "$epoch" "$package_version" "$package_release" "$package_arch" "$repo_path"); then
            echo "Failed to determine status for package: $package_name-$package_version-$package_release" >&2
            exit 1
        fi

        case $package_status in
        "EXISTS")
            echo -e "\e[32m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch exists.\e[0m"
            ;;
        "NEW")
            if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                echo -e "\e[33m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch added.\e[0m"
                download_packages "$repo_name|$package_name|$epoch|$package_version|$package_release|$package_arch|$repo_path"
            else
                echo -e "\e[33m$(align_repo_name "$repo_name"): Skipping download for local package $package_name-$package_version-$package_release.$package_arch.\e[0m"
            fi
            ;;
        "UPDATE")
            if [[ ! " ${local_repos[*]} " == *" ${repo_name} "* ]]; then
                remove_existing_packages "$package_name" "$package_version" "$package_release" "$repo_path"
                echo -e "\e[34m$(align_repo_name "$repo_name"): $package_name-$package_version-$package_release.$package_arch updated.\e[0m"
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

    # Wait for all background jobs to complete before finishing the script
    wait
}

# Function to process RPM files for uninstallation check
process_rpm_file() {
    local rpm_file="$1"

    # Debug line to check what rpm_file is being received
    if [[ -z "$rpm_file" ]]; then
        echo -e "\e[90mWarning: Received empty rpm_file argument.\e[0m" >&2
        return 1
    fi

    # Extract repo name from the path
    local repo_name
    repo_name=$(basename "$(dirname "$(dirname "$rpm_file")")") # Extract the parent directory name of getPackage

    # Extract package name, version, release, and arch
    local package_name package_version package_release package_arch package_epoch
    package_name=$(rpm -qp --queryformat '%{NAME}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_version=$(rpm -qp --queryformat '%{VERSION}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_release=$(rpm -qp --queryformat '%{RELEASE}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_arch=$(rpm -qp --queryformat '%{ARCH}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    package_epoch=$(rpm -qp --queryformat '%{EPOCH}' "$rpm_file" 2>>"$MYREPO_ERR_FILE")
    if [[ "$package_epoch" == "(none)" || -z "$package_epoch" ]]; then
        package_epoch="0"
    fi

    # Validate extraction
    if [[ -z "$package_name" || -z "$package_version" || -z "$package_release" || -z "$package_arch" ]]; then
        echo -e "\e[90mWarning: Failed to extract package details from $rpm_file\e[0m" >&2
        return 1
    fi

    # Output formatted with gray text
    [[ $DEBUG_MODE -ge 1 ]] && echo -e "\e[90m${repo_name} : ${package_name}-${package_version}.${package_arch} checking\e[0m"

    # Proceed with other operations
    if ! awk -F '|' \
        -v name="$package_name" \
        -v epoch="$package_epoch" \
        -v version="$package_version" \
        -v release="$package_release" \
        -v arch="$package_arch" \
        '($1 == name && $2 == epoch && $3 == version && $4 == release && $5 == arch)' \
        "$INSTALLED_PACKAGES_FILE" >/dev/null; then
        if ((DRY_RUN)); then
            echo -e "\e[90m${repo_name} : ${package_name}-${package_version}.${package_arch} would be removed.\e[0m"
        else
            if rm -f "$rpm_file"; then
                echo -e "\e[90m${repo_name} : ${package_name}-${package_version}.${package_arch} removed successfully\e[0m"
            else
                echo -e "\e[90m${repo_name} : ${package_name}-${package_version}.${package_arch} removal failed\e[0m" >>"$MYREPO_ERR_FILE"
                return 1
            fi
        fi
    else
        [[ $DEBUG_MODE -ge 1 ]] && echo -e "\e[90m${repo_name} : ${package_name}-${package_version}.${package_arch} exists and is not being removed.\e[0m" >&2
    fi

}

# Function to remove existing package files (ensures only older versions are removed)
remove_existing_packages() {
    local package_name="$1"
    local package_version="$2"
    local package_release="$3"
    local repo_path="$4"

    # Only display messages in debug mode
    if ((DEBUG_MODE >= 1)); then
        echo "$(align_repo_name "$repo_name"): Removing older versions of $package_name from $repo_name" >&2
    fi

    # Enable nullglob so that the pattern expands to nothing if there are no matches
    shopt -s nullglob

    # Find all RPM files for the exact package
    for file in "$repo_path/${package_name}"-[0-9]*.rpm; do
        [ -e "$file" ] || continue
        local filename
        filename=$(basename "$file")

        # Extract the version-release
        file_version_release=$(rpm -qp --queryformat '%{EPOCH}:%{VERSION}-%{RELEASE}' "$file" 2>/dev/null)
        current_version_release="$epoch:$package_version-$package_release"

        # Compare versions
        if [[ "$file_version_release" < "$current_version_release" ]]; then
            if ((DRY_RUN)); then
                if ((DEBUG_MODE >= 1)); then
                    echo -e "\e[34m$(align_repo_name "$repo_name"): $filename would be removed (dry-run)\e[0m"
                fi
            else
                if ((DEBUG_MODE >= 1)); then
                    echo -e "\e[34m$(align_repo_name "$repo_name"): $filename removed\e[0m"
                fi
                rm -f "$file"
            fi
        fi
    done

    # Disable nullglob after we're done
    shopt -u nullglob
}

# Function to remove uninstalled or removed packages from the repo
remove_uninstalled_packages() {
    local repo_path="$1"
    local repo_name
    repo_name=$(basename "$(dirname "$repo_path")") # Extract the parent directory name of getPackage

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Checking for removed packages in: $repo_name"

    # Find all RPM files for the repository and process them in parallel using a for loop
    local rpm_files=()
    while IFS= read -r -d $'\0' file; do
        rpm_files+=("$file")
    done < <(find "$repo_path" -type f -name "*.rpm" -print0)

    local num_jobs=0
    for rpm_file in "${rpm_files[@]}"; do
        {
            [[ DEBUG_MODE -ge 2 ]] && echo "Processing file: $rpm_file"
            process_rpm_file "$rpm_file"
        } & # Run in the background
        ((num_jobs++))

        # Limit the number of parallel jobs
        if [[ $num_jobs -ge $PARALLEL ]]; then
            wait -n # Wait for any of the background jobs to finish before proceeding
            ((num_jobs--))
        fi
    done

    # Wait for all background jobs to finish
    wait
}

# Function to wait for background jobs to finish
wait_for_jobs() {
    local current_jobs

    while true; do
        current_jobs=$(jobs -rp | wc -l) # Assign the number of running jobs
        if ((current_jobs >= PARALLEL)); then
            echo "Waiting for jobs in $0 ... Currently running: ${current_jobs}/${PARALLEL}" # Debugging line
            sleep 1
        else
            break
        fi
    done
}

# Trap EXIT signal to ensure cleanup is called
trap cleanup EXIT

### Main processing section ###

# Set constant padding length for alignment
PADDING_LENGTH=22

if ((SYNC_ONLY == 0)); then
    # Fetch installed packages list with detailed information
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of installed packages..."

    if ! dnf repoquery --installed --qf '%{name}|%{epoch}|%{version}|%{release}|%{arch}|%{repoid}' >"$INSTALLED_PACKAGES_FILE" 2>>"$MYREPO_ERR_FILE"; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Error fetching installed packages list." >>"$MYREPO_ERR_FILE"
        exit 1
    fi

    # Fetch the list of enabled repositories
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Fetching list of enabled repositories..."
    mapfile -t ENABLED_REPOS < <(dnf repolist enabled | awk 'NR>1 {print $1}')

    if [[ ${#ENABLED_REPOS[@]} -eq 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S') - No enabled repositories found." >>"$MYREPO_ERR_FILE"
        exit 1
    fi

    # Download repository metadata for enabled repos
    download_repo_metadata

    # Read the installed packages list
    mapfile -t package_lines <"$INSTALLED_PACKAGES_FILE"

    # Processing installed packages
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Processing installed packages..."
    package_counter=0
    batch_packages=()

    # Main loop processing the lines
    for line in "${package_lines[@]}"; do
        # Expected format: name|epoch|version|release|arch|repoid
        IFS='|' read -r package_name epoch_version package_version package_release package_arch package_repo <<<"$line"

        # If the package repo is System, @System, or @commandline, find the corresponding repo
        if [[ "$package_repo" == "System" || "$package_repo" == "@System" || "$package_repo" == "@commandline" ]]; then
            package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
            if [[ $DEBUG_MODE -ge 1 ]]; then
                echo "Mapped $package_name to repo: $package_repo"
            fi
        fi

        # Handle the case where epoch is '0' or empty (skip it in the filename)
        if [[ "$epoch_version" == "0" || -z "$epoch_version" ]]; then
            package_version_full="$package_version-$package_release.$package_arch"
        else
            package_version_full="$epoch_version:$package_version-$package_release.$package_arch"
        fi

        pkg_key="${package_name}-${package_version_full}"

        # Skip if the package has already been processed
        if is_package_processed "$pkg_key"; then
            [[ $DEBUG_MODE -ge 1 ]] && echo "Package $pkg_key already processed, skipping."
            continue
        fi

        # Create a temporary file for this thread
        temp_file=$(create_temp_file)

        # Debugging: Print captured fields
        if [[ $DEBUG_MODE -ge 2 ]]; then
            echo "Captured: package_name=$package_name, epoch_version=$epoch_version, package_version=$package_version, package_release=$package_release, package_arch=$package_arch, package_repo=$package_repo" >&2
        fi

        # Determine repository source
        if [[ "$package_repo" == "System" || "$package_repo" == "@System" ]]; then
            package_repo=$(determine_repo_source "$package_name" "$epoch_version" "$package_version" "$package_release" "$package_arch")
            if [[ $DEBUG_MODE -ge 1 ]]; then
                echo "Determined repo for $package_name: $package_repo" >&2
            fi
        fi

        # Skip if repository is invalid or commandline
        if [[ "$package_repo" == "@commandline" || "$package_repo" == "Invalid" ]]; then
            [[ $DEBUG_MODE -ge 1 ]] && echo "Skipping package $package_name as it is marked as $package_repo" >&2
            continue
        fi

        # Get repository path and name
        repo_path=$(get_repo_path "$package_repo")
        repo_name=$(get_repo_name "$package_repo")

        if [[ -n "$repo_path" ]]; then
            used_directories["$repo_name"]="$repo_path"
            # Pass 7 fields: repo_name|package_name|epoch_version|package_version|package_release|package_arch|repo_path
            batch_packages+=("$repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path")
            # Debugging: Print the package being added
            if [[ $DEBUG_MODE -ge 2 ]]; then
                echo "Adding to batch: $repo_name|$package_name|$epoch_version|$package_version|$package_release|$package_arch|$repo_path" >&2
            fi
        else
            [[ $DEBUG_MODE -ge 1 ]] && echo "Package $package_name does not have a valid repository path" >&2
            continue
        fi

        ((package_counter++))
        if ((MAX_PACKAGES > 0 && package_counter >= MAX_PACKAGES)); then
            break
        fi

        # If batch size reached, process the batch
        if ((${#batch_packages[@]} >= BATCH_SIZE)); then
            process_batch "${batch_packages[@]}"
            batch_packages=()
        fi
    done

    # Process any remaining packages in the last batch
    if ((${#batch_packages[@]} > 0)); then
        process_batch "${batch_packages[@]}"
    fi

    wait

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Removing uninstalled packages..."
    for repo in "${!used_directories[@]}"; do
        repo_path="${used_directories[$repo]}"

        # Check if the repository directory exists and contains any RPM files
        if [[ -d "$repo_path" ]]; then
            # If no RPM files are found, skip this repository
            if ! compgen -G "$repo_path/*.rpm" >/dev/null; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - No RPM files found in $repo_path, skipping removal process."
                continue
            fi

            # Run remove_uninstalled_packages if RPM files are present
            remove_uninstalled_packages "$repo_path"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Repository path $repo_path does not exist, skipping."
        fi
    done

    # Periodically check the status of running background jobs
    while true; do
        running_jobs=$(jobs -rp | wc -l)
        if ((running_jobs > 0)); then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Still removing uninstalled packages, ${running_jobs} jobs remaining..."
            sleep 10 # Adjust the interval as needed to avoid excessive output
        else
            break
        fi
    done

    # Wait for all background jobs to finish
    wait
fi # End of SYNC_ONLY condition

# Update and sync the repositories
if [ "$MAX_PACKAGES" -eq 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Updating repository metadata..."

    # If SYNC_ONLY is set, we need to determine which directories to update
    if ((SYNC_ONLY == 1)); then
        # Find all repositories under LOCAL_REPO_PATH
        while IFS= read -r -d '' dir; do
            repo_name=$(basename "$dir")
            used_directories["$repo_name"]="$dir/getPackage"
        done < <(find "$LOCAL_REPO_PATH" -mindepth 1 -maxdepth 1 -type d -print0)
    fi

    for repo in "${!used_directories[@]}"; do
        package_path="${used_directories[$repo]}"
        repo_path=$(dirname "$package_path")
        repo_name=$(basename "$repo_path")

        if ((DRY_RUN)); then
            echo "Dry Run: Would run 'createrepo --update $repo_path'"
        else
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Creating $repo_name repository indexes"
            if ! createrepo --update "$repo_path" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
                echo "$(date '+%Y-%m-%d %H:%M:%S') - Error updating metadata for $repo" >>"$MYREPO_ERR_FILE"
            fi
        fi
    done

    echo "$(date '+%Y-%m-%d %H:%M:%S') - Synchronizing repositories..."
    if ((DRY_RUN)); then
        echo "Dry Run: Would run 'rsync -av --delete $LOCAL_REPO_PATH/ $SHARED_REPO_PATH/'"
    else
        if ! rsync -av --delete "$LOCAL_REPO_PATH/" "$SHARED_REPO_PATH/" >>"$PROCESS_LOG_FILE" 2>>"$MYREPO_ERR_FILE"; then
            echo "$(date '+%Y-%m-%d %H:%M:%S') - Error synchronizing repositories." >>"$MYREPO_ERR_FILE"
        fi
    fi
fi

# Clean up
# rm "$INSTALLED_PACKAGES_FILE"

echo "myrepo.sh Version $VERSION completed."
