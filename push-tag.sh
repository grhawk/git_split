#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHANGELOG_FILE="${ROOT_DIR}/CHANGELOG.md"

readonly CLEAN_SEMVER_REGEX='^[0-9]+\.[0-9]+\.[0-9]+$'
readonly ANY_SEMVER_REGEX='^[0-9]+\.[0-9]+\.[0-9]+([\-][0-9A-Za-z.-]+)?([+][0-9A-Za-z.-]+)?$'

usage() {
  cat <<'EOF'
Usage: ./push-tag.sh <tag>

Examples:
  ./push-tag.sh 0.1.0-rc11
  ./push-tag.sh 0.1.0
EOF
}

fail() {
  echo "push-tag: $*" >&2
  exit 1
}

require_clean_targets() {
  local target

  for target in "$@"; do
    if ! git diff --quiet -- "$target"; then
      fail "${target##*/} has unstaged changes"
    fi
    if ! git diff --cached --quiet -- "$target"; then
      fail "${target##*/} has staged changes"
    fi
  done
}

require_missing_tag() {
  local tag="$1"

  if git rev-parse --verify --quiet "refs/tags/${tag}" >/dev/null; then
    fail "tag ${tag} already exists locally"
  fi

  if git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
    fail "tag ${tag} already exists on origin"
  fi
}

rotate_changelog_for_release() {
  local version="$1"
  local release_date="$2"

  python3 - "$CHANGELOG_FILE" "$version" "$release_date" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
version = sys.argv[2]
release_date = sys.argv[3]
text = path.read_text()

if re.search(rf'(?m)^## \[{re.escape(version)}\]\b', text):
    raise SystemExit(f"push-tag: CHANGELOG.md already contains a section for {version}")

match = re.search(r'(?ms)^## \[Unreleased\]\n(?P<body>.*?)(?=^## |\Z)', text)
if not match:
    raise SystemExit("push-tag: could not find the Unreleased section in CHANGELOG.md")

body = match.group("body")
content_lines = [
    line
    for line in body.splitlines()
    if line.strip() and not line.startswith("### ")
]
if not content_lines:
    raise SystemExit("push-tag: Unreleased section is empty")

new_unreleased = """## [Unreleased]

### Breaking

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security
"""
released_body = body.strip("\n")
replacement = (
    f"{new_unreleased}\n"
    f"## [{version}] - {release_date}\n\n"
    f"{released_body}\n"
)
updated = text[: match.start()] + replacement + text[match.end() :]
path.write_text(updated)
PY
}

main() {
  local tag branch release_date

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  tag="$1"
  if [[ ! "$tag" =~ $ANY_SEMVER_REGEX ]]; then
    fail "tag must be a semver tag without a v prefix"
  fi

  require_clean_targets "$CHANGELOG_FILE"
  require_missing_tag "$tag"

  if [[ "$tag" =~ $CLEAN_SEMVER_REGEX ]]; then
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [[ "$branch" != "master" ]]; then
      fail "clean release tags must be created from the master branch"
    fi

    release_date="$(date +%F)"
    rotate_changelog_for_release "$tag" "$release_date"
    git add "$CHANGELOG_FILE"
    git commit -m "chore(release): cut ${tag}"
  fi

  git tag "$tag"
  git push origin HEAD
  git push origin "$tag"
}

main "$@"
