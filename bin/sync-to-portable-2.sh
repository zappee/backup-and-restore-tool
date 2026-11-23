#!/bin/bash -eu
# ##############################################################################
# Remal File Backup Tool - Job definition
#
# Release: 0.4.0
# Created by arnold.somogyi@gmail.com
#
# Copyright (c) 2020-2026 Remal Software and Arnold Somogyi All rights reserved
# ##############################################################################
readonly SCRIPT_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_HOME}/lib/sync-lib.sh"

readonly SOURCE_BASE="$HOME/Workspace"
readonly TARGET_BASE="$HOME/Mount/portable-2"

# ------------------------------------------------------------------------------
# Job definition
# Format: "subdirectory | mode"
# Where
#   subdirectory: must exist under SOURCE_BASE
#   mode:         append, mirror, or pre-purge
# ------------------------------------------------------------------------------
readonly JOB=(
  "documents        | mirror"
  "learning         | mirror"
  "music            | append"
  "photo-album      | mirror"
  "programming      | mirror"
  "videos/my-videos | append"
)

run_job "$SOURCE_BASE" "$TARGET_BASE" "${JOB[@]}"
