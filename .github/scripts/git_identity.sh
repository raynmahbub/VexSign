#!/usr/bin/env bash
# Configure the git identity used for commits made by automation.
#
# Every commit a workflow creates is
# credited to the VexSign developer - the repository owner - instead of to
# "github-actions[bot]". The identity is resolved in this order:
#
#   1. GIT_IDENTITY_NAME / GIT_IDENTITY_EMAIL   (repository variables
#      AUTOMATION_GIT_NAME / AUTOMATION_GIT_EMAIL passed in by the workflow)
#   2. The GitHub profile of the repository owner: display name (or login) and
#      the account's noreply address <id>+<login>@users.noreply.github.com,
#      which GitHub links to the owner's account (avatar + contribution graph).
#
# Exports GIT_AUTHOR_* / GIT_COMMITTER_* for later steps via GITHUB_ENV and
# sets them on the local git config.
set -euo pipefail

owner="${GITHUB_REPOSITORY_OWNER:-${GITHUB_REPOSITORY%%/*}}"
name="${GIT_IDENTITY_NAME:-}"
email="${GIT_IDENTITY_EMAIL:-}"

if [ -z "${name}" ] || [ -z "${email}" ]; then
  api="${GITHUB_API_URL:-https://api.github.com}"
  profile="{}"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    profile="$(curl -fsSL --max-time 20 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      "${api}/users/${owner}" || echo '{}')"
  fi
  login="$(printf '%s' "${profile}" | jq -r '.login // empty')"
  id="$(printf '%s' "${profile}" | jq -r '.id // empty')"
  display="$(printf '%s' "${profile}" | jq -r '.name // empty')"

  login="${login:-${owner}}"
  if [ -z "${name}" ]; then
    name="${display:-${login}}"
  fi
  if [ -z "${email}" ]; then
    if [ -n "${id}" ]; then
      email="${id}+${login}@users.noreply.github.com"
    else
      email="${login}@users.noreply.github.com"
    fi
  fi
fi

# Trim stray whitespace (GitHub profile names may carry a trailing space).
name="$(printf '%s' "${name}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
email="$(printf '%s' "${email}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"

git config user.name "${name}"
git config user.email "${email}"

echo "Automation commits will be credited to: ${name} <${email}>"

if [ -n "${GITHUB_ENV:-}" ]; then
  {
    echo "GIT_AUTHOR_NAME=${name}"
    echo "GIT_AUTHOR_EMAIL=${email}"
    echo "GIT_COMMITTER_NAME=${name}"
    echo "GIT_COMMITTER_EMAIL=${email}"
  } >> "${GITHUB_ENV}"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "name=${name}"
    echo "email=${email}"
  } >> "${GITHUB_OUTPUT}"
fi
