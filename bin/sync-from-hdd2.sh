#!/bin/bash -eu
# ##############################################################################
# Remal File Backup-Restore Tool - Job definition
#
# Release: 0.4.0
# Created by arnold.somogyi@gmail.com
#
# Copyright (c) 2020-2026 Remal Software and Arnold Somogyi All rights reserved
# ##############################################################################
SCRIPT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_HOME}/sync-lib.sh"

SOURCE_BASE="$HOME/Mount/hdd-4"
TARGET_BASE="$HOME/Workspace"

# ------------------------------------------------------------------------------
# Job definition
# Format: "subdirectory | mode"
# Where
#   subdirectory: must exist under SOURCE_BASE
#   mode:         append, mirror, or pre-purge
# ------------------------------------------------------------------------------
readonly RESTORE_JOB=(
  "documents        | mirror"
  "learning         | mirror"
  "photo-album      | mirror"
  "programming      | mirror"
  "videos/my-videos | mirror"
)

run_job "$SOURCE_BASE" "$TARGET_BASE" "${RESTORE_JOB[@]}"
