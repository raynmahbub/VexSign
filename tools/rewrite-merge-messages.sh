#!/usr/bin/env bash
#
# rewrite-merge-messages.sh
#
# Replace historical "Merge pull request #N from ..." merge commit messages
# with the message of the commit that was merged (the merge's second parent).
# Merge topology is preserved; only merge commit messages change. Tags are
# remapped onto the rewritten commits by default, because leaving them behind
# would point releases at commits that are no longer on the branch.
#
# The rewrite runs in a throwaway clone. The script never pushes and never
# modifies the checkout it is invoked from. It writes a bundle, verifies that
# every rewritten branch tree and tag target is byte-identical to the original,
# and prints the exact atomic force-push command for a human to review and run.
#
# Usage:
#   tools/rewrite-merge-messages.sh [options]
#
#   --source <url|path>  Repository to clone (default: this repo's origin)
#   --branch <name>      Branch to rewrite (default: main)
#   --bundle <path>      Output bundle (default: ./vexsign-main-rewritten.bundle)
#   --pr-numbers         Keep traceability: "subject (#74)" instead of just the
#                        original message
#   --[no-]tags          Remap tags too (default: yes)
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
Merge topology is preserved; only merge commit messages change. Tags are
remapped onto the rewritten commits by default.

The rewrite runs in a throwaway clone. The script never pushes and never
modifies the checkout it is invoked from. It writes a bundle, verifies that
every rewritten branch tree and tag target is byte-identical to the original,
and prints the exact atomic force-push command for a human to review and run.

Usage:
  tools/rewrite-merge-messages.sh [options]

  --source <url|path>  Repository to clone (default: this repo's origin)
  --branch <name>      Branch to rewrite (default: main)
  --bundle <path>      Output bundle (default: ./vexsign-main-rewritten.bundle)
  --pr-numbers         Keep traceability: "subject (#74)" instead of just the
                       original message
  --tags               Remap tags onto the rewritten commits (default)
  --no-tags            Rewrite the branch only; leave tags out of the bundle
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
REWRITE_TAGS=1
KEEP=0
FORCE=0

while (( $# )); do
    case "$1" in
        --source)     SOURCE="${2:?--source needs a value}"; shift 2 ;;
        --branch)     BRANCH="${2:?--branch needs a value}"; shift 2 ;;
        --bundle)     BUNDLE="${2:?--bundle needs a value}"; shift 2 ;;
        --pr-numbers) PR_NUMBERS=1; shift ;;
        --tags)       REWRITE_TAGS=1; shift ;;
        --no-tags)    REWRITE_TAGS=0; shift ;;
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

# Record every tag before the rewrite. After filter-branch moves the refs, the
# old tag objects and target commits are still in the object database, so they
# can be compared without racing the rewrite.
TAG_MANIFEST="${WORK}/tags.tsv"
TAG_COUNT=0
: > "${TAG_MANIFEST}"
if (( REWRITE_TAGS )); then
    while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        name="${ref#refs/tags/}"
        old_obj="$(git rev-parse "${ref}")"
        old_type="$(git cat-file -t "${old_obj}")"
        if [[ "${old_type}" != "commit" && "${old_type}" != "tag" ]]; then
            die "tag ${name} does not point to a commit; refusing to guess"
        fi
        old_commit="$(git rev-parse "${ref}^{commit}")" \
            || die "tag ${name} does not resolve to a commit"
        old_tag_tree="$(git rev-parse "${old_commit}^{tree}")"
        printf '%s\t%s\t%s\t%s\t%s\n' \
            "${name}" "${old_obj}" "${old_type}" "${old_commit}" "${old_tag_tree}" \
            >> "${TAG_MANIFEST}"
        TAG_COUNT=$((TAG_COUNT + 1))
    done < <(git for-each-ref --format='%(refname)' refs/tags)
fi

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
if (( REWRITE_TAGS )); then
    if ! FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter '
            if [ -f "${MSG_DIR}/${GIT_COMMIT}" ]; then
                cat "${MSG_DIR}/${GIT_COMMIT}"
            else
                cat
            fi
        ' --tag-name-filter cat -- "${BRANCH}" --tags >"${WORK}/filter.log" 2>&1; then
        cat "${WORK}/filter.log" >&2
        die "git filter-branch failed"
    fi
else
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

# Annotated tag messages and taggers must survive the rewrite; a tag's target
# tree must be identical, and a tag on the rewritten branch must stay on it.
tag_message() {
    git cat-file tag "$1" | awk 'seen { print } /^$/ { seen = 1 }'
}

if (( REWRITE_TAGS )); then
    NEW_TAG_COUNT="$(git for-each-ref refs/tags | wc -l | tr -d ' ')"
    [[ "${NEW_TAG_COUNT}" == "${TAG_COUNT}" ]] \
        || die "tag count changed (${TAG_COUNT} -> ${NEW_TAG_COUNT})"

    CHECKED_TAGS=0
    while IFS=$'\t' read -r name old_obj old_type old_commit old_tag_tree; do
        [[ -n "${name}" ]] || continue
        CHECKED_TAGS=$((CHECKED_TAGS + 1))

        git rev-parse -q --verify "refs/tags/${name}" >/dev/null \
            || die "tag disappeared: ${name}"
        new_obj="$(git rev-parse "refs/tags/${name}")"
        new_type="$(git cat-file -t "${new_obj}")"
        [[ "${new_type}" == "${old_type}" ]] \
            || die "tag ${name} changed type (${old_type} -> ${new_type})"

        new_commit="$(git rev-parse "refs/tags/${name}^{commit}")" \
            || die "rewritten tag ${name} does not resolve to a commit"
        new_tag_tree="$(git rev-parse "${new_commit}^{tree}")"
        [[ "${new_tag_tree}" == "${old_tag_tree}" ]] \
            || die "tag ${name} points at a different tree (${old_tag_tree} -> ${new_tag_tree})"

        if [[ "${new_type}" == "tag" ]]; then
            old_tagger="$(git cat-file tag "${old_obj}" | sed -n 's/^tagger //p')"
            new_tagger="$(git cat-file tag "${new_obj}" | sed -n 's/^tagger //p')"
            [[ "${old_tagger}" == "${new_tagger}" ]] \
                || die "tag ${name} lost its tagger"
            [[ "$(tag_message "${old_obj}")" == "$(tag_message "${new_obj}")" ]] \
                || die "tag ${name} lost its message"
        fi

        # Tags that were on the branch must still be on the branch.
        if git merge-base --is-ancestor "${old_commit}" "${OLD_TIP}"; then
            git merge-base --is-ancestor "${new_commit}" "${BRANCH}" \
                || die "tag ${name} is no longer reachable from ${BRANCH}"
        fi
    done < "${TAG_MANIFEST}"
    [[ "${CHECKED_TAGS}" == "${TAG_COUNT}" ]] \
        || die "only ${CHECKED_TAGS} of ${TAG_COUNT} tags were verified"
fi

rm -f "${BUNDLE}"
if (( REWRITE_TAGS )) && (( TAG_COUNT > 0 )); then
    BUNDLE_REFS=(HEAD "${BRANCH}")
    while IFS= read -r ref; do
        BUNDLE_REFS+=("${ref}")
    done < <(git for-each-ref --format='%(refname)' refs/tags)
    git bundle create "${BUNDLE}" "${BUNDLE_REFS[@]}" >/dev/null
else
    git bundle create "${BUNDLE}" HEAD "${BRANCH}" >/dev/null
fi

git bundle verify "${BUNDLE}" >"${WORK}/bundle-verify.log" 2>&1 \
    || { cat "${WORK}/bundle-verify.log" >&2; die "the bundle did not verify"; }

if (( REWRITE_TAGS )); then
    BUNDLE_TAG_COUNT="$(git bundle list-heads "${BUNDLE}" | grep -c 'refs/tags/' || true)"
    [[ "${BUNDLE_TAG_COUNT}" == "${TAG_COUNT}" ]] \
        || die "bundle has ${BUNDLE_TAG_COUNT} tag(s), expected ${TAG_COUNT}"
fi

if command -v sha256sum >/dev/null 2>&1; then
    BUNDLE_SHA="$(sha256sum "${BUNDLE}" | awk '{print $1}')"
else
    BUNDLE_SHA="$(shasum -a 256 "${BUNDLE}" | awk '{print $1}')"
fi

# Build the atomic push: the branch and every moved tag are leased to their
# current remote values, so a concurrent change aborts the whole push.
PUSH_ARGS=("--force-with-lease=refs/heads/${BRANCH}:${OLD_TIP}")
PUSH_REFS=("${BRANCH}:refs/heads/${BRANCH}")
if (( REWRITE_TAGS )); then
    while IFS=$'\t' read -r name old_obj old_type old_commit old_tag_tree; do
        [[ -n "${name}" ]] || continue
        PUSH_ARGS+=("--force-with-lease=refs/tags/${name}:${old_obj}")
        PUSH_REFS+=("refs/tags/${name}:refs/tags/${name}")
    done < "${TAG_MANIFEST}"
fi

CMD=("git push" "--atomic" "${PUSH_ARGS[@]}" "${SOURCE}" "${PUSH_REFS[@]}")

REVIEW_DIR="${BUNDLE%.bundle}-review"
if (( REWRITE_TAGS )); then
    TAG_SUMMARY="${TAG_COUNT} remapped"
    TAG_NOTE="tags are included"
    TAG_REVIEW="  git tag -l                                    # ${TAG_COUNT} tag(s)"
    PUSH_NOTE="Apply it from that clone. The push is atomic; every ref is leased to its"
    PUSH_NOTE2="current value, so it aborts if the branch or any tag moved in the meantime:"
else
    TAG_SUMMARY="not rewritten (--no-tags)"
    TAG_NOTE="tags are not included"
    TAG_REVIEW="  git tag -l                                    # no tags in this bundle"
    PUSH_NOTE="Apply it from that clone. The push is atomic; the branch is leased to its"
    PUSH_NOTE2="current value, so it aborts if it moved in the meantime:"
fi

cat <<EOF

Rewrote ${RENAMED} merge message(s); kept ${NEW_MERGES} merge commits.
  old tip : ${OLD_TIP}
  new tip : ${NEW_TIP}
  tree    : ${NEW_TREE} (unchanged)
  commits : ${NEW_COMMITS}
  merges  : ${NEW_MERGES}
  tags    : ${TAG_SUMMARY}
  bundle  : ${BUNDLE}
  sha256  : ${BUNDLE_SHA}

The bundle is complete and was verified locally. Nothing was pushed.

Review it in a throwaway clone (${TAG_NOTE}):
  git clone "${BUNDLE}" "${REVIEW_DIR}"
  cd "${REVIEW_DIR}"
  git log --oneline -20
  git rev-parse HEAD^{tree}                     # ${NEW_TREE}
  git rev-list --count HEAD                     # ${NEW_COMMITS}
${TAG_REVIEW}

${PUSH_NOTE}
${PUSH_NOTE2}
EOF

for ((i = 0; i < ${#CMD[@]}; i++)); do
    if (( i < ${#CMD[@]} - 1 )); then
        printf '  %s \\\n' "${CMD[$i]}"
    else
        printf '  %s\n' "${CMD[$i]}"
    fi
done

cat <<EOF

Every collaborator must re-sync afterwards:
  git fetch && git reset --hard origin/${BRANCH}

If ${BRANCH} or its tags are protected, allow force pushes temporarily and
restore the rule afterwards. Keep a backup of the old tip until everyone has
moved:
  git branch backup/${BRANCH}-before-rewrite ${OLD_TIP}

See docs/REWRITING_HISTORY.md before running the push.
EOF
