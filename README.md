
# Repo Handler Script

**Developed by**: Dániel Némethy (nemethy@moderato.hu) with AI support (ChatGPT-o)

## Overview

The `repo-handler` project provides a bash script designed to manage, clean, and synchronize local package repositories on systems that are isolated from the Internet. This script is particularly useful for environments where a local mirror of installed packages needs to be maintained and synchronized with a shared repository. The goal is to create a much smaller repository that contains only the packages required for the specific environment, compared to the vast number of packages in the original internet repositories.

The script helps:
- Replicate and update a local repository based on installed packages from a "golden copy" system.
- Remove uninstalled or outdated packages from the repository.
- Sync the cleaned local repository with a shared repository, ensuring it always remains up-to-date while containing only essential packages.

![MyRepo Workflow](images/MyRepo.png)

### Key Features:
- **Reduced Repository Size**: The replicated repository is much smaller than the original internet repositories, containing only the necessary packages for the specific environment.
- **Batch Processing**: Efficiently processes packages in batches for performance optimization.
- **Automatic Cleanup**: Removes older or uninstalled package versions from the local repository.
- **Synchronization**: Keeps the local repository in sync with a shared repository using `rsync`, allowing the local repository to remain fresh and current.
- **Debugging Options**: Includes a `DEBUG_MODE` for verbose output during script execution.

## Component

### **myrepo.sh**  
This is a standalone bash script that handles:
- Fetching installed packages from the golden copy machine.
- Managing the local repository by adding, updating, or removing packages.
- Synchronizing the local repository with a shared repository.

## Installation

### 1. Clone the Repository:
\`\`\`bash
git clone https://github.com/your-username/repo-handler.git
cd repo-handler
\`\`\`

### 2. Prepare Your Environment:
- Set up your local repository at `/repo` or update the paths in the scripts according to your environment.
- Ensure your shared repository path is correct in the script (`/mnt/hgfs/ForVMware/ol9_repos`).
Of course you can checge these values in the script according to your setup.

### 3. Install Required Tools:
- The scripts depend on `dnf`, `rpm`, `createrepo`, and `rsync`.
- Make sure these utilities are available on your system.

## Usage

### Running `myrepo.sh`

You can customize and run the `myrepo.sh` script to handle your local repository:

\`\`\`bash
./myrepo.sh [options]
\`\`\`

#### Available Options:
- `--debug-level [LEVEL]`: Set the debug level (default is 0).
- `--max-packages [NUM]`: Set the maximum number of packages to process.
- `--batch-size [NUM]`: Set the number of packages processed in each batch (default is 10).
- `--parallel [NUM]`: Set the number of parallel jobs (default is 2).

#### Example:
\`\`\`bash
./myrepo.sh --debug-level 1 --batch-size 20
\`\`\`

## Customization

- **Repository Paths**: Update the `LOCAL_REPO_PATH` and `SHARED_REPO_PATH` variables in the scripts to match your setup.
- **Batch Size**: Adjust the `BATCH_SIZE` in the script or via the command-line option to improve performance based on your system's capacity.

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.

## Contributing

Feel free to submit issues or pull requests to improve the functionality or performance of the scripts.
