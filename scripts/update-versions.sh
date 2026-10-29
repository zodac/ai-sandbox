#!/usr/bin/env bash
# Bumps the version pins in the given Dockerfiles (and nothing else) to the newest available:
#   - every `FROM image:tag` - to the newest tag with the same major and the same suffix, digits only
#     in between (26.8.2-trixie -> 26.12.1-trixie; never 27.x, -bookworm, -alpine or an -rc/-ea build).
#     A major bump is a manual, reviewed change. `FROM ${BASE_IMAGE}` and `FROM <stage>` lines carry no
#     tag, so they are left alone.
#   - every package in a `# BEGIN DEBIAN PACKAGES` / `# END DEBIAN PACKAGES` block - to apt's candidate
#     on the file's (just updated) Debian base, with Docker's APT repo added for the engine packages. A
#     project Dockerfile with no `FROM debian:` of its own is resolved against the shared base's.
#
# Usually run as `ai-sandbox/sandbox.sh update-versions`, which passes the base Dockerfile and the
# project's own (if any). Then launch (or `sandbox.sh build`) to prove the new pins install.
#
# Usage: update-versions.sh <Dockerfile>...
# Requirements: bash, curl, docker, jq, GNU grep/sed/sort.
set -euo pipefail

BASE_DOCKERFILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/image/base/Dockerfile"

if [[ "$#" -eq 0 ]]; then
    echo "Usage: $(basename "$0") <Dockerfile>..." >&2
    exit 1
fi

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
            echo "  ⚠️  ${image}:${tag} - no matching tags found, skipped" >&2
        elif [[ "$(printf '%s\n%s\n' "${tag}" "${latest}" | newest)" == "${tag}" ]]; then
            echo "  ${image}:${tag} (up-to-date)"
        else
            echo "  ${image}: ${tag} → ${latest}"
            sed -i "s|^FROM ${image}:${tag//./\\.}\\b|FROM ${image}:${latest}|" "${dockerfile}"
        fi
    done < <(grep -oP '^FROM\s+\K[^\s:$]+:\S+' "${dockerfile}" | sort -u)
}

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

for dockerfile in "$@"; do
    echo "📄 ${dockerfile}"
    echo "🔍 Images..."
    update_images "${dockerfile}"
    # After the images: packages are resolved against the (possibly just bumped) Debian base.
    echo "🔍 Debian packages..."
    update_apt_packages "${dockerfile}"
done
echo "✅ Done - launch the sandbox (or run 'sandbox.sh build') to prove the new pins install."
