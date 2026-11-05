#!/usr/bin/env bash
#
# rewrite-merge-messages.sh
#
# Replace historical "Merge pull request #N from ..." merge commit messages
# with the message of the commit that was merged (the merge's second parent).
# The merge topology is preserved; only merge commit messages change.
#
# The rewrite runs in a throwaway clone. The script never pushes and never
# modifies the checkout it is invoked from. It writes a bundle, verifies that
# the resulting tree is byte-identical to the original, and prints the exact
# force-push command for a human to review and run.
#
# Usage:
#   tools/rewrite-merge-messages.sh [options]
#
#   --source <url|path>  Repository to clone (default: this repo's origin)
#   --branch <name>      Branch to rewrite (default: main)
#   --bundle <path>      Output bundle (default: ./vexsign-main-rewritten.bundle)
#   --pr-numbers         Keep traceability: "subject (#74)" instead of just the
#                        original message
#   --keep               Keep the temporary clone (prints its path)
#   --force              Overwrite an existing bundle
#   -h, --help           Show this help
#
# Requires: bash, git, a full clone available from --source, and network access
# unless --source is a local repository.
#
set -euo pipefail

usage() {
    cat <<'EOF'
rewrite-merge-messages.sh

Replace historical "Merge pull request #N from ..." merge commit messages
with the message of the commit that was merged (the merge's second parent).
The merge topology is preserved; only merge commit messages change.

The rewrite runs in a throwaway clone. The script never pushes and never
modifies the checkout it is invoked from. It writes a bundle, verifies that
the resulting tree is byte-identical to the original, and prints the exact
force-push command for a human to review and run.

Usage:
  tools/rewrite-merge-messages.sh [options]

  --source <url|path>  Repository to clone (default: this repo's origin)
  --branch <name>      Branch to rewrite (default: main)
  --bundle <path>      Output bundle (default: ./vexsign-main-rewritten.bundle)
  --pr-numbers         Keep traceability: "subject (#74)" instead of just the
                       original message
  --keep               Keep the temporary clone (prints its path)
  --force              Overwrite an existing bundle
  -h, --help           Show this help

Requires: bash, git, a full clone available from --source, and network access
unless --source is a local repository.
EOF
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SOURCE="$(git -C "${SCRIPT_DIR}/.." remote get-url origin 2>/dev/null || true)"

SOURCE="${SOURCE:-${DEFAULT_SOURCE:-https://github.com/raynmahbub/VexSign.git}}"
BRANCH="main"
BUNDLE="vexsign-main-rewritten.bundle"
PR_NUMBERS=0
KEEP=0
FORCE=0

while (( $# )); do
    case "$1" in
        --source)     SOURCE="${2:?--source needs a value}"; shift 2 ;;
        --branch)     BRANCH="${2:?--branch needs a value}"; shift 2 ;;
        --bundle)     BUNDLE="${2:?--bundle needs a value}"; shift 2 ;;
        --pr-numbers) PR_NUMBERS=1; shift ;;
        --keep)       KEEP=1; shift ;;
        --force)      FORCE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown argument: $1 (try --help)" ;;
    esac
done

command -v git >/dev/null 2>&1 || die "git is required"

# Normalise the bundle path before entering the temporary clone.
BUNDLE_DIR="$(cd "$(dirname "${BUNDLE}")" 2>/dev/null && pwd)" \
    || die "bundle directory does not exist: $(dirname "${BUNDLE}")"
BUNDLE="${BUNDLE_DIR}/$(basename "${BUNDLE}")"

if [[ -e "${BUNDLE}" && "${FORCE}" -ne 1 ]]; then
    die "bundle already exists: ${BUNDLE} (pass --force to overwrite)"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/vexsign-rewrite.XXXXXX")"
cleanup() {
    if (( KEEP )); then
        printf 'temporary clone kept at %s\n' "${WORK}" >&2
    else
        rm -rf "${WORK}"
    fi
}
trap cleanup EXIT

printf 'Cloning %s ...\n' "${SOURCE}"
git clone --quiet --no-local "${SOURCE}" "${WORK}/repo"
cd "${WORK}/repo"
git checkout --quiet "${BRANCH}"

if [[ "$(git rev-parse --is-shallow-repository)" == "true" ]]; then
    die "the clone is shallow; a full history is required"
fi

OLD_TIP="$(git rev-parse "${BRANCH}")"
OLD_TREE="$(git rev-parse "${BRANCH}^{tree}")"
OLD_COMMITS="$(git rev-list --count "${BRANCH}")"
OLD_MERGES="$(git rev-list --merges --count "${BRANCH}")"

MSG_DIR="${WORK}/messages"
mkdir -p "${MSG_DIR}"

RENAMED=0
while IFS= read -r commit; do
    [[ -n "${commit}" ]] || continue
    subject="$(git log -1 --format=%s "${commit}")"
    [[ "${subject}" == "Merge pull request "* ]] || continue

    if (( PR_NUMBERS )); then
        pr="$(printf '%s\n' "${subject}" | sed -n 's/^Merge pull request #\([0-9]*\).*/\1/p')"
        if [[ -n "${pr}" ]]; then
            git log -1 --format=%B "${commit}^2" \
                | sed "1s/\$/ (#${pr})/" > "${MSG_DIR}/${commit}"
        else
            git log -1 --format=%B "${commit}^2" > "${MSG_DIR}/${commit}"
        fi
    else
        git log -1 --format=%B "${commit}^2" > "${MSG_DIR}/${commit}"
    fi
    RENAMED=$((RENAMED + 1))
done < <(git rev-list --merges "${BRANCH}")

if (( RENAMED == 0 )); then
    printf 'No "Merge pull request ..." commits found on %s; nothing to do.\n' "${BRANCH}"
    exit 0
fi

printf 'Rewriting %d merge commit message(s) on %s ...\n' "${RENAMED}" "${BRANCH}"
export MSG_DIR
if ! FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter '
        if [ -f "${MSG_DIR}/${GIT_COMMIT}" ]; then
            cat "${MSG_DIR}/${GIT_COMMIT}"
        else
            cat
        fi
    ' -- "${BRANCH}" >"${WORK}/filter.log" 2>&1; then
    cat "${WORK}/filter.log" >&2
    die "git filter-branch failed"
fi

NEW_TIP="$(git rev-parse "${BRANCH}")"
NEW_TREE="$(git rev-parse "${BRANCH}^{tree}")"
NEW_COMMITS="$(git rev-list --count "${BRANCH}")"
NEW_MERGES="$(git rev-list --merges --count "${BRANCH}")"
REMAINING="$(git log --format=%s "${BRANCH}" | grep -c '^Merge pull request' || true)"

[[ "${NEW_TREE}" == "${OLD_TREE}" ]] \
    || die "tree changed (${OLD_TREE} -> ${NEW_TREE}); refusing to bundle"
[[ "${NEW_COMMITS}" == "${OLD_COMMITS}" ]] \
    || die "commit count changed (${OLD_COMMITS} -> ${NEW_COMMITS})"
[[ "${NEW_MERGES}" == "${OLD_MERGES}" ]] \
    || die "merge count changed (${OLD_MERGES} -> ${NEW_MERGES})"
[[ "${REMAINING}" == "0" ]] \
    || die "${REMAINING} 'Merge pull request' subject(s) remain"

if ! diff -q \
        <(git log --no-merges --format='%B%x00' "${OLD_TIP}") \
        <(git log --no-merges --format='%B%x00' "${BRANCH}") >/dev/null; then
    die "a non-merge commit message changed; refusing to bundle"
fi

rm -f "${BUNDLE}"
git bundle create "${BUNDLE}" HEAD "${BRANCH}" >/dev/null

if command -v sha256sum >/dev/null 2>&1; then
    BUNDLE_SHA="$(sha256sum "${BUNDLE}" | awk '{print $1}')"
else
    BUNDLE_SHA="$(shasum -a 256 "${BUNDLE}" | awk '{print $1}')"
fi

cat <<EOF

Rewrote ${RENAMED} merge message(s); kept ${NEW_MERGES} merge commits.
  old tip : ${OLD_TIP}
  new tip : ${NEW_TIP}
  tree    : ${NEW_TREE} (unchanged)
  commits : ${NEW_COMMITS}
  bundle  : ${BUNDLE}
  sha256  : ${BUNDLE_SHA}

The bundle is complete and was verified locally. Nothing was pushed.

Review it:
  git fetch "${BUNDLE}" ${BRANCH}:refs/heads/main-rewritten
  git diff --stat ${BRANCH} main-rewritten          # must be empty
  git log --oneline -20 main-rewritten

Apply it (review the force-push first):
  git push --force-with-lease=${BRANCH}:${OLD_TIP} origin main-rewritten:${BRANCH}

Every collaborator must re-sync afterwards:
  git fetch && git reset --hard origin/${BRANCH}

If ${BRANCH} is protected, allow force pushes temporarily and restore the rule
afterwards. Keep a backup of the old tip until everyone has moved:
  git branch backup/${BRANCH}-before-rewrite ${OLD_TIP}
EOF
