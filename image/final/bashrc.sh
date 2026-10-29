# shellcheck shell=bash
# Sourced by the `dev` user's ~/.bashrc (interactive shells only - an agent's non-interactive Bash tool
# calls never read it, so they don't fill the history).
#
# Persistent shell history. ~/.bash_history would live in the container's writable layer, which --rm
# deletes on teardown, so it moves into the persisted ~/.claude bind mount (the checkout's
# ai-sandbox-configuration/.claude-history), next to launch.sh's own state. And because bash normally
# writes history only when a shell exits cleanly - which a closed IntelliJ tab (the `docker exec`
# client killed under it) never is - every command is appended the moment it runs. A new shell, in this
# container or the next one, starts with everything earlier shells ran (`history -n` in a shell that
# was already open pulls in what the others have added since).
if [[ -d /home/dev/.claude ]]; then
  mkdir -p /home/dev/.claude/.sandbox-state
  HISTFILE=/home/dev/.claude/.sandbox-state/bash_history
fi
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth
shopt -s histappend
PROMPT_COMMAND="history -a${PROMPT_COMMAND:+; ${PROMPT_COMMAND}}"
