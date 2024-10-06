
# Repo Handler Scripts

**Developed by**: Dániel Némethy (nemethy@moderato.hu) with AI support (ChatGPT-4)

## Overview

The `repo-handler` project provides a set of Bash scripts designed to manage, clean, and synchronize local package repositories on systems that are isolated from the Internet. These scripts are particularly useful for environments where a local mirror of installed packages needs to be maintained and synchronized with a shared repository.

The scripts help:
- Replicate and update a local repository based on installed packages from a "golden copy" system.
- Remove uninstalled or outdated packages from the repository.
- Sync the cleaned local repository with a shared repository.

![MyRepo Workflow](images/MyRepo.png)

### Key Features:
- **Batch Processing**: Efficiently processes packages in batches for performance optimization.
- **Automatic Cleanup**: Removes older or uninstalled package versions from the local repository.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`.
- **Debugging Options**: Includes a `DEBUG_MODE` for verbose output during script execution.

## Components

1. **myrepo.sh**  
   This is the main script that handles:
   - Fetching installed packages from the golden copy machine.
   - Managing the local repository by adding, updating, or removing packages.
   - Synchronizing the local repository with a shared repository.

2. **process-package.sh**  
   This script is called by `myrepo.sh` and is responsible for:
   - Checking the status of packages in the repository (whether they exist, need to be updated, or are new).
   - Removing older versions of packages and downloading the latest versions.
   - Ensuring only the necessary packages are retained in the local repository.

## Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/your-username/repo-handler.git
   cd repo-handler
   ```

2. **Prepare Your Environment**:
   - Set up your local repository at `/repo` or update the paths in the scripts according to your environment.
   - Ensure your shared repository path is correct in the script (`/mnt/hgfs/ForVMware/ol9_repos`).

3. **Install Required Tools**:
   - The scripts depend on `dnf`, `rpm`, `createrepo`, and `rsync`.
   - Make sure these utilities are available on your system.

## Usage

### Running `myrepo.sh`

You can customize and run the `myrepo.sh` script to handle your local repository:

```bash
./myrepo.sh [options]
```

#### Available Options:
- `--debug-level [LEVEL]`: Set the debug level (default is 0).
- `--max-packages [NUM]`: Set the maximum number of packages to process.
- `--batch-size [NUM]`: Set the number of packages processed in each batch (default is 10).
- `--parallel [NUM]`: Set the number of parallel jobs (default is 1).

Example:
```bash
./myrepo.sh --debug-level 1 --batch-size 20
```

### Running `process-package.sh`

This script is called by `myrepo.sh` and handles the package management process.

```bash
./process-package.sh --debug-level [LEVEL] --packages "[PACKAGE_LIST]" --local-repos "[LOCAL_REPOS]"
```

## Customization

- **Repository Paths**: Update the `LOCAL_REPO_PATH` and `SHARED_REPO_PATH` variables in the scripts to match your setup.
- **Batch Size**: Adjust the `BATCH_SIZE` in the script or via the command-line option to improve performance based on your system's capacity.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.
