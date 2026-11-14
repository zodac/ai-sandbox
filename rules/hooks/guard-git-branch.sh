#!/usr/bin/env bash
#
# PreToolUse guard (Bash) for commands that would create a git branch - the enforcement behind organisation
# rule 1 (rules/CLAUDE.md: never use a feature branch; work on the branch that is checked out).
#
# Worth a hook rather than prose alone because the cost is asymmetric: work committed onto an unexpected
# branch is invisible on the main branch and easy to lose track of, while the guard costs nothing when the
# user genuinely wants a branch (they create it themselves, or approve this call).
#
# Shared by every project that uses ai-sandbox: `ai-sandbox/sandbox.sh init` registers it in the project's
# .claude/settings.json as "$CLAUDE_PROJECT_DIR"/<submodule>/rules/hooks/guard-git-branch.sh, so it applies on
# the host as well as in the sandbox, and a change here reaches a project when it moves to the new tag.
# Its cases are pinned in tests/run-hook-tests.sh, which the sandbox's setup.sh runs on every open.
#
# Deliberately narrow: it matches only the branch-CREATING forms. Switching to an existing branch, listing
# branches, renaming and deleting one are all left alone, as is text that merely quotes a command.
#
# Contract: reads the hook payload on stdin, exits 2 to block (stderr is fed back to the model), 0 to allow.

set -euo pipefail

readonly BLOCK=2

payload="$(cat)"
command_text="$(jq -r '.tool_input.command // ""' <<<"${payload}")"

if [[ -z "${command_text}" ]]; then
    exit 0
fi

# At the start of a command (the line, or after ; & | && ||), `git`, any `-C <dir>`, then one of:
#   checkout -b/-B          (also bundled, e.g. -qb)
#   switch -c/-C            (also bundled)
#   branch <name>           optionally after -t/--track/-f/--force; not -d/-D/-m/-l/-a/-r/--list
#   branch -c/-C/--copy     (copies a branch: a new one)
#   worktree add ... -b/-B  (anywhere among its arguments)
readonly START='(^|[;&|])[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:];&|]+)*[[:space:]]+'
readonly CHECKOUT='checkout[[:space:]]+-[[:alnum:]]*[bB]'
readonly SWITCH='switch[[:space:]]+-[[:alnum:]]*[cC]'
readonly BRANCH='branch[[:space:]]+((-t|--track|-f|--force)[[:space:]]+)*([^-[:space:]]|-[cC]([[:space:]]|$)|--copy([[:space:]]|$))'
readonly WORKTREE='worktree[[:space:]]+add([[:space:]]+[^[:space:];&|]+)*[[:space:]]+-[bB]([[:space:]]|$)'
readonly CREATE_PATTERN="${START}(${CHECKOUT}|${SWITCH}|${BRANCH}|${WORKTREE})"

if [[ "${command_text}" =~ ${CREATE_PATTERN} ]]; then
    cat >&2 <<MSG
BLOCKED: this command creates a git branch, which needs explicit permission (organisation rule 1).

Work on the branch that is currently checked out - no feature branches, no working branches, however large
the change is. If a branch genuinely seems necessary, ask the user first and proceed only on an explicit yes.

Blocked command: ${command_text}
MSG
    exit "${BLOCK}"
fi

exit 0
