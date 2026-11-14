#!/bin/bash
# ------------------------------------------------------------------------------
# Script Name:  lint_dockerfiles.sh
#
# Description:  Lints every tracked Dockerfile with hadolint, from its official Docker image. hadolint also runs
#               ShellCheck over the RUN instructions.
#               New files not yet added to git count too (unless ignored), so a run before a commit checks them.
#
#               The rules are code-quality-config/docker/.hadolint.yaml (the code-quality-config submodule),
#               passed with --config; findings are printed in its format (JSON: `[]` is a pass).
#
#               The image is pinned HERE, like actionlint's in lint_workflows.sh, so the monthly dependency
#               update can bump it; .github/scripts/update_dependency_versions.sh keeps HADOLINT_IMAGE at the
#               latest hadolint release.
#
# Usage:        .github/scripts/lint_dockerfiles.sh      (from the repository root)
#
# Requirements: docker, git, and the code-quality-config submodule checked out
# ------------------------------------------------------------------------------
set -euo pipefail

HADOLINT_IMAGE="hadolint/hadolint:v2.15.1"
HADOLINT_CONFIG="code-quality-config/docker/.hadolint.yaml"

if [[ ! -f "${HADOLINT_CONFIG}" ]]; then
    echo "❌ ${HADOLINT_CONFIG} not found: run \`git submodule update --init\`" >&2
    exit 1
fi

dockerfiles=()
dockerfile_list="$(git ls-files --cached --others --exclude-standard '*Dockerfile')"
mapfile -t dockerfiles <<< "${dockerfile_list}"

docker run --rm -v "${PWD}:/repo:ro" -w /repo "${HADOLINT_IMAGE}" \
    hadolint --config "${HADOLINT_CONFIG}" "${dockerfiles[@]}"
