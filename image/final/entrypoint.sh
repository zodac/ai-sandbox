#!/usr/bin/env bash
# Runs as root (needed to start the nested dockerd), then drops to the `dev` user to run whatever
# command was passed (default: an interactive claude session).
set -euo pipefail

# Where sandbox.sh bind-mounts the project's ai-sandbox-configuration directory (absent if the project
# has none). Fixed, so its bin/ can sit on the image's PATH and `docker exec` sessions see it too.
CONFIG_DIR=/opt/ai-sandbox/config

# ── Start the nested Docker daemon ───────────────────────────────────────────
# Lives entirely inside this container; its containers/images/volumes are wiped when the sandbox is
# removed. Never touches the host's /var/run/docker.sock.
echo "[sandbox] starting nested dockerd..."
dockerd \
  --host=unix:///var/run/docker.sock \
  >/var/log/dockerd.log 2>&1 &

# Wait for it to come up.
tries=0
until docker info >/dev/null 2>&1; do
  tries=$((tries + 1))
  if [[ "${tries}" -gt 60 ]]; then
    echo "[sandbox] dockerd failed to start; last log lines:" >&2
    tail -n 30 /var/log/dockerd.log >&2 || true
    exit 1
  fi
  sleep 0.5
done
echo "[sandbox] nested dockerd is up."

# ── The host's timezone ──────────────────────────────────────────────────────
# sandbox.sh passes the host's zone as TZ (an IANA name, "Pacific/Auckland"), so dates here - test
# output, screenshots, an emulator's clock - read as they do on the host. TZ alone covers glibc and the
# JVM; /etc/localtime is pointed at it too for anything that only reads that. A name the image's
# tzdata doesn't know would make glibc silently use UTC under a wrong name, so it's dropped instead.
if [[ -n "${TZ-}" ]]; then
  if [[ -f "/usr/share/zoneinfo/${TZ}" ]]; then
    ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
  else
    echo "[sandbox] unknown timezone '${TZ}' - using UTC (set SANDBOX_TZ on the host to an IANA name)" >&2
    unset TZ
  fi
fi

# ── Hand the persisted mount points to `dev` ─────────────────────────────────
# Docker mounts a new named volume root-owned when the image has nothing at its path, and a
# bind-mounted host directory can also land root-owned if it didn't already exist when the mount was
# set up. chown each mount point (non-recursive, so existing contents are untouched) so the dev user
# can write into it - plus any parent directories docker had to create under /home/dev for it (a
# volume at ~/.cache/ms-playwright leaves a root-owned ~/.cache otherwise). SANDBOX_CACHE_PATHS is the
# container side of SANDBOX_CACHE_VOLUMES, passed by sandbox.sh.
own_mount_point() {
  local path="$1"
  mkdir -p "${path}"
  while [[ "${path}" == /home/dev/* ]]; do
    chown dev:dev "${path}" 2>/dev/null || true
    path="$(dirname "${path}")"
  done
}
read -ra cache_paths <<< "${SANDBOX_CACHE_PATHS-}"
for path in /home/dev/.claude ${cache_paths+"${cache_paths[@]}"}; do
  own_mount_point "${path}"
done

# ── The project's start-up hooks (ai-sandbox-configuration/entrypoint.d/*.sh) ─
# Run as ROOT, in name order, before anything else: the place for one-off adjustments to this
# container that need privileges (a symlink outside $HOME, opening up a device node, ...). A failing
# hook is reported but does not stop the sandbox from starting.
if [[ -d "${CONFIG_DIR}/entrypoint.d" ]]; then
  for hook in "${CONFIG_DIR}"/entrypoint.d/*.sh; do
    [[ -f "${hook}" ]] || continue
    bash "${hook}" || { status=$?; echo "[sandbox] WARN: entrypoint hook ${hook##*/} failed (exit ${status})" >&2; }
  done
fi

# ── Drop to the unprivileged user for the actual work ────────────────────────
# If no command was given, start an interactive Claude session with permissions skipped (safe: the
# sandbox is disposable and only the project is mounted from host).
if [[ "$#" -eq 0 ]]; then
  set -- claude --dangerously-skip-permissions
fi

# Run the per-open setup only for interactive sessions (a TTY on stdin), so quick scripted
# `sandbox.sh run <cmd>` invocations aren't slowed by the setup checks.
if [[ -t 0 ]]; then RUN_SETUP=1; else RUN_SETUP=0; fi
export RUN_SETUP

# setpriv rather than `sudo -u dev`: sudo resets the environment, so every variable a tool reads
# (JAVA_HOME, ANDROID_HOME, PLAYWRIGHT_BROWSERS_PATH, TZ, CLAUDE_CONFIG_DIR, ...) had to be listed in a
# --preserve-env that each project then edited. setpriv only changes the identity: the image's ENV
# (base, project and final), sandbox.sh's `-e` values and TZ all pass through untouched, so a project
# Dockerfile's ENV needs nothing here. --init-groups picks up dev's supplementary groups (docker).
cd /work
export HOME=/home/dev USER=dev LOGNAME=dev SHELL=/bin/bash
exec setpriv --reuid=dev --regid=dev --init-groups /usr/local/bin/sandbox-launch.sh "$@"
