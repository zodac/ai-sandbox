#!/usr/bin/env bash
# Download Playwright's Chromium browser binary on the first interactive open (runs as `dev`, with
# CWD = /work and the step/skip/warn/none helpers from ai-sandbox's setup.sh).
#
# Only the browser BINARY is handled here: it is cached in the persistent `pw` volume (sandbox.conf),
# so it just needs downloading once - guarded by a marker + a non-empty cache. Its OS shared libraries
# are baked into the image (this directory's Dockerfile).
#
# Gated on the project DECLARING Playwright, not on a directory existing: `npx playwright` in a dir
# that doesn't use it would download the package itself just to run it. Override the dirs with
# SANDBOX_PW_DIRS (sandbox.conf's SANDBOX_ENV).
set -uo pipefail

PW_MARKER="${STATE_DIR}/playwright-installed"
PW_CACHE="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"
read -ra pw_dirs <<< "${SANDBOX_PW_DIRS:-tests .}"
pw_dir=""
for dir in "${pw_dirs[@]}"; do
  if [[ -f "${dir}/package.json" ]] && grep -qE '"(@playwright/|playwright)' "${dir}/package.json"; then
    pw_dir="${dir}"
    break
  fi
done
if [[ -z "${pw_dir}" ]]; then
  none "Playwright (not a dependency)"
elif [[ ! -f "${PW_MARKER}" ]] || [[ -z "$(ls -A "${PW_CACHE}" 2>/dev/null || true)" ]]; then
  step "downloading Playwright Chromium (first run only)..."
  if (cd "${pw_dir}" && npx --yes playwright install chromium); then
    touch "${PW_MARKER}"
  else
    warn "playwright browser download failed"
  fi
else
  skip "Playwright browser"
fi
