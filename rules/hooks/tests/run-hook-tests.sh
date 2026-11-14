#!/usr/bin/env bash
#
# Behaviour tests for the organisation's PreToolUse guards in rules/hooks/.
#
# A guard has to draw a narrow line: block `git checkout -b` but not `git checkout master`, block
# `git branch new` but not `git branch -d old`, and leave alone a command that only quotes another. Each of
# those distinctions is a regression waiting to happen, where a false negative is silent and a false positive
# blocks ordinary work - so they are pinned here.
#
# Run directly, or by ai-sandbox/image/final/setup.sh on every interactive open of a sandbox, which also checks
# what this cannot: that the guards are REGISTERED in the project's .claude/settings.json.
#
# A project's own guards are tested by its own .claude/hooks/tests/run-hook-tests.sh.

set -euo pipefail

HOOKS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly HOOKS_DIR

readonly BLOCK=2

passed=0
failed=0
current_hook=""

# Feeds one synthetic PreToolUse payload to the guard under test and compares the verdict. Failures are
# accumulated rather than returned, so no caller has to disable `set -e` to ask for a result.
check() {
    local expect="${1}" payload="${2}" label="${3}"
    local status=0 output="" verdict

    output="$(bash "${HOOKS_DIR}/${current_hook}" <<<"${payload}" 2>&1)" || status=$?

    case "${status}" in
        0) verdict="ALLOW" ;;
        "${BLOCK}") verdict="BLOCK" ;;
        *) verdict="ERROR(${status})" ;;
    esac

    if [[ "${verdict}" == "${expect}" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL [%s] expected %s, got %s: %s\n' "${current_hook}" "${expect}" "${verdict}" "${label}"
        if [[ -n "${output}" ]]; then
            printf '     %s\n' "${output%%$'\n'*}"
        fi
    fi
}

bash_payload() {
    jq -nc --arg command "${1}" '{tool_name: "Bash", tool_input: {command: $command}}'
}

blocks_command() {
    local payload
    payload="$(bash_payload "${1}")"
    check BLOCK "${payload}" "${1}"
}

allows_command() {
    local payload
    payload="$(bash_payload "${1}")"
    check ALLOW "${payload}" "${1}"
}

# ---------------------------------------------------------------------------------------------------------
current_hook="guard-git-branch.sh"
# ---------------------------------------------------------------------------------------------------------

blocks_command "git checkout -b feature/x"
blocks_command "git checkout -B feature/x"
blocks_command "git checkout -qb feature/x"
blocks_command "git switch -c feature/x"
blocks_command "git switch -C feature/x"
blocks_command "git branch new-branch"
blocks_command "git branch --track other origin/other"
blocks_command "git branch -t other origin/other"
blocks_command "git branch -f other HEAD~1"
blocks_command "git branch -c master copy"
blocks_command "git branch --copy master copy"
blocks_command "git -C /work checkout -b tmp"
blocks_command "git worktree add -b feature/x ../x"
blocks_command "git worktree add ../x -b feature/x"
blocks_command "cd /work && git checkout -b tmp"
blocks_command "git status; git switch -c tmp"

allows_command "git checkout master"
allows_command "git checkout main"
allows_command "git switch master"
allows_command "git checkout -- VERSION"
allows_command "git checkout -p VERSION"
allows_command "git branch"
allows_command "git branch -a"
allows_command "git branch -r"
allows_command "git branch --list"
allows_command "git branch -vv"
allows_command "git branch -d old-branch"
allows_command "git branch -D old-branch"
allows_command "git branch -m old-name new-name"
allows_command "git -C /work branch --show-current"
allows_command "git worktree list"
allows_command "git worktree add ../x master"
allows_command "git status --short"
allows_command "git log --oneline -5"
allows_command "echo 'never run git checkout -b'"
allows_command "grep -n 'git switch -c' README.md"

# ---------------------------------------------------------------------------------------------------------

echo
if [[ "${failed}" -eq 0 ]]; then
    echo "All ${passed} organisation guard cases passed"
    exit 0
fi

echo "${failed} of $((passed + failed)) organisation guard cases FAILED"
exit 1
