# Repo Handler Script

**Developed by**: Dániel Némethy (nemethy@moderato.hu) with AI support (ChatGPT-4)

## Overview

The `repo-handler` project provides a bash script designed to|| `--max-packages`    | *INT*                      | `0` | `--parallel`        | *INT*                      | `2`                   | Maximum concurrent download or cleanup jobs.                    |
| `--shared-repo-path`| *PATH*                     | `/mnt/hgfs/ol9_repos` | Destination folder that receives the rsync'ed copy.             |
| `--sync-only`       | *(flag)*                   | *off*                 | Skip download/cleanup and metadata; only rsync.                 |
| `--user-mode`       | *(flag)*                   | *off*                 | Run without `sudo`; helper files go under `$HOME/tmp`.          |              | Limit the total number of packages scanned (0 = no limit).      |
| `--name-filter`     | *REGEX*                    | *empty*               | Filter packages by name using regex pattern during processing.  |
| `--parallel`        | *INT*                      | `2`                   | Maximum concurrent download or cleanup jobs.                    |
| `--repos`           | *CSV*                      | *all enabled*         | Comma‑separated list of repos to process (filters packages).    |--parallel`        | *INT*                      | `2`                   | Maximum concurrent download or cleanup jobs.                    |
| `--repos`           | *CSV*                      | *all enabled*         | Comma‑separated list of repos to process (filters packages).    |
| `--shared-repo-path`| *PATH*                     | `/mnt/hgfs/ol9_repos` | Destination folder that receives the rsync'ed copy.             |anage, clean, and synchronize local package repositories on systems that are isolated from the Internet. This script is particularly useful for environments where a local mirror of installed packages needs to be maintained and synchronized with a shared repository. The goal is to create a much smaller repository that contains only the packages required for the specific environment, compared to the vast number of packages in the original internet repositories.

The script helps:

- **Replicate and Update**: Creates and updates a local repository based on the installed packages from a "golden copy" system.
- **Automatic Cleanup**: Removes uninstalled or outdated packages from the repository, ensuring it only contains necessary packages.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`, allowing the local repository to remain fresh and current.
- **Configuration Flexibility**: Allows customization through a configuration file `myrepo.cfg` and command-line arguments, providing flexibility and ease of use.
- **Repository Exclusions**: Enables exclusion of certain repositories from being processed, useful for repositories that should not be mirrored.

![MyRepo Workflow](images/MyRepo.png)

### Key Features:

- **Reduced Repository Size**: The replicated repository is much smaller than the original internet repositories, containing only the necessary packages for the specific environment.
- **Batch Processing**: Efficiently processes packages in batches for performance optimization.
- **Automatic Cleanup**: Removes older or uninstalled package versions from the local repository.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`.
- **Flexible Filtering**: Supports both repository-level and package name-level filtering for precise control over what gets processed.
- **Customizable Output**: Aligns repository names in output messages for better readability.
- **Configuration File Support**: Introduces `myrepo.cfg` for overriding default settings, with command-line arguments taking precedence.
- **Debugging Options**: Includes a `DEBUG_MODE` for verbose output during script execution.
- **Log Level Control**: Allows setting the verbosity of log messages using the `LOG_LEVEL` option (e.g., `ERROR`, `WARN`, `INFO`, `DEBUG`).
- **Error Handling Flexibility**: Provides configurable behavior to either halt immediately on critical download errors or continue running despite them (CONTINUE_ON_ERROR setting). 
- **Repository Exclusions**: Allows excluding repositories that should not be included in the local/shared mirror.

## Configuration

### Using `myrepo.cfg`

The `myrepo.cfg` file provides a convenient way to configure `myrepo.sh` without modifying the script itself. All default configuration options are listed in the file, commented out. To customize the script:

1. **Open `myrepo.cfg`**:

   ```bash
   nano myrepo.cfg
   ```

2. **Uncomment and Modify Desired Options**:

   For example, to change the `DEBUG_MODE` to `1`:

   ```bash
   # Set debug mode (0 = off, 1 = basic debug, 2 = verbose debug)
   DEBUG_MODE=1
   ```

3. **Save and Close the File**.

### Configuration Options

```bash
# myrepo.cfg - Configuration file for myrepo.sh
# The default values are given below, commented out.
# To configure, uncomment the desired lines and change the values.

# Set the local repository path
# LOCAL_REPO_PATH="/repo"

# Set the shared repository path
# SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"

# Define local repositories (comma-separated)
# LOCAL_REPOS="ol9_edge,pgdg-common,pgdg16"

# Set the RPM build path
# RPMBUILD_PATH="/home/nemethy/rpmbuild/RPMS"

# Set debug mode (0 = off, 1 = basic debug, 2 = verbose debug)
# DEBUG_MODE=0

# Set log level (ERROR, WARN, INFO, DEBUG)
# LOG_LEVEL="INFO"

# Set maximum number of packages to process (0 = no limit)
# MAX_PACKAGES=0

# Set batch size for processing
# BATCH_SIZE=50

# Set the number of parallel processes
# PARALLEL=2

# Enable dry run (1 = true, 0 = false)
# DRY_RUN=0

# Continue execution despite download errors (0 = halt on errors, 1 = continue despite errors)
# CONTINUE_ON_ERROR=0

# Run under the non-root user environment (1 = true, 0 = false)
# USER_MODE=0

# Define repositories that should be excluded from processing
# Any packages from these repositories will not be mirrored or added to LOCAL_REPO_PATH
EXCLUDED_REPOS="copr:copr.fedorainfracloud.org:wezfurlong:wezterm-nightly"

# Filter packages by name using regex pattern (empty = process all packages)
# NAME_FILTER=""

# Filter repositories to process (comma-separated list, empty = process all enabled)
# FILTER_REPOS=""

# myrepo.cfg – Configuration file for myrepo.sh
...
# Re‑scan everything on the next run (1 = true, 0 = false).
# When set to 1 the processed‑package cache is cleared at start‑up.
# FULL_REBUILD=0

```

### Log Level Control

The `LOG_LEVEL` option allows you to control the verbosity of log messages. Available levels are:

- `ERROR`: Logs only critical errors.
- `WARN`: Logs warnings and errors.
- `INFO`: Logs informational messages, warnings, and errors (default).
- `DEBUG`: Logs detailed debugging information, along with all other levels.

To set the log level, modify the `LOG_LEVEL` option in `myrepo.cfg`:

```bash
# Set log level (ERROR, WARN, INFO, DEBUG)
LOG_LEVEL="DEBUG"
```

Alternatively, you can override this setting using the `--log-level` command-line argument:

```bash
./myrepo.sh --log-level DEBUG
```

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
```


### Configuration: Parallel Metadata Fetching

- **REPOQUERY_PARALLEL**: Number of parallel jobs for repository metadata fetching (dnf repoquery). Default: 4. Increase for faster metadata updates if you have many enabled repositories and sufficient CPU/network resources. Lower if you experience resource contention. Set in `myrepo.cfg` as:

  ```
  REPOQUERY_PARALLEL=4
  ```

This parameter only affects the parallelism of metadata fetching, not the main package download or processing parallelism (see `PARALLEL` and `BATCH_SIZE`).

### Priority of Settings

- **Command-Line Arguments**: Highest priority. They override both the configuration file and default values.
- **Configuration File (`myrepo.cfg`)**: Overrides default values in the script.
- **Default Values**: Used when neither command-line arguments nor configuration file settings are provided.

## Usage

### Running `myrepo.sh`

You can customize and run the `myrepo.sh` script to handle your local repository:

```bash
./myrepo.sh [options]
```


## CLI Options

| Option              | Argument                   | Default               | Purpose                                                         |
|---------------------|--------------------------- |-----------------------|-----------------------------------------------------------------|
| `--batch-size`      | *INT*                      | `50`                  | Number of packages processed in one batch (optimized default). |
| `--debug`           | *0‒2*                      | `0`                   | Extra runtime diagnostics (0 = off, 1 = basic, 2 = verbose).    |
| `--dry-run`         | *(flag)*                   | *off*                 | Simulate all actions; make **no** changes on disk.              |
| `--exclude-repos`   | *CSV*                      | *empty*               | Comma‑separated list of repo IDs that must **not** be mirrored. |
| `--full-rebuild`    | *(flag)*                   | *off*                 | Clear the processed‑package cache and rescan **everything**.    |
| `--local-repo-path` | *PATH*                     | `/repo`               | Root directory that holds the local mirrors.                    |
| `--local-repos`     | *CSV*                      | `ol9_edge`            | Comma‑separated list of repos considered “local sources”.       |
| `--log-dir`         | *PATH*                     | `/var/log/myrepo`     | Where to write `process_package.log`, `myrepo.err`, etc.        |
| `--log-level`       | `ERROR\|WARN\|INFO\|DEBUG` | `INFO`                | Filter normal log messages by severity.                         |
| `--max-packages`    | *INT*                      | `0`                   | Limit the total number of packages scanned (0 = no limit).      |
| `--parallel`        | *INT*                      | `2`                   | Maximum concurrent download or cleanup jobs.                    |
| `--shared-repo-path`| *PATH*                     | `/mnt/hgfs/ol9_repos` | Destination folder that receives the rsync’ed copy.             |
| `--sync-only`       | *(flag)*                   | *off*                 | Skip download/cleanup; only run `createrepo` + `rsync`.         |
| `--user-mode`       | *(flag)*                   | *off*                 | Run without `sudo`; helper files go under `$HOME/tmp`.          |
| `--version`         | —                          | —                     | Print script version and exit.                                  |
| `--help`            | —                          | —                     | Display built‑in usage synopsis.                                |


#### Example:

```bash
# Basic usage with debugging and custom settings
./myrepo.sh --debug 1 --batch-size 60 --repos ol9_edge,pgdg16 --local-repo-path /custom/repo

# Process only Firefox packages from ol9_appstream repository
./myrepo.sh --repos ol9_appstream --name-filter "firefox" --debug 1

# Process all NodeJS packages with dry-run to see what would happen
./myrepo.sh --name-filter "nodejs" --dry-run --debug 1
```

### How It Works

1. **Fetching Installed Packages**
2. **Determining Package Status**
3. **Processing Packages**
4. **Cleaning Up**
5. **Updating Repository Metadata**
6. **Synchronization**

## Tips

- **Dry Run Mode**: Use the `--dry-run` option to simulate the script's actions without making any changes.
- **Debugging**: Increase the `DEBUG_MODE` to get more detailed output, which can help in troubleshooting.
- **Log Level Control**: Adjust the `LOG_LEVEL` to control the verbosity of log messages.
- **Repository Exclusion**: Ensure that unwanted repositories are listed in `EXCLUDED_REPOS` to prevent unnecessary replication.
- **Efficient Filtering**: Use `--name-filter` combined with `--repos` for precise control over package processing and improved performance.
- **Testing Filters**: Always test new name filter patterns with `--dry-run` first to verify they match the expected packages.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.

## Conclusion

The `repo-handler` script provides a robust solution for managing local package repositories in isolated environments. By utilizing a configuration file and command-line options, it offers flexibility and ease of use, ensuring that your repositories are always up-to-date and contain only the necessary packages.

