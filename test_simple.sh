#!/bin/bash

# Developed by: Dániel Némethy (nemethy@moderato.hu) with different AI support models
# AI flock: ChatGPT, Claude, Gemini
# Last Updated: 2025-07-06

# MIT licensing
# Purpose:
# This script replicates and updates a local repository from installed packages
# and synchronizes it with a shared repository, handling updates and cleanup of
# older package versions.

# Script version
VERSION=2.1.16
# Default values for environment variables if not set
: "${BATCH_SIZE:=20}"                  # Increased from 10
: "${CONTINUE_ON_ERROR:=0}"
: "${DEBUG_MODE:=0}"
: "${DRY_RUN:=0}"
: "${FULL_REBUILD:=0}"
: "${GROUP_OUTPUT:=1}"
: "${IS_USER_MODE:=0}"
: "${LOG_LEVEL:=INFO}"
: "${MAX_PACKAGES:=0}"
: "${PARALLEL:=6}"                     # Increased from 4
: "${SYNC_ONLY:=0}"

# Repository filtering (empty means process all enabled repos)
FILTER_REPOS=()

echo "Script runs!"
