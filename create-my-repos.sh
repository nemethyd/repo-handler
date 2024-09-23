#!/bin/bash

VERSION=0.1
echo "$0 Version $VERSION"

LOCAL_REPO_PATH="/repo"
SHARED_REPO_PATH="/mnt/hgfs/ForVMware/ol9_repos"

subdirs=($(find $LOCAL_REPO_PATH -mindepth 1 -maxdepth 1 -type d))

for repo in "${subdirs[@]}"; do
    echo "Creating $repo repository indexes"
    createrepo --update "$repo"
done

rsync -avh --delete $LOCAL_REPO_PATH/ $SHARED_REPO_PATH/