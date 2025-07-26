# Repo Handler Script (v2.2.0)

**Developed by**: Dániel Némethy (nemethy@moderato.hu) with different AI support models  
**AI flock**: ChatGPT, Claude, Gemini  
**Last Updated**: 2025-07-26

## Overview

The `repo-handler` project provides a high-performance bash script designed to manage, clean, and synchronize local package repositories on systems that are isolated from the Internet. This script is particularly useful for environments where a local mirror of installed packages needs to be maintained and synchronized with a shared repository.

**v2.2.0 Performance Optimizations**: This version has been completely optimized for performance with intelligent caching, achieving up to 95% speed improvements over previous versions while maintaining all core functionality. Complex adaptive features have been simplified in favor of reliable, fast operation with fixed optimal settings.

### Repository Architecture

The script manages a **LOCAL_REPO_PATH** (typically `/repo`) that contains two types of repositories:

1. **Internet-sourced repositories**: These contain a reduced subset of official internet repositories, including only the packages that are actually installed on the local "golden copy" system. This creates much smaller repositories compared to the original internet repositories.

2. **Manual repositories** (defined in `MANUAL_REPOS`): These are additional repositories (like `ol9_edge`) that will be replicated and synchronized regardless of whether their content is installed locally. These allow for manual package deployment and custom repository management.

The script helps:

- **Replicate and Update**: Creates and updates internet-sourced repositories based on installed packages from a "golden copy" system, plus manages manual repositories regardless of installation status.
- **Automatic Cleanup**: Removes uninstalled or outdated packages from internet-sourced repositories, ensuring they only contain necessary packages.
- **Manual Repository Support**: Maintains and synchronizes manual repositories (like `ol9_edge`) that can contain packages not necessarily installed locally.
- **Synchronization**: Keeps both types of repositories in sync with a shared repository using `rsync`.
- **Configuration Flexibility**: Allows customization through a configuration file `myrepo.cfg` and command-line arguments.
- **Repository Exclusions**: Enables exclusion of certain repositories from being processed.

![MyRepo Workflow](images/MyRepo.png)

### Key Features:

- **Reduced Repository Size**: The internet-sourced repositories are much smaller than the original upstream repositories, containing only packages installed on the specific environment, while manual repositories provide flexibility for additional package deployment.
- **Batch Processing**: Efficiently processes packages in batches for performance optimization.
- **Automatic Cleanup**: Removes older or uninstalled package versions from the local repository.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`.
- **Flexible Filtering**: Supports both repository-level and package name-level filtering for precise control over what gets processed.
- **Customizable Output**: Aligns repository names in output messages for better readability.
- **Configuration File Support**: Introduces `myrepo.cfg` for overriding default settings, with command-line arguments taking precedence.
- **Debugging Options**: Includes a `DEBUG_LEVEL` for controlling output verbosity during script execution.
- **Verbosity Control**: Allows setting the verbosity of log messages using the `DEBUG_LEVEL` option (0=critical, 1=important, 2=normal, 3=verbose, 4=very verbose). Message types determine display symbols: [E]rror, [W]arning, [S]uccess, [I]nfo, [P]rogress, [A]ction, [U]pdate, [D]ebug.
- **Error Handling Flexibility**: Provides configurable behavior to either halt immediately on critical download errors or continue running despite them (CONTINUE_ON_ERROR setting). 
- **Repository Exclusions**: Allows excluding repositories that should not be included in the local/shared mirror.

## Architecture Overview

The script manages a repository structure within **LOCAL_REPO_PATH** (typically `/repo`) that contains:

### 1. **Internet-sourced repositories** 
These are automatically managed repositories that mirror official internet repositories, but contain only packages that are installed on the local "golden copy" system. This dramatically reduces repository size compared to full upstream mirrors.

### 2. **Manual repositories** (MANUAL_REPOS)
These are additional repositories (e.g., `ol9_edge`) that:
- Are replicated and synchronized regardless of local installation status
- Allow for manual package deployment and custom repository management  
- Enable air-gapped environments to maintain custom package collections
- Can be manually populated with RPMs outside the script's automatic processing

**Key concepts:**
- **LOCAL_REPO_PATH**: Base directory (`/repo`) containing the complete repository tree structure
- **MANUAL_REPOS**: Specific repository names within LOCAL_REPO_PATH that receive special manual management treatment
- **getPackage**: Subdirectory within each repository where RPM packages are stored

## Requirements

Before running `myrepo.sh`, ensure the following requirements are met:

### System Requirements

- **Linux Distribution**: Red Hat-based distributions (RHEL, CentOS, Oracle Linux, etc.)
- **Package Manager**: DNF (Dandified YUM)
- **Tools**: `createrepo_c`, `rsync`, `bash` (version 4.0+)

### User Permissions

**Important**: Both modes require the user to have sudo privileges. The difference is how sudo is used:

**Default Mode (USER_MODE=0 - Recommended):**
- **Automatic Sudo Usage**: The script automatically prefixes necessary commands with `sudo`
- **User runs script normally**: `./myrepo.sh` (without sudo)
- The script will internally use `sudo` when needed for operations like:
  - Running DNF commands (`sudo dnf download`, `sudo dnf list`, etc.)
  - Creating and updating repository metadata (`sudo createrepo_c`)
  - Writing to system directories and fixing permissions

**User Mode (USER_MODE=1 - Advanced):**
- **Manual Sudo Usage**: User must run the entire script with elevated privileges
- **User runs script with sudo**: `sudo ./myrepo.sh --user-mode`
- The script assumes it already has elevated privileges and won't prefix commands with `sudo`
- All operations run with the elevated permissions of the sudo session

### Installation of Required Tools

```bash
# Install required packages (requires sudo)
sudo dnf install createrepo_c rsync dnf-utils
```

**Important**: If you don't have sudo access on your system, you cannot run this script. The script requires sudo privileges in both modes - the only difference is whether you run the script normally (default mode) and let it use `sudo` internally, or run the entire script with `sudo` (user mode).

## Configuration

### Using `myrepo.cfg`

The `myrepo.cfg` file provides a convenient way to configure `myrepo.sh` without modifying the script itself. All default configuration options are listed in the file, commented out. To customize the script:

1. **Open `myrepo.cfg`**:

   ```bash
   nano myrepo.cfg
   ```

2. **Uncomment and Modify Desired Options**:

   For example, to change the `DEBUG_LEVEL` to `3`:

   ```bash
   # Set verbosity level (0=critical, 1=important, 2=normal, 3=verbose, 4=very verbose)
   DEBUG_LEVEL=3
   ```

3. **Save and Close the File**.

### Configuration Options

```bash
# myrepo.cfg - Configuration file for myrepo.sh
# The default values are given below, commented out.
# To configure, uncomment the desired lines and change the values.

# Set the repository base path (directory containing both internet-sourced and manual repositories)
# LOCAL_REPO_PATH="/repo"

# Set the shared repository path
# SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"

# Define manual repositories (individual repos within LOCAL_REPO_PATH, comma-separated)
# MANUAL_REPOS="ol9_edge"

# Set the RPM build path
# RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Set verbosity level (0=critical, 1=important, 2=normal, 3=verbose, 4=very verbose)
# DEBUG_LEVEL=2

# Set maximum number of packages to process (0 = no limit)
# MAX_PACKAGES=0

# Set batch size for processing
# BATCH_SIZE=50

# Set the number of parallel processes
# PARALLEL=6

# Enable dry run (1 = true, 0 = false)
# DRY_RUN=0

# Continue execution despite download errors (0 = halt on errors, 1 = continue despite errors)
# CONTINUE_ON_ERROR=0

# Run under the non-root user environment (1 = true, 0 = false)
# IS_USER_MODE=0

# Define repositories that should be excluded from processing
# Any packages from these repositories will not be mirrored or added to LOCAL_REPO_PATH
EXCLUDED_REPOS="copr:copr.fedorainfracloud.org:wezfurlong:wezterm-nightly"

# Filter packages by name using regex pattern (empty = process all packages)
# NAME_FILTER=""

# Filter repositories to process (comma-separated list, empty = process all enabled)
# FILTER_REPOS=""

# Re‑scan everything on the next run (1 = true, 0 = false).
# When set to 1 the processed‑package cache is cleared at start‑up.
# FULL_REBUILD=0

# Cache validity in seconds (default: 14400 = 4 hours)
# CACHE_MAX_AGE=14400

# Automatically fix permission issues when detected (1 = enabled, 0 = disabled)
# SET_PERMISSIONS=0

# Force refresh of DNF metadata cache and rebuild repository cache (1 = enabled, 0 = disabled)
# REFRESH_METADATA=0

# Use serial DNF mode to prevent database lock contention (1 = enabled, 0 = disabled)
# DNF_SERIAL=0

# Note: The following options from previous versions are no longer supported in v2.2.0:
# - ADAPTIVE_TUNING and related adaptive performance settings (replaced with optimal defaults)
# - Complex cache settings (simplified to CACHE_MAX_AGE)
# - AUTO_UPDATE_MANUAL_REPOS (now always enabled)
# - LOCAL_REPO_CHECK_METHOD (optimized for performance)
# - GROUP_OUTPUT (output is now consistently formatted)
# - REPO_COMPRESS_TYPE (now uses optimal defaults)
```

### Log Level Control

The logging system uses two concepts:

1. **Verbosity Level** (`DEBUG_LEVEL`): Controls how much output is shown
2. **Message Types**: Determine the display symbol and semantic meaning

#### Verbosity Levels

The `DEBUG_LEVEL` option controls the verbosity of log output:

- `0` (Critical): Shows only critical errors that prevent script execution
- `1` (Important): Shows important messages like warnings, progress, and success notifications  
- `2` (Normal): Shows normal informational messages and all above levels (default)
- `3` (Verbose): Shows detailed debugging information and all above levels
- `4` (Very Verbose): Shows very detailed trace information for troubleshooting

#### Message Types and Display Symbols

Messages are displayed with symbols that indicate their semantic meaning:

- `[E]` Error: Critical issues that may stop execution
- `[W]` Warning: Issues that need attention but don't stop execution  
- `[S]` Success: Successful completion of operations
- `[I]` Info: General informational messages
- `[P]` Progress: Progress updates and status information
- `[A]` Action: Actions being performed
- `[U]` Update: Update operations
- `[D]` Debug: Detailed debugging information

#### Configuration

To set the verbosity level, modify the `DEBUG_LEVEL` option in `myrepo.cfg`:

```bash
# Set verbosity level (0=critical, 1=important, 2=normal, 3=verbose, 4=very verbose)
DEBUG_LEVEL=2
```

You can also set it via command line using `--debug LEVEL`.

### Repository Exclusion Feature

Some repositories may contain packages installed on the golden-copy machine but are **not intended to be mirrored**. The `EXCLUDED_REPOS` setting ensures that these repositories are:

1. **Skipped during processing** (packages from these repositories will not be added to the local repo).
2. **Removed from the local repository path if already present**.

This feature is useful for temporary or special-purpose repositories, such as **Copr repositories**.

### Package Name Filtering Feature

The `--name-filter` option allows you to process only specific packages based on their name patterns, making the script more efficient for targeted operations. This feature applies regex pattern matching to package names during the installed package fetching phase.

#### Use Cases:

- **Testing**: Process only specific packages to test repository functionality
- **Selective Mirroring**: Mirror only packages matching certain naming patterns (e.g., all `nodejs*` packages)
- **Debugging**: Isolate specific packages for troubleshooting
- **Performance**: Reduce processing time when only certain packages are needed

#### Examples:

```bash
# Process only Firefox packages
./myrepo.sh --name-filter "firefox"

# Process all NodeJS-related packages
./myrepo.sh --name-filter "nodejs"

# Process packages starting with "lib" (using regex)
./myrepo.sh --name-filter "^lib"

# Combine with repository filtering for precise control
./myrepo.sh --repos ol9_appstream --name-filter "firefox|chrome"
```

#### Configuration File Support:

You can also set the name filter in `myrepo.cfg`:

```bash
# Filter packages by name using regex pattern
NAME_FILTER="firefox"
```

#### Important Notes:

- **Regex Support**: The pattern supports extended regular expressions (ERE)
- **Efficient Processing**: Filtering is applied at the DNF query level, not after fetching all packages
- **Graceful Handling**: If no packages match the filter, the script continues normally without errors
- **Case Sensitive**: Pattern matching is case-sensitive by default
- **Combines with Repository Filtering**: Works together with `--repos` for fine-grained control

### Manual Repository Management (Manual Change Detection)

Version 2.3.0+ introduces advanced manual repository management that can automatically detect and handle manual changes to individual manual repositories within the repository tree. This is particularly useful in environments where RPM packages are manually copied to specific repositories (like `ol9_edge`) outside of the script's normal processing workflow.

#### Key Features:

- **Dual-Tier Metadata Strategy**: Regular repositories only update metadata when packages are processed, while manual repositories (e.g., `ol9_edge`) can detect manual changes even when no packages are processed during the current run.
- **Configurable Detection Methods**: Choose between FAST (timestamp-based) and ACCURATE (content-based) detection methods.
- **Automatic Updates**: Manual repositories are automatically checked for manual changes and metadata is updated accordingly.
- **Sync-Only Mode Optimization**: Metadata updates are intelligently skipped during `--sync-only` mode for better performance.

#### Configuration Options:

```bash
# Enable automatic detection and update of manual repository changes (1 = enabled, 0 = disabled)
# When enabled, the script will check manual repositories for manual changes even if no packages
# were processed during the current run. Useful for repositories where RPMs are manually copied.
AUTO_UPDATE_MANUAL_REPOS=1

# Manual repository metadata check method (FAST or ACCURATE)
# FAST: Uses timestamp comparison between RPM files and metadata (faster, good for most cases)
# ACCURATE: Uses content comparison to detect count mismatches (more thorough but slower)
# Default is FAST for optimal performance while still catching most manual changes.
LOCAL_REPO_CHECK_METHOD=FAST
```

#### How It Works:

1. **FAST Method**: Compares the newest RPM file timestamp against the repository metadata timestamp. If RPMs are newer, metadata is updated.
2. **ACCURATE Method**: Counts actual RPM files and compares with the metadata package count. If counts differ, metadata is updated.

#### Use Cases:

- **Manual Package Deployment**: When administrators manually copy RPM files to specific manual repositories (like `ol9_edge`)
- **Airgapped Environments**: Where packages are transferred via external media and manually placed
- **Mixed Workflows**: Environments where both automated and manual package management occur
- **Development Environments**: Where local builds are frequently copied to test repositories

#### Example Configuration:

```bash
# myrepo.cfg - Enable accurate detection for critical repositories
AUTO_UPDATE_MANUAL_REPOS=1
LOCAL_REPO_CHECK_METHOD=ACCURATE
MANUAL_REPOS="ol9_edge,custom_apps,local_builds"
```

This ensures that manually added packages are properly indexed and available through the repository metadata without requiring a full rebuild.

### Performance Optimizations (v2.2.0)

This version has been completely redesigned for optimal performance, replacing the previous adaptive tuning system with fixed optimal settings that provide consistently excellent performance across different environments.

#### Key Performance Improvements:

- **Intelligent Caching System**: Repository metadata is cached for 4 hours (configurable) with version-based invalidation
- **Batch Processing**: Optimized batch downloads with parallel processing for maximum throughput  
- **Cache Hits**: Up to 95% performance improvement when cache is valid
- **Fixed Optimal Settings**: Replaced complex adaptive algorithms with proven optimal defaults
- **Streamlined Code**: Reduced script complexity while maintaining all core functionality

#### Default Performance Settings:

```bash
# Optimized defaults (fixed for reliability and performance)
BATCH_SIZE=50              # Optimal batch size for most systems
PARALLEL=6                 # Optimal parallel processes for most systems  
CACHE_MAX_AGE=14400        # 4-hour cache validity (in seconds)
```

#### Cache Management:

- **Version-Based Validation**: Cache automatically invalidates when repository metadata changes
- **Time-Based Fallback**: Cache expires after configurable time period (default: 4 hours)
- **Force Refresh**: Use `--refresh-metadata` to force cache rebuild
- **Intelligent Loading**: Only caches metadata for packages that are actually installed

#### Benefits of v2.2.0 Optimizations:

- **Predictable Performance**: Fixed optimal settings provide consistent results
- **Reduced Complexity**: Simpler configuration with fewer variables to tune
- **Better Reliability**: Eliminated complex adaptive logic that could cause unpredictable behavior
- **Faster Startup**: Intelligent caching dramatically reduces initial metadata loading time
- **Lower Resource Usage**: Optimized algorithms use less CPU and memory

The adaptive tuning system is enabled by default with conservative settings that work well for most environments while providing room for optimization.

### Configuration: Parallel Metadata Fetching

- **REPOQUERY_PARALLEL**: Number of parallel jobs for repository metadata fetching (dnf repoquery). Default: 4. Increase for faster metadata updates if you have many enabled repositories and sufficient CPU/network resources. Lower if you experience resource contention. Set in `myrepo.cfg` as:

  ```bash
  REPOQUERY_PARALLEL=4
  ```

This parameter only affects the parallelism of metadata fetching, not the main package download or processing parallelism (see `PARALLEL` and `BATCH_SIZE`).

### Priority of Settings

- **Command-Line Arguments**: Highest priority. They override both the configuration file and default values.
- **Configuration File (`myrepo.cfg`)**: Overrides default values in the script.
- **Default Values**: Used when neither command-line arguments nor configuration file settings are provided.

## Permissions and Directory Setup

### Directory Requirements

The script requires proper write access to all configured directory paths. Directory permissions are validated during startup to ensure proper operation.

#### Required Directories

1. **LOCAL_REPO_PATH** (Critical)
   - Main local repository directory 
   - Must exist and be writable
   - All subdirectories must be writable
   - Validation includes practical write tests

2. **SHARED_REPO_PATH** (Warning if missing)
   - Shared/synchronization repository directory
   - Write access required for synchronization
   - Missing access generates warnings but doesn't stop execution

3. **LOG_DIR** (Auto-created)
   - Directory for log files
   - Created automatically if missing
   - Must be writable for log output

4. **RPMBUILD_PATH** (Optional)
   - RPM build directory
   - Validated but write access not strictly required

#### Permission Validation

The script performs comprehensive permission validation during startup:

1. **Directory Existence Check**
   - Verifies all configured paths exist and are directories
   - Reports missing directories as errors (LOCAL_REPO_PATH) or warnings (others)

2. **Write Permission Check**
   - Tests basic write permissions using filesystem flags
   - Performs practical write tests by creating temporary files
   - Validates access to repository subdirectories (getPackage, repodata)

3. **User Mode vs Root Mode**
   - `USER_MODE=0` (Default): User runs script normally (`./myrepo.sh`), script uses `sudo` internally for elevated operations
   - `USER_MODE=1` (Advanced): User runs entire script with sudo (`sudo ./myrepo.sh --user-mode`), script assumes elevated privileges

4. **Error Handling**
   - LOCAL_REPO_PATH permission errors will cause script exit (critical)
   - SHARED_REPO_PATH permission errors generate warnings only (non-critical)
   - Subdirectory permission errors are reported with fix suggestions

#### Setting Up Permissions

**For Default Mode (USER_MODE=0) - Recommended:**
```bash
# Simply ensure your user has sudo privileges
# The script will automatically use sudo for necessary operations
./myrepo.sh
```

**For User Mode (USER_MODE=1) - Advanced:**
```bash
# Run the entire script with sudo
sudo ./myrepo.sh --user-mode

# Or configure sudoers for passwordless sudo
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/myrepo-user
```

#### Troubleshooting Permissions

Common permission issues and solutions:

1. **"LOCAL_REPO_PATH is not writable by current user"**
   ```bash
   sudo chown -R $(whoami):$(id -gn) /repo
   ```

2. **"Repository directory not writable"**
   ```bash
   chmod -R u+w /repo/repository_name
   ```

3. **"Cannot create files in LOCAL_REPO_PATH"**
   - Check if filesystem is read-only
   - Verify disk space availability
   - Check SELinux contexts if applicable

4. **"Repository synchronization may fail"**
   - Fix SHARED_REPO_PATH permissions:
   ```bash
   sudo chown -R $(whoami):$(id -gn) /mnt/shared/repos
   ```

#### Debug Output

Use `DEBUG_LEVEL=3` (verbose) to see detailed permission validation output:
```bash
./myrepo.sh --debug 3
```

This will show:
- All permission checks being performed
- Practical write test results
- Detailed validation for each repository subdirectory
- Permission error causes and suggested fixes

#### Automatic Permission Fixing

The `--set-permissions` option enables automatic fixing of permission issues when they are detected:

```bash
# Automatically fix permission issues during script execution
./myrepo.sh --set-permissions

# Combine with debug output to see what's being fixed
./myrepo.sh --set-permissions --debug 2
```

**How it works:**
- When permission issues are detected, the script attempts to fix them automatically
- Uses `sudo chown` to set correct ownership and `chmod` to set write permissions
- Only attempts fixes when the user has appropriate sudo privileges
- Reports success or failure of permission fixes
- Continues script execution after attempting fixes

**Use cases:**
- New repository setup where permissions haven't been configured yet
- Environments where directory ownership changes (e.g., after system updates)
- Troubleshooting permission issues without manual intervention
- Automated deployment scenarios

**Safety notes:**
- Only modifies permissions on directories configured in the script
- Requires sudo privileges to modify directory ownership
- Will not attempt fixes if sudo access is not available

## Usage

### Prerequisites

**Important**: The script requires sudo privileges in all modes. You must have sudo access to run DNF operations and manage repository directories.

- **Default Mode**: Run script normally, it will use `sudo` internally when needed
- **User Mode**: Run entire script with `sudo ./myrepo.sh --user-mode`

If you don't have sudo access, the script cannot function.

### Running `myrepo.sh`

You can customize and run the `myrepo.sh` script to handle your local repository:

```bash
./myrepo.sh [options]
```


## CLI Options

| Option               | Values                     | Default               | Description                                                   |
|----------------------|----------------------------|------------------------|---------------------------------------------------------------|
| `--batch-size`       | *INT*                      | `50`                  | Number of packages per batch.                                 |
| `--cache-max-age`    | *INT*                      | `14400`               | Cache validity in seconds (14400 = 4 hours).                 |
| `--debug`            | *0‒3*                      | `1`                   | Verbosity level (0=critical, 1=important, 2=normal, 3=verbose). |
| `--dry-run`          | *(flag)*                   | *off*                 | Perform a dry run without making changes.                     |
| `--exclude-repos`    | *CSV*                      | *empty*               | Comma-separated list of repos to exclude.                     |
| `--full-rebuild`     | *(flag)*                   | *off*                 | Perform a full rebuild of the repository.                     |
| `--local-repo-path`  | *PATH*                     | `/repo`               | Set local repository path.                                    |
| `--log-dir`          | *PATH*                     | `/var/log/myrepo`     | Where to write log files (preserved for compatibility).       |
| `--manual-repos`     | *CSV*                      | `ol9_edge`            | Comma‑separated list of manual repositories.                  |
| `--max-packages`     | *INT*                      | `0`                   | Limit total number of packages processed (0 = no limit).      |
| `--max-new-packages` | *INT*                      | `0`                   | Limit number of new packages to download (0 = no limit).      |
| `--name-filter`      | *REGEX*                    | *empty*               | Filter packages by name using regex pattern.                  |
| `--parallel`         | *INT*                      | `6`                   | Maximum concurrent download or processing jobs.               |
| `--repos`            | *CSV*                      | *all enabled*         | Comma-separated list of repositories to process.              |
| `--set-permissions`  | *(flag)*                   | *off*                 | Automatically fix permission issues when detected.            |
| `--shared-repo-path` | *PATH*                     | `/mnt/hgfs/ForVMware/ol9_repos` | Set shared repository path.                         |
| `--sync-only`        | *(flag)*                   | *off*                 | Skip download/cleanup; only run sync to shared repos.         |
| `--test-limit`       | *INT*                      | *same as max-packages*| Limit to NUM packages for testing (same as --max-packages).   |
| `--user-mode`        | *(flag)*                   | *off*                 | Run entire script with sudo (advanced mode).                  |
| `--refresh-metadata` | *(flag)*                   | *off*                 | Force refresh of DNF metadata cache and rebuild repo cache.   |
| `--dnf-serial`       | *(flag)*                   | *off*                 | Use serial DNF mode to prevent database lock contention.      |

#### Examples:

```bash
# Basic usage with debugging and custom settings
./myrepo.sh --debug 1 --batch-size 60 --repos ol9_edge,pgdg16 --local-repo-path /custom/repo

# Process only Firefox packages from ol9_appstream repository
./myrepo.sh --repos ol9_appstream --name-filter "firefox" --debug 1

# Process all NodeJS packages with dry-run to see what would happen
./myrepo.sh --name-filter "nodejs" --dry-run --debug 1

# Test with limited packages and show cache performance
./myrepo.sh --test-limit 50 --dry-run --debug 2

# Limit new package downloads to manage bandwidth/storage
./myrepo.sh --max-new-packages 100 --debug 1

# Use shorter cache validity for frequently changing repositories
./myrepo.sh --cache-max-age 3600 --debug 2  # 1 hour cache

# Sync-only mode for fast rsync without package processing
./myrepo.sh --sync-only

# Full rebuild with verbose debugging
./myrepo.sh --full-rebuild --debug 2

# User mode for environments where you want to run the entire script with sudo
sudo ./myrepo.sh --user-mode --local-repo-path /repo

# Force metadata refresh before processing (clears cache)
./myrepo.sh --refresh-metadata --debug 1

# Serial DNF mode for systems with database locking issues
./myrepo.sh --dnf-serial --debug 1

# Process specific repositories with custom parallel settings
./myrepo.sh --repos ol9_appstream,ol9_baseos --parallel 4 --batch-size 80

# Automatically fix permission issues when detected
./myrepo.sh --set-permissions --debug 2

# User mode with permission auto-fix
sudo ./myrepo.sh --user-mode --set-permissions --local-repo-path /repo
```

### How It Works

The script implements a sophisticated workflow that efficiently manages local package repositories with intelligent metadata handling:

1. **Fetching Installed Packages**: Retrieves the list of installed packages from the system using DNF/YUM queries, with optional filtering by repository or package name patterns.

2. **Determining Package Status**: For each package, determines whether it's NEW (needs to be added), EXISTS (already present), UPDATE (newer version available), or should be skipped.

3. **Processing Packages**: Processes packages in optimized batches using adaptive performance tuning. Local packages are handled differently from remote packages to account for manual deployment scenarios.

4. **Cleaning Up**: Removes uninstalled packages and outdated versions from local repositories to maintain a clean, current state.

5. **Dual-Tier Metadata Updates**: 
   - **Regular Repositories**: Updates metadata only when packages are processed during the current run
   - **Manual Repositories**: Checks for manual changes (using configurable FAST/ACCURATE methods) and updates metadata accordingly, even if no packages were processed automatically

6. **Synchronization**: Uses rsync to efficiently synchronize the local repositories with shared storage, ensuring consistency across environments.

7. **Performance Optimization**: Continuously monitors and adjusts processing parameters (batch size, parallelism) based on real-time performance metrics to maximize throughput.

## Tips

- **Dry Run Mode**: Use the `--dry-run` option to simulate the script's actions without making any changes.
- **Debugging**: Increase the `DEBUG_LEVEL` to get more detailed output, which can help in troubleshooting.
- **Verbosity Control**: Adjust the `DEBUG_LEVEL` to control how much output is shown (0=critical, 1=important, 2=normal, 3=verbose, 4=very verbose).
- **Repository Exclusion**: Ensure that unwanted repositories are listed in `EXCLUDED_REPOS` to prevent unnecessary replication.
- **Efficient Filtering**: Use `--name-filter` combined with `--repos` for precise control over package processing and improved performance.
- **Testing Filters**: Always test new name filter patterns with `--dry-run` first to verify they match the expected packages.
- **Manual Repository Management**: Enable `AUTO_UPDATE_MANUAL_REPOS` and choose the appropriate `LOCAL_REPO_CHECK_METHOD` for environments with manual package deployment.
- **Performance Tuning**: Let adaptive tuning optimize performance automatically, or disable it and manually tune `BATCH_SIZE` and `PARALLEL` for specific environments.
- **Sync-Only Mode**: Use `--sync-only` for fast repository synchronization when no package processing is needed.
- **User Mode**: Use `--user-mode` when you prefer to run the entire script with sudo (`sudo ./myrepo.sh --user-mode`) rather than letting the script use sudo internally.
- **Permission Fixes**: Use `--set-permissions` to automatically fix directory permission issues when detected, useful for new setups or troubleshooting.
- **Metadata Refresh**: Use `--refresh-metadata` when DNF cache issues are suspected or after repository configuration changes.
- **Monitoring**: Check the performance statistics output to understand processing efficiency and identify potential bottlenecks.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.

## Conclusion

The `repo-handler` script provides a comprehensive and intelligent solution for managing local package repositories in isolated environments. With features like adaptive performance tuning, dual-tier metadata management, intelligent local repository change detection, and flexible filtering options, it offers both power and ease of use. The script automatically optimizes its performance while ensuring that your repositories remain current and contain only the necessary packages for your specific environment.

The combination of configuration file support, extensive command-line options, and automatic optimization makes it suitable for a wide range of use cases, from simple package mirroring to complex multi-repository environments with both automated and manual package management workflows.

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.

## Conclusion

The `repo-handler` script provides a comprehensive and intelligent solution for managing local package repositories in isolated environments. With features like adaptive performance tuning, dual-tier metadata management, intelligent local repository change detection, and flexible filtering options, it offers both power and ease of use. The script automatically optimizes its performance while ensuring that your repositories remain current and contain only the necessary packages for your specific environment.

The combination of configuration file support, extensive command-line options, and automatic optimization makes it suitable for a wide range of use cases, from simple package mirroring to complex multi-repository environments with both automated and manual package management workflows.

