#!/usr/bin/env bash
# Make the host's Android SDK path resolve in here (runs as root, at every sandbox start).
#
# /work/local.properties is the host's own file (Android Studio writes it), so its sdk.dir names the
# host's SDK - a path that doesn't exist in this container, and AGP warns about it on every build
# before falling back to ANDROID_HOME. Pointing the file at this container's SDK would break the
# host's build instead, so the host's path is made to exist here: a symlink to the SDK baked into the
# image. Never replaces anything already at that path.
set -euo pipefail

sdk_dir="$(sed -n 's/^sdk\.dir=//p' /work/local.properties 2>/dev/null | tail -n 1)"
if [[ -n "${sdk_dir}" && "${sdk_dir}" == /* && ! -e "${sdk_dir}" ]]; then
  mkdir -p "$(dirname "${sdk_dir}")"
  ln -s "${ANDROID_HOME:?set by the project image}" "${sdk_dir}"
  echo "[sandbox] linked local.properties' sdk.dir (${sdk_dir}) to ${ANDROID_HOME}."
fi
