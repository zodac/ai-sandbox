# syntax=docker/dockerfile:1.7
# This project's layer of the sandbox image: the toolchains it needs on top of the shared base
# (Debian 13, nested Docker, Node, git, gh, jq, python3 - see ai-sandbox/image/base/Dockerfile).
# Claude Code and the sandbox scripts are added ABOVE this layer, so a Claude release never rebuilds
# anything here. Built by ai-sandbox/sandbox.sh with this directory as the build context.
#
# Rules of thumb (ai-sandbox/README.md has the long version):
#   - A download of any size goes in a build stage of its own and is COPY'd in near the top, so it is
#     cached independently of everything else (a base rebuild then only re-copies it).
#   - Pin every version, and keep apt packages inside `# BEGIN DEBIAN PACKAGES` / `# END DEBIAN
#     PACKAGES` markers (one `name="version" \` per line, both --mount flags on the RUN line), so
#     `ai-sandbox/sandbox.sh update-versions` can bump them.
#   - Stay root (the default); the final layer and the entrypoint expect it. Anything that must run as
#     the sandbox user uses `runuser -u dev -- ...`.
#   - An ENV set here reaches the session as-is (no allow-list to update).

ARG BASE_IMAGE

# ── Toolchain source stages (examples) ────────────────────────────────────────
# FROM eclipse-temurin:25.0.4.1_1-jdk AS jdk

FROM ${BASE_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# COPY --from=jdk /opt/java/openjdk /opt/java/openjdk
# ENV JAVA_HOME=/opt/java/openjdk \
#     PATH=/opt/java/openjdk/bin:${PATH}

# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
# RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
#     apt-get update && apt-get install -yqq --no-install-recommends \
#         fontconfig="2.15.0-2.3"
# END DEBIAN PACKAGES
