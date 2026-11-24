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
#   ai-sandbox/sandbox.sh paste-image      # save the host clipboard's image where the sandbox sees it, and
#                                          # put its path on the clipboard for Ctrl+V into Claude
#   ai-sandbox/sandbox.sh init             # ONCE, for a new project: create ai-sandbox-configuration/, the
#                                          # IntelliJ run configs, the org rules import in CLAUDE.md and
#                                          # .claude/settings.json
#   ai-sandbox/sandbox.sh update [X.Y.Z]   # move this submodule to the newest (or given) release tag, and
#                                          # add what that release brings (new run configs, settings)
#   ai-sandbox/sandbox.sh update-versions  # bump the version pins in the base + project Dockerfiles
#                                          # (--project-only leaves the base, and so the submodule, alone;
#                                          #  --packages-only bumps the Debian packages, not the FROM tags)
#
# A launch REPLACES any sandbox of the SAME project checkout that is already running (they cannot
# coexist — same name, same ports, same ~/.claude bind mount), stopping it only once the new image has
# been built. From a terminal it asks first: replace, attach a shell instead, or cancel (see
# confirm_replace). Every docker name is derived from the project directory's path (see SLUG below), so a
# DIFFERENT project or checkout — another IntelliJ window — shares none of that state.
#
# Only the project directory is mounted from the host. No $HOME, no SSH keys, no other projects, and
# NOT the host Docker socket. The sandbox runs its own nested Docker daemon, so any container a session
# spins up lives and dies inside this disposable container. (Of the host's settings, only a sanitised
# copy of the global git config goes in - see export_git_config.)
set -euo pipefail

# This script lives in <project>/<submodule>/, so the project root is its parent dir.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ...except in this repo's own checkout, which is its own sandbox: it is developed from a sandbox that
# runs its WORKING TREE (not a published tag - a submodule of itself would nest one copy per release
# under every consumer that clones with --recursive). It is recognised by having a configuration
# directory of its own while NOT being a submodule. The second test matters: a consumer's submodule
# holds that same committed directory, but has a superproject (or, without git on the host, a .git
# FILE rather than a directory).
self_hosted() {
  local superproject
  [[ -f "${HERE}/ai-sandbox-configuration/sandbox.conf" ]] || return 1
  if command -v git >/dev/null 2>&1 && git -C "${HERE}" rev-parse --git-dir >/dev/null 2>&1; then
    superproject="$(git -C "${HERE}" rev-parse --show-superproject-working-tree 2>/dev/null)" || superproject=""
    [[ -z "${superproject}" ]]
  else
    [[ -d "${HERE}/.git" ]]
  fi
}
SELF_HOSTED=0
# shellcheck disable=SC2310  # a test: self_hosted's status is the answer, never a failure to exit on
if [[ -z "${PROJECT_DIR:-}" ]] && self_hosted; then
  SELF_HOSTED=1
  PROJECT_DIR="${HERE}"
fi
PROJECT_DIR="${PROJECT_DIR:-$(dirname "${HERE}")}"
CONFIG_DIR="${SANDBOX_CONFIG_DIR:-${PROJECT_DIR}/ai-sandbox-configuration}"
# This repo's directory relative to the project ("." in its own checkout; empty when it is not inside the
# project, so not under /work in the sandbox): where setup.sh finds the organisation's hook guards.
REPO_DIR=""
if (( SELF_HOSTED == 1 )); then
  REPO_DIR="."
elif [[ "${HERE}" == "${PROJECT_DIR}"/* ]]; then
  REPO_DIR="${HERE#"${PROJECT_DIR}"/}"
fi

# ── The project's settings: ai-sandbox-configuration/sandbox.conf ────────────
# Plain bash, sourced. A variable already set in the ENVIRONMENT wins over the file, so a one-off
# `SANDBOX_PORTS= ai-sandbox/sandbox.sh` still works - hence saving the environment's values before
# sourcing and putting them back after. Set-but-empty counts as set (an empty SANDBOX_PORTS means
# "publish nothing", which must be able to override a file that publishes something).
#
# A SANDBOX_* name the file introduces that is not a setting is almost certainly a typo, which would
# otherwise silently do nothing, so it warns. Names already in the environment are left out of that:
# SANDBOX_CONFIG_DIR is one, and they are not the file's doing.
SETTINGS=(SANDBOX_NAME SANDBOX_PORTS SANDBOX_CACHE_VOLUMES SANDBOX_NPM_DIRS SANDBOX_ENV SANDBOX_BUILD_ARGS
          SANDBOX_RUN_ARGS SANDBOX_TZ SANDBOX_HISTORY_DAYS SANDBOX_REMOTE_CONTROL SANDBOX_PASTE_CHANNEL
          SANDBOX_IDE_CONTEXT SANDBOX_DEVICES SANDBOX_PIDS_LIMIT SANDBOX_BLOCK_LOCAL_NETWORK SANDBOX_LOCAL_NETWORK_ALLOW
          SANDBOX_PRIVILEGED SANDBOX_SUDO SANDBOX_PROTECTED_PATHS)
declare -A FROM_ENV=()
for setting in "${SETTINGS[@]}"; do
  if [[ -n "${!setting+set}" ]]; then FROM_ENV["${setting}"]="${!setting}"; fi
done
declare -A NAMES_BEFORE_CONF=()
while IFS= read -r name; do NAMES_BEFORE_CONF["${name}"]=1; done < <(compgen -v SANDBOX_ || true)
if [[ -f "${CONFIG_DIR}/sandbox.conf" ]]; then
  # shellcheck source=/dev/null # the project's own file
  source "${CONFIG_DIR}/sandbox.conf"
fi
while IFS= read -r name; do
  if [[ -z "${NAMES_BEFORE_CONF[${name}]-}" && " ${SETTINGS[*]} " != *" ${name} "* ]]; then
    echo "[sandbox] WARN: ${CONFIG_DIR}/sandbox.conf sets ${name}, which is not a sandbox setting" >&2
  fi
done < <(compgen -v SANDBOX_ || true)
for setting in "${!FROM_ENV[@]}"; do
  # unset first: the file may have made it an array, and printf -v would only replace element 0.
  unset "${setting}"
  printf -v "${setting}" '%s' "${FROM_ENV[${setting}]}"
done

# A setting's words, into the named array. A string splits on spaces; a bash array (which the file may
# use, being bash) is taken as it is, which is how a value comes to hold a space.
# shellcheck disable=SC2034  # `words` is a nameref: assigning it fills the caller's array
setting_words() {
  local -n words="$1"
  local setting="$2" declaration
  declaration="$(declare -p "${setting}" 2>/dev/null || true)"
  if [[ "${declaration}" == "declare -a"* ]]; then
    local -n values="${setting}"
    words=(${values[@]+"${values[@]}"})
  else
    read -ra words <<< "${!setting-}"
  fi
}

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
# Claude's temporary directory (CLAUDE_CODE_TMPDIR), bind-mounted from here: see mirrored_path.
CLAUDE_TMP_DIR="${CLAUDE_HISTORY_DIR}/.sandbox-state/tmp"

# Ports published to the HOST, space-separated `host:container` pairs - the one resource two sandboxes
# can still collide on (two cannot both hold the same host port). Unlike the names it fails LOUDLY
# ("port is already allocated"), so it is a setting rather than a derivation. Default: nothing.
# Published on the host's LOOPBACK unless the entry names an address: Docker's own default is every
# interface, which put a session's dev server (and whatever it serves - the project, a debug endpoint)
# on the LAN. `host:container` → 127.0.0.1:host:container, a bare `container` → 127.0.0.1::container
# (a random host port); an entry with an address of its own (`0.0.0.0:8071:8081`, `[::1]:8071:8081`)
# is passed as it is - that is how to publish to the LAN on purpose.
read -ra PUBLISH_PORTS <<< "${SANDBOX_PORTS-}"
PUBLISH=()
for port in ${PUBLISH_PORTS+"${PUBLISH_PORTS[@]}"}; do
  colons="${port//[^:]/}"
  if [[ "${port}" == \[* ]]; then PUBLISH+=(-p "${port}")
  elif [[ "${#colons}" -eq 0 ]]; then PUBLISH+=(-p "127.0.0.1::${port}")
  elif [[ "${#colons}" -eq 1 ]]; then PUBLISH+=(-p "127.0.0.1:${port}")
  else PUBLISH+=(-p "${port}")
  fi
done

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

# Extra environment for the sandbox, KEY=VALUE pairs (an array in sandbox.conf for a value with spaces),
# and extra `docker run` flags (e.g. "--device /dev/kvm"), passed through as-is.
EXTRA_ENV=()
setting_words EXTRA_ENV SANDBOX_ENV
ENV_ARGS=()
for pair in ${EXTRA_ENV+"${EXTRA_ENV[@]}"}; do ENV_ARGS+=(-e "${pair}"); done
read -ra RUN_ARGS <<< "${SANDBOX_RUN_ARGS-}"

# Build args for the project's Dockerfile, KEY=VALUE pairs in the same form. Its build context stops at
# the configuration directory, so this is how the image learns anything from the rest of the project:
# sandbox.conf is bash, so it can read a version out of a lockfile. Not passed to the base or final
# layers, which the project does not own.
EXTRA_BUILD_ARGS=()
setting_words EXTRA_BUILD_ARGS SANDBOX_BUILD_ARGS
BUILD_ARGS=()
for pair in ${EXTRA_BUILD_ARGS+"${EXTRA_BUILD_ARGS[@]}"}; do BUILD_ARGS+=(--build-arg "${pair}"); done

# Whether Claude starts its Remote Control bridge with each session (launch.sh). On by default.
SANDBOX_REMOTE_CONTROL="${SANDBOX_REMOTE_CONTROL:-true}"
if [[ "${SANDBOX_REMOTE_CONTROL}" != "true" && "${SANDBOX_REMOTE_CONTROL}" != "false" ]]; then
  echo "[sandbox] SANDBOX_REMOTE_CONTROL must be true or false, not '${SANDBOX_REMOTE_CONTROL}'" >&2
  exit 1
fi

# ── Isolation from the host ──────────────────────────────────────────────────
# The nested dockerd used to get it all with --privileged: every capability, AppArmor and seccomp off,
# AND every host device - the raw disks among them, so root in the sandbox could mount the host's
# filesystem whatever was or wasn't bind-mounted, load kernel modules, or write the host's clock. It
# needs much less: CAP_SYS_ADMIN (mounts: overlayfs, its containers' /proc) and CAP_NET_ADMIN (their
# networks), CAP_SYS_PTRACE (a container whose user is not root: the daemon, root but a different uid,
# may open that process's /proc/<pid>/ns/net only with it - without, every `docker run --user` or image
# with a USER failed with "bind-mount /proc/<pid>/ns/net ...: permission denied"), seccomp and AppArmor
# off (Docker's default profiles refuse those mounts, and runc's own setup), and a cgroup namespace of
# its own, so /sys/fs/cgroup is this container's subtree, which entrypoint.sh makes writable along with /proc/sys/net (and nothing else in /proc/sys). That leaves
# out every device but the default few, and CAP_SYS_MODULE, CAP_SYS_RAWIO, CAP_SYS_TIME, CAP_SYS_BOOT
# and the rest of --privileged's extras.
#
# It is still NOT a boundary against hostile code: CAP_SYS_ADMIN without a user namespace leaves root in
# the sandbox ways out (and `dev` has sudo, and the nested daemon's socket). See the README.
# SANDBOX_PRIVILEGED=true brings --privileged back, for a project whose tooling needs what this leaves
# out (a device of every kind, a kernel module): a deliberate, visible choice.
SANDBOX_PRIVILEGED="${SANDBOX_PRIVILEGED:-false}"
if [[ "${SANDBOX_PRIVILEGED}" != "true" && "${SANDBOX_PRIVILEGED}" != "false" ]]; then
  echo "[sandbox] SANDBOX_PRIVILEGED must be true or false, not '${SANDBOX_PRIVILEGED}'" >&2
  exit 1
fi
if [[ "${SANDBOX_PRIVILEGED}" == "true" ]]; then
  ISOLATION_ARGS=(--privileged)
else
  ISOLATION_ARGS=(--cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add SYS_PTRACE
                  --security-opt seccomp=unconfined --security-opt apparmor=unconfined --cgroupns private)
fi

# Host devices handed in, space-separated paths ("/dev/kvm" for an Android emulator) - --privileged used to
# hand in every one. A path the host does not have is skipped with a warning rather than failing the
# launch (docker refuses a missing --device), so a configuration that names /dev/kvm still opens on a
# host without KVM (a Mac); only the tool that needs it then fails. Ignored with SANDBOX_PRIVILEGED.
read -ra DEVICES <<< "${SANDBOX_DEVICES-}"
DEVICE_ARGS=()
DEVICE_PATHS=()  # the ones passed in, for entrypoint.sh to open to `dev` (who has no sudo to chmod them)
for device in ${DEVICES+"${DEVICES[@]}"}; do
  if [[ "${device}" != /dev/* ]]; then
    echo "[sandbox] SANDBOX_DEVICES entry '${device}' is not a /dev path" >&2
    exit 1
  elif [[ -e "${device}" ]]; then
    DEVICE_ARGS+=(--device "${device}")
    DEVICE_PATHS+=("${device}")
  else
    echo "[sandbox] WARN: SANDBOX_DEVICES names ${device}, which this host does not have - not passed in" >&2
  fi
done

# The most processes (threads included) the sandbox may run at once, nested containers included: a fork
# bomb or a runaway test otherwise exhausts the HOST's process table. High enough for a Gradle daemon,
# an emulator and a stack of nested containers; `unlimited` turns it off. (Memory and CPU stay
# unlimited by default, as an emulator or a big build needs them: `--memory 16g` in SANDBOX_RUN_ARGS.)
# Whether `dev` gets passwordless sudo (entrypoint.sh writes the rule at start). Off by default: a
# session with sudo can undo the firewall and the read-only mounts below as root. A tool missing from the
# image belongs in the project's Dockerfile (pinned), not in a `sudo apt-get install` that the next
# launch forgets anyway.
SANDBOX_SUDO="${SANDBOX_SUDO:-false}"
if [[ "${SANDBOX_SUDO}" != "true" && "${SANDBOX_SUDO}" != "false" ]]; then
  echo "[sandbox] SANDBOX_SUDO must be true or false, not '${SANDBOX_SUDO}'" >&2
  exit 1
fi

# ── Files the HOST runs, read-only in the sandbox ────────────────────────────
# The project is mounted read-write, and some of it is not just data: the host RUNS it, outside any
# sandbox. ai-sandbox/sandbox.sh and sandbox.conf (sourced by the host's bash: one SANDBOX_RUN_ARGS edit
# mounts the host's /) at the next launch; .git/hooks in the host's git; .claude/settings*.json and the
# hooks they name in the host's Claude; .run/ and .idea/ in IntelliJ; .vscode/ tasks; .envrc in direnv.
# A prompt-injected session that edits one has a way out of the sandbox without breaking anything. So
# each of those that exists is mounted READ-ONLY over itself (at /work and at the host path), and one
# that doesn't exist yet is reported at teardown if the session created it (report_created_host_files).
#
# .git/config is NOT on the list, though its core.fsmonitor, core.pager and filters run programs in the
# host's git (IntelliJ's own `git status` within seconds): read-only, it broke ordinary git work in the
# sandbox - `git submodule init`, `git branch -u`, `git remote add`, `git config --local`. Instead the keys
# that make git run something are compared at teardown, and any the session added or changed is reported
# (report_risky_git_config).
#
# SANDBOX_PROTECTED_PATHS, paths relative to the project, replaces the list (empty protects nothing).
# The submodule is left out when this repo runs its own working tree (self_hosted), where it is the
# whole project; ai-sandbox's own sandbox.conf lists what it protects.
#
# A guard, not a boundary (root in the sandbox can unmount them: see SANDBOX_SUDO); and it covers the
# host's TOOLS, not what a person may later run by hand (a build script, a test) - review those as before.
default_protected_paths() {
  local rel="${HERE#"${PROJECT_DIR}"/}" config_rel="${CONFIG_DIR#"${PROJECT_DIR}"/}" path
  [[ "${HERE}" == "${PROJECT_DIR}" || "${rel}" == /* ]] || printf '%s\n' "${rel}"
  [[ "${config_rel}" == /* ]] || printf '%s\n' "${config_rel}/sandbox.conf"
  printf '%s\n' .git/hooks .claude/settings.json .claude/settings.local.json .claude/hooks \
    .idea .run .vscode .envrc
  # Each submodule's own hooks (.git/modules/<name>/hooks, nested ones below that).
  if [[ -d "${PROJECT_DIR}/.git/modules" ]]; then
    find "${PROJECT_DIR}/.git/modules" -maxdepth 6 -name hooks -type d -prune -print \
      2>/dev/null | while IFS= read -r path; do printf '%s\n' "${path#"${PROJECT_DIR}"/}"; done
  fi
}
if [[ -n "${SANDBOX_PROTECTED_PATHS+set}" ]]; then
  read -ra PROTECTED_PATHS <<< "${SANDBOX_PROTECTED_PATHS}"
else
  PROTECTED_PATHS=()
  defaults="$(default_protected_paths)"
  [[ -z "${defaults}" ]] || mapfile -t PROTECTED_PATHS <<< "${defaults}"
fi
for path in ${PROTECTED_PATHS+"${PROTECTED_PATHS[@]}"}; do
  if [[ "${path}" == /* || "/${path}/" == */../* || -z "${path}" ]]; then
    echo "[sandbox] SANDBOX_PROTECTED_PATHS entry '${path}' must be a path inside the project, relative to it" >&2
    exit 1
  fi
done

SANDBOX_PIDS_LIMIT="${SANDBOX_PIDS_LIMIT:-32768}"
if [[ "${SANDBOX_PIDS_LIMIT}" == "unlimited" ]]; then
  PIDS_ARGS=()
elif [[ "${SANDBOX_PIDS_LIMIT}" =~ ^[1-9][0-9]*$ ]]; then
  PIDS_ARGS=(--pids-limit "${SANDBOX_PIDS_LIMIT}")
else
  echo "[sandbox] SANDBOX_PIDS_LIMIT must be a whole number or 'unlimited', not '${SANDBOX_PIDS_LIMIT}'" >&2
  exit 1
fi

# Whether the sandbox is kept off the host's local network: the LAN, the host itself and link-local
# addresses (entrypoint.sh's block_local_network has the details). On by default; addresses or CIDRs in
# SANDBOX_LOCAL_NETWORK_ALLOW stay reachable. Checked here so a typo fails the launch rather than the
# rules.
SANDBOX_BLOCK_LOCAL_NETWORK="${SANDBOX_BLOCK_LOCAL_NETWORK:-true}"
if [[ "${SANDBOX_BLOCK_LOCAL_NETWORK}" != "true" && "${SANDBOX_BLOCK_LOCAL_NETWORK}" != "false" ]]; then
  echo "[sandbox] SANDBOX_BLOCK_LOCAL_NETWORK must be true or false, not '${SANDBOX_BLOCK_LOCAL_NETWORK}'" >&2
  exit 1
fi
# The host's network namespace is refused outright. With it (and CAP_NET_ADMIN), the nested dockerd
# configures the HOST's networking as its own: on 2026-11-22 a test launch re-addressed the host's docker0
# to the nested daemon's default 172.17.0.1/16 and rewrote its NAT rule, cutting every container on the
# host's default bridge - another project's live sandbox among them - off the network. The block above
# would be the host's firewall, too. Publish ports (SANDBOX_PORTS) instead.
if [[ " ${RUN_ARGS[*]-} " =~ [[:space:]]--net(work)?(=|[[:space:]]+)host[[:space:]] ]]; then
  echo "[sandbox] SANDBOX_RUN_ARGS must not use the host's network (--network host): the nested Docker" \
       "daemon would reconfigure the host's own Docker networking. Publish ports with SANDBOX_PORTS instead." >&2
  exit 1
fi
read -ra LOCAL_NETWORK_ALLOW <<< "${SANDBOX_LOCAL_NETWORK_ALLOW-}"
for address in ${LOCAL_NETWORK_ALLOW+"${LOCAL_NETWORK_ALLOW[@]}"}; do
  if [[ ! "${address}" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}|[0-9a-fA-F:]*:[0-9a-fA-F:.]*)(/[0-9]{1,3})?$ ]]; then
    echo "[sandbox] SANDBOX_LOCAL_NETWORK_ALLOW entry '${address}' is not an IP address or CIDR" >&2
    exit 1
  fi
done

# Whether Claude loads the paste-image channel (launch.sh), which hands it each image `paste-image` saves
# without a Ctrl+V. On by default.
SANDBOX_PASTE_CHANNEL="${SANDBOX_PASTE_CHANNEL:-true}"
if [[ "${SANDBOX_PASTE_CHANNEL}" != "true" && "${SANDBOX_PASTE_CHANNEL}" != "false" ]]; then
  echo "[sandbox] SANDBOX_PASTE_CHANNEL must be true or false, not '${SANDBOX_PASTE_CHANNEL}'" >&2
  exit 1
fi

# Whether the open file and selection in the host's IDE reach the Claude in the sandbox (start_ide_relay).
SANDBOX_IDE_CONTEXT="${SANDBOX_IDE_CONTEXT:-true}"
if [[ "${SANDBOX_IDE_CONTEXT}" != "true" && "${SANDBOX_IDE_CONTEXT}" != "false" ]]; then
  echo "[sandbox] SANDBOX_IDE_CONTEXT must be true or false, not '${SANDBOX_IDE_CONTEXT}'" >&2
  exit 1
fi

# How many days of Claude session history (transcripts and their file-history / tool-result side-cars)
# to keep in .claude-history: launch.sh sets it as Claude's `cleanupPeriodDays`, and Claude deletes
# anything older at startup. Memory and settings are not session data and are always kept. Checked
# here, on the host, so a typo fails the launch loudly rather than silently keeping the default.
SANDBOX_HISTORY_DAYS="${SANDBOX_HISTORY_DAYS:-14}"
if [[ ! "${SANDBOX_HISTORY_DAYS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "[sandbox] SANDBOX_HISTORY_DAYS must be a whole number of days (1 or more), not '${SANDBOX_HISTORY_DAYS}'" >&2
  exit 1
fi

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

# Host paths that are valid in the sandbox too. The sandbox sees the project at /work, but the host
# knows it by its own path: dragging a file from IntelliJ into the terminal, *Copy Absolute Path* and a
# host build's stack trace all give /home/.../<project>/... So the project is mounted a second time, at
# its host path (the same directory, not a copy), and those paths open in the sandbox as well.
#
# Claude runs THERE too (SANDBOX_WORKDIR), not in /work, so the file paths it prints are host paths: in
# IntelliJ's terminal each is a link (see TERMINAL_ENV), and a link to /work/... opens nothing on the
# host. /work stays mounted for everything else (setup.sh, the projects' entrypoint.d hooks, paths in
# older transcripts). Claude keys its sessions by its working directory, so launch.sh links the new key
# to the sessions every earlier launch kept under /work's (see link_project_state there).
#
# Claude's temporary directory is mirrored the same way. It holds the session scratchpads, where Claude
# saves the screenshots and other files it shows you, printed as `[image] <path>`. In a terminal Claude
# knows can follow links (IntelliJ's: see TERMINAL_ENV) that path is a link the IDE opens in its image
# viewer. In the container's own /tmp the file would be gone with the container, and its path would
# not exist on the host. So the directory is CLAUDE_TMP_DIR, in the checkout, mounted at its host path:
# the path Claude prints is then the file's path on the host as well.
#
# A path can't be mirrored when it is not a Linux path (Windows: C:\...), contains a character `-v` or
# `-e` would misread (a colon), or would land on the container's own directories (/work, dev's home,
# /usr, ...). Then the project is only at /work, where Claude runs as before, and the temporary
# directory at the image's fixed default, /opt/ai-sandbox/tmp: still files on the host, just not a
# path the host can open.
mirrored_path() {  # <host path, absolute>: prints it, or fails when it can't be used in the container
  local path="$1"
  if command -v cygpath &>/dev/null || [[ "${path}" != /* || "${path}" == *:* ]]; then
    return 1
  fi
  case "${path}" in
    / | /work | /work/* | /home | /home/dev | /home/dev/* | /opt/ai-sandbox | /opt/ai-sandbox/* | /bin/* \
      | /boot/* | /dev/* | /etc/* | /lib/* | /lib64/* | /proc/* | /root/* | /run/* | /sbin/* | /sys/* \
      | /usr/* | /var/lib/docker/* | /var/log/*)
      return 1
      ;;
    *) printf '%s\n' "${path}" ;;
  esac
}
CLAUDE_TMP_DEFAULT=/opt/ai-sandbox/tmp

# What Claude reads to tell which terminal it is in, passed through from the host's: docker sets only
# TERM. Without them Claude takes IntelliJ's terminal for an unknown one, so it doesn't link the file
# paths it prints (see mirrored_path), and it falls back on generic behaviour for anything else it
# looks up by terminal. TERM itself is left as docker sets it: the host's could name a terminfo entry
# the image doesn't have. An unset one is passed as empty, which Claude reads the same way; `attach`
# passes them again, so a second shell from another terminal is not taken for the first.
TERMINAL_ENV=()
for var in TERMINAL_EMULATOR TERM_PROGRAM TERM_PROGRAM_VERSION COLORTERM; do
  TERMINAL_ENV+=(-e "${var}=${!var-}")
done

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

# What the image is built from, as one checksum: the base's tag (itself a hash of image/base), the
# project's configuration directory (its Dockerfile's build context, less .claude-history), its build args,
# image/final, the Claude Code version and the UID/GID. The final image carries it as a label, so a launch
# whose inputs are all unchanged skips `docker build` - three builds' worth of cache checks and their
# output, most of a no-change relaunch's time. What the build cache would not notice either (a moved
# `FROM` tag upstream, an unpinned download) is not noticed here; `sandbox.sh build` always builds.
BUILD_KEY_LABEL='net.zodac.sandbox.build-key'
tree_hash() {  # <directory> [<path inside it to leave out>]
  local dir="$1" skip="${2:-}"
  (cd "${dir}" && find . \( -path "./${skip:-/}" -prune \) -o -type f -print | LC_ALL=C sort \
     | while IFS= read -r file; do printf '%s\n' "${file}"; cat "${file}"; done) | cksum | cut -d' ' -f1
}
build_key() {  # <Claude Code version>
  local history_rel="${CLAUDE_HISTORY_DIR#"${CONFIG_DIR}"/}" base final uid gid inputs
  base="$(base_image)"
  final="$(tree_hash "${HERE}/image/final")"
  uid="$(id -u)"
  gid="$(id -g)"
  inputs="base ${base}"$'\n'"final ${final}"$'\n'"claude $1"$'\n'"uid ${uid}"$'\n'"gid ${gid}"
  if [[ -f "${CONFIG_DIR}/Dockerfile" ]]; then
    inputs+=$'\n'"project $(tree_hash "${CONFIG_DIR}" "${history_rel}")"$'\n'"args ${BUILD_ARGS[*]-}"
  fi
  printf '%s\n' "${inputs}" | cksum | cut -d' ' -f1
}

build() {  # [--if-changed]: skip the build when the image's inputs are unchanged (a launch)
  local uid gid base from claude_arg=() baked context version key
  uid="$(id -u)"
  gid="$(id -g)"
  base="$(base_image)"

  # The Claude Code version to bake in: the newest release, or (offline) the one the image has.
  resolve_claude_version
  baked="$(docker image inspect -f "{{ index .Config.Labels \"${CLAUDE_VERSION_LABEL}\" }}" "${IMAGE}" 2>/dev/null || true)"
  [[ "${baked}" != "<no value>" ]] || baked=""
  version="${CLAUDE_VERSION:-${baked}}"
  key="$(build_key "${version}")"
  if [[ "${1:-}" == "--if-changed" ]] \
     && [[ "$(docker image inspect -f "{{ index .Config.Labels \"${BUILD_KEY_LABEL}\" }}" "${IMAGE}" 2>/dev/null || true)" == "${key}" ]]; then
    echo "[sandbox] image ${IMAGE} is up to date (Claude Code ${version:-unknown})" >&2
    return 0
  fi
  [[ "${1:-}" != "--if-changed" ]] || echo "[sandbox] building ${IMAGE} before launch..." >&2

  # 1. The shared base.
  if docker image inspect "${base}" >/dev/null 2>&1; then
    echo "[sandbox] base image ${base} is up to date" >&2
  else
    echo "[sandbox] building base image ${base}..." >&2
    context="$(to_docker_path "${HERE}/image/base")"
    docker build -t "${base}" \
      --build-arg UID="${uid}" \
      --build-arg GID="${gid}" \
      "${context}"
  fi

  # 2. The project's toolchains, if it has a Dockerfile. Its build context is the configuration
  #    directory, so it can COPY its own files - and must not send .claude-history (auth tokens!)
  #    along, which ensure_config's .dockerignore prevents.
  from="${base}"
  if [[ -f "${CONFIG_DIR}/Dockerfile" ]]; then
    echo "[sandbox] building project image ${PROJECT_IMAGE}..." >&2
    context="$(to_docker_path "${CONFIG_DIR}")"
    docker build -t "${PROJECT_IMAGE}" \
      --build-arg BASE_IMAGE="${base}" \
      ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} \
      "${context}"
    from="${PROJECT_IMAGE}"
  fi

  # 3. Claude Code + the sandbox scripts.
  if [[ -n "${CLAUDE_VERSION}" ]]; then
    echo "[sandbox] baking Claude Code ${CLAUDE_VERSION} into the image" >&2
    claude_arg=(--build-arg CLAUDE_CODE_VERSION="${CLAUDE_VERSION}")
  else
    if [[ -n "${baked}" ]]; then
      echo "[sandbox] WARN: could not reach the npm registry - keeping the image's Claude Code ${baked}" >&2
      claude_arg=(--build-arg CLAUDE_CODE_VERSION="${baked}")
    else
      echo "[sandbox] WARN: could not reach the npm registry, and the image records no Claude Code version" >&2
    fi
  fi
  context="$(to_docker_path "${HERE}/image/final")"
  docker build -t "${IMAGE}" \
    --build-arg PROJECT_IMAGE="${from}" \
    --build-arg UID="${uid}" \
    --build-arg GID="${gid}" \
    ${claude_arg[@]+"${claude_arg[@]}"} \
    --label "${BUILD_KEY_LABEL}=${key}" \
    "${context}"
}

# The files every launch needs in the configuration directory, created when missing:
#   - .claude-history/ itself: an unprivileged bind mount source must already exist, or the daemon
#     creates it ROOT-owned. It holds a `*` .gitignore of its own, so it ignores itself in any project
#     without that project's .gitignore having to know about it;
#   - its .sandbox-state/tmp, Claude's temporary directory (see mirrored_path), for the same reason;
#   - .dockerignore keeping .claude-history out of the project image's build context: it holds the
#     OAuth tokens, and one careless `COPY . ...` would bake them into an image.
ensure_config() {
  mkdir -p "${CLAUDE_HISTORY_DIR}"
  # Private to the host user: it holds Claude's OAuth tokens and every transcript (and nothing in it is
  # anyone else's to read). Re-applied each launch, as it was created group-writable before 1.3.0.
  chmod 700 "${CLAUDE_HISTORY_DIR}"
  # Private, as Claude insists of its temporary directory (it refuses one another user owns).
  mkdir -p "${CLAUDE_TMP_DIR}" && chmod 700 "${CLAUDE_TMP_DIR}"
  [[ -f "${CLAUDE_HISTORY_DIR}/.gitignore" ]] || printf '*\n' > "${CLAUDE_HISTORY_DIR}/.gitignore"
  if [[ ! -f "${CONFIG_DIR}/.dockerignore" ]]; then
    printf '.claude-history\n' > "${CONFIG_DIR}/.dockerignore"
  elif ! grep -qxE '/?\.claude-history/?' "${CONFIG_DIR}/.dockerignore"; then
    echo "[sandbox] WARN: ${CONFIG_DIR}/.dockerignore does not exclude .claude-history (Claude's auth tokens)" >&2
  fi
}

# Hand the host's global git settings (identity, aliases, push/pull preferences, global ignores) to the
# sandbox, so they need no configuring in there. A sanitised COPY rather than a mount of ~/.gitconfig:
#   - it keeps the "no $HOME" rule, and needs no new mount - .sandbox-state is already in the bind-mounted
#     .claude-history, so this works unchanged on every host (launch.sh installs the copy at start);
#   - a single-file mount would break `git config --global` inside (git replaces the file by rename);
#   - plenty of a host's config is secret, or names something that does not exist in here, and some of
#     that would break git rather than merely go unused (see the case below).
# Rewritten on every launch, so an edit on the host is picked up and a removed setting does not linger.
# `--includes` inlines included files, and running in the project applies an includeIf "gitdir:..." the
# way the host would (a work identity for a work checkout). The project's own .git/config still wins.
export_git_config() {
  local state="${CLAUDE_HISTORY_DIR}/.sandbox-state" entry key value excludes=""
  mkdir -p "${state}"
  rm -f "${state}/host-gitconfig" "${state}/host-gitignore"
  command -v git >/dev/null 2>&1 || return 0

  # --null: entries end in NUL, the key ends at the first newline, and no newline at all means a
  # valueless key (git's shorthand for true). Multi-valued keys arrive in order, hence --add.
  while IFS= read -r -d '' entry; do
    key="${entry%%$'\n'*}"
    if [[ "${entry}" == *$'\n'* ]]; then value="${entry#*$'\n'}"; else value=true; fi
    case "${key,,}" in
      # Secrets, or the way to reach them. The sandbox ships no credentials (see the README's Notes), and
      # a url.*.insteadOf would rewrite HTTPS remotes to SSH, which the image has no client for.
      credential.*|http.*|url.*|sendemail.*|*token*|*passw*|*secret*) continue ;;
      # Signing: the key is not in here, so every commit would fail.
      gpg.*|user.signingkey|commit.gpgsign|tag.gpgsign|tag.forcesignannotated|push.gpgsign) continue ;;
      # Host programs. A required filter (git-lfs's, by default) fails every checkout without its binary.
      filter.*|core.sshcommand|core.askpass|core.fsmonitor|core.pager|interactive.difffilter) continue ;;
      # Host paths, and include directives whose content --includes has already inlined. The excludes
      # file is copied separately below.
      include.*|includeif.*|safe.*|core.hookspath|core.excludesfile|core.attributesfile|init.templatedir) continue ;;
      # Everything else is plain behaviour (aliases, diff/merge styles, user.name, ...), copied as it is.
      *) ;;
    esac
    git config --file "${state}/host-gitconfig" --add -- "${key}" "${value}" \
      || echo "[sandbox] WARN: could not copy the git setting ${key} to the sandbox" >&2
  done < <(git -C "${PROJECT_DIR}" config --global --includes --null --list 2>/dev/null || true)

  # The global ignore file, which the copy above deliberately does not point at: installed at git's
  # default location, it applies without any setting.
  excludes="$(git -C "${PROJECT_DIR}" config --global --includes --path core.excludesFile 2>/dev/null || true)"
  excludes="${excludes:-${XDG_CONFIG_HOME:-${HOME}/.config}/git/ignore}"
  if [[ -r "${excludes}" ]]; then
    cp "${excludes}" "${state}/host-gitignore" \
      || echo "[sandbox] WARN: could not copy the global git ignore file to the sandbox" >&2
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
# A launch replaces this checkout's running sandbox (remove_existing), ending any session in it - which,
# unasked, has cost a live session (2026-11-14). So where someone can answer (a terminal: IntelliJ's run
# configurations run in one), ask: replace it, open a shell in it instead (attach), or cancel - the
# default, so a stray Enter loses nothing. A launch with no terminal (a script) replaces it as before, and
# so does SANDBOX_REPLACE=true.
confirm_replace() {
  local answer status running
  running="$(docker ps -q -f "name=^${CONTAINER}$" 2>/dev/null)" || running=""
  [[ -n "${running}" ]] || return 0
  if [[ "${SANDBOX_REPLACE:-}" == "true" ]] || ! [[ -t 0 && -t 1 ]]; then
    return 0
  fi
  echo "[sandbox] ${CONTAINER} is already running: a new launch replaces it, ending the session in it." >&2
  while true; do
    read -r -p "[sandbox] [r]eplace it, [a]ttach a shell to it, or [c]ancel? [c] " answer || answer=c
    case "${answer,,}" in
      r|replace) return 0 ;;
      a|attach)
        status=0
        # shellcheck disable=SC2310  # its status is passed on as this launch's
        attach || status=$?
        exit "${status}" ;;
      ""|c|cancel)
        echo "[sandbox] cancelled - the running sandbox is untouched" >&2
        exit 0 ;;
      *) echo "[sandbox] answer r, a or c" >&2 ;;
    esac
  done
}

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

# Delete every *.run.xml under Claude's temporary directory. That directory is inside the project
# (CLAUDE_TMP_DIR), and IntelliJ loads a `*.run.xml` from ANYWHERE in the project tree: a scratch project an
# agent made there to test `init`/`update` carries `.run/Claude Sandbox*.run.xml` files with the real
# configs' names, pointing at `$PROJECT_DIR$/ai-sandbox/sandbox.sh` relative to the PROJECT, not to the
# scratch dir. After an IDE restart those shadow the real configs, and every launch fails with "Shell script
# not found" (it happened here on 2026-11-22). A cleanup on launch would come too late, since the broken
# configs are the ones that won't launch, so it runs at shutdown: from the launcher's teardown (tab or IDE
# closed, Stop) and from `stop`. Only these files are touched, never the rest of a scratchpad.
remove_scratch_run_configs() {
  local count
  if [[ ! -d "${CLAUDE_TMP_DIR}" ]]; then
    return 0
  fi
  count="$(find "${CLAUDE_TMP_DIR}" -name '*.run.xml' -type f -print -delete 2>/dev/null | wc -l)" || true
  if (( count > 0 )); then
    echo "[sandbox] removed ${count} IntelliJ run configuration(s) left in Claude's temp dir" >&2
  fi
}

stop_own() {
  local cidfile="$1" cid=""
  # First, before the (up to 10s) `docker stop`: IntelliJ may SIGKILL the launcher during that grace.
  stop_ide_relay
  remove_scratch_run_configs
  report_created_host_files
  report_risky_git_config
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

# The protected paths (above) that did not exist at launch, so could not be mounted read-only: any of
# them the session created is reported at teardown, as it runs on the host as much as an edited one would.
# Best effort - a launcher SIGKILLed before its trap runs reports nothing.
UNPROTECTED_MISSING=()
report_created_host_files() {
  local path created=()
  for path in ${UNPROTECTED_MISSING+"${UNPROTECTED_MISSING[@]}"}; do
    [[ -e "${PROJECT_DIR}/${path}" || -L "${PROJECT_DIR}/${path}" ]] && created+=("${path}")
  done
  UNPROTECTED_MISSING=()
  [[ "${#created[@]}" -gt 0 ]] || return 0
  echo "[sandbox] WARN: the sandbox CREATED files that tools on the host run or load - review them before" \
       "you use git, IntelliJ or Claude on the host: ${created[*]}" >&2
}

# The git settings that make the HOST's git run a program, or read settings from another file: the
# project's .git/config and every submodule's (.git/modules/**/config), which stay writable in the sandbox
# (see SANDBOX_PROTECTED_PATHS). run() records them at launch, and teardown reports each one the session
# added or changed, before IntelliJ's next `git status` runs it. Keys are matched as `git config --list`
# prints them: section and name lower-cased, a subsection as written.
RISKY_GIT_KEYS='^(core\.(hookspath|fsmonitor|sshcommand|pager|editor|askpass|gitproxy|worktree|alternaterefscommand)'
RISKY_GIT_KEYS+='|sequence\.editor|include\.path|includeif\..*\.path|alias\..*|pager\..*|interactive\.difffilter'
RISKY_GIT_KEYS+='|filter\..*\.(clean|smudge|process)|diff\.external|diff\..*\.(textconv|command)|merge\..*\.driver'
RISKY_GIT_KEYS+='|credential\.(.*\.)?helper|gpg\.(.*\.)?program|submodule\..*\.update|uploadpack\..*|protocol\..*'
RISKY_GIT_KEYS+='|remote\..*\.(uploadpack|receivepack|proxy)|http\.(.*\.)?proxy|ssh\.variant)='
risky_git_config() {
  local file
  command -v git >/dev/null 2>&1 || return 0
  {
    if [[ -f "${PROJECT_DIR}/.git/config" ]]; then printf '%s\n' "${PROJECT_DIR}/.git/config"; fi
    if [[ -d "${PROJECT_DIR}/.git/modules" ]]; then
      find "${PROJECT_DIR}/.git/modules" -maxdepth 6 -name config -type f 2>/dev/null || true
    fi
  } | LC_ALL=C sort | while IFS= read -r file; do
    git config --file "${file}" --list 2>/dev/null | grep -E "${RISKY_GIT_KEYS}" \
      | sed "s|^|${file#"${PROJECT_DIR}"/}: |" || true
  done
}
RISKY_GIT_BEFORE=""
RISKY_GIT_RECORDED=0
report_risky_git_config() {
  local after added
  [[ "${RISKY_GIT_RECORDED}" -eq 1 ]] || return 0
  RISKY_GIT_RECORDED=0
  # shellcheck disable=SC2310  # best effort: no reading is no report
  after="$(risky_git_config)" || after=""
  # The lines in `after` that `before` doesn't have (both are sorted by risky_git_config's own order).
  added="$(grep -vxF -f <(printf '%s\n' "${RISKY_GIT_BEFORE}") <<< "${after}" | grep -v '^$')" || added=""
  [[ -n "${added}" ]] || return 0
  echo "[sandbox] WARN: the sandbox ADDED or CHANGED git settings that make git on the host run a program." \
       "Review them (git config --file <file> --unset <key> removes one) before you use git or IntelliJ" \
       "on the host:" >&2
  printf '%s\n' "${added}" | sed 's/^/[sandbox]     /' >&2
}

# The IDE's context in the sandbox (SANDBOX_IDE_CONTEXT): the file open in the host's IDE and the lines
# selected in it, which the IDE's Claude Code plugin sends to a Claude on the host. The plugin's websocket
# is on the host's loopback, behind a token, and anything that can use it can also call the IDE, so the
# sandbox gets neither: host/ide-relay.py, on the host, listens to the plugin and writes the latest
# selection of a file in the PROJECT into a directory of its own, mounted read-only, and
# image/final/ide-bridge.mjs, in the sandbox, stands in for the plugin there (launch.sh starts it). A
# directory outside the checkout, so there is nothing for the sandbox to plant a symlink in for the relay to
# write through, and no selection is kept after the session.
#
# Only when an IDE that has the plugin has this project open at launch (and the host has python3);
# otherwise the sandbox is as it was. The relay follows an IDE that restarts. A fixed port: it is in the
# container's own network namespace, and as the container's environment an `attach`ed shell gets it too.
IDE_PORT=27483
IDE_ARGS=()
IDE_RELAY_PID=""
start_ide_relay() {  # <the project's path in the sandbox>
  local ide state
  IDE_ARGS=()
  [[ "${SANDBOX_IDE_CONTEXT}" == "true" ]] || return 0
  # Not on Windows: the paths the IDE names are not the sandbox's, and neither is python3's view of them.
  if command -v cygpath >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then return 0; fi
  ide="$(python3 -I "${HERE}/host/ide-relay.py" --check "${PROJECT_DIR}" 2>/dev/null)" || return 0
  if ! state="$(mktemp -d "${TMPDIR:-/tmp}/${CONTAINER}.ide.XXXXXX")"; then
    echo "[sandbox] WARN: no temporary directory for ${ide}'s selection - the sandbox won't see it" >&2
    return 0
  fi
  python3 -I "${HERE}/host/ide-relay.py" "${PROJECT_DIR}" "$1" "${state}" "$$" </dev/null >/dev/null 2>&1 3<&- &
  IDE_RELAY_PID=$!
  IDE_ARGS=(-e "SANDBOX_IDE=${ide}" -e SANDBOX_IDE_DIR=/opt/ai-sandbox/ide -e "CLAUDE_CODE_SSE_PORT=${IDE_PORT}"
            -v "${state}:/opt/ai-sandbox/ide:ro")
  echo "[sandbox] passing the open file and selection in ${ide} to Claude (this project's files only)" >&2
}

# The relay removes its directory as it stops. It also stops by itself when the launcher is SIGKILLed.
stop_ide_relay() {
  [[ -n "${IDE_RELAY_PID}" ]] || return 0
  kill "${IDE_RELAY_PID}" 2>/dev/null || true
  IDE_RELAY_PID=""
}

run() {
  if [[ ! -d "${PROJECT_DIR}" ]]; then
    echo "Project directory not found: ${PROJECT_DIR}" >&2
    exit 1
  fi
  ensure_config
  export_git_config

  # A running sandbox of this checkout would be replaced: ask first, where someone can answer.
  confirm_replace

  # (Re)build before launching so every session runs the latest image - unless nothing it is built
  # from has changed (build_key), when even Docker's cache checks are skipped.
  build --if-changed

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
  # The git settings that run programs on the host, to compare at teardown (report_risky_git_config).
  # shellcheck disable=SC2310  # best effort, as at teardown
  RISKY_GIT_BEFORE="$(risky_git_config)" || RISKY_GIT_BEFORE=""
  RISKY_GIT_RECORDED=1

  # The mounts:
  #   - the project at /work (its configuration directory included, wherever it is inside it);
  #   - the configuration directory AGAIN at the fixed /opt/ai-sandbox/config, so the image finds its
  #     bin/ (on PATH), entrypoint.d/ and setup.d/ without knowing where the project keeps it;
  #   - the nested Docker data dir, a named volume - by far the largest (see the README's disk usage);
  #   - /home/dev/.claude, a BIND MOUNT to CLAUDE_HISTORY_DIR, a plain directory in the configuration
  #     rather than an opaque named volume: Claude's auth, transcripts and memory are visible with a
  #     normal `ls`/`cp`/`tar`, backed up by copying a directory, wiped with `rm -rf`, and inherently
  #     scoped to this one checkout;
  #   - the project AGAIN at its host path, and Claude's temporary directory (CLAUDE_TMP_DIR) at its
  #     host path, where they can be (see mirrored_path);
  #   - the project's cache volumes (SANDBOX_CACHE_VOLUMES).
  # Claude derives its per-project history key from its working directory: the host path where it can
  # be (launch.sh links that key to the sessions of earlier launches), else /work.
  local project_mount config_mount history_mount tmp_mount tmp_host tmp_target project_host
  local tmp_env=() mirror_mounts=() workdir_env=() protect_mounts=() protected=() path source client
  project_mount="$(to_docker_path "${PROJECT_DIR}")"
  config_mount="$(to_docker_path "${CONFIG_DIR}")"
  history_mount="$(to_docker_path "${CLAUDE_HISTORY_DIR}")"
  tmp_mount="$(to_docker_path "${CLAUDE_TMP_DIR}")"
  # Absolute (PROJECT_DIR and SANDBOX_CONFIG_DIR may be relative), so they can name container paths.
  # run() has checked the project exists, and ensure_config has just created the temporary directory.
  project_host="$(cd "${PROJECT_DIR}" && pwd)"
  tmp_host="$(cd "${CLAUDE_TMP_DIR}" && pwd)"
  # shellcheck disable=SC2310  # its status only says whether the path can be mirrored
  if project_host="$(mirrored_path "${project_host}")"; then
    mirror_mounts+=(-v "${project_mount}:${project_host}")
    workdir_env=(-e "SANDBOX_WORKDIR=${project_host}")
  fi
  # The files the host runs, read-only over themselves wherever the project is mounted (see
  # SANDBOX_PROTECTED_PATHS). A symlink is left alone: docker would mount whatever it points at, and the
  # target, inside the container, may not be the file it names on the host.
  for path in ${PROTECTED_PATHS+"${PROTECTED_PATHS[@]}"}; do
    if [[ -L "${PROJECT_DIR}/${path}" ]]; then
      continue
    elif [[ ! -e "${PROJECT_DIR}/${path}" ]]; then
      UNPROTECTED_MISSING+=("${path}")
      continue
    fi
    source="$(to_docker_path "${PROJECT_DIR}/${path}")"
    protected+=("${path}")
    protect_mounts+=(-v "${source}:/work/${path}:ro")
    [[ "${#workdir_env[@]}" -eq 0 ]] || protect_mounts+=(-v "${source}:${project_host}/${path}:ro")
  done
  # sandbox.conf at the configuration's fixed mount point too (whether or not the list names it there).
  if [[ -f "${CONFIG_DIR}/sandbox.conf" && ! -L "${CONFIG_DIR}/sandbox.conf" ]]; then
    protect_mounts+=(-v "$(to_docker_path "${CONFIG_DIR}/sandbox.conf"):/opt/ai-sandbox/config/sandbox.conf:ro")
  fi
  # shellcheck disable=SC2310  # as above
  if tmp_target="$(mirrored_path "${tmp_host}")"; then
    tmp_env=(-e "CLAUDE_CODE_TMPDIR=${tmp_target}")
  else
    tmp_target="${CLAUDE_TMP_DEFAULT}"
  fi
  # Interactive sessions only: a scripted `run` has no one selecting anything for it.
  if [[ "${tty[0]}" == "-it" ]]; then
    start_ide_relay "${project_host:-/work}"
  fi
  docker run "${tty[@]}" --rm \
    --name "${CONTAINER}" \
    --cidfile "${CIDFILE}" \
    "${ISOLATION_ARGS[@]}" \
    ${DEVICE_ARGS[@]+"${DEVICE_ARGS[@]}"} \
    ${PIDS_ARGS[@]+"${PIDS_ARGS[@]}"} \
    --hostname "${NAME}" \
    -e TZ="${SANDBOX_TIMEZONE}" \
    -e SANDBOX_CACHE_PATHS="${CACHE_PATHS[*]-}" \
    -e SANDBOX_NPM_DIRS="${SANDBOX_NPM_DIRS-}" \
    -e SANDBOX_HISTORY_DAYS="${SANDBOX_HISTORY_DAYS}" \
    -e SANDBOX_REMOTE_CONTROL="${SANDBOX_REMOTE_CONTROL}" \
    -e SANDBOX_PASTE_CHANNEL="${SANDBOX_PASTE_CHANNEL}" \
    ${IDE_ARGS[@]+"${IDE_ARGS[@]}"} \
    -e SANDBOX_BLOCK_LOCAL_NETWORK="${SANDBOX_BLOCK_LOCAL_NETWORK}" \
    -e SANDBOX_LOCAL_NETWORK_ALLOW="${LOCAL_NETWORK_ALLOW[*]-}" \
    -e SANDBOX_SUDO="${SANDBOX_SUDO}" \
    -e SANDBOX_DEVICE_PATHS="${DEVICE_PATHS[*]-}" \
    -e SANDBOX_PROTECTED="${protected[*]-}" \
    -e SANDBOX_PUBLISHED_PORTS="${PUBLISH_PORTS[*]-}" \
    -e SANDBOX_CONFIG_REL="${CONFIG_DIR#"${PROJECT_DIR}"/}" \
    ${ROOT_COMMAND:+-e "SANDBOX_ROOT_COMMAND=${ROOT_COMMAND}"} \
    -e SANDBOX_REPO_DIR="${REPO_DIR}" \
    "${TERMINAL_ENV[@]}" \
    ${tmp_env[@]+"${tmp_env[@]}"} \
    ${workdir_env[@]+"${workdir_env[@]}"} \
    ${ENV_ARGS[@]+"${ENV_ARGS[@]}"} \
    -v "${project_mount}":/work \
    -v "${config_mount}":/opt/ai-sandbox/config \
    -v "${NAME}-docker":/var/lib/docker \
    -v "${history_mount}":/home/dev/.claude \
    ${mirror_mounts[@]+"${mirror_mounts[@]}"} \
    -v "${tmp_mount}":"${tmp_target}" \
    ${protect_mounts[@]+"${protect_mounts[@]}"} \
    ${CACHE_MOUNTS[@]+"${CACHE_MOUNTS[@]}"} \
    ${PUBLISH[@]+"${PUBLISH[@]}"} \
    ${RUN_ARGS[@]+"${RUN_ARGS[@]}"} \
    "${IMAGE}" "$@" <&3 &
  client=$!
  show_published_ports "${client}"
  wait "${client}"
}

# Where the published ports (SANDBOX_PORTS) are on the host, once the container is up: a bare `8081`
# gets a port docker picks, which nothing else shows. Printed before the session starts drawing (the
# entrypoint's nested dockerd takes longer than this), and given up on after 10s.
show_published_ports() {  # <the docker run client's pid>
  local tries=0 ports
  [[ "${#PUBLISH[@]}" -gt 0 ]] || return 0
  while (( tries < 20 )) && kill -0 "$1" 2>/dev/null; do
    ports="$(docker port "${CONTAINER}" 2>/dev/null)" || ports=""
    if [[ -n "${ports}" ]]; then
      printf '%s\n' "${ports}" | sed 's/^\(.*\) -> \(.*\)$/[sandbox] port \1 is published at \2/' >&2
      return 0
    fi
    sleep 0.5
    tries=$(( tries + 1 ))
  done
}

# A second shell in the sandbox that is ALREADY running (a launch would replace it instead). It joins
# the same container: same nested dockerd, same files, same environment (the image's ENV and the
# `docker run -e` values are the container's own, so `docker exec` inherits them).
attach() {
  if ! docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    echo "No ${CONTAINER} container is running - start one first." >&2
    exit 1
  fi
  local tty=() workdir
  if [[ -t 0 ]] && [[ -t 1 ]]; then tty=(-it); else tty=(-i); fi
  # Where the sandbox's Claude runs (see mirrored_path): the launch passed it as SANDBOX_WORKDIR, and a
  # sandbox started by an older version has none.
  workdir="$(docker exec "${CONTAINER}" printenv SANDBOX_WORKDIR 2>/dev/null)" || workdir=""
  docker port "${CONTAINER}" 2>/dev/null | sed 's/^\(.*\) -> \(.*\)$/[sandbox] port \1 is published at \2/' >&2 || true
  docker exec "${tty[@]}" -u dev -w "${workdir:-/work}" -e HOME=/home/dev -e USER=dev "${TERMINAL_ENV[@]}" \
    "${CONTAINER}" "${@:-bash}"
}

# Reclaim disk inside the NESTED docker daemon - the `-docker` volume, by far the largest (image layers
# and BuildKit cache from every nested build land there). The GC policy baked into the image
# (`daemon.json`) caps the build cache on its own; this is the manual, immediate version, and it also
# clears the images/containers/volumes that no policy covers.
#
# Prefers `docker exec` into a RUNNING sandbox so a live Claude session is never interrupted; only
# starts a container when none is up. Runs as root inside.
ROOT_COMMAND=""
PRUNE_CMD='docker system df; docker builder prune -af --max-used-space=20GB; docker image prune -af --filter until=336h; docker container prune -f; docker volume prune -f; echo; docker system df'
prune() {
  # `docker container inspect`, not `docker inspect`: the image has the container's name too, and a plain
  # inspect found it, so prune (and attach) took the sandbox for running whenever its image existed.
  if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    echo "[sandbox] pruning inside the running ${CONTAINER} (session untouched)..."
    docker exec -u root "${CONTAINER}" bash -c "${PRUNE_CMD}"
  else
    echo "[sandbox] no ${CONTAINER} running - starting one to prune..."
    # As root (entrypoint.sh's SANDBOX_ROOT_COMMAND): `dev` has no sudo.
    ROOT_COMMAND="${PRUNE_CMD}" run
  fi
}

stop() {
  # Stopping the container triggers the running launcher's --rm + trap teardown (nested dockerd and
  # everything it spun up dies with it). A no-op if nothing is there. The scratch run configs are removed
  # here too, in case the launcher was killed before its trap could do it.
  remove_existing
  remove_scratch_run_configs
  if (( REMOVED_EXISTING == 1 )); then
    echo "Stopped ${CONTAINER}."
  else
    echo "No ${CONTAINER} container to stop."
  fi
}

# Import the organisation rules (rules/CLAUDE.md, shared by every ai-sandbox project) into the project's
# own CLAUDE.md with an `@<submodule>/rules/CLAUDE.md` line. An import, not a copy, so moving the
# submodule to a newer tag updates the rules with no re-init. Claude Code only loads CLAUDE.md files
# from the working directory up, so a CLAUDE.md inside the submodule would never be read on its own.
# The project's file is either CLAUDE.md or .claude/CLAUDE.md (Claude loads both): the import goes into
# whichever exists (the root one if both do), and a new .claude/CLAUDE.md is created if neither does.
# An import path is relative to the file holding it, so the one in .claude/CLAUDE.md needs `../` (without
# it, Claude silently looks in .claude/<submodule>/ and loads nothing).
# Idempotent: nothing changes if either file already has the import.
ensure_claude_rules() {  # <submodule path relative to the project>
  local rules="$1/rules/CLAUDE.md" import target tmp
  if [[ -f "${PROJECT_DIR}/CLAUDE.md" ]] && grep -qxF "@${rules}" "${PROJECT_DIR}/CLAUDE.md"; then
    echo "  exists   @${rules} in CLAUDE.md"
    return 0
  fi
  if [[ -f "${PROJECT_DIR}/.claude/CLAUDE.md" ]] && grep -qxF "@../${rules}" "${PROJECT_DIR}/.claude/CLAUDE.md"; then
    echo "  exists   @../${rules} in .claude/CLAUDE.md"
    return 0
  fi

  if [[ -f "${PROJECT_DIR}/CLAUDE.md" ]]; then
    target="${PROJECT_DIR}/CLAUDE.md"
    import="@${rules}"
  else
    target="${PROJECT_DIR}/.claude/CLAUDE.md"
    import="@../${rules}"
  fi
  if [[ ! -f "${target}" ]]; then
    mkdir -p "$(dirname "${target}")"
    printf '# %s\n\n%s\n' "$(basename "${PROJECT_DIR}")" "${import}" > "${target}"
    echo "  created  ${target#"${PROJECT_DIR}"/} (importing the organisation rules)"
    return 0
  fi

  # Under the file's title, if it opens with one (so the title stays first), else at the very top.
  tmp="${target}.tmp.$$"
  if head -n 1 "${target}" | grep -q '^# '; then
    { head -n 1 "${target}"; printf '\n%s\n' "${import}"; tail -n +2 "${target}"; } > "${tmp}"
  else
    { printf '%s\n\n' "${import}"; cat "${target}"; } > "${tmp}"
  fi
  mv -f "${tmp}" "${target}"
  echo "  updated  ${target#"${PROJECT_DIR}"/} (imports the organisation rules)"
}

# The project's shared Claude settings (.claude/settings.json, committed) that every ai-sandbox project
# wants. These are project settings rather than ones launch.sh asserts in the sandbox's ~/.claude, so they
# also apply when Claude runs on the host:
#   • `attribution: false` - no Co-Authored-By trailer, session link or PR footer from Claude. The
#     boolean form needs a recent Claude Code; older releases reject it and only accept
#     { "commit": "", "pr": "" }.
#   • the organisation's PreToolUse guards (rules/hooks/), by a $CLAUDE_PROJECT_DIR-relative command - no
#     host path - so the committed file works in every checkout, and on the host as well as in the sandbox.
#     Today that is guard-git-branch.sh (organisation rule 1). An entry is recognised by its exact command,
#     so a project's own copy of a guard is left in place (and the two simply both run) until it is removed.
# Merged with jq when the host has it (a Git Bash host may not). Without jq, an existing file that lacks a
# setting gets a warning instead of a hand-rolled JSON edit.
ensure_claude_settings() {  # <submodule path relative to the project>
  local settings="${PROJECT_DIR}/.claude/settings.json" rel_settings=".claude/settings.json" tmp
  local guard="\"\$CLAUDE_PROJECT_DIR\"/$1/rules/hooks/guard-git-branch.sh"
  # shellcheck disable=SC2016  # $cmd is jq's variable, not the shell's
  local has_guard='[.hooks.PreToolUse[]?.hooks[]?.command] | any(. == $cmd)'
  if [[ ! -f "${settings}" ]] && ! command -v jq >/dev/null 2>&1; then
    mkdir -p "$(dirname "${settings}")"
    printf '%s\n' '{' '  "attribution": false,' '  "hooks": {' '    "PreToolUse": [' '      {' \
      '        "matcher": "Bash",' "        \"hooks\": [{ \"type\": \"command\", \"command\": \"${guard//\"/\\\"}\" }]" \
      '      }' '    ]' '  }' '}' > "${settings}"
    echo "  created  ${rel_settings}"
    return 0
  fi
  if ! command -v jq >/dev/null 2>&1; then
    grep -q '"attribution"[[:space:]]*:[[:space:]]*false' "${settings}" \
      || echo "[sandbox] WARN: no jq to update ${rel_settings} - add \"attribution\": false to it by hand" >&2
    grep -qF "/$1/rules/hooks/guard-git-branch.sh" "${settings}" \
      || echo "[sandbox] WARN: no jq to update ${rel_settings} - register ${guard} as a Bash PreToolUse hook by hand" >&2
    return 0
  fi
  if [[ ! -f "${settings}" ]]; then
    mkdir -p "$(dirname "${settings}")"
    echo '{}' > "${settings}"
    echo "  created  ${rel_settings}"
  elif ! jq -e . "${settings}" >/dev/null 2>&1; then
    echo "[sandbox] WARN: ${rel_settings} is not valid JSON - add \"attribution\": false and the ${guard##*/} hook by hand" >&2
    return 0
  fi
  tmp="${settings}.tmp.$$"
  if jq -e '.attribution == false' "${settings}" >/dev/null; then
    echo "  exists   \"attribution\": false in ${rel_settings}"
  else
    jq --indent 2 '.attribution = false' "${settings}" > "${tmp}" && mv -f "${tmp}" "${settings}"
    echo "  updated  ${rel_settings} (\"attribution\": false)"
  fi
  if jq -e --arg cmd "${guard}" "${has_guard}" "${settings}" >/dev/null; then
    echo "  exists   the ${guard##*/} hook in ${rel_settings}"
  else
    jq --indent 2 --arg cmd "${guard}" \
      '.hooks.PreToolUse += [{matcher: "Bash", hooks: [{type: "command", command: $cmd}]}]' \
      "${settings}" > "${tmp}" && mv -f "${tmp}" "${settings}"
    echo "  updated  ${rel_settings} (the ${guard##*/} hook)"
  fi
}

# Set up a project, ONCE, when it starts using ai-sandbox: its configuration directory from
# templates/configuration/, the IntelliJ run configurations from templates/run/ into the project's .run/
# (which IntelliJ loads on its own, no plugin needed), the organisation rules import in CLAUDE.md and
# .claude/settings.json. From then on `update` keeps the project current: it moves the submodule to a
# release and adds whatever that release brings (add_release_content).
#
# The templates are named *.run.xml.template, not *.run.xml: IntelliJ loads every *.run.xml in the
# project, so in a project using this repo as a submodule the unsubstituted templates (@SANDBOX_DIR@
# still in the script path) would shadow the generated configs of the same name. For the same reason
# this repo's own configurations are in .idea/runConfigurations/, not .run/. The run configurations
# reference the launcher by a $PROJECT_DIR$-relative path only - no host path - so they can be committed.
project_paths_ok() {  # the checks init and update's second half share
  if (( SELF_HOSTED == 1 )); then
    echo "[sandbox] $1: not needed - this is ai-sandbox's own checkout, which is its own sandbox" >&2
    echo "[sandbox]       (its ai-sandbox-configuration/, .idea/runConfigurations/ and .claude/ are committed by hand)" >&2
    exit 1
  fi
  if [[ "${HERE}" != "${PROJECT_DIR}"/* ]]; then
    echo "[sandbox] $1: ${HERE} is not inside ${PROJECT_DIR} - set PROJECT_DIR" >&2
    exit 1
  fi
}

# What a release adds to a project, and all that init writes besides the configuration templates: each
# configuration file or setting the project doesn't have yet, and the run configurations. The
# configuration directory is the project's (sandbox.conf and the Dockerfile are always edited), so
# nothing there is overwritten or removed; a release that needs an EXISTING file changed must do it
# here, as an idempotent step of its own (ensure_claude_rules and ensure_claude_settings are such steps).
# The run configurations are ai-sandbox's, not the project's: every `.run/Claude Sandbox*.run.xml` is
# synced to this release's templates - added, overwritten when it differs, and removed when the release
# no longer has it - so a fix to one (Paste Image moving to the Terminal tool window, 1.3.0) reaches every
# project. A project's own run configurations must not use the "Claude Sandbox" name prefix.
ADDED=0
CHANGED=0
add_release_content() {  # <"init"|"update">
  local rel="${HERE#"${PROJECT_DIR}"/}" src templates mode="$1"

  copy_template() {  # <source> <destination> - substituting @SANDBOX_DIR@
    if [[ -e "$2" ]]; then
      [[ "${mode}" == "init" ]] && echo "  exists   ${2#"${PROJECT_DIR}"/}"
      return 0
    fi
    mkdir -p "$(dirname "$2")"
    sed "s|@SANDBOX_DIR@|${rel}|g" "$1" > "$2"
    [[ -x "$1" ]] && chmod +x "$2"
    if [[ "${mode}" == "init" ]]; then echo "  created  ${2#"${PROJECT_DIR}"/}"; else echo "  added    ${2#"${PROJECT_DIR}"/}"; fi
    ADDED=$((ADDED + 1))
  }

  sync_run_configs() {  # .run/Claude Sandbox*.run.xml = templates/run/, exactly
    local dst rel_dst expected current
    for src in "${HERE}"/templates/run/*.run.xml.template; do
      dst="${PROJECT_DIR}/.run/$(basename "${src}" .template)"
      rel_dst="${dst#"${PROJECT_DIR}"/}"
      if [[ ! -e "${dst}" ]]; then
        copy_template "${src}" "${dst}"
        continue
      fi
      expected="$(sed "s|@SANDBOX_DIR@|${rel}|g" "${src}")"
      current="$(<"${dst}")"
      if [[ "${current}" == "${expected}" ]]; then
        [[ "${mode}" == "init" ]] && echo "  exists   ${rel_dst}"
      else
        printf '%s\n' "${expected}" > "${dst}"
        echo "  updated  ${rel_dst}"
        CHANGED=$((CHANGED + 1))
      fi
    done
    for dst in "${PROJECT_DIR}"/.run/Claude\ Sandbox*.run.xml; do
      [[ -e "${dst}" ]] || continue
      [[ -e "${HERE}/templates/run/$(basename "${dst}").template" ]] && continue
      rm -f "${dst}"
      echo "  removed  ${dst#"${PROJECT_DIR}"/} (no longer in this release)"
      CHANGED=$((CHANGED + 1))
    done
  }

  # Any OTHER "Claude Sandbox" run configuration IntelliJ can see shadows the synced ones: it loads a
  # `*.run.xml` from anywhere in the project, and its own local copies too, and a same-named copy with an
  # old script path wins after a restart ("Shell script not found"). Both happened on 2026-11-22:
  #   - a `Claude Sandbox*.run.xml` outside the root `.run/` (a scratch project's, in Claude's temp dir,
  #     which is inside the project): deleted, wherever it is. The search skips .git and this submodule
  #     (whose templates are `*.template`, never loaded);
  #   - a `Claude Sandbox*` Shell Script configuration in `.idea/workspace.xml` (made by hand before the
  #     migration, still pointing at the deleted `sandbox/sandbox.sh`) or in `.idea/runConfigurations/`:
  #     removed. That XML is IntelliJ's local state, git-ignored, so the old one is kept as
  #     `.idea/workspace.xml.before-ai-sandbox`. An open IntelliJ writes its in-memory copy back over it.
  # The name prefix is ai-sandbox's (see above), so none of these can be the project's own.
  remove_shadowing_run_configs() {
    local found ws kept
    found="$(find "${PROJECT_DIR}" \( -path "${PROJECT_DIR}/.git" -o -path "${HERE}" \) -prune -o \
               -type f -name 'Claude Sandbox*.run.xml' ! -path "${PROJECT_DIR}/.run/*" -print 2>/dev/null)" || true
    while IFS= read -r dst; do
      [[ -n "${dst}" ]] || continue
      rm -f "${dst}"
      echo "  removed  ${dst#"${PROJECT_DIR}"/} (shadows .run/$(basename "${dst}"))"
      CHANGED=$((CHANGED + 1))
    done <<< "${found}"

    for dst in "${PROJECT_DIR}"/.idea/runConfigurations/Claude_Sandbox*.xml; do
      [[ -e "${dst}" ]] || continue
      rm -f "${dst}"
      echo "  removed  ${dst#"${PROJECT_DIR}"/} (a copy of a .run/ configuration)"
      CHANGED=$((CHANGED + 1))
    done

    ws="${PROJECT_DIR}/.idea/workspace.xml"
    if [[ -f "${ws}" ]] && grep -q '<configuration name="Claude Sandbox[^"]*" type="ShConfigurationType"' "${ws}"; then
      # IntelliJ writes each <configuration> start and end tag on lines of their own; a self-closing one
      # (no options) is a single line.
      kept="$(awk '
        skip { if ($0 ~ /<\/configuration>/) skip = 0; next }
        /<configuration name="Claude Sandbox[^"]*" type="ShConfigurationType"/ {
          if ($0 !~ /\/>[[:space:]]*$/) skip = 1
          next
        }
        { print }' "${ws}")"
      cp -p "${ws}" "${ws}.before-ai-sandbox"
      printf '%s\n' "${kept}" > "${ws}"
      echo "  updated  .idea/workspace.xml (removed its own \"Claude Sandbox\" configurations; old copy: .idea/workspace.xml.before-ai-sandbox)"
      echo "           if $(basename "${PROJECT_DIR}") is open in IntelliJ, close and reopen it - or it writes them back"
      CHANGED=$((CHANGED + 1))
    fi
  }

  # The configuration templates only on init: once a project is set up, its configuration directory is
  # its own - a file deleted there (an unneeded Dockerfile) must stay deleted.
  if [[ "${mode}" == "init" ]]; then
    templates="$(find "${HERE}/templates/configuration" -type f)"
    templates="$(LC_ALL=C sort <<< "${templates}")"
    while IFS= read -r src; do
      copy_template "${src}" "${CONFIG_DIR}/${src#"${HERE}/templates/configuration/"}"
    done <<< "${templates}"
  fi
  sync_run_configs
  remove_shadowing_run_configs
  ensure_config
  ensure_devices_setting
  ensure_claude_rules "${rel}"
  ensure_claude_settings "${rel}"
}

# 1.3.0 stopped running the sandbox --privileged, which had handed it every host device; a device is now
# passed in only when SANDBOX_DEVICES names it. A project whose configuration uses /dev/kvm (an Android
# emulator: bin/emulator.sh in examples/android-gradle, DiceFive, LudoPlus) would lose it on update, so
# the setting is added to its sandbox.conf - once: a sandbox.conf that sets SANDBOX_DEVICES at all
# (even to nothing) has made its own choice.
ensure_devices_setting() {
  local conf="${CONFIG_DIR}/sandbox.conf" uses
  [[ -f "${conf}" ]] || return 0
  grep -qE '^[[:space:]]*SANDBOX_DEVICES=' "${conf}" && return 0
  for uses in "${CONFIG_DIR}"/{Dockerfile,bin,entrypoint.d,setup.d}; do
    [[ -e "${uses}" ]] || continue
    if grep -rqsF -- /dev/kvm "${uses}"; then
      printf '\n%s\n%s\n%s\n' \
        "# Host devices passed in (space-separated /dev paths). Added by ai-sandbox's update: the sandbox is" \
        "# no longer --privileged, which passed in every device, and this configuration uses /dev/kvm." \
        'SANDBOX_DEVICES="/dev/kvm"' >> "${conf}"
      echo "  updated  ${conf#"${PROJECT_DIR}"/} (SANDBOX_DEVICES=\"/dev/kvm\", for the emulator)"
      CHANGED=$((CHANGED + 1))
      return 0
    fi
  done
}

init() {
  project_paths_ok init
  # A project with a sandbox.conf is set up already, and init is not how it gets a new release: that is
  # update. The `update` of releases up to 1.2.2 ends by running the NEW release's plain init, so a
  # project upgraded by one of those lands here too, with its submodule already moved: the `update`
  # suggested then finds it on the newest tag and only adds what the release brings.
  if [[ -f "${CONFIG_DIR}/sandbox.conf" ]]; then
    echo "[sandbox] ERROR: init: $(basename "${PROJECT_DIR}") is set up already" \
         "(${CONFIG_DIR#"${PROJECT_DIR}"/}/sandbox.conf exists), and init is a one-time step for a new project." >&2
    echo "[sandbox]        To take it to a new release, and add what that release brings: ${HERE#"${PROJECT_DIR}"/}/sandbox.sh update" >&2
    exit 1
  fi
  echo "[sandbox] initialising $(basename "${PROJECT_DIR}")..."
  add_release_content init
  echo "[sandbox] ${ADDED} file(s) created. Next: edit ${CONFIG_DIR#"${PROJECT_DIR}"/}/sandbox.conf (and its Dockerfile, if the project needs toolchains)."
}

# update's second half, run by the release update has just checked out (`init --update`, see update).
apply_update_content() {
  local version
  project_paths_ok update
  version="$(git -C "${HERE}" describe --tags 2>/dev/null)" || version="this version"
  echo "[sandbox] adding what ${version} brings..."
  add_release_content update
  if (( ADDED + CHANGED == 0 )); then
    echo "[sandbox] no new files; review and commit the moved ${HERE#"${PROJECT_DIR}"/} submodule and any changed settings."
  else
    echo "[sandbox] ${ADDED} file(s) added, ${CHANGED} file(s) updated or removed; review and commit them with the moved ${HERE#"${PROJECT_DIR}"/} submodule."
  fi
}

# Upgrade a project to a newer ai-sandbox: move the submodule to the newest X.Y.Z tag (or the one given),
# then run that NEW version's init. Releases add their migrations to init (new templates, the rules import,
# project settings), and init is idempotent and never overwrites, so "update" = "move + re-scaffold".
# The new version's init has to be the one that runs, so this script exec's the freshly checked-out copy
# of itself. That is also what makes moving it safe: git replaces sandbox.sh with a new file (the running
# bash keeps reading the old one, now unlinked), and the exec comes before the old copy reads any further.
# The result is left uncommitted: the submodule pointer plus whatever init created or updated.
update() {
  local target current
  if (( SELF_HOSTED == 1 )); then
    echo "[sandbox] update: this is ai-sandbox's own checkout, which runs its working tree - use git here" >&2
    exit 1
  fi
  if ! command -v git >/dev/null 2>&1 || ! git -C "${HERE}" rev-parse --git-dir >/dev/null 2>&1; then
    echo "[sandbox] update: ${HERE} is not a git checkout (it should be a submodule of the project)" >&2
    exit 1
  fi
  # Local edits would block the checkout, or be carried silently onto the new tag.
  local changes
  changes="$(git -C "${HERE}" status --porcelain)"
  if [[ -n "${changes}" ]]; then
    echo "[sandbox] update: ${HERE#"${PROJECT_DIR}"/} has local changes - commit or discard them first" >&2
    exit 1
  fi

  echo "[sandbox] fetching ai-sandbox tags..."
  git -C "${HERE}" fetch --quiet --tags origin
  if [[ -n "${1:-}" ]]; then
    target="$1"
    git -C "${HERE}" rev-parse --verify --quiet "refs/tags/${target}" >/dev/null || {
      echo "[sandbox] update: no tag '${target}'" >&2
      exit 1
    }
  else
    # Releases only (X.Y.Z): git's own version sort, so no `sort -V` is needed on the host.
    target="$(git -C "${HERE}" tag --list --sort=-v:refname '[0-9]*.[0-9]*.[0-9]*' | head -n 1)"
    [[ -n "${target}" ]] || { echo "[sandbox] update: no X.Y.Z release tags found" >&2; exit 1; }
  fi
  current="$(git -C "${HERE}" describe --tags --exact-match 2>/dev/null || git -C "${HERE}" rev-parse --short HEAD)"

  local head_commit target_commit
  head_commit="$(git -C "${HERE}" rev-parse HEAD)"
  target_commit="$(git -C "${HERE}" rev-parse "refs/tags/${target}^{commit}")"
  if [[ "${head_commit}" == "${target_commit}" ]]; then
    echo "[sandbox] ai-sandbox is already on ${target}"
  else
    git -C "${HERE}" -c advice.detachedHead=false checkout --quiet "refs/tags/${target}"
    echo "[sandbox] ai-sandbox ${current} -> ${target}"
  fi
  echo "[sandbox] the next launch rebuilds the image."
  # The second half - adding what the release brings (run configurations, settings) - is the NEW
  # release's to do, so it runs from the checkout just made. As `init --update`: every release has
  # `init` (which is how this worked up to 1.2.2, and so what an `update X.Y.Z` back to one of those
  # still needs), and a release that doesn't know `--update` ignores it. A word an older sandbox.sh
  # doesn't know as a command would LAUNCH the sandbox instead.
  exec "${HERE}/sandbox.sh" init --update
}

# ── paste-image: the host clipboard's picture, handed to the sandbox ──────────
# On the host, Ctrl+V of a screenshot works because Claude reads the clipboard itself (wl-paste, xclip).
# In the sandbox it can't, and it must not be able to: the only way in would be mounting the display
# server's socket, which lets anything in the sandbox log keystrokes and grab the screen (X11), or read
# every password you copy without ever having focus (Wayland, on compositors with the data-control
# protocol). So the HOST reads the clipboard, and only when you ask: this saves its image (as PNG) into
# Claude's temporary directory, which the sandbox sees (see mirrored_path), and replaces it on the
# clipboard with that file's path in the sandbox. The running Claude session picks the image up by itself
# (image/final/paste-channel.mjs, unless SANDBOX_PASTE_CHANNEL=false); Ctrl+V in Claude pastes the path,
# which Claude attaches as the image, as it does a file dragged into the terminal. Nothing in the sandbox
# can ask for it. Never starts, stops or looks at a sandbox; the pictures go when SANDBOX_HISTORY_DAYS says.
#
# Runs on the host, so it uses the host's own tools: wl-paste/wl-copy (Wayland) or xclip (X11) on
# Linux, osascript/pbcopy on macOS, PowerShell/clip.exe on Windows.
clipboard_image_to() {  # <file>: the clipboard's image as PNG, or fails when it holds none
  local file="$1"
  if [[ -n "${WAYLAND_DISPLAY-}" ]] && command -v wl-paste &>/dev/null; then
    wl-paste --list-types 2>/dev/null | grep -qx 'image/png' || return 1
    wl-paste --type image/png > "${file}"
  elif [[ -n "${DISPLAY-}" ]] && command -v xclip &>/dev/null; then
    xclip -selection clipboard -t TARGETS -o 2>/dev/null | grep -qx 'image/png' || return 1
    xclip -selection clipboard -t image/png -o > "${file}"
  elif command -v osascript &>/dev/null; then
    osascript -e "set png to (the clipboard as «class PNGf»)" \
              -e "set out to open for access (POSIX file \"${file}\") with write permission" \
              -e 'write png to out' -e 'close access out' >/dev/null 2>&1
  elif command -v powershell.exe &>/dev/null; then
    local windows_file
    windows_file="$(to_docker_path "${file}")"
    # shellcheck disable=SC2016 # the $ variables are PowerShell's, so bash must not expand them
    powershell.exe -NoProfile -STA -Command \
      'Add-Type -AssemblyName System.Windows.Forms, System.Drawing;
       $i = [System.Windows.Forms.Clipboard]::GetImage();
       if ($i -eq $null) { exit 1 }; $i.Save($args[0], [System.Drawing.Imaging.ImageFormat]::Png)' \
      "${windows_file}" >/dev/null 2>&1
  else
    echo "[sandbox] paste-image: no clipboard tool found (wl-paste, xclip, osascript or PowerShell)" >&2
    return 1
  fi
  [[ -s "${file}" ]]
}
text_to_clipboard() {  # <text>
  if [[ -n "${WAYLAND_DISPLAY-}" ]] && command -v wl-copy &>/dev/null; then
    printf '%s' "$1" | wl-copy
  elif [[ -n "${DISPLAY-}" ]] && command -v xclip &>/dev/null; then
    # xclip stays behind to serve the selection; with its output closed, so this returns at once.
    printf '%s' "$1" | xclip -selection clipboard -i >/dev/null 2>&1
  elif command -v pbcopy &>/dev/null; then
    printf '%s' "$1" | pbcopy
  elif command -v clip.exe &>/dev/null; then
    printf '%s' "$1" | clip.exe
  else
    return 1
  fi
}
paste_image() {
  local dir file name in_sandbox tmp_host
  ensure_config
  dir="${CLAUDE_TMP_DIR}/pastes"
  mkdir -p "${dir}"
  name="clipboard-$(date +%Y%m%d-%H%M%S).png"
  file="${dir}/${name}"
  # shellcheck disable=SC2310  # its status is the answer: whether there was an image
  if ! clipboard_image_to "${file}"; then
    rm -f "${file}"
    echo "[sandbox] paste-image: the clipboard holds no image (copy a screenshot first)" >&2
    exit 1
  fi
  # The file's path as the sandbox sees it: as run() mounts the directory.
  tmp_host="$(cd "${CLAUDE_TMP_DIR}" && pwd)"
  # shellcheck disable=SC2310  # its status only says whether the path can be mirrored
  in_sandbox="$(mirrored_path "${tmp_host}")" || in_sandbox="${CLAUDE_TMP_DEFAULT}"
  in_sandbox="${in_sandbox}/pastes/${name}"
  # shellcheck disable=SC2310  # a failure only means the path has to be copied by hand
  if text_to_clipboard "${in_sandbox}"; then
    echo "[sandbox] saved the clipboard's image; the running Claude session gets it by itself (its path is on the clipboard too):"
  else
    echo "[sandbox] saved the clipboard's image; the running Claude session gets it by itself (could not put its path on the clipboard):"
  fi
  echo "${in_sandbox}"
}

# --project-only is for a project consuming this repo as a submodule: the base's pins belong to this repo
# and arrive with its tags, and bumping them from a project dirties the submodule (which can then block
# the project's own move to a newer tag). The project's Debian pins still resolve against the base's release.
# --packages-only bumps the Debian package pins alone, leaving every `FROM image:tag` as it is: for a project
# whose own update script owns its image tags (a JDK it proves before pinning, a Maven kept in step with
# pom.xml), and calls this for the part every project shares - the packages, resolved on the base's Debian.
update_versions() {
  local dockerfiles=() project_only=0 options=()
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --project-only)  project_only=1 ;;
      --packages-only) options+=(--packages-only) ;;
      *)
        echo "[sandbox] update-versions: unknown option '$1' (the options are --project-only and --packages-only)" >&2
        exit 1
        ;;
    esac
    shift
  done
  (( project_only == 1 )) || dockerfiles+=("${HERE}/image/base/Dockerfile")
  if [[ -f "${CONFIG_DIR}/Dockerfile" ]]; then
    dockerfiles+=("${CONFIG_DIR}/Dockerfile")
  fi
  if [[ "${#dockerfiles[@]}" -eq 0 ]]; then
    echo "[sandbox] update-versions: ${CONFIG_DIR} has no Dockerfile" >&2
    exit 1
  fi
  "${HERE}/.github/scripts/update_dependency_versions.sh" ${options[@]+"${options[@]}"} --dockerfiles "${dockerfiles[@]}"
}

usage() { sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}"; }
commands() { usage | sed -n '/^  ai-sandbox\/sandbox.sh/,/^$/p' | sed '$d'; }

case "${1:-}" in
  build)    ensure_config; build ;;
  stop)     stop ;;
  prune)    prune ;;
  attach)   shift; attach "$@" ;;
  # `init --update` is update's second half (see update), not a command of its own.
  init)     if [[ "${2:-}" == "--update" ]]; then apply_update_content; else init; fi ;;
  update)   shift; update "$@" ;;
  update-versions) shift; update_versions "$@" ;;
  paste-image) paste_image ;;
  shell)    shift; run bash ;;
  # The two ways back into an earlier Claude session. Equivalent to (and interchangeable with) the
  # long forms `run claude --dangerously-skip-permissions --continue|--resume`.
  continue) shift; run claude --dangerously-skip-permissions --continue "$@" ;;
  resume)   shift; run claude --dangerously-skip-permissions --resume "$@" ;;
  run)      shift; run "$@" ;;
  -h|--help|help) usage ;;
  "")       run ;;            # default: interactive claude (entrypoint default)
  # Anything else is a mistake, not a command to run: a typo (`stauts`), or a command this version
  # doesn't have, once rebuilt the image and REPLACED the running sandbox before failing with
  # `exec: <word>: not found`. A command for the sandbox goes after `run`.
  *)        echo "[sandbox] unknown command '$1' - to run a command in the sandbox: sandbox.sh run $*" >&2
            echo >&2
            commands >&2
            exit 2 ;;
esac
