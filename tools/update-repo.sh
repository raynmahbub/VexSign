#!/bin/sh
# Updates app-repo.json with assets + changelog from a GitHub release.
#
# Called from .github/workflows/update_repo.yml whenever a release is
# published. It can also be run locally:
#
#   # Pick up the latest published release on the repo:
#   ./tools/update-repo.sh
#
#   # Target a specific release tag (e.g. to backfill):
#   RELEASE_TAG=v1.2.0 ./tools/update-repo.sh
#
#   # Mirror releases from another repo:
#   RELEASE_REPO=owner/name ./tools/update-repo.sh
#
# Environment:
#   RELEASE_REPO   owner/name to read releases from. Defaults to the origin
#                  remote of the current checkout (or raynmahbub/VexSign).
#   RELEASE_TAG    the tag to sync. When unset, uses the latest *published*
#                  release on RELEASE_REPO. In CI, the workflow passes this
#                  from github.event.release.tag_name so a pre-release or a
#                  corrected publish doesn't race against "latest".
#   GITHUB_TOKEN   optional; authenticates the GitHub API call so we aren't
#                  limited to 60 unauthenticated requests/hour.

set -eu

# Resolve the checkout from this script, not the caller's working directory.
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"

JSON_FILE="app-repo.json"

handle_error() {
  echo "Error: $1" >&2
  exit 1
}

warn() {
  echo "::warning::$1"
  echo "Warning: $1" >&2
}

command -v jq >/dev/null 2>&1 || handle_error "jq is required but was not found in PATH."

origin_repo() {
  git remote get-url origin 2>/dev/null \
    | sed -e 's#^https\{0,1\}://[^/]*/##' -e 's#^git@[^:]*:##' -e 's#\.git$##'
}

RELEASE_REPO="${RELEASE_REPO:-$(origin_repo)}"
[ -n "$RELEASE_REPO" ] || RELEASE_REPO="raynmahbub/VexSign"

if [ -n "${RELEASE_TAG:-}" ]; then
  API_URL="https://api.github.com/repos/${RELEASE_REPO}/releases/tags/${RELEASE_TAG}"
else
  API_URL="https://api.github.com/repos/${RELEASE_REPO}/releases/latest"
fi

echo "Fetching release data from GitHub..."
echo "Repository: ${RELEASE_REPO}"
echo "Endpoint:   ${API_URL}"

BODY_FILE="$(mktemp)"
trap 'rm -f "$BODY_FILE"' EXIT INT TERM

# Pass the auth header as positional parameters so word splitting can never
# break its value into separate curl arguments (which turned the token into
# bogus extra URLs and failed every authenticated run).
if [ -n "${GITHUB_TOKEN:-}" ]; then
  set -- -H "Authorization: Bearer ${GITHUB_TOKEN}"
else
  set --
fi

HTTP_CODE=$(curl -sS -o "$BODY_FILE" -w '%{http_code}' \
  "$@" \
  -H 'Accept: application/vnd.github+json' \
  -H 'X-GitHub-Api-Version: 2022-11-28' \
  "$API_URL") || handle_error "Request to ${API_URL} failed."

if [ "$HTTP_CODE" != "200" ]; then
  handle_error "GitHub API returned HTTP ${HTTP_CODE} for ${API_URL}: $(head -c 400 "$BODY_FILE")"
fi

# Strip control characters so jq always sees well-formed input.
clean_release_info=$(tr -d '\000-\037' < "$BODY_FILE")

jq -e . >/dev/null 2>&1 <<EOF || handle_error "GitHub API did not return valid JSON."
$clean_release_info
EOF

is_draft=$(printf '%s' "$clean_release_info" | jq -r '.draft // false')
is_prerelease=$(printf '%s' "$clean_release_info" | jq -r '.prerelease // false')
tag=$(printf '%s' "$clean_release_info" | jq -r '.tag_name // empty')
version="${tag#v}"
updated_at=$(printf '%s' "$clean_release_info" | jq -r '.published_at // .created_at // empty')
release_body=$(printf '%s' "$clean_release_info" | jq -r '.body // ""')
release_name=$(printf '%s' "$clean_release_info" | jq -r '.name // empty')
release_url=$(printf '%s' "$clean_release_info" | jq -r '.html_url // empty')

[ -n "$version" ] || handle_error "Release has no tag_name; refusing to write an empty version."
[ -n "$updated_at" ] || handle_error "Release has no published_at/created_at."

if [ "$is_draft" = "true" ]; then
  warn "Release ${tag} is a draft; skipping repo update."
  exit 0
fi

echo "Release:  ${release_name:-$tag}"
echo "Version:  ${version}"
echo "Date:     ${updated_at}"
echo "Prerelease: ${is_prerelease}"

#
# Assemble the versionDescription and a single-line caption for the news
# card. We use the release body verbatim (authors can write curated
# markdown), and fall back to a one-liner when the body is empty. Newlines
# are preserved — AltStore/SideStore/ESign render them.
#
if [ -z "$release_body" ] || [ "$release_body" = "null" ]; then
  version_description="VexSign ${version}."
  news_caption="See release notes for what's new."
else
  # Strip the leading H2 ("## VexSign vX.Y[.Z]") which duplicates the version
  # label in the source UI, then trim blank lines at the top.
  cleaned_body="$(printf '%s' "$release_body" \
    | sed -E '1{/^##[[:space:]]*VexSign[[:space:]]+v?[0-9]+\.[0-9]+(\.[0-9]+)?/d;}' \
    | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')"
  version_description="$cleaned_body"
  # First line of prose for the news caption, truncated. Headings, quote/bullet
  # markers and image-only lines are skipped: the release bodies open with the
  # app icon, and `![alt](url)` used to land in the caption verbatim.
  news_caption="$(printf '%s' "$cleaned_body" \
    | grep -vE '^[[:space:]]*$' \
    | grep -vE '^[#>-]' \
    | grep -vE '^[[:space:]]*!\[' \
    | head -n 1 \
    | sed -E 's/!\[[^]]*\]\([^)]*\)//g' \
    | sed -E 's/\[([^]]*)\]\([^)]*\)/\1/g' \
    | sed -E 's/[*_`]+//g' \
    | cut -c1-160)"
  [ -n "$news_caption" ] || news_caption="See release notes for what's new."
fi

ipa_files=$(printf '%s' "$clean_release_info" | jq -c '[.assets[]? | select(.name | endswith(".ipa") or endswith(".tipa")) | {
    name: .name,
    size: (.size | tonumber),
    download_url: .browser_download_url
}]')

if [ "$(printf '%s' "$ipa_files" | jq 'length')" -eq 0 ]; then
  warn "No .ipa/.tipa assets in release ${tag}; app-repo.json left untouched."
  exit 0
fi

echo "Found IPA/TIPA files:"
printf '%s' "$ipa_files" | jq -r '.[] | "• \(.name) (\(.size) bytes)"'

[ -f "$JSON_FILE" ] || handle_error "$JSON_FILE does not exist."
jq -e . "$JSON_FILE" >/dev/null 2>&1 || handle_error "$JSON_FILE is not valid JSON."

num_apps=$(jq '.apps | length' "$JSON_FILE")
echo "Repository has $num_apps apps"

app_index=0
while [ "$app_index" -lt "$num_apps" ]; do
    app_name=$(jq -r ".apps[$app_index].name" "$JSON_FILE")
    app_id=$(jq -r ".apps[$app_index].bundleIdentifier" "$JSON_FILE")

    echo "Processing app[$app_index]: $app_name ($app_id)"

    if echo "$app_name" | grep -i "idevice" > /dev/null; then
        matching_file=$(printf '%s' "$ipa_files" | jq -c 'map(select(.name | endswith(".tipa") or contains("idevice"))) | first')
    else
        matching_file=$(printf '%s' "$ipa_files" | jq -c 'map(select(.name | endswith(".ipa") and (contains("idevice") | not))) | first')
    fi

    if [ -z "$matching_file" ] || [ "$matching_file" = "null" ]; then
        matching_file=$(printf '%s' "$ipa_files" | jq -c 'first')
        echo "No specific match found for $app_name, using first available file"
    fi

    if [ -n "$matching_file" ] && [ "$matching_file" != "null" ]; then
        name=$(printf '%s' "$matching_file" | jq -r '.name')
        size=$(printf '%s' "$matching_file" | jq -r '.size')
        download_url=$(printf '%s' "$matching_file" | jq -r '.download_url')

        echo "Updating $app_name with: $name"

        # Update top-level fields and PREpend the new version entry to the
        # history (keep the 20 most recent). Preserve prior versions so users
        # can downgrade from the source UI.
        jq --arg index "$app_index" \
           --arg version "$version" \
           --arg date "$updated_at" \
           --argjson size "$size" \
           --arg url "$download_url" \
           --arg desc "$version_description" \
           '.apps[$index | tonumber] |= (
                .version = $version
              | .versionDate = $date
              | .size = $size
              | .downloadURL = $url
              | .versionDescription = $desc
              | .versions = ( [
                    { version: $version,
                      date: $date,
                      size: $size,
                      downloadURL: $url,
                      localizedDescription: $desc }
                  ]
                  + [ (.versions // [])[] | select(.version != $version) ]
                )
              | .versions |= .[0:20]
            )' "$JSON_FILE" > "${JSON_FILE}.tmp"

        if jq -e '.apps | length' "${JSON_FILE}.tmp" >/dev/null 2>&1; then
            mv "${JSON_FILE}.tmp" "$JSON_FILE"
        else
            echo "Error: JSON file is invalid after update. Keeping the previous version." >&2
            rm -f "${JSON_FILE}.tmp"
            exit 1
        fi
    else
        echo "No matching file found for $app_name"
    fi

    app_index=$((app_index + 1))
done

# Update the news section with an entry for this release so source browsers
# show a "new release" card.
jq --arg tag "$tag" \
   --arg version "$version" \
   --arg date "$updated_at" \
   --arg name "${release_name:-VexSign ${version}}" \
   --arg url "${release_url:-"https://github.com/${RELEASE_REPO}/releases/tag/${tag}"}" \
   --arg caption "$news_caption" \
   '.news = (
      [ { identifier: ("vexsign-" + $version),
          date: $date,
          title: ("VexSign " + $version),
          caption: $caption,
          tintColor: "C96FAD",
          imageURL: "https://raw.githubusercontent.com/raynmahbub/VexSign/main/icon.png",
          notify: true,
          url: $url } ]
      + [ (.news // [])[] | select(.identifier != ("vexsign-" + $version)) ]
    )
    | .news |= .[0:10]' \
  "$JSON_FILE" > "${JSON_FILE}.tmp" && mv "${JSON_FILE}.tmp" "$JSON_FILE"

echo "Repository update completed for v${version}."

# Echo the version for the caller (used by the workflow's commit message).
echo "UPDATED_VERSION=${version}" >> "${GITHUB_OUTPUT:-/dev/null}"
