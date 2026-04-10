#!/usr/bin/env bash

set -euo pipefail
set -E

TMP_DIR=
SEQUENCE_EDITOR=
BACKUP_BRANCH=
REPO_ROOT=
GIT_DIR=
TARGET_COMMIT=
PARENT_COMMIT=
ORIGINAL_SUBJECT=
AUTHOR_NAME=
AUTHOR_EMAIL=
AUTHOR_DATE=

declare -a DISPLAY_PATHS=()
declare -a STAGE_SPECS=()
declare -a STAGE_PATHS=()

usage() {
  cat <<EOF >&2
Usage:
  $0 list <commit-sha>
  $0 split <commit-sha>
  $0 split-file <commit-sha> <repo-relative-path>

Commands:
  list        List the files changed by the target commit.
  split       Rewrite the target commit into one commit per changed file.
  split-file  Rewrite the target commit into:
              1. <repo-relative-path>-<original subject>
              2. <original subject> for the remaining files
EOF
  exit 1
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "${TMP_DIR}" ] && [ -d "${TMP_DIR}" ]; then
    rm -rf "${TMP_DIR}"
  fi
}

report_unexpected_error() {
  local exit_code=$?
  local line_no=$1

  printf 'Error: script failed at line %s.\n' "${line_no}" >&2
  if [ -n "${BACKUP_BRANCH}" ]; then
    printf 'Backup branch preserved at %s\n' "${BACKUP_BRANCH}" >&2
  fi
  exit "${exit_code}"
}

trap cleanup EXIT
trap 'report_unexpected_error "$LINENO"' ERR

require_git_repo() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "must be run inside a Git repository"

  REPO_ROOT=$(git rev-parse --show-toplevel)
  GIT_DIR=$(git rev-parse --git-dir)
  cd "${REPO_ROOT}"
}

ensure_no_rebase_in_progress() {
  if [ -d "${GIT_DIR}/rebase-merge" ] || [ -d "${GIT_DIR}/rebase-apply" ]; then
    die "a rebase is already in progress"
  fi
}

require_clean_worktree() {
  git diff --quiet --ignore-submodules -- || die "working tree has unstaged changes"
  git diff --cached --quiet --ignore-submodules -- || die "index has staged changes"

  if [ -n "$(git ls-files --others --exclude-standard)" ]; then
    die "working tree has untracked files"
  fi
}

resolve_commit() {
  local target_input=$1

  git rev-parse --verify --quiet "${target_input}^{commit}" >/dev/null || die "commit '${target_input}' does not exist"
  TARGET_COMMIT=$(git rev-parse "${target_input}^{commit}")
}

load_commit_metadata() {
  local parent_count

  parent_count=$(git rev-list --parents -n 1 "${TARGET_COMMIT}" | awk '{print NF - 1}')
  if [ "${parent_count}" -eq 0 ]; then
    die "root commits are not supported"
  fi
  if [ "${parent_count}" -ne 1 ]; then
    die "merge commits are not supported"
  fi

  PARENT_COMMIT=$(git rev-parse "${TARGET_COMMIT}^")
  ORIGINAL_SUBJECT=$(git show -s --format=%s "${TARGET_COMMIT}")
  AUTHOR_NAME=$(git show -s --format=%an "${TARGET_COMMIT}")
  AUTHOR_EMAIL=$(git show -s --format=%ae "${TARGET_COMMIT}")
  AUTHOR_DATE=$(git show -s --format=%aI "${TARGET_COMMIT}")

  DISPLAY_PATHS=()
  STAGE_SPECS=()

  while IFS= read -r -d '' status; do
    case "${status}" in
      R*)
        IFS= read -r -d '' old_path || die "failed to parse renamed path for ${TARGET_COMMIT}"
        IFS= read -r -d '' new_path || die "failed to parse renamed path for ${TARGET_COMMIT}"
        DISPLAY_PATHS+=("${new_path}")
        STAGE_SPECS+=("${old_path}"$'\n'"${new_path}")
        ;;
      *)
        IFS= read -r -d '' path || die "failed to parse changed path for ${TARGET_COMMIT}"
        DISPLAY_PATHS+=("${path}")
        STAGE_SPECS+=("${path}")
        ;;
    esac
  done < <(git diff-tree --no-commit-id --name-status -r -M -z "${TARGET_COMMIT}")

  if [ "${#DISPLAY_PATHS[@]}" -eq 0 ]; then
    die "target commit does not change any files"
  fi
}

print_changed_files() {
  local path

  for path in "${DISPLAY_PATHS[@]}"; do
    printf '%s\n' "${path}"
  done
}

create_backup_branch() {
  local short_sha
  local timestamp

  short_sha=$(git rev-parse --short "${TARGET_COMMIT}")
  timestamp=$(date -u +%Y%m%d%H%M%S)
  BACKUP_BRANCH="backup/pre-split-${short_sha}-${timestamp}"

  git branch "${BACKUP_BRANCH}" >/dev/null
  printf 'Created backup branch %s\n' "${BACKUP_BRANCH}"
}

prepare_sequence_editor() {
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/split-commit.XXXXXX")
  SEQUENCE_EDITOR="${TMP_DIR}/sequence_editor.sh"

  cat > "${SEQUENCE_EDITOR}" <<'EOF'
#!/usr/bin/env bash

set -eu

todo_file=$1
tmp_file=${todo_file}.tmp

if awk -v target="$SPLIT_TARGET_COMMIT" '
BEGIN {
  found = 0
}
$1 == "pick" && substr(target, 1, length($2)) == $2 {
  $1 = "edit"
  found = 1
}
{
  print
}
END {
  if (!found) {
    exit 42
  }
}
' "$todo_file" > "$tmp_file"; then
  :
else
  awk_status=$?

  if [ "$awk_status" -eq 42 ]; then
    echo "Error: could not mark the target commit as edit during rebase setup." >&2
    rm -f "$tmp_file"
    exit 1
  fi

  rm -f "$tmp_file"
  exit "$awk_status"
fi

mv "$tmp_file" "$todo_file"
EOF

  chmod +x "${SEQUENCE_EDITOR}"
  export SPLIT_TARGET_COMMIT="${TARGET_COMMIT}"
}

start_rebase_and_stop_at_target() {
  local sequence_editor=$1
  local rebase_status

  # Rewrite the rebase todo list so the target commit changes from "pick" to
  # "edit", which pauses the rebase exactly at the commit we want to replace.
  if GIT_SEQUENCE_EDITOR="${sequence_editor}" GIT_EDITOR=: git -c commit.gpgsign=false rebase -i "${PARENT_COMMIT}"; then
    rebase_status=0
  else
    rebase_status=$?
  fi

  if [ ! -d "${GIT_DIR}/rebase-merge" ] && [ ! -d "${GIT_DIR}/rebase-apply" ]; then
    if [ "${rebase_status}" -ne 0 ]; then
      exit "${rebase_status}"
    fi
    die "rebase finished without stopping at the target commit"
  fi
}

reset_target_commit() {
  # Once rebase pauses at the edited commit, resetting to HEAD^ removes that
  # commit from history while leaving its full patch in the worktree/index so
  # we can re-commit it in smaller pieces.
  git reset HEAD^
}

build_stage_paths() {
  local stage_spec=$1
  local stage_path

  STAGE_PATHS=()

  while IFS= read -r stage_path; do
    if [ -n "${stage_path}" ]; then
      STAGE_PATHS+=("${stage_path}")
    fi
  done <<< "${stage_spec}"
}

commit_staged_changes() {
  local commit_message=$1

  if git diff --cached --quiet --; then
    die "no staged changes are available for commit '${commit_message}'"
  fi

  GIT_AUTHOR_NAME="${AUTHOR_NAME}" \
  GIT_AUTHOR_EMAIL="${AUTHOR_EMAIL}" \
  GIT_AUTHOR_DATE="${AUTHOR_DATE}" \
  GIT_COMMITTER_DATE="${AUTHOR_DATE}" \
    git -c commit.gpgsign=false commit --no-verify -m "${commit_message}"
}

commit_split_entry() {
  local index=$1
  local display_path=${DISPLAY_PATHS[$index]}
  local stage_spec=${STAGE_SPECS[$index]}

  build_stage_paths "${stage_spec}"
  git add -A -- "${STAGE_PATHS[@]}"
  commit_staged_changes "${display_path}-${ORIGINAL_SUBJECT}"
}

commit_remaining_changes_as_original() {
  git add -A --
  commit_staged_changes "${ORIGINAL_SUBJECT}"
}

ensure_no_remaining_changes() {
  if ! git diff --quiet --ignore-submodules -- || ! git diff --cached --quiet --ignore-submodules --; then
    die "remaining changes were left after rewriting the target commit"
  fi
}

continue_rebase() {
  GIT_EDITOR=: git -c commit.gpgsign=false rebase --continue
}

find_path_index() {
  local requested_path=$1
  local i

  for i in "${!DISPLAY_PATHS[@]}"; do
    if [ "${DISPLAY_PATHS[$i]}" = "${requested_path}" ]; then
      printf '%s\n' "${i}"
      return 0
    fi
  done

  return 1
}

run_list() {
  [ "$#" -eq 1 ] || usage

  require_git_repo
  resolve_commit "$1"
  load_commit_metadata
  print_changed_files
}

run_split() {
  local i

  [ "$#" -eq 1 ] || usage

  require_git_repo
  ensure_no_rebase_in_progress
  resolve_commit "$1"
  require_clean_worktree
  load_commit_metadata

  create_backup_branch
  prepare_sequence_editor
  start_rebase_and_stop_at_target "${SEQUENCE_EDITOR}"
  reset_target_commit

  for i in "${!DISPLAY_PATHS[@]}"; do
    commit_split_entry "${i}"
  done

  ensure_no_remaining_changes
  continue_rebase

  printf 'Split commit %s into %s per-file commits.\n' "${TARGET_COMMIT}" "${#DISPLAY_PATHS[@]}"
  printf 'Backup branch: %s\n' "${BACKUP_BRANCH}"
}

run_split_file() {
  local target_input=$1
  local requested_path=$2
  local target_index

  [ "$#" -eq 2 ] || usage

  require_git_repo
  ensure_no_rebase_in_progress
  resolve_commit "${target_input}"
  require_clean_worktree
  load_commit_metadata

  if [ "${#DISPLAY_PATHS[@]}" -lt 2 ]; then
    die "split-file requires a commit that changes at least two files"
  fi

  if ! target_index=$(find_path_index "${requested_path}"); then
    printf 'Error: file %s is not changed by commit %s.\n' "${requested_path}" "${TARGET_COMMIT}" >&2
    printf 'Changed files:\n' >&2
    print_changed_files >&2
    exit 1
  fi

  create_backup_branch
  prepare_sequence_editor
  start_rebase_and_stop_at_target "${SEQUENCE_EDITOR}"
  reset_target_commit

  commit_split_entry "${target_index}"
  commit_remaining_changes_as_original
  ensure_no_remaining_changes
  continue_rebase

  printf 'Split file %s out of commit %s.\n' "${requested_path}" "${TARGET_COMMIT}"
  printf 'Backup branch: %s\n' "${BACKUP_BRANCH}"
}

main() {
  local command

  [ "$#" -ge 1 ] || usage

  command=$1
  shift

  case "${command}" in
    list)
      run_list "$@"
      ;;
    split)
      run_split "$@"
      ;;
    split-file)
      run_split_file "$@"
      ;;
    *)
      # Preserve the original one-argument usage as a convenience alias for
      # the full split operation.
      if [ "$#" -eq 0 ]; then
        run_split "${command}"
      else
        usage
      fi
      ;;
  esac
}

main "$@"
