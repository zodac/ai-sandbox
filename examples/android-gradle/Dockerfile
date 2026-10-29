# syntax=docker/dockerfile:1.7
# Example project layer: an Android app built with Gradle (taken from DiceFive's sandbox). Copy this
# directory to <project>/ai-sandbox-configuration/ and adjust the pins to the project's own
# compileSdk / buildToolsVersion / ndkVersion / Gradle toolchain.
#
# Adds, on top of the shared base: JDK 25, the Android SDK (platform-tools, a platform, build-tools),
# the NDK, the emulator with a system image and a virtual device (bin/emulator.sh boots it),
# ImageMagick 7, ffmpeg, fonttools, and Playwright's Chromium OS libraries.
#
# ── LAYER ORDER IS DELIBERATE: THIS FILE IS OPTIMISED FOR REBUILD TIME ────────
# sandbox.sh rebuilds the image before EVERY launch, so a cache miss is paid on every session until
# something else invalidates the layer.
#
# About 10 GB of the image is downloaded content: the emulator and its system image (~6 GB), the NDK
# (~2.3 GB), the rest of the Android SDK, the JDK and ImageMagick. Each is fetched in a build stage of
# its own, cached on its own (a stage rebuilds only when its own text or base changes), and COPY'd in
# FIRST, straight after `FROM ${BASE_IMAGE}`, so nothing else in this file can invalidate them. A
# rebuilt shared base re-runs these COPYs too, but as local copies from the cached stages - never as
# downloads. Within the runtime stage:
#
#   1. COPY the downloaded toolchains  ordered JDK -> emulator -> NDK -> SDK -> ImageMagick, by how
#                                      often their pins move
#   2. Playwright's Chromium libs      reruns only when the playwright-deps stage's list changes
#   3. ENV block                       edited by hand now and then
#   4. tooling apt                     volatile pins
#   5. ImageMagick link, AVD           tiny
#
# The rule when adding a step: a download of any size goes in a stage of its own and is COPY'd in at
# the top, and so does any slow work whose result can be copied; anything else goes as far DOWN as its
# dependencies permit.
#
# Plain COPY, not `COPY --link`: on the classic overlay2 image store (the default on a Linux host's
# Docker Engine) a linked COPY is still re-copied once a layer above it changes, so the order is what
# keeps them cached.
#
# NOTE: every version below is pinned. `ai-sandbox/sandbox.sh update-versions` bumps the `FROM` tags
# and the BEGIN/END DEBIAN PACKAGES blocks; the Android packages, cmdline-tools URL/sha1 and
# ImageMagick release are this project's own to bump (DiceFive's
# .github/scripts/update_dependency_versions.sh does it).

# The base image to build on - always passed by sandbox.sh.
ARG BASE_IMAGE

# ── The emulator's Android version ────────────────────────────────────────────
# Follows compileSdk: the API level the app is compiled against, so the emulator runs the newest
# Android the project targets. Written as the image package names it ("37.0": from API 37 even the base
# release carries a minor; older ones are plain, "34"). Google APIs, not Google Play: only the former
# allows `adb root`. A global ARG, because two stages need it: the emulator stage installs its image,
# and the runtime stage makes the virtual device and exports it as ENV (for bin/emulator.sh).
ARG EMULATOR_API=37.0

# ── Toolchain source stages ───────────────────────────────────────────────────
# JDK 25 — self-contained under /opt/java/openjdk, portable onto glibc Debian. LTS: move to a newer
# major only once the project is proven to build on it, and keep it on the same major as the Gradle
# toolchain (gradle/gradle-daemon-jvm.properties), so a sandbox build never has to download a JDK.
FROM eclipse-temurin:25.0.4.1_1-jdk AS jdk

# ── Download stage: curl + unzip for the Android and ImageMagick stages ───────
# Unpinned on purpose: nothing installed here reaches the runtime image, only what the stages below
# download with it. An unchanged instruction is a cache hit, so this layer is rebuilt only when its own
# text or the Debian base changes. No BEGIN/END markers, so the update script leaves it alone. Its apt
# cache mounts have ids of their own, so its unpinned state never mixes with the runtime image's.
FROM debian:13.7 AS fetch
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008,DL3009
RUN --mount=type=cache,id=fetch-apt-cache,target=/var/cache/apt,sharing=locked --mount=type=cache,id=fetch-apt-lib,target=/var/lib/apt,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -yqq --no-install-recommends \
        ca-certificates curl unzip

# ── Android cmdline-tools (the installer the Android stages below share) ──────
# A direct download + checksum + unzip: there is no official image that is just "the Android SDK".
# Extracted with `unzip`, which keeps the executable bits (`jar xf` drops them). Pinned to the build
# Google's repository manifest (https://dl.google.com/android/repository/repository2-3.xml) serves as
# `cmdline-tools;latest`, sha1-verified against that same manifest. A bump here rebuilds the three
# stages below, which are built on it.
FROM fetch AS android-cli
# pipefail is set: the stage inherits fetch's SHELL, which hadolint does not follow.
# hadolint ignore=DL4006
RUN set -eux; \
    curl -fsSL -o /tmp/cmdline-tools.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-16111833_latest.zip"; \
    echo "e025545c62a8e64c7559119566a569fb1dec5f60  /tmp/cmdline-tools.zip" | sha1sum -c -; \
    mkdir -p /opt/android-sdk/cmdline-tools; \
    unzip -q /tmp/cmdline-tools.zip -d /opt/android-sdk/cmdline-tools; \
    mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest; \
    rm -f /tmp/cmdline-tools.zip

# The three Android stages below share this installer step's shape: `android sdk install` asks
# nothing; `|| true` on it because the `test` lines after it are what verify the packages landed; and
# `chmod -R a+rX` lets `dev` run what the installer unpacked without the other-user execute bit.

# ── Android emulator + its system image (~6 GB: so `emulator.sh start` boots at once) ──
FROM android-cli AS android-emulator
ARG EMULATOR_API
RUN set -eux; \
    /opt/android-sdk/cmdline-tools/latest/bin/android sdk install --sdk=/opt/android-sdk \
        "emulator" "system-images;android-${EMULATOR_API};google_apis;x86_64" </dev/null >/dev/null || true; \
    test -x /opt/android-sdk/emulator/emulator; \
    test -d "/opt/android-sdk/system-images/android-${EMULATOR_API}/google_apis/x86_64"; \
    chmod -R a+rX /opt/android-sdk

# ── Android NDK (matches `ndkVersion`) ────────────────────────────────────────
FROM android-cli AS android-ndk
RUN set -eux; \
    /opt/android-sdk/cmdline-tools/latest/bin/android sdk install --sdk=/opt/android-sdk \
        "ndk;30.0.16248370" </dev/null >/dev/null || true; \
    test -d /opt/android-sdk/ndk/30.0.16248370; \
    chmod -R a+rX /opt/android-sdk

# ── Android SDK (matches compileSdk + compileSdkMinor and buildToolsVersion) ──
# Keep these in step with the project's Gradle config, or a build will reach out to the network for
# whatever AGP defaults to instead of what is baked in here. The runtime stage copies this stage's
# whole SDK directory but only the package directories of the two stages above.
FROM android-cli AS android-sdk
RUN set -eux; \
    /opt/android-sdk/cmdline-tools/latest/bin/android sdk install --sdk=/opt/android-sdk \
        "platform-tools" "platforms;android-37.2" "build-tools;36.0.0" </dev/null >/dev/null || true; \
    test -x /opt/android-sdk/platform-tools/adb; \
    test -d /opt/android-sdk/platforms/android-37.2; \
    test -d /opt/android-sdk/build-tools/36.0.0; \
    chmod -R a+rX /opt/android-sdk

# ── ImageMagick 7 (its own AppImage, the same build CI uses) ──────────────────
# Extracted rather than mounted (no FUSE in a container); its AppRun runs the tool named by the link it
# was called through, so the runtime stage's `magick` link is `magick`.
FROM fetch AS imagemagick
ENV IMAGEMAGICK_VERSION=7.1.2-34
ENV IMAGEMAGICK_SHA256=6e9edfd35d5f30b57c27533afe003d6085faaf8607b207426f398d11751acf93
WORKDIR /opt
# hadolint ignore=DL4006
RUN set -eux; \
    curl -fsSL -o /tmp/magick.AppImage \
        "https://github.com/ImageMagick/ImageMagick/releases/download/${IMAGEMAGICK_VERSION}/ImageMagick-${IMAGEMAGICK_VERSION}-gcc-x86_64.AppImage"; \
    echo "${IMAGEMAGICK_SHA256}  /tmp/magick.AppImage" | sha256sum -c -; \
    chmod +x /tmp/magick.AppImage; \
    /tmp/magick.AppImage --appimage-extract > /dev/null; \
    mv /opt/squashfs-root /opt/imagemagick; \
    rm -f /tmp/magick.AppImage; \
    chmod -R a+rX /opt/imagemagick

# ── Playwright Chromium's OS shared libs: the package LIST (libnspr4, libnss3, …) ─
# The libraries are apt packages, so they are installed in the runtime stage itself; this stage works
# out WHICH ones. Playwright's own `install-deps` resolves the correct set (the names drift across
# Debian releases) - run on a copy of the shared base, so the list is exactly what the runtime stage
# is missing; the packages it marks as manually installed are the list. Pinned to an explicit
# Playwright version so the build stays reproducible. /var/lib/apt is NOT a cache mount here: it holds
# apt's manual/auto marks, which must start from the base's own for the list to be right.
#
# The browser BINARY stays out of the image: a session that wants one runs
# `npx playwright@<this version> install chromium`, which lands in the `pw` cache volume (sandbox.conf).
FROM ${BASE_IMAGE} AS playwright-deps
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3008,DL3009
RUN --mount=type=cache,id=playwright-apt-cache,target=/var/cache/apt,sharing=locked --mount=type=cache,id=playwright-npm,target=/root/.npm,sharing=locked \
    apt-get update \
    && apt-mark showmanual | sort > /tmp/before \
    && npx --yes playwright@1.64.1 install-deps chromium \
    && apt-mark showmanual | sort | comm -13 /tmp/before - > /playwright-packages.txt \
    && test -s /playwright-packages.txt

# ── Runtime: the shared base + this project's toolchains ──────────────────────
FROM ${BASE_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── The downloaded toolchains (first, so nothing below can invalidate them) ───
COPY --from=jdk              /opt/java/openjdk               /opt/java/openjdk
COPY --from=android-emulator /opt/android-sdk/emulator       /opt/android-sdk/emulator
COPY --from=android-emulator /opt/android-sdk/system-images  /opt/android-sdk/system-images
COPY --from=android-ndk      /opt/android-sdk/ndk            /opt/android-sdk/ndk
COPY --from=android-sdk      /opt/android-sdk                /opt/android-sdk
COPY --from=imagemagick      /opt/imagemagick                /opt/imagemagick

# ── Playwright Chromium OS shared libs (the playwright-deps stage's list) ──────
# The list is bind-mounted, and a read-only mount is cached by its content: a rebuilt playwright-deps
# stage that produces the same list is a cache hit here. Unpinned, the same as `install-deps` itself.
# hadolint ignore=DL3008,DL3009
RUN --mount=type=bind,from=playwright-deps,source=/playwright-packages.txt,target=/tmp/playwright-packages.txt --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && xargs -a /tmp/playwright-packages.txt apt-get install -yqq --no-install-recommends

ARG EMULATOR_API

# Every ENV in one block. These reach the session as-is (the entrypoint keeps the environment).
# ANDROID_HOME / ANDROID_SDK_ROOT — both, since AGP reads the former and some older tooling the latter.
# PLAYWRIGHT_BROWSERS_PATH — Playwright's own Chromium, cached in the `pw` volume.
ENV JAVA_HOME=/opt/java/openjdk \
    ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    EMULATOR_API=${EMULATOR_API} \
    PLAYWRIGHT_BROWSERS_PATH=/home/dev/.cache/ms-playwright \
    PATH=/opt/java/openjdk/bin:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:${PATH}

# ── Project tooling ───────────────────────────────────────────────────────────
# ffmpeg: re-encoding / gain-adjusting the app's .ogg sound effects.
# fontconfig: backs the copied-in Temurin JDK (the temurin base image normally supplies it).
# python3-fonttools: font instancing/subsetting (the distro package: pip is PEP-668 refused).
# hadolint ignore=DL3009
# BEGIN DEBIAN PACKAGES
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -yqq --no-install-recommends \
        ffmpeg="7:7.1.5-0+deb13u1" \
        fontconfig="2.15.0-2.3" \
        python3-fonttools="4.57.0-1+deb13u1"
# END DEBIAN PACKAGES

# ── ImageMagick's `magick`, and the emulator's virtual device ─────────────────
# `magick -version` runs here, after the tooling block, so the check sees the runtime libraries. The
# virtual device is made as `dev` - the user that boots it - under dev's own ~/.android/avd, which no
# volume mounts over. Single quotes on purpose: the inner bash expands EMULATOR_API from the ENV block.
# hadolint ignore=SC2016
RUN ln -s /opt/imagemagick/AppRun /usr/local/bin/magick \
    && magick -version \
    && runuser -u dev -- env HOME=/home/dev bash -c \
    'echo no | /opt/android-sdk/cmdline-tools/latest/bin/avdmanager create avd \
        -n "sandbox-api${EMULATOR_API}" -k "system-images;android-${EMULATOR_API};google_apis;x86_64" -d pixel_6' \
    && test -d "/home/dev/.android/avd/sandbox-api${EMULATOR_API}.avd"
