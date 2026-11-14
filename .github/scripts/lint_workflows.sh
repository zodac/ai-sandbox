#!/bin/bash
# ------------------------------------------------------------------------------
# Script Name:  lint_workflows.sh
#
# Description:  Lints every GitHub workflow under .github/workflows with actionlint, from its official
#               Docker image. actionlint also runs ShellCheck over the workflows' `run:` blocks.
#
#               The image is pinned HERE, like the other linters' in their lint_*.sh, so the CI and a
#               local run use the same version; .github/scripts/update_dependency_versions.sh keeps
#               ACTIONLINT_IMAGE at the latest actionlint release.
#
#               Its config is code-quality-config/github-actions/actionlint.yaml, passed explicitly:
#               actionlint only discovers one at .github/actionlint.yaml.
#
# Usage:        .github/scripts/lint_workflows.sh      (from the repository root)
#
# Requirements: docker, and the code-quality-config submodule checked out
# ------------------------------------------------------------------------------
set -euo pipefail

ACTIONLINT_IMAGE="rhysd/actionlint:1.7.12"
ACTIONLINT_CONFIG="code-quality-config/github-actions/actionlint.yaml"

if [[ ! -f "${ACTIONLINT_CONFIG}" ]]; then
    echo "❌ ${ACTIONLINT_CONFIG} not found: run \`git submodule update --init\`" >&2
    exit 1
fi

docker run --rm -v "${PWD}:/repo:ro" -w /repo "${ACTIONLINT_IMAGE}" -no-color -config-file "${ACTIONLINT_CONFIG}"
