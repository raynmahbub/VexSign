#!/usr/bin/env python3
"""Dispatch stable packaging only for a green main commit that bumps every version."""
import json
import os
import re
import subprocess


def version(project):
    versions = {v.strip().strip('"') for v in re.findall(r'MARKETING_VERSION\s*=\s*([^;]+);', project)}
    if len(versions) != 1:
        return None
    value = versions.pop()
    return value if re.fullmatch(r'\d+\.\d+\.\d+', value) else None


def main():
    repo, sha = os.environ['GH_REPO'], os.environ['SOURCE_SHA']
    def api(path):
        return json.loads(subprocess.check_output(['gh', 'api', f'repos/{repo}/{path}'], text=True))
    branch = api('')['default_branch']
    if api(f'commits/{branch}')['sha'] != sha:
        print('Newer main exists; do not release an obsolete candidate')
        return
    jobs = api(f"actions/runs/{os.environ['SOURCE_RUN']}/jobs?per_page=100")['jobs']
    passed = {j['name'] for j in jobs if j['conclusion'] == 'success'}
    if not {'build · VexSign Debug (unsigned)', 'tests · VexSignTests (simulator)'} <= passed:
        print('Full build and simulator success required')
        return
    project = 'VexSign.xcodeproj/project.pbxproj'
    def content(ref):
        return subprocess.check_output(['git', 'show', f'{ref}:{project}'], text=True)
    current, previous = version(content(sha)), version(content(sha + '^1'))
    if not current or not previous or tuple(map(int, current.split('.'))) <= tuple(map(int, previous.split('.'))):
        print('No reviewed, unanimous marketing-version increase on this commit')
        return
    # List instead of treating a failed release lookup as proof of absence.
    releases = json.loads(subprocess.check_output(
        ['gh', 'api', '--paginate', '--slurp', f'repos/{repo}/releases?per_page=100'], text=True))
    if any(r['tag_name'] == 'v' + current for page in releases for r in page):
        print('Version already published')
        return
    subprocess.run(['gh', 'workflow', 'run', 'release.yml', '--repo', repo, '--ref', branch,
                    '-f', 'channel=stable', '-f', 'build_only=false'], check=True)
    print(f'Queued stable v{current}; Release revalidates, builds, tests and enforces environment rules')


if __name__ == '__main__':
    main()
