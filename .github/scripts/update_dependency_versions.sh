#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# Script Name:  update_dependency_versions.sh
#
# Description:  Updates pinned versions, in one of two modes:
#
#               This repository (no arguments) - every pin it owns:
#                 - the base image's Dockerfile (image/base/Dockerfile), then the examples' Dockerfiles
#                   (examples/*/Dockerfile) and this repo's own sandbox's
#                   (ai-sandbox-configuration/Dockerfile), as described below
#                 - GitHub Actions in .github/workflows (latest stable release tag, best-effort)
#
#               Given Dockerfiles (--dockerfiles) - only those. This is what consuming projects run, via
#               `ai-sandbox/sandbox.sh update-versions` (the base's Dockerfile plus the project's own),
#               and with --packages-only before it, the Debian packages alone (no `FROM` is touched):
#                 - every `FROM image:tag` - to the newest tag with the same major and the same suffix,
#                   digits only in between (26.8.2-trixie -> 26.12.1-trixie; never 27.x, -bookworm,
#                   -alpine or an -rc/-ea build). A major bump is a manual, reviewed change.
#                   `FROM ${BASE_IMAGE}` and `FROM <stage>` lines carry no tag, so they are left alone.
#                 - every package in a `# BEGIN DEBIAN PACKAGES` / `# END DEBIAN PACKAGES` block - to
#                   apt's candidate on the file's (just updated) Debian base, with Docker's APT repo added
#                   for the engine packages. A Dockerfile with no `FROM debian:` of its own (a project's,
#                   an example's) is resolved against the shared base's.
#
#               Debian drops a superseded package version from its repositories, so a pin that is
#               never bumped eventually stops installing, and a clean build (the Publish workflow's, or
#               any host without the base image cached) fails with
#               "E: Version '...' for '...' was not found". Run this, then build, then commit.
#
# Usage:        .github/scripts/update_dependency_versions.sh [--skip-android-gradle]
#               .github/scripts/update_dependency_versions.sh [--packages-only] --dockerfiles <Dockerfile>...
#                 --skip-android-gradle  leave examples/android-gradle alone. The monthly workflow uses
#                                        it: that image is too large to prove on a hosted runner, and an
#                                        unproven bump must not reach a release.
#
# Requirements: bash, curl, docker, git, jq, GNU grep/sed/sort
#               GITHUB_TOKEN (optional) raises the GitHub API rate limit for the Actions lookups.
#
# Exit codes:   0 - success (including a best-effort GitHub Actions step that could not resolve one)
#               1 - a Dockerfile could not be updated (e.g. a Debian package with no apt candidate)
# ------------------------------------------------------------------------------

# The GitHub Actions step is deliberately best-effort under `set -e`: its lookups are invoked as
# conditions (`|| warn`, `|| true`, `if ! is_prerelease`) so one failure never aborts the run. That is
# exactly what SC2310 flags, so it is disabled file-wide (as in the other projects' update scripts).
# shellcheck disable=SC2310
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BASE_DOCKERFILE="${REPO_ROOT}/image/base/Dockerfile"
WORKFLOWS_DIR="${REPO_ROOT}/.github/workflows"

usage() {
    echo "Usage: $(basename "$0") [--skip-android-gradle]" >&2
    echo "       $(basename "$0") [--packages-only] --dockerfiles <Dockerfile>..." >&2
    exit 1
}

# ── Output helpers ────────────────────────────────────────────────────────────

ok()   { echo "  ✅ ${*}"; }
warn() { echo "  ⚠️  ${*}" >&2; }

# ── curl wrappers ─────────────────────────────────────────────────────────────

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    github_curl() { curl -fsSL --connect-timeout 10 --max-time 60 -H "Authorization: Bearer ${GITHUB_TOKEN}" "${@}"; }
else
    github_curl() { curl -fsSL --connect-timeout 10 --max-time 60 "${@}"; }
fi

# ── Pre-release filtering ─────────────────────────────────────────────────────
# Nothing that is not a final release may ever be pinned: an unattended monthly bump is exactly where a
# release candidate must not slip in, and upstreams do not always flag their own pre-releases (Apache
# Maven published `maven-3.10.0-rc-1` without GitHub's pre-release flag). A marker only counts as a whole
# token optionally followed by digits: `3.10.0-rc-1` and `1.0.0-alpha2` are rejected, `v1.21.0` is not.
PRERELEASE_MARKERS='alpha|beta|rc|cr|snapshot|milestone|preview|pre|ea|nightly|canary|dev|unstable|m[0-9]+'

is_prerelease() {
    local version="${1,,}"
    [[ "${version}" =~ (^|[^a-z0-9])(${PRERELEASE_MARKERS})[0-9]*([^a-z0-9]|$) ]]
}

# Echoes the latest STABLE release tag of a GitHub repo (empty if none could be resolved).
# `releases/latest` only skips releases the project remembered to flag, so an unflagged pre-release falls
# back to the highest-VERSIONED stable entry (sort -V, not date order: a backport cut after a newer release
# is the most recent one while being the lower version, and would walk the pin backwards).
latest_stable_github_release() {
    local repo="${1}" tag
    tag=$(github_curl "https://api.github.com/repos/${repo}/releases/latest" | jq -r '.tag_name // empty') || tag=""
    if [[ -n "${tag}" ]] && ! is_prerelease "${tag}"; then
        printf '%s\n' "${tag}"
        return 0
    fi
    [[ -n "${tag}" ]] && warn "Ignoring pre-release '${tag}' offered as ${repo}'s latest release"

    github_curl "https://api.github.com/repos/${repo}/releases?per_page=100" \
        | jq -r '.[] | select(.draft == false and .prerelease == false) | .tag_name // empty' \
        | while IFS= read -r candidate; do is_prerelease "${candidate}" || printf '%s\n' "${candidate}"; done \
        | sort -V | tail -1
}

# ── 1. Docker images (FROM image:tag) ─────────────────────────────────────────

# Every tag of a Docker Hub image, from the registry API (complete in one response, unlike the
# paginated hub.docker.com listing).
list_tags() {
    local repo="${1}" token
    [[ "${repo}" == */* ]] || repo="library/${repo}"
    token=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" | jq -r .token)
    curl -fsSL -H "Authorization: Bearer ${token}" "https://registry-1.docker.io/v2/${repo}/tags/list?n=100000" | jq -r '.tags[]'
}

# Picks the highest version from stdin. A Temurin build number (`_10`) is sorted as `+10`, which
# ranks it below a newer patch: 26.0.2_10 < 26.0.2.1_1.
newest() {
    sed 's/_/+/' | sort -V | tail -1 | sed 's/+/_/'
}

update_images() {
    local dockerfile="$1" image tag version suffix major latest
    while IFS=: read -r image tag; do
        if ! version=$(grep -oE '^[0-9]+([._][0-9]+)*' <<< "${tag}"); then
            echo "  ${image}:${tag} - not a version tag, skipped"
            continue
        fi
        suffix="${tag#"${version}"}"
        major="${version%%[._]*}"
        latest=$(list_tags "${image}" | grep -E "^${major}([._][0-9]+)*${suffix//./\\.}\$" | newest || true)
        if [[ -z "${latest}" ]]; then
            warn "${image}:${tag} - no matching tags found, skipped"
        elif [[ "$(printf '%s\n%s\n' "${tag}" "${latest}" | newest)" == "${tag}" ]]; then
            echo "  ${image}:${tag} (up-to-date)"
        else
            echo "  ${image}: ${tag} → ${latest}"
            sed -i "s|^FROM ${image}:${tag//./\\.}\\b|FROM ${image}:${latest}|" "${dockerfile}"
        fi
    done < <(grep -oP '^FROM\s+\K[^\s:$]+:\S+' "${dockerfile}" | sort -u)
}

# ── 2. Debian packages (BEGIN/END DEBIAN PACKAGES blocks) ─────────────────────

update_apt_packages() {
    local dockerfile="$1" base packages candidates package version escaped
    mapfile -t packages < <(awk '/^# BEGIN DEBIAN PACKAGES/ { f = 1 } /^# END DEBIAN PACKAGES/ { f = 0 } f' "${dockerfile}" \
        | grep -oP '^\s+\K[a-z0-9.+-]+(?==")' || true)
    if [[ "${#packages[@]}" -eq 0 ]]; then
        echo "  (no pinned packages)"
        return 0
    fi
    base=$(grep -oP '^FROM\s+\Kdebian:\S+' "${dockerfile}" | tail -1 || true)
    [[ -n "${base}" ]] || base=$(grep -oP '^FROM\s+\Kdebian:\S+' "${BASE_DOCKERFILE}" | tail -1)

    # Docker's APT repo is added the same way the base Dockerfile adds it, for the engine packages.
    # shellcheck disable=SC2016  # expanded inside the container
    candidates=$(docker run --rm "${base}" bash -c '
        set -e
        apt-get update -qq >/dev/null
        DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends ca-certificates curl >/dev/null 2>&1
        curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
        . /etc/os-release
        echo "deb [signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq >/dev/null
        apt-cache policy "$@"' _ "${packages[@]}" \
        | awk '/^[a-z0-9]/ { p = $1; sub(/:$/, "", p) } /Candidate:/ && $2 != "(none)" { print p, $2 }')

    # All or nothing: a package with no candidate leaves every pin in this file untouched.
    for package in "${packages[@]}"; do
        if ! grep -q "^${package} " <<< "${candidates}"; then
            echo "  ❌ No apt candidate for '${package}' on ${base} - no packages updated in ${dockerfile}" >&2
            exit 1
        fi
    done

    for package in "${packages[@]}"; do
        version=$(awk -v p="${package}" '$1 == p { print $2 }' <<< "${candidates}")
        escaped="${package//./\\.}"
        escaped="${escaped//+/\\+}"
        if grep -qF " ${package}=\"${version}\"" "${dockerfile}"; then
            echo "  ${package}=${version} (up-to-date)"
        else
            echo "  ${package} → ${version}"
            sed -i -E "s|^([[:space:]]+${escaped}=)\"[^\"]*\"|\\1\"${version}\"|" "${dockerfile}"
        fi
    done
}

# Not best-effort: a package with no apt candidate fails the run, since committing the other bumps would
# still leave a Dockerfile that cannot build. Pass the base first: the others' Debian packages are
# resolved against its (just bumped) Debian release.
# PACKAGES_ONLY (--packages-only) leaves the images alone: for a project whose own update script owns its
# image tags and calls this for the Debian packages only.
update_dockerfiles() {
    local dockerfile
    for dockerfile in "$@"; do
        echo
        echo "📄 ${dockerfile}"
        if [[ "${PACKAGES_ONLY}" -eq 0 ]]; then
            echo "🔍 Images..."
            update_images "${dockerfile}"
        fi
        # After the images: packages are resolved against the (possibly just bumped) Debian base.
        echo "🔍 Debian packages..."
        update_apt_packages "${dockerfile}"
    done
}

# ── 3. GitHub Actions ─────────────────────────────────────────────────────────
# Every `uses: owner/repo@version` in the workflows, moved to that action's latest stable release tag.
# Best-effort: an action that cannot be resolved (rate limit, no releases) is warned and left unchanged.

update_github_actions() {
    echo
    echo "🔍 Updating GitHub Actions versions..."

    local action_refs=() ref action current_version latest_version workflow
    mapfile -t action_refs < <(
        grep -rhoP 'uses:\s+\K[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+@\S+' "${WORKFLOWS_DIR}"/*.yml | sort -u || true
    )
    if [[ "${#action_refs[@]}" -eq 0 ]]; then
        echo "  No action references found."
        return 0
    fi

    for ref in "${action_refs[@]}"; do
        action="${ref%@*}"
        current_version="${ref#*@}"
        latest_version=$(latest_stable_github_release "${action}" || true)

        if [[ -z "${latest_version}" ]]; then
            warn "Could not fetch a stable version for ${action}, skipping"
        elif [[ "${current_version}" == "${latest_version}" ]]; then
            echo "  ${action}@${latest_version} (up-to-date)"
        else
            echo "  ${action}: ${current_version} → ${latest_version}"
            for workflow in "${WORKFLOWS_DIR}"/*.yml; do
                sed -i "s|${action}@${current_version//./\\.}\\b|${action}@${latest_version}|g" "${workflow}"
            done
        fi
    done

    ok "GitHub Actions updated in .github/workflows"
}

# ── Entry point ───────────────────────────────────────────────────────────────

dockerfiles=(
    "${BASE_DOCKERFILE}"
    "${REPO_ROOT}/examples/java-maven/Dockerfile"
    "${REPO_ROOT}/examples/android-gradle/Dockerfile"
    "${REPO_ROOT}/ai-sandbox-configuration/Dockerfile"
)
PACKAGES_ONLY=0
if [[ "${1:-}" == "--packages-only" ]]; then
    PACKAGES_ONLY=1
    shift
    [[ "${1:-}" == "--dockerfiles" ]] || usage
fi
case "${1:-}" in
    --dockerfiles)
        shift
        [[ "$#" -gt 0 ]] || usage
        update_dockerfiles "$@"
        echo
        echo "✅ Done - launch the sandbox (or run 'sandbox.sh build') to prove the new pins install."
        exit 0
        ;;
    "") ;;
    --skip-android-gradle) unset 'dockerfiles[2]' ;;
    *) usage ;;
esac

update_dockerfiles "${dockerfiles[@]}"
update_github_actions || warn "GitHub Actions update failed, continuing..."

echo
echo "✅ Dependency version update complete - run './sandbox.sh build' to prove the new pins install."
