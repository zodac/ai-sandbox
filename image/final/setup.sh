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

# ── 3. Playwright — the browser for each SANDBOX_NPM_DIRS dir that declares it ─
# Only the browser BINARY: its OS shared libraries are the project's to bake into its image (Playwright
# is not in the base - see examples/java-maven's playwright-deps stage). Each Playwright release expects
# its own browser revision, so the marker records the VERSION it last installed for: an upgrade downloads
# the new revision, and an unchanged version with a non-empty cache is a no-op.
#
# Gated on the project DECLARING Playwright, and only in the dirs step 2 installed: `--no-install`,
# because a bare `npx playwright` with no node_modules would fetch whatever is newest, and with it a
# browser revision the project's own version cannot use.
pw_cache="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"
pw_found=0
for dir in ${npm_dirs+"${npm_dirs[@]}"}; do
  if [[ ! -f "${dir}/package.json" ]] || ! grep -qE '"(@playwright/|playwright)' "${dir}/package.json"; then
    continue
  fi
  pw_found=1
  pw_version="$(cd "${dir}" && npx --no-install playwright --version 2>/dev/null)"
  pw_version="${pw_version#Version }"
  if [[ -z "${pw_version}" ]]; then
    warn "${dir} declares Playwright, but it is not installed there (did npm fail above?)"
    continue
  fi
  pw_marker="${STATE_DIR}/playwright-${dir//[^a-zA-Z0-9]/-}"
  pw_cached="$(ls -A "${pw_cache}" 2>/dev/null || true)"
  if [[ "$(cat "${pw_marker}" 2>/dev/null || true)" == "${pw_version}" && -n "${pw_cached}" ]]; then
    skip "Playwright browser (${dir}: ${pw_version})"
    continue
  fi
  # Outside a cache volume the download lands in the container's writable layer, which `--rm` deletes:
  # every launch would download ~150MB again.
  if ! mountpoint -q "${pw_cache}" 2>/dev/null; then
    warn "${pw_cache} is not a cache volume, so this download is lost on teardown - add" \
         "pw:${pw_cache} to SANDBOX_CACHE_VOLUMES"
  fi
  step "downloading the Chromium for Playwright ${pw_version} (${dir})..."
  if (cd "${dir}" && npx --no-install playwright install chromium); then
    printf '%s\n' "${pw_version}" > "${pw_marker}"
  else
    warn "the Playwright browser download failed in ${dir}"
  fi
done
[[ "${pw_found}" -eq 1 ]] || none "Playwright (not a dependency in SANDBOX_NPM_DIRS)"

# ── 4. Claude's old background jobs ──────────────────────────────────────────
# Each job (~/.claude/jobs/<id>) is deleted once nothing in it has changed for SANDBOX_HISTORY_DAYS.
# launch.sh's cleanupPeriodDays covers session transcripts and their side-car directories, not these, and
# a job's tmp/ can hold gigabytes (one kept a whole emulator image and SDK copy). It goes by the newest
# file in the job, so one still in use stays however long ago it began. A pinned job (jobs/pins.json)
# stays too.
jobs_dir="${HOME}/.claude/jobs"
history_days="${SANDBOX_HISTORY_DAYS:-14}"
if [[ ! "${history_days}" =~ ^[1-9][0-9]*$ ]]; then
  warn "SANDBOX_HISTORY_DAYS is '${history_days}', not a number of days: old background jobs are kept"
elif [[ ! -d "${jobs_dir}" ]]; then
  none "old background jobs (no jobs)"
else
  removed=0
  for job in "${jobs_dir}"/*/; do
    [[ -d "${job}" ]] || continue
    id="$(basename "${job}")"
    grep -qF "\"${id}\"" "${jobs_dir}/pins.json" 2>/dev/null && continue
    recent="$(find "${job}" -type f -mtime "-${history_days}" -print -quit || true)"
    [[ -n "${recent}" ]] && continue
    rm -rf -- "${job}" && removed=$((removed + 1))
  done
  if ((removed > 0)); then
    step "deleted ${removed} background job(s) unchanged for ${history_days} days"
  else
    skip "old background jobs"
  fi
fi

# ── 5. Claude Code PreToolUse guards — prove they work BEFORE the session ────
# Guards are often the only thing standing between an agent and an edit it must never make, and they fail
# SILENTLY: an unregistered, non-executable or jq-less hook simply never blocks anything, and nothing in
# the session says so. So they are exercised here, before any work happens, in the environment that will
# actually run them. Two sets:
#   - the organisation's (ai-sandbox's rules/hooks/), which `sandbox.sh init` registers in the project's
#     .claude/settings.json - so each is also checked for being registered there;
#   - the project's own (.claude/hooks/), if it has any.
# SANDBOX_REPO_DIR is ai-sandbox's directory relative to /work (passed by sandbox.sh; "." in its own
# checkout), empty when it is not inside the project.
run_guard_tests() {  # <label> <test script>
  local output
  if output="$("$2" 2>&1)"; then
    # Last line only (the "All N cases passed" summary), via parameter expansion rather than `| tail -1`,
    # so there is no pipeline whose exit status would be masked inside the message.
    skip "$1 (${output##*$'\n'})"
  else
    warn "$1 are NOT behaving as expected - they may not be protecting this session:"
    printf '%s\n' "${output}" >&2
  fi
}
ORG_HOOKS="${SANDBOX_REPO_DIR:+${SANDBOX_REPO_DIR}/rules/hooks}"
GUARD_TESTS=".claude/hooks/tests/run-hook-tests.sh"
if ! command -v jq >/dev/null 2>&1; then
  warn "jq is missing - the PreToolUse guards cannot parse a hook payload and will NOT block anything"
else
  if [[ -n "${ORG_HOOKS}" && -x "${ORG_HOOKS}/tests/run-hook-tests.sh" ]]; then
    for guard in "${ORG_HOOKS}"/*.sh; do
      [[ -f "${guard}" ]] || continue
      if ! jq -e --arg g "/rules/hooks/${guard##*/}" '[.hooks[]?[]?.hooks[]?.command // empty] | any(contains($g))' \
             .claude/settings.json >/dev/null 2>&1; then
        warn "the organisation guard ${guard##*/} is not registered in .claude/settings.json - run ${SANDBOX_REPO_DIR}/sandbox.sh init on the host"
      fi
    done
    run_guard_tests "organisation hook guards" "${ORG_HOOKS}/tests/run-hook-tests.sh"
  else
    none "organisation hook guards (ai-sandbox is not inside the project)"
  fi
  if [[ -x "${GUARD_TESTS}" ]]; then
    run_guard_tests "the project's hook guards" "${GUARD_TESTS}"
  else
    none "the project's hook guards"
  fi
fi

# ── 6. The project's own steps (ai-sandbox-configuration/setup.d/*.sh) ───────
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
