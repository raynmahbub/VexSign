#!/bin/sh
# Generate a markdown changelog for the release currently being built.
#
# Output goes to stdout. Used by the Release workflow to populate the GitHub
# release body and (via Tools/Release/update-repo.sh) the versionDescription fields in
# app-repo.json.
#
# Commits since the previous release tag are grouped by conventional-commit
# prefix, contributors are listed, and a short install/repo footer is appended.
# When no previous tag exists (first release or shallow checkout) we fall back
# to all reachable commits.
#
# "Previous release" is the nearest release tag reachable from HEAD - i.e. it
# follows commit ancestry, not tag creation date - so the notes for a given
# tag are the same no matter when or where they are generated. A stable
# release skips pre-release tags (v1.2.0 lists everything since v1.1.0, not
# just since v1.2.0-rc.1); a pre-release diffs against whatever came last.
# Release tags are v<MAJOR>.<MINOR>[.<PATCH>][-<pre-release>], e.g. v1.0,
# v1.2.0, v1.2.0-beta.1.
#
# Environment:
#   VERSION       version being released (e.g. "1.2.0" or "1.2.0-beta.1").
#                 Auto-detected when unset (tag ref, or
#                 CFBundleShortVersionString from a built Payload/*.app, or
#                 "0.0.0" as a last resort).
#   PREVIOUS_TAG  override the previous-release tag.
#   BASE_SHA      override the start of the commit range.

set -e

# Robustness: require git and avoid failing on missing tags / shallow clones
command -v git >/dev/null 2>&1 || { echo "git not available; skipping changelog"; exit 0; }

RELEASE_TAG_RE='^v[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.]+)?$'

# ---------------------------------------------------------------------------
# Resolve version
# ---------------------------------------------------------------------------
VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
    if [ -n "${GITHUB_REF_NAME:-}" ] && printf '%s' "$GITHUB_REF_NAME" | grep -qE "$RELEASE_TAG_RE"; then
        VERSION="${GITHUB_REF_NAME#v}"
    elif ls Payload/*.app/Info.plist >/dev/null 2>&1; then
        VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Payload/*.app/Info.plist 2>/dev/null || true)"
    fi
fi
[ -n "$VERSION" ] || VERSION="0.0.0"

case "$VERSION" in
    *-*) IS_PRERELEASE=1 ;;
    *)   IS_PRERELEASE=0 ;;
esac

# ---------------------------------------------------------------------------
# Resolve commit range
# ---------------------------------------------------------------------------
RANGE=""
PREVIOUS_TAG="${PREVIOUS_TAG:-}"

# Drop the tag being released and, for stable releases, pre-release tags.
filter_candidate_tags() {
    grep -E "$RELEASE_TAG_RE" | grep -vxF "v${VERSION}" | {
        if [ "$IS_PRERELEASE" -eq 1 ]; then cat; else grep -v -- '-'; fi
    } || true
}

if [ -n "${BASE_SHA:-}" ]; then
    RANGE="${BASE_SHA}..HEAD"
elif [ -z "$PREVIOUS_TAG" ]; then
    # Nearest release tag in HEAD's ancestry. `git describe` only takes glob
    # patterns, so the exact shape is enforced by the regex filter afterwards.
    if [ "$IS_PRERELEASE" -eq 1 ]; then
        PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' \
            --exclude "v${VERSION}" HEAD 2>/dev/null | filter_candidate_tags | head -n 1)"
    else
        PREVIOUS_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*' \
            --exclude "v${VERSION}" --exclude 'v*-*' HEAD 2>/dev/null | filter_candidate_tags | head -n 1)"
    fi

fi

if [ -z "$RANGE" ]; then
    if [ -n "$PREVIOUS_TAG" ]; then
        # Verify the tag actually exists; if not, fall back to everything reachable.
        if git rev-parse --verify "$PREVIOUS_TAG^{tag}" >/dev/null 2>&1 || git rev-parse --verify "$PREVIOUS_TAG" >/dev/null 2>&1; then
            RANGE="${PREVIOUS_TAG}..HEAD"
        else
            RANGE="HEAD"
            PREVIOUS_TAG="(first release)"
        fi
    else
        # Shallow clones / first release: fall back to everything reachable.
        RANGE="HEAD"
        PREVIOUS_TAG="(first release)"
    fi
fi

# ---------------------------------------------------------------------------
# Collect commits (subject line only, no merges)
# ---------------------------------------------------------------------------
# If the chosen range is invalid (e.g. missing tag/shallow clone), fall back.
if [ -n "$RANGE" ] && [ "$RANGE" != "HEAD" ]; then
    if ! git rev-parse --verify "${RANGE%%..*}" >/dev/null 2>&1; then
        RANGE="HEAD"
        PREVIOUS_TAG="(first release)"
    fi
fi

COMMITS="$(git log --no-merges --pretty=format:'%h %s' "$RANGE" 2>/dev/null || true)"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
section_for_prefix() {
    case "$1" in
        feat|feature)            printf '%s' "✨ Features" ;;
        fix|bugfix|hotfix)       printf '%s' "🐛 Fixes" ;;
        perf)                    printf '%s' "⚡ Performance" ;;
        refactor)                printf '%s' "♻️ Refactoring" ;;
        docs|readme)             printf '%s' "📝 Documentation" ;;
        test|tests)              printf '%s' "✅ Tests" ;;
        build|ci|chore|deps)     printf '%s' "🔧 Build & CI" ;;
        i18n|localiz*)           printf '%s' "🌐 Localization" ;;
        *)                       printf '%s' "" ;;
    esac
}

format_bullet() {
    line="$1"
    sha="$(printf '%s' "$line" | awk '{print $1}')"
    subj="$(printf '%s' "$line" | cut -d' ' -f2-)"
    clean="$(printf '%s' "$subj" | sed -E 's/^[a-zA-Z][a-zA-Z0-9_-]*(\([^)]+\))?!?:[[:space:]]*//')"
    # Use '%s' and -- to keep printf from treating a leading dash as a flag.
    printf -- '- %s (`%s`)\n' "$clean" "$sha"
}

emit_section() {
    title="$1"
    file="$2"
    if [ -s "$file" ]; then
        printf '\n### %s\n\n' "$title"
        cat "$file"
    fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

for bucket in features fixes perf refactor docs tests build i18n other; do
    : > "$TMP/$bucket"
done

printf '%s\n' "$COMMITS" | while IFS= read -r line; do
    [ -z "$line" ] && continue
    subj="$(printf '%s' "$line" | cut -d' ' -f2-)"
    # BSD sed treats text after `t` as its label, including semicolons.
    # Separate expressions work with both BSD sed (macOS) and GNU sed.
    prefix="$(printf '%s' "$subj" | sed -E -e 's/^([a-zA-Z][a-zA-Z0-9_-]*).*$/\1/' -e t -e 's/.*//')"
    section="$(section_for_prefix "$prefix")"
    bullet="$(format_bullet "$line")"
    case "$section" in
        "✨ Features")        printf '%s\n' "$bullet" >> "$TMP/features" ;;
        "🐛 Fixes")           printf '%s\n' "$bullet" >> "$TMP/fixes" ;;
        "⚡ Performance")     printf '%s\n' "$bullet" >> "$TMP/perf" ;;
        "♻️ Refactoring")     printf '%s\n' "$bullet" >> "$TMP/refactor" ;;
        "📝 Documentation")   printf '%s\n' "$bullet" >> "$TMP/docs" ;;
        "✅ Tests")           printf '%s\n' "$bullet" >> "$TMP/tests" ;;
        "🔧 Build & CI")      printf '%s\n' "$bullet" >> "$TMP/build" ;;
        "🌐 Localization")    printf '%s\n' "$bullet" >> "$TMP/i18n" ;;
        *)                   printf '%s\n' "$bullet" >> "$TMP/other" ;;
    esac
done

# Contributors in range.
contributors="$(git log --no-merges --pretty=format:'%an <%ae>' "$RANGE" 2>/dev/null | sort -u || true)"

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
printf '## VexSign v%s\n\n' "$VERSION"

if [ "$PREVIOUS_TAG" = "(first release)" ]; then
    printf 'Initial release.\n'
else
    printf 'Changes since %s:\n' "$PREVIOUS_TAG"
fi

[ -n "$COMMITS" ] || printf '\nNo source changes since the previous release.\n'

emit_section "✨ Features"        "$TMP/features"
emit_section "🐛 Fixes"           "$TMP/fixes"
emit_section "⚡ Performance"     "$TMP/perf"
emit_section "♻️ Refactoring"     "$TMP/refactor"
emit_section "📝 Documentation"   "$TMP/docs"
emit_section "🌐 Localization"    "$TMP/i18n"
emit_section "✅ Tests"           "$TMP/tests"
emit_section "🔧 Build & CI"      "$TMP/build"
emit_section "Other changes"      "$TMP/other"

if [ -n "$contributors" ]; then
    printf '\n### 🙏 Contributors\n\n'
    printf '%s\n' "$contributors" | while IFS= read -r who; do
        [ -z "$who" ] && continue
        name="${who% <*}"
        email="${who#*<}"
        email="${email%>}"
        case "$email" in
            *@users.noreply.github.com)
                gh_user="${email%@users.noreply.github.com}"
                gh_user="${gh_user#*+}"
                printf '@%s\n' "$gh_user"
                ;;
            *)
                # De-duplicate against the GitHub-noreply form: if the author's
                # name parses as a GitHub login we already emitted above, skip
                # the plain-name duplicate.
                case "$name" in
                    @*) printf '%s\n' "$name" ;;
                    *)   printf '%s\n' "$name" ;;
                esac
                ;;
        esac
    done | awk '!seen[tolower($0)]++'
fi

printf '\n---\n\n'
IPA_VERSION="${VERSION%%-*}"
printf -- '- 📦 Download: `VexSign-%s.ipa` attached below\n' "$IPA_VERSION"
printf -- '- 📲 AltStore source: `https://raw.githubusercontent.com/raynmahbub/VexSign/main/app-repo.json`\n'
printf -- '- 💬 Report issues: https://github.com/raynmahbub/VexSign/issues\n'
