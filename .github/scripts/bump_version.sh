#!/bin/sh
set -eu

current_version="${1}"

# Split version into major, minor, patch
OLD_IFS="${IFS}"
IFS=.
# shellcheck disable=SC2086
set -- ${current_version}
major="${1}"
minor="${2}"
patch="${3}"
IFS="${OLD_IFS}"

# Increment patch
new_patch=$((patch + 1))
next_version="${major}.${minor}.${new_patch}"

echo "Bumping version to ${next_version}"
echo "${next_version}" > VERSION

# Push changes
git add VERSION

if git diff --cached --quiet; then
    echo "No changes to commit"
else
    git commit -m "[CI] Prepare next version: ${next_version}"
    # shellcheck disable=SC2154  # GITHUB_ENV is injected by the GitHub Actions runner
    echo "has_changes=true" >> "${GITHUB_ENV}"
fi
