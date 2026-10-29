#!/bin/sh
set -eu

# shellcheck disable=SC2154  # GITHUB_SERVER_URL and GITHUB_REPOSITORY are injected by the GitHub Actions runner
GIT_REPO_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"
previous_git_tag="${1:-}"

# Get commit messages
if [ -z "${previous_git_tag}" ]; then
    commit_messages=$(git log --pretty=format:"%h%n%B%n---END---")
else
    commit_messages=$(git log "${previous_git_tag}"..HEAD --pretty=format:"%h%n%B%n---END---")
fi

# Temporary files
tmp_commits=$(mktemp)
tmp_output=$(mktemp)
printf "%s\n" "${commit_messages}" >"${tmp_commits}"

# Extract commit info and categorize
commit_hash=""
commit_message=""
categories_tmp=$(mktemp)

while IFS= read -r line || [ -n "${line}" ]; do
    if [ "${line}" = "---END---" ]; then
        printf "%s" "${commit_message}" | while IFS= read -r msg_line || [ -n "${msg_line}" ]; do
            case "${msg_line}" in
                \[*\]*)
                    category=$(printf "%s" "${msg_line}" | sed -n 's/^\[\([A-Za-z0-9_. -]*\)\] .*/\1/p')
                    message=$(printf "%s" "${msg_line}" | sed -n 's/^\[[^]]*\] \(.*\)/\1/p')
                    if [ -n "${category}" ]; then
                        printf "%s|%s|%s\n" "${category}" "${commit_hash}" "${message}" >>"${categories_tmp}"
                    fi
                ;;
                *) ;;  # non-categorised line, ignore
            esac
        done
        commit_hash=""
        commit_message=""
        elif [ -z "${commit_hash}" ]; then
        commit_hash="${line}"
    else
        commit_message="${commit_message}${line}
"
    fi
done <"${tmp_commits}"

# Sort categories alphabetically
categories_sorted=$(awk -F'|' '{print $1}' "${categories_tmp}" | sort -u)

# Build changelog
{
    printf "%s\n" "${categories_sorted}" | while IFS= read -r cat; do
        [ -n "${cat}" ] || continue
        echo "**[${cat}]**"
        awk -F'|' -v cat="${cat}" -v repo="${GIT_REPO_URL}" '
        $1 == cat {
            printf "- [[%s](%s/commit/%s)] %s\n", $2, repo, $2, $3
        }
        ' "${categories_tmp}"
        echo ""
    done
} >>"${tmp_output}"

# Output changelog content for GitHub Actions
# shellcheck disable=SC2154  # GITHUB_ENV is injected by the GitHub Actions runner
{
    echo "changelog_content<<EOF"
    cat "${tmp_output}"
    echo "EOF"
} >>"${GITHUB_ENV}"

# Cleanup
rm -f "${tmp_commits}" "${categories_tmp}" "${tmp_output}"
