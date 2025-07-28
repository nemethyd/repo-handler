#!/bin/bash

# Manual correction script to fix existing repodata structure issues
# This script will move misplaced repodata directories from getPackage subdirectories 
# to the repository level and clean up old repodata

LOCAL_REPO_PATH="/repo"

echo "🔧 Repository Structure Fix Tool"
echo "==============================="
echo
echo "This script will fix the repository structure by:"
echo "1. Moving repodata directories from getPackage subdirectories to repository level"
echo "2. Cleaning up old/duplicate repodata directories"
echo "3. Preserving all package files"
echo

if [[ ! -d "$LOCAL_REPO_PATH" ]]; then
    echo "❌ Repository path not found: $LOCAL_REPO_PATH"
    exit 1
fi

# Check if running as root or with sudo
if [[ $EUID -ne 0 && -z "$SUDO_USER" ]]; then
    echo "⚠️  This script may need sudo privileges to move repodata directories"
    echo "   Consider running with sudo if you encounter permission errors"
    echo
fi

total_fixed=0
total_cleaned=0

# Process each repository
for repo_dir in "$LOCAL_REPO_PATH"/*; do
    if [[ -d "$repo_dir" ]]; then
        repo_name=$(basename "$repo_dir")
        
        # Skip invalid directories
        if [[ "$repo_name" == "getPackage" ]]; then
            echo "⚠️  Found invalid getPackage directory at root level: $repo_dir"
            echo "   This should be removed manually after backing up any important data"
            continue
        fi
        
        echo "🔍 Checking repository: $repo_name"
        
        # Check for getPackage subdirectory
        getpackage_dir="$repo_dir/getPackage"
        if [[ -d "$getpackage_dir" ]]; then
            
            # Check for misplaced repodata inside getPackage
            if [[ -d "$getpackage_dir/repodata" ]]; then
                echo "   📦 Found misplaced repodata in getPackage subdirectory"
                
                # Check if there's already repodata at repository level
                if [[ -d "$repo_dir/repodata" ]]; then
                    echo "   ⚠️  Repository level repodata already exists - backing up getPackage version"
                    
                    # Create backup
                    backup_name="repodata.backup.getPackage.$(date +%Y%m%d_%H%M%S)"
                    if mv "$getpackage_dir/repodata" "$repo_dir/$backup_name" 2>/dev/null; then
                        echo "   ✅ Backed up getPackage repodata as: $backup_name"
                        ((total_cleaned++))
                    elif sudo mv "$getpackage_dir/repodata" "$repo_dir/$backup_name" 2>/dev/null; then
                        echo "   ✅ Backed up getPackage repodata as: $backup_name (with sudo)"
                        ((total_cleaned++))
                    else
                        echo "   ❌ Failed to backup getPackage repodata"
                    fi
                else
                    echo "   📤 Moving repodata to repository level..."
                    
                    # Move repodata to repository level
                    if mv "$getpackage_dir/repodata" "$repo_dir/repodata" 2>/dev/null; then
                        echo "   ✅ Successfully moved repodata to repository level"
                        ((total_fixed++))
                    elif sudo mv "$getpackage_dir/repodata" "$repo_dir/repodata" 2>/dev/null; then
                        echo "   ✅ Successfully moved repodata to repository level (with sudo)"
                        ((total_fixed++))
                    else
                        echo "   ❌ Failed to move repodata to repository level"
                    fi
                fi
            fi
            
            # Clean up old repodata patterns inside getPackage
            for pattern in "repodata.old.*" "repodata.bak.*" ".repodata.*"; do
                find "$getpackage_dir" -maxdepth 1 -name "$pattern" -type d 2>/dev/null | while read -r old_repodata; do
                    echo "   🗑️  Removing old repodata from getPackage: $(basename "$old_repodata")"
                    if rm -rf "$old_repodata" 2>/dev/null; then
                        echo "   ✅ Cleaned up: $(basename "$old_repodata")"
                        # shellcheck disable=SC2030
                        ((total_cleaned++))
                    elif sudo rm -rf "$old_repodata" 2>/dev/null; then
                        echo "   ✅ Cleaned up: $(basename "$old_repodata") (with sudo)"
                        ((total_cleaned++))
                    else
                        echo "   ❌ Failed to clean up: $(basename "$old_repodata")"
                    fi
                done
            done
        fi
        
        # Clean up old repodata patterns at repository level
        cleaned_at_repo_level=0
        for pattern in "repodata.old.*" "repodata.bak.*" ".repodata.*"; do
            find "$repo_dir" -maxdepth 1 -name "$pattern" -type d 2>/dev/null | while read -r old_repodata; do
                echo "   🗑️  Removing old repodata: $(basename "$old_repodata")"
                if rm -rf "$old_repodata" 2>/dev/null; then
                    echo "   ✅ Cleaned up: $(basename "$old_repodata")"
                    ((cleaned_at_repo_level++))
                elif sudo rm -rf "$old_repodata" 2>/dev/null; then
                    echo "   ✅ Cleaned up: $(basename "$old_repodata") (with sudo)"
                    ((cleaned_at_repo_level++))
                else
                    echo "   ❌ Failed to clean up: $(basename "$old_repodata")"
                fi
            done
        done
        
        # Check final structure
        if [[ -d "$repo_dir/repodata" ]]; then
            echo "   ✅ Repository structure correct: repodata at repository level"
        elif [[ -d "$getpackage_dir" ]] && [[ $(find "$getpackage_dir" -name "*.rpm" -type f 2>/dev/null | wc -l) -gt 0 ]]; then
            echo "   ℹ️  Repository has packages but no repodata - will be created by next script run"
        else
            echo "   ℹ️  Repository appears empty or has no packages"
        fi
        
        echo
    fi
done

echo "📊 Summary:"
echo "   Fixed repositories: $total_fixed"
# shellcheck disable=SC2031
echo "   Cleaned old repodata: $total_cleaned"
echo
echo "✅ Repository structure fix completed!"
echo
echo "Next steps:"
echo "1. Run your myrepo.sh script normally"
echo "2. The script will now create repodata at the correct repository level"
echo "3. Old/misplaced repodata has been cleaned up"
echo
echo "Repository structure should now be:"
echo "  /repo/"
echo "  ├── repository_name/"
echo "  │   ├── getPackage/     (contains RPM files)"
echo "  │   └── repodata/       (contains metadata - at repository level)"
