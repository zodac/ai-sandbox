# syntax=docker/dockerfile:1.7
# ai-sandbox's OWN sandbox layer: the tools for developing this repo, on top of the shared base
# (Debian 13, nested Docker, Node, git, gh, jq, python3 - see image/base/Dockerfile). The nested
# Docker is what lets a session build and launch the images it is changing.
# Its pins are bumped with the rest of this repo's by .github/scripts/update_dependency_versions.sh.

ARG BASE_IMAGE

FROM ${BASE_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# shellcheck: lints sandbox.sh, the image scripts and the update script.
# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -yqq --no-install-recommends \
        shellcheck="0.10.0-1"
# END DEBIAN PACKAGES
