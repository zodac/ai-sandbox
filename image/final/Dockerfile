# syntax=docker/dockerfile:1.7
# The FINAL, thin layer of every sandbox image: Claude Code and the sandbox's own scripts, on top of
# the project image (the project's ai-sandbox-configuration/Dockerfile, or ai-sandbox-base directly
# when the project has none). See image/base/Dockerfile for the three-layer overview.
#
# Everything here is either volatile (Claude Code: a release most days) or the most-edited files (the
# scripts), so it sits ABOVE the project's toolchains: a rebuild of this file costs one npm install and
# a few COPYs, never a re-copy of a project's multi-GB SDKs.
#
# PROJECT_IMAGE is always passed by sandbox.sh; there is no sensible default.
ARG PROJECT_IMAGE
FROM ${PROJECT_IMAGE}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# A project Dockerfile may have switched user for a step of its own; everything below (and the
# entrypoint, which starts the nested dockerd) runs as root - it drops to `dev` itself.
# hadolint ignore=DL3002
USER 0

# ── Claude Code CLI into a dev-owned npm prefix ──────────────────────────────
# Installing `-g` into npm's default /usr prefix makes the package and the /usr/bin/claude launcher
# root-owned, so the unprivileged `dev` user can't write to them — /doctor reports "npm global folder
# isn't writable". Instead, point npm's global prefix at a dev-owned dir (persisted in the image layer,
# baked via .npmrc so it needs no runtime env) and install AS dev. The prefix's bin dir is already on
# PATH (see the base image's ENV block). runuser (util-linux) drops to `dev` for the install without
# invoking sudo (hadolint DL3004); like `sudo -H` it resets HOME to /home/dev, so npm writes its config
# to the dev-owned ~/.npmrc.
#
# PINNED, to the version sandbox.sh resolved from the npm registry at build time, with the runtime
# self-update off (DISABLE_AUTOUPDATER in the base image). The self-update CANNOT be relied on to keep
# the sandbox current: it writes into the CONTAINER's writable layer, which `docker run --rm` deletes
# on teardown — so every launch came back on the image's version, downloaded the same update again, and
# showed the same "Update installed. Restart to apply" banner that a restart could never clear. Leaving
# the install unpinned did not help, because an unchanged instruction is a cache HIT: the layer was
# resolved once and then reused for months. The build arg is what changes when a release lands, and it
# is therefore the ONLY thing that rebuilds this layer.
#
# `latest` is the default only so a direct `docker build` still works; sandbox.sh always passes an
# explicit version. When it cannot reach the registry it passes the version on the existing image's
# label (below), so the layer stays a cache hit.
#
# The npm cache is a BuildKit cache mount owned by the dev UID, so re-running this after an unrelated
# invalidation resolves from disk rather than the registry. UID/GID must match the base image's.
ARG UID=1000
ARG GID=1000
ARG CLAUDE_CODE_VERSION=latest
RUN --mount=type=cache,target=/home/dev/.npm,uid=${UID},gid=${GID},sharing=locked \
    install -d -o dev -g dev /home/dev/.npm-global \
    && runuser -u dev -- npm config set prefix /home/dev/.npm-global \
    && runuser -u dev -- npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
# Read back by sandbox.sh's offline fallback.
LABEL net.zodac.sandbox.claude-code-version="${CLAUDE_CODE_VERSION}"

# ── Entrypoint + helper scripts (most-edited files, cheapest layer) ──────────
# --chmod sets the mode inline, avoiding a second layer for a `chmod +x`.
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 launch.sh     /usr/local/bin/sandbox-launch.sh
COPY --chmod=0755 setup.sh      /usr/local/bin/sandbox-setup.sh

WORKDIR /work

# ── Healthcheck ──────────────────────────────────────────────────────────────
# The sandbox runs no service, so the one thing worth probing is the nested dockerd started by
# entrypoint.sh: without it anything containerised fails, even though the container is still "up"
# from the host daemon's point of view. `docker info` talks to that nested daemon over
# /var/run/docker.sock and exits non-zero when it is unreachable; --format keeps the output to a single
# line (Docker retains the probe's output in the health log). The start period matches the
# entrypoint's own 30s (60 x 0.5s) dockerd wait, so a slow daemon start is never reported unhealthy.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["docker", "info", "--format", "{{.ServerVersion}}"]

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
