# syntax=docker/dockerfile:1.7
# Example project layer: a Java service built with Maven, with a Node frontend, Playwright E2E tests
# and an image/font brand pipeline (taken from Diurnal's sandbox). Copy this directory to
# <project>/ai-sandbox-configuration/ and trim what the project does not use.
#
# Adds, on top of the shared base: JDK 26, Maven, Playwright's Chromium OS libraries, and ImageMagick /
# librsvg / optipng / fonttools / fontconfig.
#
# Layer order: the toolchain COPYs first (rarely move, and a change re-copies everything below), then
# the Playwright libs (rerun only when their list changes), the ENV block, and the most volatile apt
# pins last. Versions are bumped by `ai-sandbox/sandbox.sh update-versions` (FROM tags + the BEGIN/END
# DEBIAN PACKAGES block).

# The base image to build on - always passed by sandbox.sh.
ARG BASE_IMAGE

# ── Toolchain source stages ───────────────────────────────────────────────────
# Each is only mined for its self-contained directory; none of their base OS reaches the image.
FROM eclipse-temurin:26.0.2.1_1-jdk AS jdk
FROM maven:3.10.0-eclipse-temurin-26 AS maven

# ── Playwright Chromium's OS shared libs: the package LIST (libnspr4, libnss3, …) ─
# Playwright's own `install-deps` resolves the correct set (the names drift across Debian releases) -
# run on a copy of the shared base, so the list is exactly what the runtime stage is missing. Pinned to
# the version in the project's tests/package-lock.json. The browser BINARY stays out of the image:
# setup.d/20-playwright.sh downloads it into the `pw` cache volume on first open.
FROM ${BASE_IMAGE} AS playwright-deps
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008,DL3009
RUN --mount=type=cache,id=playwright-apt-cache,target=/var/cache/apt,sharing=locked --mount=type=cache,id=playwright-npm,target=/root/.npm,sharing=locked \
    apt-get update \
    && apt-mark showmanual | sort > /tmp/before \
    && npx --yes playwright@1.62.0 install-deps chromium \
    && apt-mark showmanual | sort | comm -13 /tmp/before - > /playwright-packages.txt \
    && test -s /playwright-packages.txt

# ── Runtime: the shared base + this project's toolchains ──────────────────────
FROM ${BASE_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=jdk   /opt/java/openjdk /opt/java/openjdk
COPY --from=maven /usr/share/maven  /opt/maven

# hadolint ignore=DL3008,DL3009
RUN --mount=type=bind,from=playwright-deps,source=/playwright-packages.txt,target=/tmp/playwright-packages.txt --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && xargs -a /tmp/playwright-packages.txt apt-get install -yqq --no-install-recommends

# These reach the session as-is (the entrypoint keeps the environment).
ENV JAVA_HOME=/opt/java/openjdk \
    MAVEN_HOME=/opt/maven \
    PLAYWRIGHT_BROWSERS_PATH=/home/dev/.cache/ms-playwright \
    PATH=/opt/java/openjdk/bin:/opt/maven/bin:${PATH}

# ── Project + brand tooling ───────────────────────────────────────────────────
# fontconfig: backs the copied-in Temurin JDK (the temurin base image normally supplies it).
# imagemagick + librsvg2-bin + optipng: rasterising the SVG favicon into .ico/.png sizes.
# python3-fonttools: rendering the wordmark glyphs (the distro package: pip is PEP-668 refused).
# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -yqq --no-install-recommends \
        fontconfig="2.15.0-2.3" \
        imagemagick="8:7.1.1.43+dfsg1-1+deb13u12" \
        librsvg2-bin="2.60.0+dfsg-1+deb13u1" \
        optipng="0.7.8+ds-1+b1" \
        python3-fonttools="4.57.0-1+deb13u1"
# END DEBIAN PACKAGES
