#!/usr/bin/env bash
# First-run / per-open setup for the sandbox. Runs as the `dev` user with CWD = /work, for interactive
# sessions only (RUN_SETUP, see entrypoint.sh). Every step is GUARDED so re-opening the environment is
# a fast no-op when nothing has changed; real work happens only on a fresh sandbox or after a relevant
# file changes. Failures are non-fatal (warn + continue) so the session still opens if you're offline.
#
# The steps here apply to any project and detect whether they are relevant; anything specific to one
# project goes in its ai-sandbox-configuration/setup.d/*.sh, which run last (see step 4).
set -uo pipefail

STATE_DIR="${HOME}/.claude/.sandbox-state"
mkdir -p "${STATE_DIR}"

step()  { printf '\033[36m[setup]\033[0m %s\n' "$*"; }
skip()  { printf '\033[2m[setup] %s (up to date)\033[0m\n' "$*"; }
warn()  { printf '\033[33m[setup] WARN: %s\033[0m\n' "$*" >&2; }
# A step this project has nothing for - distinct from "up to date", which implies it applies here.
none()  { printf '\033[2m[setup] %s (not applicable)\033[0m\n' "$*"; }

cd /work || { warn "no /work mount"; exit 0; }

# ── 1. Git submodules — initialise any the project declares ──────────────────
if git submodule status 2>/dev/null | grep -q '^-'; then
  step "initialising git submodules..."
  git submodule update --init || warn "submodule init failed"
else
  skip "git submodules"
fi

# ── 2. npm — for every dir in SANDBOX_NPM_DIRS that HAS a package.json ───────
# Opt-in (SANDBOX_NPM_DIRS in sandbox.conf: space-separated, relative to /work, "." = the root), and
# even then checked rather than assumed: `npm --prefix X install` against a missing X still WRITES
# `X/package-lock.json` before it errors, so an unguarded install litters the project with a stray
# lockfile. An entry with no package.json is a mistake in the settings, so it warns. Re-runs only when
# the lockfile changes (or node_modules is gone).
read -ra npm_dirs <<< "${SANDBOX_NPM_DIRS-}"
npm_found=0
for dir in ${npm_dirs+"${npm_dirs[@]}"}; do
  if [[ ! -f "${dir}/package.json" ]]; then
    warn "SANDBOX_NPM_DIRS names ${dir}, which has no package.json"
    continue
  fi
  npm_found=1
  hash_file="${STATE_DIR}/npm-${dir//[^a-zA-Z0-9]/-}.sha"
  current_hash="$(sha256sum "${dir}/package-lock.json" 2>/dev/null | cut -d' ' -f1)"
  if [[ ! -d "${dir}/node_modules" ]] || [[ "${current_hash}" != "$(cat "${hash_file}" 2>/dev/null || true)" ]]; then
    # `ci` wherever there is a lockfile: `install` trusts node_modules/.package-lock.json over what is
    # actually on disk, so it reports "up to date" on a tree the hidden lockfile misdescribes, and it can
    # rewrite the project's lockfile as well. `ci` rebuilds node_modules from the real one.
    npm_command=install
    if [[ -f "${dir}/package-lock.json" ]]; then npm_command=ci; fi
    step "running npm ${npm_command} in ${dir}..."
    if npm --prefix "${dir}" "${npm_command}" --no-audit --no-fund; then
      echo "${current_hash}" > "${hash_file}"
    else
      warn "npm ${npm_command} failed in ${dir}"
    fi
  else
    skip "npm dependencies (${dir})"
  fi
done
[[ "${npm_found}" -eq 1 ]] || none "npm (SANDBOX_NPM_DIRS has no package.json)"

# ── 3. Claude Code PreToolUse guards — prove they work BEFORE the session ────
# A project's guards (.claude/hooks/) are often the only thing standing between an agent and an edit it
# must never make, and they fail SILENTLY: an unregistered, non-executable or jq-less hook simply never
# blocks anything, and nothing in the session says so. So they are exercised here, before any work
# happens, in the environment that will actually run them.
GUARD_TESTS=".claude/hooks/tests/run-hook-tests.sh"
if [[ ! -x "${GUARD_TESTS}" ]]; then
  none "Claude Code hook guards"
elif ! command -v jq >/dev/null 2>&1; then
  warn "jq is missing - the PreToolUse guards cannot parse a hook payload and will NOT block anything"
elif guard_output="$("${GUARD_TESTS}" 2>&1)"; then
  # Last line only (the "All N cases passed" summary), via parameter expansion rather than `| tail -1`, so
  # there is no pipeline whose exit status would be masked inside the message.
  skip "Claude Code hook guards (${guard_output##*$'\n'})"
else
  warn "the PreToolUse guards are NOT behaving as expected - they may not be protecting this session:"
  printf '%s\n' "${guard_output}" >&2
fi

# ── 4. The project's own steps (ai-sandbox-configuration/setup.d/*.sh) ───────
# Run in name order, each in its own bash with CWD = /work. The helpers above (step/skip/warn/none)
# and STATE_DIR are exported, so a hook reports in the same style and can keep its own "already done"
# markers under STATE_DIR (persisted with ~/.claude). Same rule as every step here: guard the work,
# and warn rather than fail - a non-zero exit is reported, never fatal.
export STATE_DIR
export -f step skip warn none
for hook in /opt/ai-sandbox/config/setup.d/*.sh; do
  [[ -f "${hook}" ]] || continue
  bash "${hook}" || { status=$?; warn "setup hook ${hook##*/} failed (exit ${status})"; }
done

step "ready."
