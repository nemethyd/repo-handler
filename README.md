# Repo Handler Script (v2.3.30)

Author: Dániel Némethy (nemethy@moderato.hu)

## Purpose

`myrepo.sh` builds and maintains lean local RPM repositories that mirror only the packages actually installed on a host (plus any manually managed repositories). It can then update repository metadata and optionally sync the result to a shared location. Intended for disconnected / controlled environments where you need a reproducible subset of upstream repositories.

## Workflow Diagram

The high‑level flow (golden system -> curated local repos -> optional sync) is illustrated below:

![MyRepo Workflow](images/MyRepo.png)

Legend:
- Golden / source system: authoritative list of currently installed RPMs.
- Repo handler (`myrepo.sh`): classifies packages (NEW / UPDATE / EXISTS), downloads only what is missing or newer, prunes removed ones, regenerates metadata.
- Local lean repositories: minimal per‑repository trees containing just required RPMs + `repodata/`.
- (Optional) Shared / exported repository location: synchronized mirror for other consumers or air‑gapped hosts.

Result: You retain only the subset of upstream content actually in use, drastically shrinking storage and transfer footprint while preserving reproducibility.

### Single-File Design Philosophy

This project is intentionally delivered as **one self‑contained Bash script** (plus an optional config file):

Why one file:
1. Zero install friction – copy `myrepo.sh` to a host and run.
2. Easier auditing – security / change reviews can diff a single artifact.
3. Air‑gapped friendliness – no module resolution or path dependencies.
4. Rapid field patching – emergency edits can be applied in place, then replaced later with a clean upstream copy.

What this means:
- No sourcing of external helper libraries is required (and we keep it that way).
- `myrepo.cfg` is **optional**; absence falls back to safe internal defaults.
- Any future feature must justify extraction; preference is structured sections inside the same file with clear comment banners.

Non‑goals (by design):
- Splitting into many shell modules.
- Introducing a build / packaging step.
- Requiring installation of the project into system paths to function.

Potential future (optional) enhancement (not implemented): a `--write-default-config` flag that would emit a commented template `myrepo.cfg` if missing. Deferred intentionally to avoid side‑effects and because the script already runs well without a config file.

## What It Actually Does (Current Implementation)

1. Loads defaults and (if present) `myrepo.cfg` located beside the script.
2. Auto‑detects privilege mode (root / sudo / user) and uses `dnf` directly or via `sudo`.
3. Builds / reuses a shared metadata cache of repository package lists (only for installed packages) under `SHARED_CACHE_PATH`.
4. Queries all installed packages with repository info using `dnf repoquery`.
5. Filters, normalizes and deduplicates the package list (skips invalid repos, collapses duplicates, optional name regex filter).
6. Determines the source repository for each package (resolving `@System` packages using cached metadata, fallback heuristics and manual repo scan).
7. Classifies each package as NEW / UPDATE / EXISTS per repository by comparing the presence and version of RPM files already stored locally.
8. Copies RPMs from configured local source directories first (avoids redownloading already available artifacts).
9. Batches remaining NEW and UPDATE downloads per repository using `dnf download`, with fallback to smaller batches and individual retries; tracks failed downloads.
10. (Optional) Removes RPMs for packages no longer installed (`cleanup_uninstalled_packages`).
11. Generates repository metadata (`createrepo_c --update`) at the repository base directory (not inside `getPackage`), including manual repositories when changed.
12. (Optional) Syncs the local repository tree to a shared path, skipping disabled repos.
13. Produces: colored per‑package log lines, a per‑repository summary table, failed download report, unknown package report.

## Repository Layout

```
LOCAL_REPO_PATH/
   <repo_name>/
      repodata/              (generated here)
      getPackage/            (RPM files stored here)
         pkgA-ver-rel.arch.rpm
         ...
   <manual_repo>/
      repodata/
      getPackage/ (same structure)
```

Manual repositories are listed in `MANUAL_REPOS` and are NOT downloaded from DNF; only existing or locally supplied RPMs are included. The script will not attempt to fetch missing RPMs for manual repos.

## Key Features Implemented

- NEW / UPDATE / EXISTS classification with filename pattern + version comparison (RPM vercmp + numeric fallback).
- Local RPM reuse: scans `LOCAL_RPM_SOURCES` before downloading.
- Batch + fallback download strategy with progress output and centralized threshold-based logging (log LEVEL "message" [debug_threshold]).
- Shared repository metadata cache with age invalidation (`CACHE_MAX_AGE`).
- Cleanup of uninstalled packages (hash‑based fast lookup) excluding manual repos.
- Metadata generation via `createrepo_c` with optional parallel workers.
- Auto privilege detection (`ELEVATE_COMMANDS`=auto) – uses sudo only when needed.
- Filtering: include (`--repos`), exclude (`--exclude-repos`), name regex (`--name-filter`).
- Limits: `--max-packages` (overall processed), `--max-changed-packages` (new + update downloads; 0=none, -1=unlimited).
- Dry run mode (`--dry-run`) showing intended actions without changes.
- Manual repository metadata refresh detection (timestamp + presence logic).
- Summary table and reports (failed downloads, unknown packages).

## Configuration (`myrepo.cfg`)

Place `myrepo.cfg` next to `myrepo.sh`. Any shell assignments override defaults. Example snippet:

```bash
LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"
MANUAL_REPOS=("ol9_edge")
LOCAL_RPM_SOURCES=("$HOME/rpmbuild/RPMS" "/var/cache/dnf")
MAX_CHANGED_PACKAGES=-1
DEBUG_LEVEL=1
```

You may also supply `MANUAL_REPOS` as a comma list via CLI (`--manual-repos ol9_edge,custom_repo`).

## Command Line Options (Implemented)

```
--cache-max-age SEC              Max age for cached repo metadata
--shared-cache-path PATH         Cache directory (default: /var/cache/myrepo)
--cleanup-uninstalled | --no-cleanup-uninstalled
--parallel-compression | --no-parallel-compression
--debug [LEVEL]                  If no LEVEL, defaults to 2
--dry-run                        No filesystem or download changes
--exclude-repos list             Comma-separated
--full-rebuild                   Purge all RPMs + repodata first
--local-repo-path PATH
--log-dir PATH                   (currently informational)
--manual-repos list              Comma-separated (overrides config)
--max-packages INT               Limit packages processed (0 = unlimited)
--max-changed-packages INT       Limit NEW+UPDATE downloads (0=none, -1=unlimited)
--name-filter REGEX              Process only matching package names
--parallel INT                   Worker hint for compression / future parallelism
--repos list                     Only these repositories
--refresh-metadata               Force rebuild of cache timestamp + dnf metadata clean
--set-permissions                (basic permission normalization)
--shared-repo-path PATH          Target sync destination
-s | --sync-only                 Skip processing; just sync
--no-sync                        Skip sync stage
--no-metadata-update             Skip createrepo_c
--dnf-serial                     Hint to avoid parallel DNF (currently advisory)
--self-test                      Run environment diagnostics and output JSON then exit
-v | --verbose                   Set debug level 2
-h | --help                      Show help
```

## Environment / Important Variables

| Variable | Meaning |
|----------|---------|
| LOCAL_REPO_PATH | Root of local repositories |
| SHARED_REPO_PATH | Sync destination (rsync target) |
| MANUAL_REPOS | Array of manual repositories (no DNF fetch) |
| LOCAL_RPM_SOURCES | Directories scanned for existing RPMs first |
| CACHE_MAX_AGE | Seconds before repo metadata cache refresh |
| MAX_CHANGED_PACKAGES | Cap on new+updated downloads (-1 unlimited, 0 forbid) |
| ELEVATE_COMMANDS | 1 (auto) or 0 (never sudo) |
| FORCE_REDOWNLOAD | 1 remove existing before download, 0 keep until success |
| DEBUG_LEVEL | 0–3 impact verbosity (with threshold-aware log function) |

### Logging System (v2.3.30)

Unified logging helper:

```
log LEVEL "message" [threshold]
```

Where:
- LEVEL: E (error), W (warn), I (info), D (debug)
- threshold (optional numeric): Minimum DEBUG_LEVEL required to emit this message (applies to D and I levels; E/W always shown unless DEBUG_LEVEL=0 and externally suppressed)

Examples:
```
log "D" "Using cache directory: $cache_dir" 2   # Shown when DEBUG_LEVEL >=2
log "I" "   Skipping manual repo: $pkg" 1        # Info gated at level 1+
log "E" "Failed to build cache"                # Always shown
```

Legacy inline patterns like `[[ $DEBUG_LEVEL -ge 2 ]] && ...` have been replaced for consistency, reducing conditional clutter and centralizing verbosity control. Former level 4 (TRACE) output has been folded into level 3 (VERBOSE); maximum DEBUG_LEVEL is now 3.

### Test / Development Hooks

These environment variables are intended strictly for testing and development. Do **not** enable them in production workflows.

| Variable | Purpose | When Honored |
|----------|---------|--------------|
| ENABLE_TEST_SELECTIVE=1 | Force-mark one repo as changed to exercise selective metadata update path during tests. | During package status evaluation; ignored if `CHANGED_REPOS` already populated. |
| MYREPO_BREAK_VERSION=1 | Interactive step prompts inside `version_is_newer` for the first N comparisons (see count var). | Each version comparison until counter hits 0. |
| MYREPO_BREAK_VERSION_COUNT=5 | Remaining interactive steps for `version_is_newer`. Decremented automatically. | Set before run to adjust step budget. |
| MYREPO_BREAK_DETERMINE=1 | Interactive step prompts inside `determine_repo_source`. | Each determine invocation until counter hits 0. |
| MYREPO_BREAK_DETERMINE_COUNT=5 | Remaining interactive steps for `determine_repo_source`. | Set before run. |

Interactive breakpoint usage example (safe dry‑run):

```bash
MYREPO_BREAK_VERSION=1 MYREPO_BREAK_VERSION_COUNT=3 \
MYREPO_BREAK_DETERMINE=1 MYREPO_BREAK_DETERMINE_COUNT=2 \
DRY_RUN=1 DEBUG_LEVEL=2 ./myrepo.sh --dry-run --name-filter '^bash$'
```

Enter (newline) to step, `c` to continue (disable further breaks), `q` to abort. These are *development only* diagnostics and should not be enabled in production automation.

Notes:
- The selective metadata optimization updates metadata only for repositories whose RPM contents changed (added / updated / removed). If `CHANGED_REPOS` ends empty we conservatively scan all.
- `ENABLE_TEST_SELECTIVE` and all `MYREPO_BREAK_*` variables are *testing / debugging aids*; avoid in production runs.

All can be overridden via `myrepo.cfg` or CLI; CLI wins.

## Typical Workflow

1. Place script + config: `/opt/tools/myrepo.sh`, `/opt/tools/myrepo.cfg`.
2. Ensure `LOCAL_REPO_PATH` exists (e.g. `/repo`).
3. Run once to build cache & populate repos: `./myrepo.sh --debug 2`.
4. Add new packages (install them on system or drop into manual repo) and rerun.
5. Sync results: either automatic (default) or later with `./myrepo.sh -s`.

## Examples

Download only changed packages for selected repos:
```
./myrepo.sh --repos ol9_baseos_latest,ol9_appstream --max-changed-packages 100
```

Dry run with filtering:
```
./myrepo.sh --dry-run --name-filter '^(kernel|openssl)'
```

Full rebuild (purge + repopulate) without syncing yet:
```
./myrepo.sh --full-rebuild --no-sync
```

Manual repositories only (metadata refresh):
```
./myrepo.sh --repos ol9_edge --refresh-metadata
```

Sync only (no processing):
```
./myrepo.sh --sync-only
```

## Exit Status

0 = success / completed script path
>0 = failure during early validation or critical operation (cache build, dnf query, etc.)

## Requirements

- Oracle / RHEL compatible system with `dnf`
- `createrepo_c` (preferred) or fallback `createrepo`
- `rsync` (recommended for efficient syncing)
- Bash 4+

## Notes / Guarantees

- Does not attempt to “guess” missing packages for manual repos—silently skips downloads there unless RPM supplied locally.
- Will not place `repodata/` inside `getPackage`; ensures metadata resides at repository root.
- Protects against accidental creation of a naked `$LOCAL_REPO_PATH/getPackage` directory (warns if detected).
- Uses only enabled repositories for downloads; disabled repos are temporarily enabled per batch when needed.

## Limitations (Known, Accepted)

- No signature verification of RPMs (assumes trusted environment).
- Metadata change detection for manual repos is timestamp-based (not content hashing).
- Parallel DNF download concurrency limited by DNF itself; `--parallel` mainly influences metadata compression workers.
- No built-in lock for multi-host concurrent writes to the same shared path.

## License

MIT License. See `LICENSE` file.

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

### Automatic Privilege Detection

The script now **automatically detects** whether it's running as root or as a regular user and adapts accordingly:

**When running as regular user** (`./myrepo.sh`):
- **Automatic Sudo Usage**: The script automatically prefixes necessary commands with `sudo`
- **User runs script normally**: `./myrepo.sh` (without sudo)
- The script detects EUID≠0 and internally uses `sudo` when needed for operations like:
  - Running DNF commands (`sudo dnf download`, `sudo dnf list`, etc.)
  - Creating and updating repository metadata (`sudo createrepo_c`)
  - Writing to system directories and fixing permissions

**When running as root** (`sudo ./myrepo.sh`):
- **Direct Command Usage**: Script runs commands directly without `sudo`
- **User runs script as root**: `sudo ./myrepo.sh`
- The script detects EUID=0 and assumes it already has elevated privileges
- All operations run with the elevated permissions of the root session

**Configuration Override**: You can still override this behavior by setting `ELEVATE_COMMANDS=0` in `myrepo.cfg` to disable automatic sudo usage (advanced users only).

### Installation of Required Tools

```bash
# Install required packages (requires sudo)
sudo dnf install createrepo_c rsync dnf-utils
```

**Important**: If you don't have sudo access on your system, you cannot run this script as a regular user. The script requires sudo privileges when not running as root - it will automatically detect your privilege level and adapt accordingly.

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
   # Set verbosity level (0=critical, 1=important, 2=normal, 3=verbose)
   DEBUG_LEVEL=3
   ```

3. **Save and Close the File**.

### Configuration Options

```bash
# myrepo.cfg - Configuration file for myrepo.sh v2.3.30
# The default values are given below, commented out.
# To configure, uncomment the desired lines and change the values.

# Set the repository base path (directory containing both internet-sourced and manual repositories)
# LOCAL_REPO_PATH="/repo"

# Set the shared repository path
# SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"

# Define manual repositories (individual repos within LOCAL_REPO_PATH, comma-separated)
# MANUAL_REPOS="ol9_edge"

# Define local RPM source directories (comma-separated list)
# LOCAL_RPM_SOURCES="/home/nemethy/rpmbuild/RPMS,/var/cache/dnf,/var/cache/yum,/tmp"

# Set verbosity level (0=critical, 1=important, 2=normal, 3=verbose)
# DEBUG_LEVEL=1

# Set maximum number of packages to process (0 = no limit)
# MAX_PACKAGES=0

# Set maximum number of changed packages to download (-1 = no limit, 0 = none)
# MAX_CHANGED_PACKAGES=-1

# Set the number of parallel processes (optimized default: 6)
# PARALLEL=6

# Enable dry run (1 = enabled, 0 = disabled)
# DRY_RUN=0

# Run full rebuild - removes all packages first (1 = enabled, 0 = disabled)
# FULL_REBUILD=0

# Define repositories that should be excluded from processing
# EXCLUDE_REPOS=""

# Cache validity in seconds (default: 14400 = 4 hours)
# CACHE_MAX_AGE=14400

# Shared cache directory path (default: /var/cache/myrepo)
# SHARED_CACHE_PATH="/var/cache/myrepo"

# Enable cleanup of uninstalled packages (1 = enabled, 0 = disabled)
# CLEANUP_UNINSTALLED=1

# Enable parallel compression for createrepo (1 = enabled, 0 = disabled)
# USE_PARALLEL_COMPRESSION=1

# Force refresh of DNF metadata cache (1 = enabled, 0 = disabled)
# REFRESH_METADATA=0

# Use serial DNF mode to prevent database lock contention (1 = enabled, 0 = disabled)
# DNF_SERIAL=0

# Automatic privilege detection (1 = auto-detect, 0 = never use sudo)
# ELEVATE_COMMANDS=1

# Progress update interval for download operations (in seconds, default: 30)
# PROGRESS_UPDATE_INTERVAL=30

# Timeout settings (in seconds)
# DNF_QUERY_TIMEOUT=60
# DNF_CACHE_TIMEOUT=120
# DNF_DOWNLOAD_TIMEOUT=1800
# SUDO_TEST_TIMEOUT=10

# (Legacy adaptive / load-balancing tuning variables removed; remaining performance-related variables above are sufficient.)

```

### Log Level Control

The logging system uses two concepts:

1. **Verbosity Level** (`DEBUG_LEVEL`): Controls how much output is shown
2. **Message Types**: Determine the display symbol and semantic meaning

#### Verbosity Levels

The `DEBUG_LEVEL` option controls the verbosity of log output (0–3):

- `0` (Critical): Only critical errors that prevent script execution
- `1` (Important): Warnings, key progress, success notifications
- `2` (Normal): Standard informational messages (default)
- `3` (Verbose): Detailed debugging information (absorbs former ultra‑verbose traces)

#### Message Types and Display Symbols

Messages are displayed with symbols that indicate their semantic meaning:

- `[E]` Error: Critical issues that may stop execution
- `[W]` Warning: Issues that need attention but don't stop execution  
- `[I]` Info: General informational messages
- `[D]` Debug: Detailed debugging information

#### Configuration

To set the verbosity level, modify the `DEBUG_LEVEL` option in `myrepo.cfg`:

```bash
# Set verbosity level (0=critical, 1=important, 2=normal, 3=verbose)
DEBUG_LEVEL=2
```

You can also set it via command line using `--debug LEVEL`.

### Repository Exclusion Feature

Some repositories may contain packages installed on the golden-copy machine but are **not intended to be mirrored**. The `EXCLUDE_REPOS` setting ensures that these repositories are:

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

3. **SHARED_CACHE_PATH** (Auto-created)
   - Directory for shared cache files
   - Created automatically if missing
   - Must be writable for cache operations

#### Permission Validation

The script performs comprehensive permission validation during startup:

1. **Directory Existence Check**
   - Verifies all configured paths exist and are directories
   - Reports missing directories as errors (LOCAL_REPO_PATH) or warnings (others)

2. **Write Permission Check**
   - Tests basic write permissions using filesystem flags
   - Performs practical write tests by creating temporary files
   - Validates access to repository subdirectories (getPackage, repodata)

3. **Command Elevation vs Direct Mode**
   - `ELEVATE_COMMANDS=1` (Default): User runs script normally (`./myrepo.sh`), script uses `sudo` internally for elevated operations
   - `ELEVATE_COMMANDS=0` (Advanced): User runs entire script as root (`sudo ./myrepo.sh --no-elevate`), script assumes elevated privileges

4. **Error Handling**
   - LOCAL_REPO_PATH permission errors will cause script exit (critical)
   - SHARED_REPO_PATH permission errors generate warnings only (non-critical)
   - Subdirectory permission errors are reported with fix suggestions

#### Setting Up Permissions

**For Default Mode (ELEVATE_COMMANDS=1) - Recommended:**
```bash
# Simply ensure your user has sudo privileges
# The script will automatically use sudo for necessary operations
./myrepo.sh
```

**For Direct Mode (ELEVATE_COMMANDS=0) - Advanced:**
```bash
# Run the entire script as root
sudo ./myrepo.sh --no-elevate

# Or configure sudoers for passwordless sudo and run as root
echo "$(whoami) ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/myrepo-user
```

## Usage

### Prerequisites

**Important**: The script requires sudo privileges to run DNF operations and manage repository directories. You must have sudo access to run the script.

### Running `myrepo.sh`

You can customize and run the `myrepo.sh` script to handle your local repository:

```bash
./myrepo.sh [options]
```


## CLI Options

| Option               | Values                     | Default               | Description                                                   |
|----------------------|----------------------------|------------------------|---------------------------------------------------------------|
| `--cache-max-age`    | *INT*                      | `14400`               | Cache validity in seconds (14400 = 4 hours).                 |
| `--shared-cache-path`| *PATH*                     | `/var/cache/myrepo`   | Shared cache directory path.                                  |
| `--cleanup-uninstalled` | *(flag)*                | *on*                  | Enable cleanup of uninstalled packages.                      |
| `--no-cleanup-uninstalled` | *(flag)*             | *off*                 | Disable cleanup of uninstalled packages.                     |
| `--parallel-compression` | *(flag)*               | *on*                  | Enable parallel compression for createrepo.                  |
| `--no-parallel-compression` | *(flag)*            | *off*                 | Disable parallel compression for createrepo.                 |
| `--debug`            | *0‒3*                      | `1`                   | Verbosity level (0=critical, 1=important, 2=normal, 3=verbose). |
| `--dry-run`          | *(flag)*                   | *off*                 | Perform a dry run without making changes.                     |
| `--exclude-repos`    | *CSV*                      | *empty*               | Comma-separated list of repos to exclude.                     |
| `--full-rebuild`     | *(flag)*                   | *off*                 | Perform a full rebuild of the repository.                     |
| `--local-repo-path`  | *PATH*                     | `/repo`               | Set local repository path.                                    |
| `--manual-repos`     | *CSV*                      | `ol9_edge`            | Comma‑separated list of manual repositories.                  |
| `--max-packages`     | *INT*                      | `0`                   | Limit total number of packages processed (0 = no limit).      |
| `--max-new-packages` | *INT*                      | `-1`                  | Limit number of new packages to download (-1 = no limit, 0 = none). |
| `--name-filter`      | *REGEX*                    | *empty*               | Filter packages by name using regex pattern.                  |
| `--parallel`         | *INT*                      | `6`                   | Maximum concurrent download or processing jobs.               |
| `--repos`            | *CSV*                      | *all enabled*         | Comma-separated list of repositories to process.              |
| `--shared-repo-path` | *PATH*                     | `/mnt/hgfs/ForVMware/ol9_repos` | Set shared repository path.                         |
| `--sync-only`        | *(flag)*                   | *off*                 | Skip download/cleanup; only run sync to shared repos.         |
| `--no-sync`          | *(flag)*                   | *off*                 | Skip synchronization to shared location entirely.             |
| `--no-metadata-update` | *(flag)*                 | *off*                 | Skip repository metadata updates (createrepo_c).              |
| `--refresh-metadata` | *(flag)*                   | *off*                 | Force refresh of DNF metadata cache and rebuild repo cache.   |
| `--dnf-serial`       | *(flag)*                   | *off*                 | Use serial DNF mode to prevent database lock contention.      |
| `-v, --verbose`      | *(flag)*                   | *off*                 | Set debug level to 2 (normal verbosity).                     |
| `-h, --help`         | *(flag)*                   | *off*                 | Show help message and exit.                                   |

#### Examples:

```bash
# Basic usage with debugging
./myrepo.sh --debug 2 --repos ol9_edge,ol9_appstream --local-repo-path /custom/repo

# Process only Firefox packages from ol9_appstream repository
./myrepo.sh --repos ol9_appstream --name-filter "firefox" --debug 2

# Process all NodeJS packages with dry-run to see what would happen
./myrepo.sh --name-filter "nodejs" --dry-run --debug 2

# Test with limited packages and show performance
./myrepo.sh --max-packages 50 --dry-run --debug 2

# Limit new package downloads to manage bandwidth/storage  
./myrepo.sh --max-new-packages 100 --debug 2

# Use shorter cache validity for frequently changing repositories
./myrepo.sh --cache-max-age 3600 --debug 2  # 1 hour cache

# Sync-only mode for fast rsync without package processing
./myrepo.sh --sync-only

# Skip synchronization (useful for testing or development)
./myrepo.sh --no-sync --name-filter "geos*"

# Skip metadata updates (useful for development/testing)
./myrepo.sh --no-metadata-update --no-sync --name-filter "geos*"

# Full rebuild with verbose debugging
./myrepo.sh --full-rebuild --debug 3

# Force metadata refresh before processing (clears cache)
./myrepo.sh --refresh-metadata --debug 2

# Serial DNF mode for systems with database locking issues
./myrepo.sh --dnf-serial --debug 2

# Process specific repositories with custom parallel settings and batch size
./myrepo.sh --repos ol9_appstream,ol9_baseos --parallel 4

# Use custom batch size for better performance on slower systems
./myrepo.sh --debug 2

# Use shared cache path and enable cleanup
./myrepo.sh --shared-cache-path /tmp/myrepo_cache --cleanup-uninstalled

# Disable cleanup and use custom cache settings
./myrepo.sh --no-cleanup-uninstalled --cache-max-age 7200

# Run with parallel compression enabled (default behavior)
./myrepo.sh --parallel-compression --debug 2

# Quick environment diagnostic producing JSON (no repository work)
./myrepo.sh --self-test

# Self-test then run normal operation (separate runs)
./myrepo.sh --self-test && ./myrepo.sh --debug 2 --repos ol9_appstream
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

## Self-Test Mode (`--self-test`)

The `--self-test` flag performs a fast, side‑effect free diagnostic of the runtime environment and prints a single JSON object, then exits (0 on success, 2 on failure). This is ideal for CI health checks or pre‑flight validation before scheduling large runs.

Checks performed:
- Bash version (requires 4+)
- Presence of required commands (`dnf`, `rpm`, `createrepo_c` or fallback `createrepo`, `rsync`, core text utils)
- Basic `dnf repolist` query (verifies DNF operational)
- Writable status (with actual write probe) for `LOCAL_REPO_PATH` and `SHARED_CACHE_PATH`
- Sudo capability detection (`root`, `sudo-nopass`, `sudo-pass`, or `no-sudo`)

Sample output (pretty-printed for readability):

```json
{
   "version": "2.3.30",
   "ok": 1,
   "bash_ok": 1,
   "dnf_query_ok": 1,
   "sudo_mode": "sudo-nopass",
   "commands": [
      { "name": "dnf", "present": 1 },
      { "name": "rpm", "present": 1 }
   ],
   "paths": [
      { "path": "/repo", "exists": 1, "writable": 1 },
      { "path": "/var/cache/myrepo", "exists": 1, "writable": 1 }
   ],
   "failures": []
}
```

Failure entries (e.g. `missing_command:dnf`, `not_writable:/repo`, `dnf_query_failed`) appear in the `failures` array and set `ok` to 0. Exit status is 2 when any failures are present.

Typical CI usage:

```bash
if ./myrepo.sh --self-test > selftest.json; then
   echo "Environment OK";
else
   echo "Environment NOT OK"; cat selftest.json; exit 1;
fi
```

## Tips

- **Dry Run Mode**: Use the `--dry-run` option to simulate the script's actions without making any changes.
- **Debugging**: Increase the `DEBUG_LEVEL` to get more detailed output, which can help in troubleshooting.
- **Verbosity Control**: Adjust the `DEBUG_LEVEL` to control how much output is shown (0=critical, 1=important, 2=normal, 3=verbose).
- **Repository Exclusion**: Ensure that unwanted repositories are listed in `EXCLUDE_REPOS` to prevent unnecessary replication.
- **Efficient Filtering**: Use `--name-filter` combined with `--repos` for precise control over package processing and improved performance.
- **Testing Filters**: Always test new name filter patterns with `--dry-run` first to verify they match the expected packages.
- **Performance**: The script uses fixed optimal settings (batch size: 50, parallel: 6) for best performance.
- **Sync-Only Mode**: Use `--sync-only` for fast repository synchronization when no package processing is needed.
- **Skip Sync Mode**: Use `--no-sync` for development and testing scenarios where you want to process packages but skip the time-consuming synchronization step.
- **Skip Metadata Updates**: Use `--no-metadata-update` for development and testing scenarios where you want to skip repository metadata creation (createrepo_c) for faster execution.
- **Combined Development Mode**: Use `--no-sync --no-metadata-update` for maximum speed during development and testing.
- **Metadata Refresh**: Use `--refresh-metadata` when DNF cache issues are suspected or after repository configuration changes.
- **Cache Management**: The shared cache at `/var/cache/myrepo` provides optimal performance for both root and user executions.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.

## Conclusion

The `repo-handler` script provides a comprehensive solution for managing local package repositories in isolated environments. Version 2.3.10 significantly improves package version comparison logic with RPM-native version comparison and enhanced status detection, ensuring accurate handling of complex multi-repository scenarios where manual repositories may contain newer versions than official ones. This builds on v2.3.8's `--no-metadata-update` option for enhanced development workflows and v2.3.7's performance optimizations.

The combination of configuration file support, extensive command-line options, performance optimization, accurate version comparison, and flexible synchronization and metadata controls (including `--no-sync` and `--no-metadata-update`) makes it suitable for a wide range of use cases, from simple package mirroring to complex multi-repository environments with both automated and manual package management workflows.

