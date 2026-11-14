#!/bin/bash
# ------------------------------------------------------------------------------
# Script Name:  lint_shell_scripts.sh
#
# Description:  Lints every tracked shell script (*.sh) with ShellCheck, from its official Docker image.
#               New files not yet added to git count too (unless ignored), so a run before a commit checks them.
#
#               The rules are code-quality-config/shellscript/.shellcheckrc (the code-quality-config submodule),
#               passed with --rcfile: ShellCheck would otherwise look for a .shellcheckrc above each script.
#
#               The image is pinned HERE, like actionlint's in lint_workflows.sh, so the monthly dependency
#               update can bump it; .github/scripts/update_dependency_versions.sh keeps SHELLCHECK_IMAGE at the
#               latest ShellCheck release.
#
# Usage:        .github/scripts/lint_shell_scripts.sh      (from the repository root)
#
# Requirements: docker, git, and the code-quality-config submodule checked out
# ------------------------------------------------------------------------------
set -euo pipefail

SHELLCHECK_IMAGE="koalaman/shellcheck:v0.11.0"
SHELLCHECKRC="code-quality-config/shellscript/.shellcheckrc"

if [[ ! -f "${SHELLCHECKRC}" ]]; then
    echo "❌ ${SHELLCHECKRC} not found: run \`git submodule update --init\`" >&2
    exit 1
fi

scripts=()
script_list="$(git ls-files --cached --others --exclude-standard '*.sh')"
mapfile -t scripts <<< "${script_list}"

docker run --rm -v "${PWD}:/repo:ro" -w /repo "${SHELLCHECK_IMAGE}" --rcfile "${SHELLCHECKRC}" "${scripts[@]}"
