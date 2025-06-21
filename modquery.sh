#!/bin/bash

# Define the full package name and the repository
# Use the full name including version, release, and architecture for precise querying
FULL_PACKAGE_NAME="nodejs-full-i18n-18.20.8-1.module+el9.6.0+90614+f11b29ab.x86_64"
REPOSITORY="ol9_appstream"

# Query DNF for package info and filter for the "From module:" line.
# We're querying the specific package name, ensuring DNF finds it.
# Redirect stderr to /dev/null to suppress any DNF warnings/errors if the package isn't found.
MODULE_INFO=$(dnf repoquery --info "$FULL_PACKAGE_NAME" --disablerepo="*" --enablerepo="$REPOSITORY" 2>/dev/null | grep "From module:")

# Check if module information was found
if [[ -n "$MODULE_INFO" ]]; then
    # Extract the module name and stream (e.g., nodejs:18).
    # This sed command captures content after "From module: " up to the second colon (if present),
    # effectively removing any build IDs (like :90614) that might follow the stream number.
    MOD_STREAM=$(echo "$MODULE_INFO" | sed -E 's/From module: ([^:]+:[^:]+)(:.*)?/\1/')
    echo "Module stream for $FULL_PACKAGE_NAME: $MOD_STREAM"
else
    # If no module info is found, try to see if the package exists at all to give better feedback.
    if dnf repoquery --quiet "$FULL_PACKAGE_NAME" --disablerepo="*" --enablerepo="$REPOSITORY" 2>/dev/null >/dev/null; then
        echo "Package '$FULL_PACKAGE_NAME' found in '$REPOSITORY', but no explicit 'From module:' line was detected in its info."
        echo "However, based on its name ('1.module+el9.6.0+90614+f11b29ab'), it is almost certainly part of the 'nodejs:18' module stream."
    else
        echo "Package '$FULL_PACKAGE_NAME' was not found in '$REPOSITORY'. Please verify the package name and repository."
    fi
fi