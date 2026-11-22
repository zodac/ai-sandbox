#!/usr/bin/env bash
# Runs as root (needed to start the nested dockerd), then drops to the `dev` user to run whatever
# command was passed (default: an interactive claude session).
set -euo pipefail

# Where sandbox.sh bind-mounts the project's ai-sandbox-configuration directory (absent if the project
# has none). Fixed, so its bin/ can sit on the image's PATH and `docker exec` sessions see it too.
CONFIG_DIR=/opt/ai-sandbox/config

# ── What the nested daemon needs, without --privileged ───────────────────────
# sandbox.sh no longer runs the sandbox --privileged (which handed it every host device, raw disks
# included, and every capability): it adds only CAP_SYS_ADMIN and CAP_NET_ADMIN, with seccomp and
# AppArmor off and a private cgroup namespace (see SANDBOX_PRIVILEGED there). Docker then mounts two
# things read-only that a nested dockerd must write, so they are opened up here, as root, before it
# starts. Both are no-ops in a --privileged sandbox, where they are writable already.
#
#   - the cgroup v2 tree (/sys/fs/cgroup, this container's own, through the cgroup namespace): dockerd
#     makes a cgroup per nested container under it. cgroup v2 lets a cgroup hand its controllers to
#     children only once it holds no processes itself, so everything here moves to an `init` child
#     first (as Docker's own dind image does) - in a loop, as a process forked mid-move lands in the
#     root again. Without the controllers, nested containers would start but ignore --memory/--cpus.
#     `docker exec` (attach) joins `init` too. A cgroup v1 host has no cgroup.controllers: skipped.
#   - /proc/sys/net: dockerd sets each nested container's network sysctls (IPv6 off on its eth0)
#     through it. Only that subtree is made writable, by a bind mount of its own: kernel.* and the rest
#     of /proc/sys stay read-only (kernel.core_pattern, written from here, would run a program on the
#     HOST), and /proc's masked paths stay masked.
open_up_for_dockerd() {
  local cg=/sys/fs/cgroup try pid
  if [[ -f "${cg}/cgroup.controllers" ]]; then
    [[ -w "${cg}" ]] || mount -o remount,rw "${cg}" \
      || echo "[sandbox] WARN: could not make ${cg} writable - nested containers will not start" >&2
    if [[ -w "${cg}" ]]; then
      mkdir -p "${cg}/init"
      for try in 1 2 3 4 5; do
        while read -r pid; do echo "${pid}" > "${cg}/init/cgroup.procs" 2>/dev/null || true; done < "${cg}/cgroup.procs"
        sed -e 's/ / +/g' -e 's/^/+/' < "${cg}/cgroup.controllers" > "${cg}/cgroup.subtree_control" 2>/dev/null && break
        [[ "${try}" -lt 5 ]] \
          || echo "[sandbox] WARN: could not delegate the cgroup controllers - nested containers ignore resource limits" >&2
      done
    fi
  fi
  if [[ ! -w /proc/sys/net/ipv4/ip_forward ]]; then
    { mount --bind /proc/sys/net /proc/sys/net && mount -o remount,bind,rw /proc/sys/net; } \
      || echo "[sandbox] WARN: could not make /proc/sys/net writable - nested containers will not start" >&2
  fi
}
open_up_for_dockerd

# ── Keep the host's local network out of reach ───────────────────────────────
# The sandbox can reach the internet, which it needs (packages, git, Claude itself), but by default
# also every machine on the host's LAN, the host itself (through Docker's bridge gateway, so any
# service the host has listening on all interfaces) and a cloud host's metadata service
# (169.254.169.254, which hands out credentials). A session has no business there, and a prompt-injected
# one could probe or attack them. So, unless SANDBOX_BLOCK_LOCAL_NETWORK=false, new connections leaving
# the sandbox's own interface for a private, link-local, CGNAT (Tailscale), multicast or reserved
# address - or the gateway, whatever its range - are refused; SANDBOX_LOCAL_NETWORK_ALLOW lists the
# addresses/CIDRs to let through anyway (a LAN proxy, a test server). Kept open regardless:
#   - replies to connections from outside (the published ports): `ct state established,related`;
#   - DNS (port 53) to the nameservers in /etc/resolv.conf, which Docker copies from the host and which
#     is often the LAN router;
#   - ICMPv6, which IPv6 needs to find its neighbours at all;
#   - everything not leaving through that interface: loopback, and the nested daemon's own bridges, so
#     the sandbox still reaches its nested containers (which are themselves on private addresses).
# The nested containers' traffic is forwarded out of the same interface, so the `forward` hook covers
# them too. One nftables table of our own: dockerd's rules (in tables of their own) never touch it, and a
# reject in any table is final.
# FAILS CLOSED, as Anthropic's reference devcontainer firewall does: if the rules cannot be loaded, or
# the self-test after them finds a local address still reachable, the sandbox does not start (set
# SANDBOX_BLOCK_LOCAL_NETWORK=false to start without the block). The self-test opens a connection to
# the gateway and to the cloud metadata address and checks, by the rules' own counter, that the rules
# refused it - a refused connection alone would prove nothing, as a closed port is refused too.
#
# A guard against accidents and casual probing, NOT a boundary: root in the sandbox can delete the
# table, and `dev` reaches root through the nested daemon's socket (and through sudo, if
# SANDBOX_SUDO=true). (sandbox.sh refuses `--network host`, with which these rules would be the HOST's.)
block_local_network() {
  local ext gw dns4 dns6 entry allow4=() allow6=() rules=()
  if [[ "${SANDBOX_BLOCK_LOCAL_NETWORK:-true}" != "true" ]]; then
    echo "[sandbox] local network: reachable (SANDBOX_BLOCK_LOCAL_NETWORK=${SANDBOX_BLOCK_LOCAL_NETWORK})"
    return 0
  fi
  ext="$(ip -o route show default 2>/dev/null | awk '{ print $5; exit }')" || ext=""
  if [[ -z "${ext}" ]]; then
    return 0  # no route out (--network none): nothing to block
  fi
  gw="$(ip -o route show default 2>/dev/null | awk '{ print $3; exit }')" || gw=""
  dns4="$(awk '/^nameserver/ && $2 !~ /:/ { print $2 }' /etc/resolv.conf 2>/dev/null | paste -sd, -)" || dns4=""
  dns6="$(awk '/^nameserver/ && $2 ~ /:/ { print $2 }' /etc/resolv.conf 2>/dev/null | paste -sd, -)" || dns6=""
  for entry in ${SANDBOX_LOCAL_NETWORK_ALLOW-}; do
    if [[ "${entry}" == *:* ]]; then allow6+=("${entry}"); else allow4+=("${entry}"); fi
  done
  [[ -z "${dns4}" ]] || rules+=("ip daddr { ${dns4} } meta l4proto { tcp, udp } th dport 53 accept")
  [[ -z "${dns6}" ]] || rules+=("ip6 daddr { ${dns6} } meta l4proto { tcp, udp } th dport 53 accept")
  [[ "${#allow4[@]}" -eq 0 ]] || rules+=("ip daddr { $(IFS=,; echo "${allow4[*]}") } accept")
  [[ "${#allow6[@]}" -eq 0 ]] || rules+=("ip6 daddr { $(IFS=,; echo "${allow6[*]}") } accept")
  [[ -z "${gw}" ]] || rules+=("ip daddr ${gw} counter name rejected reject with icmpx type admin-prohibited")
  if ! nft -f - <<NFT; then
table inet ai_sandbox {
  counter rejected { }
  set local4 {
    type ipv4_addr; flags interval
    elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24,
                 192.168.0.0/16, 198.18.0.0/15, 224.0.0.0/4, 240.0.0.0/4 }
  }
  set local6 {
    type ipv6_addr; flags interval
    elements = { fc00::/7, fe80::/10, ff00::/8 }
  }
  chain guard {
    ct state established,related accept
    meta l4proto ipv6-icmp accept
    $(printf '%s\n    ' "${rules[@]}")
    ip daddr @local4 counter name rejected reject with icmpx type admin-prohibited
    ip6 daddr @local6 counter name rejected reject with icmpx type admin-prohibited
  }
  chain output { type filter hook output priority 0; policy accept; oifname "${ext}" jump guard; }
  chain forward { type filter hook forward priority 0; policy accept; oifname "${ext}" jump guard; }
}
NFT
    echo "[sandbox] ERROR: could not block the local network (nft failed), so the sandbox is not started." \
         "Set SANDBOX_BLOCK_LOCAL_NETWORK=false in sandbox.conf to start it with the LAN reachable." >&2
    exit 1
  fi
  local before after target
  before="$(rejected_count)"
  for target in "${gw}" 169.254.169.254; do
    [[ -n "${target}" ]] || continue
    timeout 2 bash -c "exec 3<>/dev/tcp/${target}/9" 2>/dev/null || true
  done
  after="$(rejected_count)"
  if [[ "${after}" -le "${before}" ]]; then  # empty (no counter to read) counts as 0: fails closed
    echo "[sandbox] ERROR: the local-network block is loaded but did not refuse a test connection to" \
         "${gw:-the gateway} or 169.254.169.254, so the sandbox is not started. (Does SANDBOX_LOCAL_NETWORK_ALLOW" \
         "cover both? Otherwise set SANDBOX_BLOCK_LOCAL_NETWORK=false to start without the block.)" >&2
    exit 1
  fi
  echo "[sandbox] local network: blocked, and tested${SANDBOX_LOCAL_NETWORK_ALLOW:+ (except ${SANDBOX_LOCAL_NETWORK_ALLOW})}"
}
rejected_count() {
  nft list counter inet ai_sandbox rejected 2>/dev/null | awk '/packets/ { print $2; exit }' || true
}
block_local_network

# ── sudo, and the devices sandbox.sh passed in ───────────────────────────────
# `dev` has NO sudo unless SANDBOX_SUDO=true: with passwordless sudo, any command a session ran could
# undo everything above (the firewall, the read-only mounts sandbox.sh makes of the files the host runs)
# as root. As Anthropic's reference devcontainer does, root's work is done here, at start, instead. The
# sudo binary stays in the image, so SANDBOX_SUDO=true only has to write the rule. Written (or removed)
# on every start, as the image itself carries none.
#
# This narrows root, it doesn't remove it: `dev` is in the nested daemon's `docker` group, and a
# `docker run --privileged` there is root over this container. Only a rootless nested daemon closes that.
if [[ "${SANDBOX_SUDO:-false}" == "true" ]]; then
  echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev && chmod 0440 /etc/sudoers.d/dev
  echo "[sandbox] sudo: enabled for dev (SANDBOX_SUDO=true)"
  rm -f /usr/local/bin/sudo
else
  rm -f /etc/sudoers.d/dev
  # Without a rule, sudo itself says only "dev is not in the sudoers file", and Claude goes on trying
  # other ways round it. This one, ahead of /usr/bin/sudo on PATH, says what to do instead. A script that
  # asks `sudo -n true` first still gets its "no".
  config_rel="${SANDBOX_CONFIG_REL:-ai-sandbox-configuration}"
  cat > /usr/local/bin/sudo <<EOF
#!/bin/sh
cat >&2 <<'MESSAGE'
sudo: not available - this sandbox runs without root (ai-sandbox's SANDBOX_SUDO is off).
  A system package or tool: add it to ${config_rel}/Dockerfile; the next launch builds it in.
  A device (e.g. /dev/kvm): list it in SANDBOX_DEVICES in ${config_rel}/sandbox.conf.
  Root in every session: set SANDBOX_SUDO=true in ${config_rel}/sandbox.conf (it weakens the sandbox).
These are changes for the person at the host to make; sandbox.conf is read-only in here.
MESSAGE
exit 1
EOF
  chmod 0755 /usr/local/bin/sudo
fi

# ── What Claude should know about this sandbox ───────────────────────────────
# A managed-policy CLAUDE.md (Claude Code reads /etc/claude-code/CLAUDE.md in every session, and nothing
# a session runs as dev can change it): which paths are read-only, that there is no sudo, that the local
# network is blocked, and where the published ports are. Without it, Claude meets each one as a bare
# "Read-only file system" or "Connection refused" and tends to try ways round it (chmod, a copy elsewhere,
# another address) instead of telling the user what to change. Written on every start, from the settings
# sandbox.sh passed in.
write_claude_note() {
  local config_rel="${SANDBOX_CONFIG_REL:-ai-sandbox-configuration}" path
  echo "# The ai-sandbox sandbox"
  echo
  echo "This session runs in a disposable Docker container (ai-sandbox). Only the project is mounted from"
  echo "the host. These limits are deliberate: don't work round them (chmod, remounting, copying a file"
  echo "elsewhere, another address). Tell the user what to change on the host instead."
  echo
  if [[ -n "${SANDBOX_PROTECTED-}" ]]; then
    echo "- **Read-only paths.** These paths in the project are mounted read-only, because tools on the"
    echo "  host (git, IntelliJ, Claude, direnv) run or load them. A write fails with \"Read-only file"
    echo "  system\". If one needs changing, show the user the change to make on the host:"
    for path in ${SANDBOX_PROTECTED}; do echo "  - \`${path}\`"; done
  fi
  if [[ "${SANDBOX_SUDO:-false}" != "true" ]]; then
    echo "- **No sudo or root.** A system package or tool belongs in \`${config_rel}/Dockerfile\` (the next"
    echo "  launch builds it in). Root in every session is \`SANDBOX_SUDO=true\` in"
    echo "  \`${config_rel}/sandbox.conf\`, which weakens the sandbox."
  fi
  if [[ "${SANDBOX_BLOCK_LOCAL_NETWORK:-true}" == "true" ]]; then
    echo "- **No local network.** The internet works, but the LAN, the host machine and link-local"
    echo "  addresses (169.254.169.254 among them) are refused (\"administratively prohibited\")."
    echo "  An address the project needs goes in \`SANDBOX_LOCAL_NETWORK_ALLOW\` in \`sandbox.conf\`."
  fi
  if [[ -n "${SANDBOX_PUBLISHED_PORTS-}" ]]; then
    echo "- **Ports.** These are published to the host, on its 127.0.0.1 only: ${SANDBOX_PUBLISHED_PORTS}"
    echo "  (as \`host:container\`, or a container port the host picks a port for). A server the user should"
    echo "  open on the host must listen on 0.0.0.0 inside, on the container port. Other ports can't be"
    echo "  reached from the host. \`SANDBOX_PORTS\` in \`sandbox.conf\` sets them."
  fi
  echo "- **Git.** You can commit, but not push, unless the user runs \`gh auth login\` in this session."
  echo "  Settings in .git/config that make git run a program (hooks path, fsmonitor, pager, filters,"
  echo "  aliases, ...) are reported to the user when the sandbox stops."
}
# shellcheck disable=SC2310  # it only echoes; a failure here is the redirect's
write_claude_note > /etc/claude-code/CLAUDE.md \
  || echo "[sandbox] WARN: could not write Claude's notes on the sandbox (/etc/claude-code/CLAUDE.md)" >&2
# Each device in SANDBOX_DEVICES (e.g. /dev/kvm) arrives root:<the host's group for it>, a group `dev`
# isn't in - which used to take a `sudo chmod`. Its node here is this container's own copy, so it is handed
# to a group `dev` joins (before setpriv --init-groups reads dev's groups, below); the host's is untouched.
read -ra devices <<< "${SANDBOX_DEVICE_PATHS-}"
if [[ "${#devices[@]}" -gt 0 ]]; then
  getent group sandbox-devices >/dev/null || groupadd -r sandbox-devices
  usermod -aG sandbox-devices dev
  for device in "${devices[@]}"; do
    { chgrp sandbox-devices "${device}" && chmod g+rw "${device}"; } \
      || echo "[sandbox] WARN: could not open ${device} to dev" >&2
  done
fi

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
# Claude's temporary directory (CLAUDE_CODE_TMPDIR, bind-mounted by sandbox.sh): Claude refuses one
# that is not its user's, and makes it private (0700) itself, so it must be dev's before Claude starts.
if [[ -n "${CLAUDE_CODE_TMPDIR-}" ]]; then
  { mkdir -p "${CLAUDE_CODE_TMPDIR}" && chown dev:dev "${CLAUDE_CODE_TMPDIR}" && chmod 700 "${CLAUDE_CODE_TMPDIR}"; } \
    || echo "[sandbox] WARN: could not hand Claude's temporary directory ${CLAUDE_CODE_TMPDIR} to dev" >&2
fi

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

# ── A command that must run as root (sandbox.sh prune) ───────────────────────
# `prune` with no sandbox running starts one to clean the nested daemon's data, which takes root - once
# `sudo bash -c ...` as dev, but dev has no sudo now. Only whoever starts the container can set this (it
# is a `docker run -e`), and that is the host, which is root over the container anyway. It is unset for
# everything else, so a session's own processes never see it.
if [[ -n "${SANDBOX_ROOT_COMMAND-}" ]]; then
  root_command="${SANDBOX_ROOT_COMMAND}"
  unset SANDBOX_ROOT_COMMAND
  exec bash -c "${root_command}"
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
# The working directory: the project's host path, which sandbox.sh mounts as well as /work where it
# can (SANDBOX_WORKDIR; see mirrored_path there), so the paths Claude prints open on the host.
workdir="${SANDBOX_WORKDIR:-/work}"
if [[ ! -d "${workdir}" ]]; then
  echo "[sandbox] WARN: SANDBOX_WORKDIR ${workdir} is not mounted - working in /work" >&2
  workdir=/work
fi
cd "${workdir}"
export HOME=/home/dev USER=dev LOGNAME=dev SHELL=/bin/bash
exec setpriv --reuid=dev --regid=dev --init-groups /usr/local/bin/sandbox-launch.sh "$@"
