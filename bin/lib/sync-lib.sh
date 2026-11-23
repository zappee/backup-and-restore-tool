#!/bin/bash -eu
set -eu -o pipefail

# ##############################################################################
# Remal File Backup-Restore Tool - Core function library
#
# Release: 0.4.0
# Created by arnold.somogyi@gmail.com
#
# Copyright (c) 2020-2026 Remal Software and Arnold Somogyi All rights reserved
#
# Usage:
#    Source this library in job scripts, do not execute directly.
#    source sync-lib.sh
#
# File copy modes:
#    append:   Copies new and modified files from source to target, leaving
#              deleted or older files untouched on the backup drive.
#
#    mirror:   Keeps the target identical to the source by deleting obsolete
#              files on the fly during the file transfer. Best when the backup
#              disk has ample free space.
#
#   pre-purge: Space-saving exact mirror. Scans and purges all obsolete files
#              from the target first before copying any new data. Use this when
#              the backup drive is tight on free disk space so removed files
#              free up room before new ones arrive.
#
#
# Understand the rsync output:
#
#    YXcstpoguax  path/to/file
#    |||||||||||
#    ||||||||||╰- x: The extended attribute information changed
#    |||||||||╰-- a: The ACL information changed
#    ||||||||╰--- u: The u slot is reserved for future use
#    |||||||╰---- g: Group is different
#    ||||||╰----- o: Owner is different
#    |||||╰------ p: Permissions are different
#    ||||╰------- t: Modification time is different
#    |||╰-------- s: Size is different
#    ||╰--------- c: Different checksum (for regular files), or
#    ||              changed value (for symlinks, devices, and special files)
#    |╰---------- the file type:
#    |            f: for a file,
#    |            d: for a directory,
#    |            L: for a symlink,
#    |            D: for a device,
#    |            S: for a special file (e.g. named sockets and fifos)
#    ╰----------- the type of update being done:
#                <: file is being transferred to the remote host (sent)
#                >: file is being transferred to the local host (received)
#                c: local change/creation for the item, such as:
#                    - the creation of a directory
#                    - the changing of a symlink,
#                    - etc.
#                h: the item is a hard link to another item (requires
#                    --hard-links).
#                .: the item is not being updated (though it might have
#                    attributes that are being modified)
#                *: means that the rest of the itemized-output area contains
#                    a message (e.g. "deleting")
# ##############################################################################

# ------------------------------------------------------------------------------
# Main program.
# ------------------------------------------------------------------------------
readonly COLOR_BORDER="\033[0;32m"
readonly COLOR_LABEL="\033[38;5;244m"
readonly COLOR_VALUE="\033[38;5;108m"
readonly COLOR_HIGHLIGHT="\033[1;92m"
readonly COLOR_MODE="\033[1;97m"
readonly COLOR_ERROR="\033[1;38;5;203m"
readonly COLOR_RESET="\033[0m"

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  printf "%b[ERROR] The %s is a library and must be sourced, not executed directly.%b\n" "$COLOR_ERROR" "${0##*/}" "$COLOR_RESET"
  exit 1
fi

# ------------------------------------------------------------------------------
# Validates and executes a sync job list defined by the caller script.
#
# Parameters:
#    $1: Root source directory path
#    $2: Root target directory path
#    $@: Job entries formatted as "relative-subdir | mode"
# ------------------------------------------------------------------------------
function run_job() {
  local -r src_base="${1%/}"
  local -r dst_base="${2%/}"
  shift 2
  local -a jobs=("$@")
  local jobs_total="${#jobs[@]}"
  local job_index=0

  validate_job "$src_base" "$dst_base" "${jobs[@]}"

  local job sub_dir mode job_id rc
  for job in "${jobs[@]}"; do
    job_index=$((job_index + 1))
    IFS='| ' read -r sub_dir mode <<< "$job"
    printf -v job_id "%02d/%02d" "$job_index" "$jobs_total"
    show_job_banner "$job_id" "$src_base" "$sub_dir" "$dst_base" "$mode"

    rc=0
    sync_dir "${src_base}/${sub_dir}" "${dst_base}/${sub_dir}" "$mode" || rc=$?

    if (( rc == 2 )); then
      continue
    elif (( rc != 0 )); then
      exit "$rc"
    fi
  done

  printf -- "-- END --\n"
}

# ------------------------------------------------------------------------------
# Performs pre-flight validation for the entire job list before any sync starts.
# Checks rsync availability, base paths, every source subdirectory, and modes.
#
# Parameters:
#    $1: Root source directory path
#    $2: Root target directory path
#    $@: Job entries formatted as "relative-subdir | mode"
#
# Returns:
#    0: if all checks pass
#    1: if any dependency, path, or mode is invalid
# ------------------------------------------------------------------------------
function validate_job() {
  local -r src_base="$1"
  local -r dst_base="$2"
  shift 2
  local -a jobs=("$@")
  local has_error=0
  local job sub_dir mode

  if ! command -v rsync >/dev/null 2>&1; then
    printf "%b[ERROR] rsync is not installed.%b\n" "${COLOR_ERROR}" "${COLOR_RESET}"
    return 1
  fi

  if [[ ! -d "$src_base" ]]; then
    printf "%b[ERROR] Source base directory not found: %s%b\n" "${COLOR_ERROR}" "$src_base" "${COLOR_RESET}"
    return 1
  fi

  if [[ ! -d "$dst_base" ]]; then
    printf "%b[ERROR] Target base directory not found (is the drive mounted?): %s%b\n" "${COLOR_ERROR}" "$dst_base" "${COLOR_RESET}"
    return 1
  fi

  for job in "${jobs[@]}"; do
    IFS='| ' read -r sub_dir mode <<< "$job"

    if [[ ! -d "${src_base}/${sub_dir}" ]]; then
      printf "%b[ERROR] Source directory not found: %s/%s%b\n" "${COLOR_ERROR}" "$src_base" "$sub_dir" "${COLOR_RESET}"
      has_error=1
    fi

    case "$mode" in
      append|mirror|pre-purge) ;;
      *)
        printf "%b[ERROR] Unrecognized mode '%s' for '%s'. Expected 'append', 'mirror', or 'pre-purge'.%b\n" "${COLOR_ERROR}" "$mode" "$sub_dir" "${COLOR_RESET}"
        has_error=1
        ;;
    esac
  done

  return "$has_error"
}

# ------------------------------------------------------------------------------
# Syncs a single directory from source to target using rsync. Dry run first,
# followed by user confirmation before the live file transfer.
#
# Parameters:
#    $1: Full source directory path
#    $2: Full target directory path
#    $3: Sync mode ('append', 'mirror', or 'pre-purge'; defaults to 'append')
#
# Returns:
#    0: on successful sync
#    2: if job skipped by the user (exits on abort/error)
# ------------------------------------------------------------------------------
function sync_dir() {
  local -r src_dir="${1%/}/"
  local -r dst_dir="${2%/}/"
  local -r mode="${3:-append}"
  local -a dry_opts=(--itemize-changes --dry-run)
  local -a rsync_opts=(
    --archive
    --progress
    --mkpath
    --stats
    --human-readable
  )

  case "$mode" in
    mirror)    rsync_opts+=("--delete-during") ;;
    pre-purge) rsync_opts+=("--delete-before") ;;
  esac

  # Dry run.
  local -a dry_cmd=(rsync "${rsync_opts[@]}" "${dry_opts[@]}" "$src_dir" "$dst_dir")
  printf "%s\n\n" "${dry_cmd[*]}"

  local rc=0
  confirm_step "Comparing SOURCE and TARGET directories. Continue?" || rc=$?
  case "$rc" in
    1) printf "Aborted by user.\n"; exit 0 ;;
    2) printf "Skipped by user.\n"; return 2 ;;
  esac

  "${dry_cmd[@]}"

  # File copy.
  local -a sync_cmd=(rsync "${rsync_opts[@]}" "$src_dir" "$dst_dir")
  show_params "$src_dir" "$dst_dir" "$mode" "${sync_cmd[*]}"
  printf "%bDo you want to copy files from SOURCE to TARGET?%b\n" "${COLOR_ERROR}" "${COLOR_RESET}"
  printf "%bFiles on TARGET media will be overwritten!%b\n" "${COLOR_ERROR}" "${COLOR_RESET}"

  rc=0
  confirm_step "Continue?" || rc=$?
  case "$rc" in
    1) printf "Aborted by user.\n"; exit 0 ;;
    2) printf "Skipped by user.\n"; return 2 ;;
  esac

  "${sync_cmd[@]}"
}

# ------------------------------------------------------------------------------
# Prints a formatted header banner for the current directory sync job.
#
# Parameters:
#    $1: Formatted job progress counter (e.g., "01/13").
#    $2: Root source directory path without trailing slash.
#    $3: Directory path being synced, relative to $2.
#    $4: Base target directory path without trailing slash.
#    $5: Sync mode ('append', 'mirror', or 'pre-purge').
# ------------------------------------------------------------------------------
function show_job_banner() {
  local -r job_id="$1"
  local -r src_base="$2"
  local -r sub_dir="$3"
  local -r dst_base="$4"
  local -r mode="$5"
  local -r mode_description="$(get_mode_info "$mode")"


  printf "\n"
  printf "%b********************************************************************************%b\n" "$COLOR_BORDER" "$COLOR_RESET"
  printf "%b** %b%s%b\n" "$COLOR_BORDER" "$COLOR_HIGHLIGHT" "$job_id" "$COLOR_RESET"
  printf "%b** %bsource: %b%s/%b%s%b\n" "$COLOR_BORDER" "$COLOR_LABEL" "$COLOR_VALUE" "$src_base" "$COLOR_HIGHLIGHT" "$sub_dir" "$COLOR_RESET"
  printf "%b** %btarget: %b%s%b\n" "$COLOR_BORDER" "$COLOR_LABEL" "$COLOR_VALUE" "${dst_base}/${sub_dir}" "$COLOR_RESET"
  printf "%b** %bmode:   %b%s (%s)%b\n" "$COLOR_BORDER" "$COLOR_LABEL" "$COLOR_MODE" "$mode" "$mode_description" "$COLOR_RESET"
  printf "%b********************************************************************************%b\n" "$COLOR_BORDER" "$COLOR_RESET"
}

# ------------------------------------------------------------------------------
# Prints source, target, mode description, and exact rsync command preview.
#
# Parameters:
#    $1: Full source directory path
#    $2: Full target directory path
#    $3: Sync mode ('append', 'mirror', or 'pre-purge')
#    $4: Formatted rsync command string to preview
# ------------------------------------------------------------------------------
function show_params() {
  local -r src_dir="$1"
  local -r dst_dir="$2"
  local -r mode="$3"
  local -r cmd_preview="$4"
  local -r mode_description="$(get_mode_info "$mode")"

  printf "\n"
  printf "Source:%b %s%b\n" "${COLOR_VALUE}" "$src_dir" "${COLOR_RESET}"
  printf "Target:%b %s%b\n" "${COLOR_VALUE}" "$dst_dir" "${COLOR_RESET}"
  printf "Mode:%b   %s (%s)%b\n" "${COLOR_VALUE}" "$mode" "$mode_description" "${COLOR_RESET}"
  printf "\n%s\n\n" "$cmd_preview"
}

# ------------------------------------------------------------------------------
# Prints a short human-readable description for the given sync mode.
#
# Parameters:
#    $1: Sync mode ('append', 'mirror', or 'pre-purge')
#
# Returns:
#    0: on success
#    1: if the mode is unrecognized
# ------------------------------------------------------------------------------
function get_mode_info() {
  local -r mode="$1"
  case "$mode" in
    append)
      printf "Copies new and modified files only, existing target files are never deleted"
      ;;
    mirror)
      printf "Deletes obsolete target files on the fly during transfer"
      ;;
    pre-purge)
      printf "Space-saving mirror, it purges obsolete target files before copying"
      ;;
    *)
      printf "%b[ERROR] Unrecognized mode '%s'. Expected 'append', 'mirror', or 'pre-purge'.%b" "$COLOR_ERROR" "$mode" "$COLOR_RESET" >&2
      return 1
      ;;
  esac
}

# ------------------------------------------------------------------------------
# Prompts the user for a single-key confirmation before executing an action.
#
# Parameters:
#    $1: Prompt message displayed to the user
#
# Returns:
#    0: for Yes ('y', 'Y', 'Enter')
#    1: for Abort ('n', 'N', 'Esc')
#    2: for Skip ('s', 'S')
# ------------------------------------------------------------------------------
function confirm_step() {
  local -r prompt_msg="$1"
  local key

  printf "%b%s [Yes, Enter / Skip / No, Esc]%b " "${COLOR_ERROR}" "$prompt_msg" "${COLOR_RESET}"
  read -rsn1 key
  printf "\n"

  case "$key" in
    [Yy]|"") return 0 ;;   # <-- Handles 'y', 'Y', and 'Enter'
    [Ss]) return 2 ;;      # <-- Handles 's' and 'S'
    [Nn]|$'\e')            # <-- Handles 'n', 'N', and 'Esc'
      read -rsn2 -t 0.01 _ || true
      return 1
      ;;
    *)
      printf "Please press 'y', 'Enter' (yes) / 's' (skip job) / 'n', 'Esc' (abort).\n"
      confirm_step "$prompt_msg"
      ;;
  esac
}
