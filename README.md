
# Repo Handler Script

**Developed by**: Dániel Némethy (nemethy@moderato.hu) with AI support (ChatGPT-4)

## Overview

The `repo-handler` project provides a bash script designed to manage, clean, and synchronize local package repositories on systems that are isolated from the Internet. This script is particularly useful for environments where a local mirror of installed packages needs to be maintained and synchronized with a shared repository. The goal is to create a much smaller repository that contains only the packages required for the specific environment, compared to the vast number of packages in the original internet repositories.

The script helps:

- **Replicate and Update**: Creates and updates a local repository based on the installed packages from a "golden copy" system.
- **Automatic Cleanup**: Removes uninstalled or outdated packages from the repository, ensuring it only contains necessary packages.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`, allowing the local repository to remain fresh and current.
- **Configuration Flexibility**: Allows customization through a configuration file `myrepo.cfg` and command-line arguments, providing flexibility and ease of use.

![MyRepo Workflow](images/MyRepo.png)

### Key Features:

- **Reduced Repository Size**: The replicated repository is much smaller than the original internet repositories, containing only the necessary packages for the specific environment.
- **Batch Processing**: Efficiently processes packages in batches for performance optimization.
- **Automatic Cleanup**: Removes older or uninstalled package versions from the local repository.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`.
- **Customizable Output**: Aligns repository names in output messages for better readability.
- **Configuration File Support**: Introduces `myrepo.cfg` for overriding default settings, with command-line arguments taking precedence.
- **Debugging Options**: Includes a `DEBUG_MODE` for verbose output during script execution.

## Components

### **myrepo.sh**

This is a standalone bash script that handles:

- Fetching installed packages from the golden copy machine.
- Managing the local repository by adding, updating, or removing packages.
- Synchronizing the local repository with a shared repository.
- Reading configuration from `myrepo.cfg` and command-line arguments.

### **myrepo.cfg**

A configuration file that allows you to override default settings in `myrepo.sh`. It contains all configurable options with their default values commented out. You can customize the script by uncommenting and modifying these values.

## Installation

### 1. Clone the Repository:

```bash
git clone https://github.com/nemethyd/repo-handler.git
cd repo-handler
```

**Note**: Remember to replace `https://github.com/nemethyd/repo-handler.git` with the actual URL of your repository.

### 2. Prepare Your Environment:

- Ensure your local repository path (`LOCAL_REPO_PATH`) and shared repository path (`SHARED_REPO_PATH`) are correct.
- These can be set in `myrepo.cfg` or via command-line arguments.

### 3. Install Required Tools:

- The script depends on `dnf`, `rpm`, `createrepo`, and `rsync`.
- Ensure these utilities are available on your system.

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

### Available Configuration Options in `myrepo.cfg`:

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

# Set maximum number of packages to process (0 = no limit)
# MAX_PACKAGES=0

# Set batch size for processing
# BATCH_SIZE=10

# Set the number of parallel processes
# PARALLEL=2

# Enable dry run (1 = true, 0 = false)
# DRY_RUN=0

# Run without sudo privileges (1 = true, 0 = false)
# NO_SUDO=0
```

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

#### Available Command-Line Options:

- `--debug-level LEVEL`: Set the debug level (default: `0`).
- `--max-packages NUM`: Maximum number of packages to process (default: `0` for no limit).
- `--batch-size NUM`: Number of packages processed in each batch (default: `10`).
- `--parallel NUM`: Number of parallel jobs (default: `2`).
- `--dry-run`: Perform a dry run without making changes.
- `--no-sudo`: Run without sudo privileges.
- `--local-repo-path PATH`: Set local repository path.
- `--shared-repo-path PATH`: Set shared repository path.
- `--local-repos REPOS`: Comma-separated list of local repositories.

#### Example:

```bash
./myrepo.sh --debug-level 1 --batch-size 20 --local-repo-path /custom/repo
```

### Output Messages

- **Aligned Repository Names**: Repository names in output messages are aligned to a constant width for better readability.
- **Suppressed Messages**: In normal mode (when `DEBUG_MODE` is less than `1`), certain messages (like package removal during updates) are suppressed for clarity.

## How It Works

1. **Fetching Installed Packages**:

   - The script fetches a list of installed packages from the system.

2. **Determining Package Status**:

   - For each package, the script determines whether it's new, needs an update, or already exists in the local repository.

3. **Processing Packages**:

   - **New Packages**: Downloaded and added to the local repository.
   - **Updates**: Older versions are removed (messages about removal are shown only in debug mode), and the latest versions are added.
   - **Existing Packages**: No action is taken.

4. **Cleaning Up**:

   - Uninstalled or removed packages are deleted from the local repository to keep it clean and efficient.

5. **Updating Repository Metadata**:

   - After processing, the script updates the repository metadata using `createrepo`.

6. **Synchronization**:

   - The local repository is synchronized with the shared repository using `rsync`.

## Customization

- **Repository Paths**: Can be set via `myrepo.cfg` or command-line options.
- **Batch Size and Parallelism**: Adjust `BATCH_SIZE` and `PARALLEL` to optimize performance based on your system's capacity.
- **Local Repositories**: Define your own local repositories using the `LOCAL_REPOS` configuration.

## Tips

- **Dry Run Mode**: Use the `--dry-run` option to simulate the script's actions without making any changes.
- **Debugging**: Increase the `DEBUG_MODE` to get more detailed output, which can help in troubleshooting.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.

## Conclusion

The `repo-handler` script provides a robust solution for managing local package repositories in isolated environments. By utilizing a configuration file and command-line options, it offers flexibility and ease of use, ensuring that your repositories are always up-to-date and contain only the necessary packages.
