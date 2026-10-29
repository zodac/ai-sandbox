#!/usr/bin/env bash
# Launch the isolated project sandbox. This repo is a git submodule of the project (normally at
# <project>/ai-sandbox/), and the project's own settings live beside it in
# <project>/ai-sandbox-configuration/ (see the README).
#
#   ai-sandbox/sandbox.sh                  # start an interactive Claude session in the sandbox
#   ai-sandbox/sandbox.sh continue         # ... continuing the most recent Claude session
#   ai-sandbox/sandbox.sh resume           # ... picking a previous Claude session from a list
#   ai-sandbox/sandbox.sh shell            # drop into a bash shell instead of Claude
#   ai-sandbox/sandbox.sh run <cmd...>     # run an arbitrary command in the sandbox
#   ai-sandbox/sandbox.sh attach           # open another shell in the RUNNING sandbox
#   ai-sandbox/sandbox.sh build            # (re)build the image
#   ai-sandbox/sandbox.sh stop             # stop & remove a running sandbox (one-click teardown)
#   ai-sandbox/sandbox.sh prune            # reclaim disk in the nested docker (build cache, images, volumes)
#   ai-sandbox/sandbox.sh init             # create ai-sandbox-configuration/ and the IntelliJ run configs
#   ai-sandbox/sandbox.sh update-versions  # bump the version pins in the base + project Dockerfiles
#
# A launch REPLACES any sandbox of the SAME project checkout that is already running (they cannot
# coexist — same name, same ports, same ~/.claude bind mount), stopping it only once the new image has
# been built. Every docker name is derived from the project directory's path (see SLUG below), so a
# DIFFERENT project or checkout — another IntelliJ window — shares none of that state.
#
# Only the project directory is mounted from the host. No $HOME, no SSH keys, no other projects, and
# NOT the host Docker socket. The sandbox runs its own nested Docker daemon, so any container a session
# spins up lives and dies inside this disposable container.
set -euo pipefail

# This script lives in <project>/<submodule>/, so the project root is its parent dir.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${PROJECT_DIR:-$(dirname "${HERE}")}"
CONFIG_DIR="${SANDBOX_CONFIG_DIR:-${PROJECT_DIR}/ai-sandbox-configuration}"

# ── The project's settings: ai-sandbox-configuration/sandbox.conf ────────────
# Plain bash, sourced. A variable already set in the ENVIRONMENT wins over the file, so a one-off
# `SANDBOX_PORTS= ai-sandbox/sandbox.sh` still works - hence saving the environment's values before
# sourcing and putting them back after. Set-but-empty counts as set (an empty SANDBOX_PORTS means
# "publish nothing", which must be able to override a file that publishes something).
SETTINGS=(SANDBOX_NAME SANDBOX_PORTS SANDBOX_CACHE_VOLUMES SANDBOX_NPM_DIRS SANDBOX_ENV SANDBOX_RUN_ARGS SANDBOX_TZ)
declare -A FROM_ENV=()
for setting in "${SETTINGS[@]}"; do
  if [[ -n "${!setting+set}" ]]; then FROM_ENV["${setting}"]="${!setting}"; fi
done
if [[ -f "${CONFIG_DIR}/sandbox.conf" ]]; then
  # shellcheck source=/dev/null # the project's own file
  source "${CONFIG_DIR}/sandbox.conf"
fi
for setting in "${!FROM_ENV[@]}"; do
  printf -v "${setting}" '%s' "${FROM_ENV[${setting}]}"
done

# ── Names ─────────────────────────────────────────────────────────────────────
# EVERY docker name below is DERIVED, never hardcoded - the container, the image, the hostname and the
# cache volumes - from the project directory's basename (readable in `docker ps`) PLUS a short hash of
# its absolute path. The basename alone is not enough: two checkouts of the same repo (or two repos
# that happen to share a name) would attach each other's caches and replace each other's sandbox. The
# hash is taken here, before the Windows path conversion below, so it is stable per checkout.
# `cksum` (CRC-32) rather than sha256sum: it is POSIX, so present on every host (macOS and Git Bash
# included), and this only has to tell a handful of checkouts apart. Set SANDBOX_NAME to pin a name.
#
# Claude's own state (~/.claude — auth, history, memory) is NOT a named volume but a plain directory in
# the project's configuration (CLAUDE_HISTORY_DIR), so it is scoped by the checkout itself.
SLUG="$(basename "${PROJECT_DIR}")"
SLUG="${SLUG,,}"                     # docker image names must be lowercase
SLUG="${SLUG//[^a-z0-9_.-]/-}"       # ... and hold only [a-z0-9_.-]
[[ "${SLUG}" =~ ^[a-z0-9] ]] || SLUG="sandbox${SLUG}"  # ... and start alphanumeric
PATH_HASH="$(printf '%s' "${PROJECT_DIR}" | cksum | cut -d' ' -f1)"
PATH_HASH="$(printf '%08x' "${PATH_HASH}")"
NAME="${SANDBOX_NAME:-${SLUG}-${PATH_HASH:0:6}}-sandbox"
IMAGE="${NAME}"
PROJECT_IMAGE="${NAME}-project"
CONTAINER="${NAME}"
CLAUDE_HISTORY_DIR="${CONFIG_DIR}/.claude-history"

# Ports published to the HOST, space-separated `host:container` pairs - the one resource two sandboxes
# can still collide on (two cannot both hold the same host port). Unlike the names it fails LOUDLY
# ("port is already allocated"), so it is a setting rather than a derivation. Default: nothing.
read -ra PUBLISH_PORTS <<< "${SANDBOX_PORTS-}"
PUBLISH=()
for port in ${PUBLISH_PORTS+"${PUBLISH_PORTS[@]}"}; do PUBLISH+=(-p "${port}"); done

# Named cache volumes, space-separated `name:/container/path` pairs, each mounted as
# `<NAME>-<name>` (e.g. "m2:/home/dev/.m2 gradle:/home/dev/.gradle"). Without one a cache lives in the
# container's writable layer, which --rm deletes on teardown, so every fresh sandbox re-downloads the
# lot. A named volume — rather than a bind to the host's ~/.m2 — keeps the "no $HOME from the host"
# rule intact. The container paths are passed on as SANDBOX_CACHE_PATHS so entrypoint.sh can hand the
# mount points to `dev`.
read -ra CACHE_VOLUMES <<< "${SANDBOX_CACHE_VOLUMES-}"
CACHE_MOUNTS=()
CACHE_PATHS=()
for volume in ${CACHE_VOLUMES+"${CACHE_VOLUMES[@]}"}; do
  if [[ "${volume}" != *:/* ]]; then
    echo "[sandbox] SANDBOX_CACHE_VOLUMES entry '${volume}' is not name:/absolute/path" >&2
    exit 1
  fi
  CACHE_MOUNTS+=(-v "${NAME}-${volume%%:*}:${volume#*:}")
  CACHE_PATHS+=("${volume#*:}")
done

# Extra environment for the sandbox, space-separated KEY=VALUE pairs (no spaces inside a value), and
# extra `docker run` flags (e.g. "--device /dev/kvm"), passed through as-is.
read -ra EXTRA_ENV <<< "${SANDBOX_ENV-}"
ENV_ARGS=()
for pair in ${EXTRA_ENV+"${EXTRA_ENV[@]}"}; do ENV_ARGS+=(-e "${pair}"); done
read -ra RUN_ARGS <<< "${SANDBOX_RUN_ARGS-}"

# The host's timezone, so the sandbox's clock reads the same as the machine it runs on: dates in test
# output, screenshots and an emulator's clock. An IANA name ("Pacific/Auckland"). SANDBOX_TZ overrides
# it; otherwise TZ, then the OS's own setting; UTC if none can be read. entrypoint.sh checks the name
# against the image's tzdata and falls back to UTC (with a warning) for one it doesn't know.
host_timezone() {
  local zone=""
  if [[ -n "${TZ-}" && "${TZ}" != :* ]]; then
    zone="${TZ}"
  elif command -v timedatectl &>/dev/null; then
    zone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi
  if [[ -z "${zone}" && -r /etc/timezone ]]; then
    zone="$(head -n 1 /etc/timezone)"
  fi
  if [[ -z "${zone}" && -L /etc/localtime ]]; then
    # Linux (/usr/share/zoneinfo/...) and macOS (/var/db/timezone/zoneinfo/...) both link to zoneinfo/<zone>.
    zone="$(readlink /etc/localtime)"
    zone="${zone##*zoneinfo/}"
  fi
  if [[ -z "${zone}" ]] && command -v powershell.exe &>/dev/null; then
    # Windows names its zones its own way ("New Zealand Standard Time"); .NET converts to IANA.
    # shellcheck disable=SC2016 # the $ variables are PowerShell's, so bash must not expand them
    zone="$(powershell.exe -NoProfile -Command \
      '$i=$null; if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId([TimeZoneInfo]::Local.Id, [ref]$i)) { $i }' \
      2>/dev/null | tr -d '\r' || true)"
  fi
  echo "${zone:-UTC}"
}
SANDBOX_TIMEZONE="${SANDBOX_TZ:-$(host_timezone)}"

# The host-side paths as Docker wants them. Git Bash on Windows resolves paths as /c/Users/... but
# Docker Desktop needs C:\Users\... - while bash's own tools (mkdir, the cksum above) need the POSIX
# form, so both are kept.
to_docker_path() {
  if command -v cygpath &>/dev/null; then cygpath -w "$1"; else printf '%s' "$1"; fi
}

# ── Image build: base → project → final ───────────────────────────────────────
# See image/base/Dockerfile for why the image is three layers. Each is an ordinary `docker build`, so
# the host's layer cache makes an unchanged one a near-instant no-op.

# The Claude Code version to bake into the final image, read from the npm registry.
#
# Needed because the sandbox container is `--rm`: Claude's runtime self-update writes into the
# container's writable layer, which teardown deletes, so without this every launch comes back on the
# image's version, re-downloads the same update, and shows an "Update installed. Restart to apply"
# banner that restarting can never clear. Leaving the Dockerfile's install unpinned does NOT fix that
# either - an unchanged instruction is a cache hit, so the layer keeps serving whatever version it
# resolved months ago. Passing the resolved version as a build arg is what makes the layer rebuild when
# (and only when) a new release exists.
#
# Reports the version in CLAUDE_VERSION, left EMPTY when the registry cannot be reached or curl is
# absent (a global rather than an exit status, for the same reason REMOVED_EXISTING below is one: a
# function called as an `if` condition runs with `set -e` disabled). The caller then passes the version
# the existing image was built with (its CLAUDE_VERSION_LABEL), so the layer stays cached and an
# offline build still works. Parsed with grep rather than jq because this half runs on the HOST, where
# jq is not a given (Git Bash on Windows especially) - the /latest document opens with
# `{"name":...,"version":"x.y.z"`, so the first match is the one wanted.
CLAUDE_PACKAGE_URL='https://registry.npmjs.org/@anthropic-ai/claude-code/latest'
CLAUDE_VERSION_LABEL='net.zodac.sandbox.claude-code-version'
CLAUDE_VERSION=""
resolve_claude_version() {
  local document
  CLAUDE_VERSION=""
  command -v curl >/dev/null 2>&1 || return 0
  document="$(curl -fsSL --max-time 10 "${CLAUDE_PACKAGE_URL}" 2>/dev/null)" || return 0
  CLAUDE_VERSION="$(printf '%s' "${document}" \
    | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -n 1 \
    | cut -d'"' -f4)"
}

# The shared base image's tag: a hash of everything in image/base/ plus the UID/GID it bakes in. Two
# projects whose submodules are on the same commit get the same tag (and share one image); a project
# on another commit gets its own, so neither keeps retagging the other's. Since the tag IS the content,
# an existing tag never needs rebuilding.
base_image() {
  local hash
  hash="$( (cd "${HERE}/image/base" && find . -type f | LC_ALL=C sort | while read -r file; do
             printf '%s\n' "${file}"; cat "${file}"; done; id -u; id -g) | cksum | cut -d' ' -f1)"
  printf 'ai-sandbox-base:%08x' "${hash}"
}

build() {
  local uid gid base from claude_arg=() baked
  uid="$(id -u)"
  gid="$(id -g)"
  base="$(base_image)"

  # 1. The shared base.
  if docker image inspect "${base}" >/dev/null 2>&1; then
    echo "[sandbox] base image ${base} is up to date" >&2
  else
    echo "[sandbox] building base image ${base}..." >&2
    docker build -t "${base}" \
      --build-arg UID="${uid}" \
      --build-arg GID="${gid}" \
      "$(to_docker_path "${HERE}/image/base")"
  fi

  # 2. The project's toolchains, if it has a Dockerfile. Its build context is the configuration
  #    directory, so it can COPY its own files - and must not send .claude-history (auth tokens!)
  #    along, which ensure_config's .dockerignore prevents.
  from="${base}"
  if [[ -f "${CONFIG_DIR}/Dockerfile" ]]; then
    echo "[sandbox] building project image ${PROJECT_IMAGE}..." >&2
    docker build -t "${PROJECT_IMAGE}" \
      --build-arg BASE_IMAGE="${base}" \
      "$(to_docker_path "${CONFIG_DIR}")"
    from="${PROJECT_IMAGE}"
  fi

  # 3. Claude Code + the sandbox scripts.
  resolve_claude_version
  if [[ -n "${CLAUDE_VERSION}" ]]; then
    echo "[sandbox] baking Claude Code ${CLAUDE_VERSION} into the image" >&2
    claude_arg=(--build-arg CLAUDE_CODE_VERSION="${CLAUDE_VERSION}")
  else
    baked="$(docker image inspect -f "{{ index .Config.Labels \"${CLAUDE_VERSION_LABEL}\" }}" "${IMAGE}" 2>/dev/null || true)"
    if [[ -n "${baked}" && "${baked}" != "<no value>" ]]; then
      echo "[sandbox] WARN: could not reach the npm registry - keeping the image's Claude Code ${baked}" >&2
      claude_arg=(--build-arg CLAUDE_CODE_VERSION="${baked}")
    else
      echo "[sandbox] WARN: could not reach the npm registry, and the image records no Claude Code version" >&2
    fi
  fi
  docker build -t "${IMAGE}" \
    --build-arg PROJECT_IMAGE="${from}" \
    --build-arg UID="${uid}" \
    --build-arg GID="${gid}" \
    ${claude_arg[@]+"${claude_arg[@]}"} \
    "$(to_docker_path "${HERE}/image/final")"
}

# The files every launch needs in the configuration directory, created when missing:
#   - .claude-history/ itself: an unprivileged bind mount source must already exist, or the daemon
#     creates it ROOT-owned. It holds a `*` .gitignore of its own, so it ignores itself in any project
#     without that project's .gitignore having to know about it.
#   - .dockerignore keeping .claude-history out of the project image's build context: it holds the
#     OAuth tokens, and one careless `COPY . ...` would bake them into an image.
ensure_config() {
  mkdir -p "${CLAUDE_HISTORY_DIR}"
  [[ -f "${CLAUDE_HISTORY_DIR}/.gitignore" ]] || printf '*\n' > "${CLAUDE_HISTORY_DIR}/.gitignore"
  if [[ ! -f "${CONFIG_DIR}/.dockerignore" ]]; then
    printf '.claude-history\n' > "${CONFIG_DIR}/.dockerignore"
  elif ! grep -qxE '/?\.claude-history/?' "${CONFIG_DIR}/.dockerignore"; then
    echo "[sandbox] WARN: ${CONFIG_DIR}/.dockerignore does not exclude .claude-history (Claude's auth tokens)" >&2
  fi
}

# Stop and remove whatever container is already holding our name, and wait until the name is actually
# free again. Reports what it did in REMOVED_EXISTING (1 = removed something, 0 = there was nothing) —
# a variable rather than an exit status, because a function called as an `if`/`||` condition runs with
# `set -e` disabled, which the docker calls in here should not.
#
# Two sandboxes of the same checkout CANNOT coexist: they share the container name, the published
# ports and — worst of all — the persisted state, including /home/dev/.claude (bind-mounted from
# CLAUDE_HISTORY_DIR), whose login/session state Claude rewrites in place. Starting a second one while
# the first is up therefore takes BOTH down. So a launch does not compete with the running sandbox, it
# replaces it: the old one is killed here, deliberately AFTER build() has finished, so the outgoing
# session stays usable for the whole rebuild and the gap between the two is only the teardown itself.
# (`attach` is the way to get a second terminal into the same sandbox.)
REMOVED_EXISTING=0
remove_existing() {
  local existing waited=0
  REMOVED_EXISTING=0
  existing="$(docker ps -aq -f "name=^${CONTAINER}$")"
  if [[ -z "${existing}" ]]; then
    return 0
  fi
  REMOVED_EXISTING=1

  echo "[sandbox] stopping the existing ${CONTAINER} container..." >&2
  # `stop` first, with the same -t 10 grace as the teardown trap below (so the outgoing Claude still gets
  # to flush ~/.claude/.claude.json cleanly), then `rm -f` for a container that was NOT started with --rm
  # and would otherwise linger in `exited` state, still owning the name.
  docker stop -t 10 "${existing}" >/dev/null 2>&1 || true
  docker rm -f "${existing}" >/dev/null 2>&1 || true

  # `--rm` removal is asynchronous in the daemon: the name can stay taken for a moment after the client
  # exits, and `docker run --name` fails outright ("name is already in use") if we race it. Poll until the
  # name really is free rather than guessing at a sleep.
  while true; do
    existing="$(docker ps -aq -f "name=^${CONTAINER}$")"
    if [[ -z "${existing}" ]]; then
      return 0
    fi
    if (( waited >= 30 )); then
      echo "Timed out waiting for the existing ${CONTAINER} container to be removed." >&2
      exit 1
    fi
    sleep 1
    waited=$(( waited + 1 ))
  done
}

# Stop the container THIS launcher started, identified by the id docker wrote to the cidfile — never by
# name. Because remove_existing hands the name from an outgoing sandbox to an incoming one, a name-based
# teardown would let a departing launcher stop the container that replaced it.
#
# The path is a GLOBAL, set by run(). An EXIT trap fires in whatever scope the shell is in when it leaves:
# on the signal paths that is still inside run() (the INT/TERM trap's `exit`), but on a normal return it is
# the top level, where a `local` of run()'s is long out of scope — under `set -u` the trap body then dies
# with "cidfile: unbound variable" before it can stop anything or clean the file up.
CIDFILE=""
stop_own() {
  local cidfile="$1" cid=""
  if [[ -z "${cidfile}" ]]; then
    return 0
  fi
  if [[ -s "${cidfile}" ]]; then
    cid="$(<"${cidfile}")"
  fi
  if [[ -n "${cid}" ]]; then
    docker stop -t 10 "${cid}" >/dev/null 2>&1 || true
  fi
  rm -f "${cidfile}"
}

run() {
  if [[ ! -d "${PROJECT_DIR}" ]]; then
    echo "Project directory not found: ${PROJECT_DIR}" >&2
    exit 1
  fi
  ensure_config

  # Always (re)build before launching so every session runs the latest image. Docker's layer
  # cache makes this a near-instant no-op when nothing in the build context has changed.
  echo "[sandbox] building ${IMAGE} before launch..." >&2
  build

  # Only now (image ready, downtime minimised) take the name off any sandbox that is already running.
  remove_existing

  # Allocate a TTY only when attached to one (so scripted `run` invocations work too).
  local tty=()
  if [[ -t 0 ]] && [[ -t 1 ]]; then tty=(-it); else tty=(-i); fi

  # Tie the container's lifetime to THIS launcher. `docker run --rm` removes the container only when it
  # *exits*; if the client is killed — IntelliJ stops the run configuration, or the terminal/console
  # is closed — the container would otherwise keep running in the daemon. So stop it whenever we leave.
  # Running `docker run` as `… & wait` (not in the foreground) is what lets the trap fire *immediately*
  # on the signal: a foreground command defers traps until it returns, by which point IntelliJ may have
  # already escalated to SIGKILL. With job control off (a script), the background-ed client stays in the
  # foreground process group, so the interactive TTY keeps working.
  #
  # BUT: in a non-interactive shell (job control off — exactly how IntelliJ's Shell Script config and
  # `bash sandbox.sh` invoke us), POSIX reassigns a background-ed command's stdin to /dev/null *unless it
  # is explicitly redirected*. Without that explicit redirect, `docker run -it … &` would see a
  # non-terminal stdin and fail with "cannot attach stdin to a TTY-enabled container". So save the real
  # stdin on fd 3 and feed it back into the background-ed client with `<&3`, which suppresses the
  # /dev/null default and keeps the PTY attached.
  # `-t 10` (not a tighter grace) gives Claude time to finish its atomic rewrite of
  # ~/.claude/.claude.json on SIGTERM before docker SIGKILL it; too short a grace
  # interrupts that rename and loses the login/onboarding state (launch.sh restores
  # it from backup as a safety net, but a clean flush is better than relying on it).
  #
  # The container is identified for teardown by the id docker writes to --cidfile (see stop_own), not by
  # name. `mktemp -u` because docker refuses to start if the cidfile already exists.
  CIDFILE="$(mktemp -u "${TMPDIR:-/tmp}/${CONTAINER}.cid.XXXXXX")"
  exec 3<&0
  trap 'stop_own "${CIDFILE}"' EXIT
  trap 'exit' INT TERM HUP

  # The mounts:
  #   - the project at /work (its configuration directory included, wherever it is inside it);
  #   - the configuration directory AGAIN at the fixed /opt/ai-sandbox/config, so the image finds its
  #     bin/ (on PATH), entrypoint.d/ and setup.d/ without knowing where the project keeps it;
  #   - the nested Docker data dir, a named volume - by far the largest (see the README's disk usage);
  #   - /home/dev/.claude, a BIND MOUNT to CLAUDE_HISTORY_DIR, a plain directory in the configuration
  #     rather than an opaque named volume: Claude's auth, transcripts and memory are visible with a
  #     normal `ls`/`cp`/`tar`, backed up by copying a directory, wiped with `rm -rf`, and inherently
  #     scoped to this one checkout;
  #   - the project's cache volumes (SANDBOX_CACHE_VOLUMES).
  # Claude derives its per-project history key from the working directory, /work, which is the same in
  # every sandbox - so `continue`/`resume` find the transcripts of earlier launches.
  docker run "${tty[@]}" --rm \
    --name "${CONTAINER}" \
    --cidfile "${CIDFILE}" \
    --privileged \
    --hostname "${NAME}" \
    -e TZ="${SANDBOX_TIMEZONE}" \
    -e SANDBOX_CACHE_PATHS="${CACHE_PATHS[*]-}" \
    -e SANDBOX_NPM_DIRS="${SANDBOX_NPM_DIRS-}" \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    -v "$(to_docker_path "${PROJECT_DIR}")":/work \
    -v "$(to_docker_path "${CONFIG_DIR}")":/opt/ai-sandbox/config \
    -v "${NAME}-docker":/var/lib/docker \
    -v "$(to_docker_path "${CLAUDE_HISTORY_DIR}")":/home/dev/.claude \
    ${CACHE_MOUNTS[@]+"${CACHE_MOUNTS[@]}"} \
    ${PUBLISH[@]+"${PUBLISH[@]}"} \
    ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} \
    "${IMAGE}" "$@" <&3 &
  wait $!
}

# A second shell in the sandbox that is ALREADY running (a launch would replace it instead). It joins
# the same container: same nested dockerd, same files, same environment (the image's ENV and the
# `docker run -e` values are the container's own, so `docker exec` inherits them).
attach() {
  if ! docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    echo "No ${CONTAINER} container is running - start one first." >&2
    exit 1
  fi
  local tty=()
  if [[ -t 0 ]] && [[ -t 1 ]]; then tty=(-it); else tty=(-i); fi
  docker exec "${tty[@]}" -u dev -w /work -e HOME=/home/dev -e USER=dev "${CONTAINER}" "${@:-bash}"
}

# Reclaim disk inside the NESTED docker daemon - the `-docker` volume, by far the largest (image layers
# and BuildKit cache from every nested build land there). The GC policy baked into the image
# (`daemon.json`) caps the build cache on its own; this is the manual, immediate version, and it also
# clears the images/containers/volumes that no policy covers.
#
# Prefers `docker exec` into a RUNNING sandbox so a live Claude session is never interrupted; only
# starts a container when none is up. Runs as root inside.
PRUNE_CMD='docker system df; docker builder prune -af --max-used-space=20GB; docker image prune -af --filter until=336h; docker container prune -f; docker volume prune -f; echo; docker system df'
prune() {
  if docker inspect "${CONTAINER}" >/dev/null 2>&1; then
    echo "[sandbox] pruning inside the running ${CONTAINER} (session untouched)..."
    docker exec -u root "${CONTAINER}" bash -c "${PRUNE_CMD}"
  else
    echo "[sandbox] no ${CONTAINER} running - starting one to prune..."
    run sudo bash -c "${PRUNE_CMD}"
  fi
}

stop() {
  # Stopping the container triggers the running launcher's --rm + trap teardown (nested dockerd and
  # everything it spun up dies with it). A no-op if nothing is there.
  remove_existing
  if (( REMOVED_EXISTING == 1 )); then
    echo "Stopped ${CONTAINER}."
  else
    echo "No ${CONTAINER} container to stop."
  fi
}

# Scaffold a project: its configuration directory from templates/configuration/, and the IntelliJ run
# configurations from templates/run/ into the project's .run/ (which IntelliJ loads on its own, no
# plugin needed). Never overwrites an existing file, so it is safe to re-run after an update to pick
# up a new template. The run configurations reference the launcher by a $PROJECT_DIR$-relative path
# only - no host path - so they can be committed.
init() {
  local rel src dest created=0
  if [[ "${HERE}" != "${PROJECT_DIR}"/* ]]; then
    echo "[sandbox] init: ${HERE} is not inside ${PROJECT_DIR} - set PROJECT_DIR" >&2
    exit 1
  fi
  rel="${HERE#"${PROJECT_DIR}"/}"

  copy_template() {  # <source> <destination> - substituting @SANDBOX_DIR@
    if [[ -e "$2" ]]; then
      echo "  exists   ${2#"${PROJECT_DIR}"/}"
      return 0
    fi
    mkdir -p "$(dirname "$2")"
    sed "s|@SANDBOX_DIR@|${rel}|g" "$1" > "$2"
    [[ -x "$1" ]] && chmod +x "$2"
    echo "  created  ${2#"${PROJECT_DIR}"/}"
    created=$((created + 1))
  }

  echo "[sandbox] initialising $(basename "${PROJECT_DIR}")..."
  while IFS= read -r src; do
    copy_template "${src}" "${CONFIG_DIR}/${src#"${HERE}/templates/configuration/"}"
  done < <(find "${HERE}/templates/configuration" -type f | LC_ALL=C sort)
  for src in "${HERE}"/templates/run/*.run.xml; do
    dest="${PROJECT_DIR}/.run/$(basename "${src}")"
    copy_template "${src}" "${dest}"
  done
  ensure_config
  echo "[sandbox] ${created} file(s) created. Next: edit ${CONFIG_DIR#"${PROJECT_DIR}"/}/sandbox.conf (and its Dockerfile, if the project needs toolchains)."
}

update_versions() {
  local dockerfiles=("${HERE}/image/base/Dockerfile")
  [[ -f "${CONFIG_DIR}/Dockerfile" ]] && dockerfiles+=("${CONFIG_DIR}/Dockerfile")
  "${HERE}/scripts/update-versions.sh" "${dockerfiles[@]}"
}

case "${1:-}" in
  build)    ensure_config; build ;;
  stop)     stop ;;
  prune)    prune ;;
  attach)   shift; attach "$@" ;;
  init)     init ;;
  update-versions) update_versions ;;
  shell)    shift; run bash ;;
  # The two ways back into an earlier Claude session. Equivalent to (and interchangeable with) the
  # long forms `run claude --dangerously-skip-permissions --continue|--resume`.
  continue) shift; run claude --dangerously-skip-permissions --continue "$@" ;;
  resume)   shift; run claude --dangerously-skip-permissions --resume "$@" ;;
  run)      shift; run "$@" ;;
  -h|--help|help) sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" ;;
  "")       run ;;            # default: interactive claude (entrypoint default)
  *)        run "$@" ;;
esac
