#!/usr/bin/env python3
"""Keep the published source entry pointing at the repository that serves it.

`app-repo.json` is what every AltStore-compatible client downloads when someone
adds the source. Its identity links (icon, header, website, source URL, download
URL) are literals written by `update-repo.sh`, so they survive a repository
rename and keep advertising the previous account: the source lists correctly,
then shows someone else's icon and a website that no longer explains where the
IPA came from. That is what happened here — every URL pointed at a stale account
while the README badges pointed at the current one.

The rule enforced here is consistency, not one hard-coded owner: every VexSign
link in the file must resolve to the same `owner/repository`, and that pair must
be the one `sourceURL` is served from. Mirroring releases from another repository
(`RELEASE_REPO=owner/name`) still passes as long as the whole file agrees.

Usage:

    python3 tools/distribution-metadata.py      # check (exit 1 on disagreement)
    python3 tools/distribution-metadata.py -v   # also print what it inspected

The version is reported but never fails the gate: a release can legitimately lag
the project version in the working tree. A *published* version newer than the
project version is a real problem, so that direction does fail.
"""

import json
import re
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
REPO_FILE = ROOT / "app-repo.json"
PROJECT_FILE = ROOT / "VexSign.xcodeproj" / "project.pbxproj"
URL_PATTERN = re.compile(
    r"https?://(?:raw\.githubusercontent\.com|github\.com)/([^/\s]+)/([^/\s\"]+)"
)


def fail(message):
    print(f"FAIL: {message}", file=sys.stderr)
    return 1


def project_version():
    text = PROJECT_FILE.read_text(errors="ignore")
    versions = {
        value.strip().strip('"')
        for value in re.findall(r"MARKETING_VERSION = ([^;]+);", text)
    }
    return versions.pop() if len(versions) == 1 else None


def main(argv):
    verbose = "-v" in argv or "--verbose" in argv
    if not REPO_FILE.exists():
        return fail("app-repo.json is missing")

    try:
        source = json.loads(REPO_FILE.read_text())
    except json.JSONDecodeError as error:
        return fail(f"app-repo.json is not valid JSON: {error}")

    apps = source.get("apps") or []
    if not apps:
        return fail("app-repo.json declares no apps")
    bundle = apps[0].get("bundleIdentifier")
    if not bundle:
        return fail("apps[0] has no bundleIdentifier")

    raw_urls = URL_PATTERN.findall(REPO_FILE.read_text())
    if not raw_urls:
        return fail("app-repo.json contains no GitHub URL to verify")

    owners = {
        (owner.lower(), repo.removesuffix(".git").lower()) for owner, repo in raw_urls
    }
    if len(owners) > 1:
        listed = ", ".join(sorted(f"{o}/{r}" for o, r in owners))
        return fail(f"identity links disagree on the repository: {listed}")

    owner, repo = owners.pop()

    source_url = source.get("sourceURL", "")
    parsed = urlparse(source_url)
    if parsed.scheme != "https":
        return fail(f"sourceURL must be HTTPS, found {source_url or '(empty)'}")
    served = URL_PATTERN.findall(source_url)
    if not served or (served[0][0].lower(), served[0][1].removesuffix(".git").lower()) != (owner, repo):
        return fail(f"sourceURL {source_url!r} does not match the repository the other links use")

    for app in apps:
        url = app.get("downloadURL", "")
        if urlparse(url).scheme != "https":
            return fail(f"{app.get('name')}: downloadURL must be HTTPS, found {url or '(empty)'}")

    version = str(apps[0].get("version", ""))
    current = project_version()
    if not version:
        return fail("apps[0] has no version")
    if current and version.split(".")[0:2] != current.split(".")[0:2]:
        try:
            newer = tuple(int(x) for x in version.split(".")) > tuple(int(x) for x in current.split("."))
        except ValueError:
            newer = False
        if newer:
            return fail(f"source advertises {version} but the project is {current}")
        print(
            f"note: source advertises {version}, project is {current}. "
            "Regenerate app-repo.json with update-repo.sh once that release is published."
        )

    if verbose:
        print(f"repository: {owner}/{repo}")
        print(f"bundle:     {bundle}")
        print(f"version:    {version} (project {current or 'unknown'})")
        print(f"links:      {len(raw_urls)} GitHub URLs, all on one repository")
    print(f"OK: app-repo.json points at {owner}/{repo} for every identity link")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
