# syntax=docker/dockerfile:1.7
# The SHARED base of every sandbox image: what any project needs to run Claude Code with
# --dangerously-skip-permissions against itself, fully isolated from the host - and nothing else.
#
# sandbox.sh builds every sandbox image in three layers:
#
#   1. ai-sandbox-base:<hash>   THIS file. Tagged by a hash of this directory's contents plus the
#                               host UID/GID, so it is built once and shared by every project whose
#                               submodule is on the same commit.
#   2. <name>-sandbox-project   The project's own ai-sandbox-configuration/Dockerfile (optional),
#                               `FROM ${BASE_IMAGE}`: its toolchains (JDK, Maven, Android, Playwright...).
#   3. <name>-sandbox           image/final/Dockerfile: Claude Code + the sandbox scripts. On TOP, so
#                               Claude's near-daily releases never invalidate a project's toolchains.
#
# ── KEEP THIS MINIMAL ─────────────────────────────────────────────────────────
# Anything added here lands in EVERY project's image, and a change here rebuilds every project's
# layer 2. A toolchain or library only some projects use (a JDK, Maven, ImageMagick, fonttools,
# Playwright's Chromium libs...) belongs in that project's Dockerfile instead.
#
# The runtime is a plain Debian 13 (trixie) base. Node (needed by Claude Code) is pulled from its
# official image as a build stage and its directory copied straight in, so we track an upstream image
# tag instead of hand-rolling a NodeSource download. On top: a NESTED Docker engine, so anything a
# session spins up runs inside this throwaway container, never touching the host daemon.
#
# The nested Docker engine is NOT copied from an image: the binaries in the official
# `docker`/`docker:dind` images are musl-linked (Alpine), so they can't be dropped onto this glibc
# Debian base — Docker's own Debian APT repo is the portable path, so it stays a normal apt install.
#
# NOTE: every version below is pinned, and bumped by `ai-sandbox/sandbox.sh update-versions`
# (scripts/update-versions.sh). That script relies on this file's shape: `FROM image:tag` lines and
# the BEGIN/END DEBIAN PACKAGES markers around each pinned package list.
#
# ── LAYER ORDER ───────────────────────────────────────────────────────────────
# Ordered from the most stable to the most volatile, so a pin bump rebuilds as little as possible:
#
#   1. apt cache config     static
#   2. ENV block            edited by hand now and then
#   3. bootstrap apt        4 packages, rarely bumped
#   4. user creation        UID/GID build args
#   5. Docker repo + engine volatile pins
#   6. tooling apt          volatile pins
#   7. COPY node            bumped on most update runs
#
# BuildKit cache mounts back the apt downloads, so even a genuine cache miss re-installs from local
# disk instead of re-fetching over the network.

# ── Toolchain source stage (its payload is copied into the Debian base) ──────
# Node 26 — installed under /usr/local; the prebuilt binaries are glibc-portable (the -trixie tag
# matches this base's glibc exactly).
FROM node:26.12.1-trixie AS node

# ── Runtime base ─────────────────────────────────────────────────────────────
FROM debian:13.7

# pipefail for every RUN in this stage so a failure in the middle of a `getent … | cut` pipe (or any
# other) aborts the layer instead of being masked by the pipe's last command (debian base has bash).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── apt cache configuration (static) ─────────────────────────────────────────
# Debian base images ship /etc/apt/apt.conf.d/docker-clean, which deletes every downloaded .deb the
# moment apt finishes — that would empty the BuildKit cache mounts below on each run and defeat the
# point. Removing it and setting Keep-Downloaded-Packages lets the mounts retain the archives between
# builds, so a bumped pin re-installs from local disk instead of re-downloading. Project Dockerfiles
# built FROM this image inherit the setting, so their apt cache mounts work the same way.
#
# The apt RUNs below therefore deliberately do NOT `apt-get clean` or `rm -rf /var/lib/apt/lists/*`
# (that is what DL3009 asks for): both paths ARE the cache mounts, so cleaning them would throw away
# exactly what we want to keep. Nothing is left in the image layer either way — a cache mount is not
# part of the filesystem it is mounted over.
#
# FORMATTING CONSTRAINT: keep BOTH --mount flags on the same physical line as `RUN`, and keep the
# BEGIN/END DEBIAN PACKAGES markers around each list. The update script harvests package names from
# the block with `grep -oP '^\s+\K[a-z0-9.+-]+(?==")'`, which would otherwise pick up a continuation
# line beginning with `--mount=` as a package called "--mount" and silently stop updating the block.
RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# Every ENV in one block, BELOW the static layer above: an edit here rebuilds only what follows.
#
# CLAUDE_CONFIG_DIR — keep ALL of Claude Code's config in the persisted ~/.claude bind mount. By
#   default Claude splits its state: the ~/.claude/ directory (history, OAuth credentials) AND a
#   separate ~/.claude.json file in the home root (onboarding/terminal-setup state + login). Only the
#   directory is mounted, so without this the .claude.json file is recreated empty on every run —
#   forcing terminal reconfiguration + re-login each time. This redirects .claude.json (and
#   credentials) INTO the mounted dir, so it all persists.
# DISABLE_AUTOUPDATER — Claude Code is pinned per build (see image/final/Dockerfile); a runtime
#   self-update would only land in the container's writable layer, which `--rm` deletes, so every
#   launch re-downloaded the same update.
# PATH — the dev-owned npm prefix goes FIRST so the image's `claude` wins over any other copy on the
#   path; the project configuration's bin/ (bind-mounted at /opt/ai-sandbox/config by sandbox.sh) goes
#   LAST, so a project helper script can never shadow a system tool. A project Dockerfile prepends its
#   own toolchains with `ENV PATH=/opt/<tool>/bin:${PATH}`.
ENV DEBIAN_FRONTEND=noninteractive \
    CLAUDE_CONFIG_DIR=/home/dev/.claude \
    DISABLE_AUTOUPDATER=1 \
    PATH=/home/dev/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/ai-sandbox/config/bin

# ── Bootstrap packages (kept deliberately minimal) ───────────────────────────
# ONLY what later BUILD steps need — everything required merely at runtime lives in the tooling block
# below. Every layer below this one rebuilds when it changes, so it stays as small as possible.
#
#   curl + gnupg + ca-certificates → fetch and trust the Docker APT repo signing key in the Docker
#     repo step; ca-certificates also provides the TLS chain for the npm install in the final image.
#   libatomic1 → the Node binary copied from the node stage is dynamically linked against
#     libatomic.so.1, which the bare Debian base does NOT ship. Without it `node` exits 127 ("error
#     while loading shared libraries") and the Claude Code install fails.
# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -yqq --no-install-recommends \
        ca-certificates="20250419+deb13u1" \
        curl="8.14.1-2+deb13u7" \
        gnupg="2.4.7-21+deb13u1" \
        libatomic1="14.2.0-19"
# END DEBIAN PACKAGES

# ── Non-root user `dev` matching the host UID/GID, with passwordless sudo ────
# The Debian base ships no user at ${UID}/${GID}, so this normally just creates `dev`. The getent
# guards keep it robust if a base ever does pre-populate the UID/GID: rename whatever owns them to
# `dev` and point its home at /home/dev.
#
# UID/GID are declared HERE, not at the top of the stage: every RUN after an ARG's declaration gets it
# as an environment variable, so a value that differs from the last build (a macOS host is typically
# 501) misses the cache from the first RUN after the ARG, not from the first one that uses it.
#
# The `docker` group is created here rather than by the docker-ce package below (whose install reuses
# an existing group), so this block does not have to wait for it.
#
# /etc/sudoers.d is created explicitly rather than relying on the `sudo` package — sudo installs in
# the tooling block BELOW this one, so the directory would not otherwise exist yet.
#
# Cache directories (~/.m2, ~/.gradle, ...) are NOT pre-created here: which ones a project mounts is
# its own choice (SANDBOX_CACHE_VOLUMES), and entrypoint.sh hands every mount point to `dev` at start.
ARG UID=1000
ARG GID=1000
RUN set -eux; \
    if ! getent group "${GID}" >/dev/null; then groupadd -g "${GID}" dev; \
    else groupmod -n dev "$(getent group ${GID} | cut -d: -f1)" || true; fi; \
    if getent passwd "${UID}" >/dev/null; then \
      usermod -l dev -d /home/dev -m -s /bin/bash "$(getent passwd ${UID} | cut -d: -f1)"; \
    else \
      useradd -l -m -u "${UID}" -g "${GID}" -s /bin/bash dev; \
    fi; \
    getent group docker >/dev/null || groupadd -r docker; \
    usermod -aG docker dev; \
    install -d -m 0755 /etc/sudoers.d; \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev; \
    chmod 0440 /etc/sudoers.d/dev

# ── Nested daemon config: keep the build cache from growing without limit ────
# The `-docker` volume (/var/lib/docker) is by far the largest of a sandbox's volumes - every nested
# build or run leaves image layers and BuildKit cache behind, and nothing reclaims them by default.
# Left alone it reaches tens of GB: measured 77GB on a two-month-old sandbox, 61GB of it build cache.
# BuildKit's own GC is the fix, but it is off unless configured, so the policy is baked into the image
# (rather than left to the host). `maxUsedSpace` keeps enough cache to make a re-run a cache hit while
# capping the total; `keepDuration` drops anything untouched for a week. Reclaim the rest with
# `sandbox.sh prune`.
COPY daemon.json /etc/docker/daemon.json

# ── Docker engine + compose plugin (the nested daemon) ───────────────────────
# The base is pinned to Debian, so the repo distro is hardcoded as `debian`; only the release codename
# is derived (from /etc/os-release, via sed rather than a sourced shell var) so a base point/major
# bump follows automatically.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release) stable" \
         > /etc/apt/sources.list.d/docker.list

# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -yqq --no-install-recommends \
        docker-ce="5:29.9.2-1~debian.13~trixie" \
        docker-ce-cli="5:29.9.2-1~debian.13~trixie" \
        containerd.io="2.4.2-3~debian.13~trixie" \
        docker-buildx-plugin="0.38.1-1~debian.13~trixie" \
        docker-compose-plugin="5.6.1-1~debian.13~trixie"
# END DEBIAN PACKAGES

# ── Runtime tooling ───────────────────────────────────────────────────────────
# Everything EVERY sandbox needs at RUNTIME but nothing above needs at BUILD time.
#
# git + jq: the agent's everyday tools; jq also backs launch.sh's settings merge and the projects'
#   PreToolUse hook guards (a jq-less hook silently blocks nothing).
#
# python3 (+pip/venv): general scripting. The base image's Python is PEP-668 "externally managed", so
#   `pip install` is refused system-wide - a project wanting Python packages installs the distro
#   `python3-<name>` package in its own Dockerfile, or uses a venv.
#
# lsof + iproute2 (`ss`) find whatever is LISTENing on a port inside the sandbox — the usual way to
#   clear a stale process holding a port before rerunning something.
#
# tzdata: entrypoint.sh points /etc/localtime at the host's timezone, which needs the zone files.
#
# sudo provides the runtime `sudo` binary; /etc/sudoers.d/dev is already written above.
#
# unzip: needed often enough by sessions (and by project scripts) to be worth carrying everywhere.
#
# gh is the GitHub CLI, so a session can read the CI run it just triggered (`gh run view --log-failed`)
# rather than asking someone to paste the log in. Debian's own package, not GitHub's apt repo: the repo
# would cost a keyring + sources step and a volatile pin for a tool nothing builds against. The
# tradeoff is that trixie ships a version behind upstream, which reads runs, PRs and logs perfectly
# well. It ships NO credentials, and nothing persists any: a `gh auth login` is entered per session and
# dies with the container. Deliberate - see the README's Notes before adding a token passthrough or a
# volume for ~/.config/gh, because that is a policy decision that has already been taken the other way.
# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -yqq --no-install-recommends \
        bash="5.2.37-2+b10" \
        gh="2.46.0-3" \
        git="1:2.47.3-0+deb13u1" \
        iproute2="6.15.0-1" \
        jq="1.7.1-6+deb13u4" \
        lsof="4.99.4+dfsg-2" \
        python3="3.13.5-1" \
        python3-pip="25.1.1+dfsg-1" \
        python3-venv="3.13.5-1" \
        sudo="1.9.16p2-3+deb13u2" \
        tzdata="2026e-0+deb13u1" \
        unzip="6.0-29+deb13u1"
# END DEBIAN PACKAGES

# ── Node (copied from the node stage above) ───────────────────────────────────
# Last: its tag moves on most update runs, and it is small enough (~230MB) to re-copy cheaply. Nothing
# above needs it; the Claude Code install in the final image does.
COPY --from=node /usr/local /usr/local

WORKDIR /work
