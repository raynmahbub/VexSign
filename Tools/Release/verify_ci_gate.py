#!/usr/bin/env python3
"""Refuse to release a commit unless its CI checks are really green.

The check list is fetched from the GitHub API (or a fixture in tests). A check that
was skipped, missing, cancelled or failed is not success. Physical-device evidence is
required for publishing releases when --require-device is set; previews and build-only
runs can pass with simulator evidence alone.
"""

import argparse
import json
import os
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_CHECKS = (
    "quick",
    "build · VexSign Debug (unsigned)",
    "tests · VexSignTests (simulator)",
    "ui-tests · VexSignUITests (simulator)",
)
DEVICE_CHECK = "device · iPhone (self-hosted, opt-in)"
API_ROOT = "https://api.github.com"


def fetch_check_runs(repo, sha, token, api_root=API_ROOT):
    if not repo or "/" not in repo:
        raise ValueError("GITHUB_REPOSITORY must be owner/name")
    if not token:
        raise ValueError("A GitHub token is required to read check runs")
    path = f"/repos/{urllib.parse.quote(repo, safe='/')}/commits/{urllib.parse.quote(sha, safe='')}/check-runs?per_page=100"
    runs = []
    url = api_root + path
    while url:
        request = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "VexSign-release-gate",
        })
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
            runs.extend(payload.get("check_runs") or [])
            link = response.headers.get("Link", "")
            url = None
            for part in link.split(","):
                if 'rel="next"' in part and part.startswith("<") and ">" in part:
                    url = part[1:part.index(">")]
    return runs


def latest_by_name(check_runs):
    """A retry should not be judged by an older failed attempt."""
    by_name = {}
    for check in check_runs:
        name = check.get("name")
        if not name:
            continue
        stamp = check.get("completed_at") or check.get("started_at") or ""
        current = by_name.get(name)
        if current is None or stamp >= (current.get("completed_at") or current.get("started_at") or ""):
            by_name[name] = check
    return by_name


def evaluate(check_runs, required):
    by_name = latest_by_name(check_runs)
    errors = []
    statuses = {}
    for name in required:
        check = by_name.get(name)
        if check is None:
            errors.append(f"{name}: no check run for this commit")
            statuses[name] = "missing"
            continue
        conclusion = check.get("conclusion")
        statuses[name] = conclusion or "unknown"
        if conclusion != "success":
            detail = check.get("output", {}).get("summary") or check.get("html_url") or ""
            errors.append(f"{name}: conclusion={conclusion or 'incomplete'} {detail}".rstrip())
    return errors, statuses


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--token", default=os.environ.get("GITHUB_TOKEN", ""))
    parser.add_argument("--api-root", default=API_ROOT)
    parser.add_argument("--fixture", help="JSON check-runs fixture for offline tests")
    parser.add_argument("--require-device", action="store_true")
    parser.add_argument("--check", action="append", default=[],
                        help="Additional required check name; repeatable")
    args = parser.parse_args()

    required = list(DEFAULT_CHECKS) + args.check
    if args.require_device:
        required.append(DEVICE_CHECK)

    if args.fixture:
        payload = json.loads(args.fixture)
        check_runs = payload["check_runs"] if isinstance(payload, dict) and "check_runs" in payload else payload
    else:
        try:
            check_runs = fetch_check_runs(args.repo, args.sha, args.token, args.api_root)
        except (ValueError, urllib.error.URLError) as error:
            parser.exit(2, f"error: {error}\n")

    errors, statuses = evaluate(check_runs, required)
    for name, status in statuses.items():
        print(f"{name}: {status}")
    if errors:
        for error in errors:
            print(f"FAIL {error}")
        raise SystemExit(1)
    print(f"CI gate passed: {len(required)} required checks succeeded for {args.sha}")


if __name__ == "__main__":
    main()
