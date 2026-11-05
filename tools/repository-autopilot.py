#!/usr/bin/env python3
"""Trusted-branch controller: dispatch read-only validation, then merge narrow bot PRs.

Never checks out PR code. Never retries failed tests, bypasses rules or auto-merges
major updates, workflow edits, signing code, arbitrary bot PRs or human features.
"""
import json
import os
import re
import subprocess

REPO = os.environ.get('GH_REPO', '')


def command(*args):
    return subprocess.check_output(list(args), text=True).strip()


def api(path):
    endpoint = f'repos/{REPO}' + (f'/{path}' if path else '')
    return json.loads(command('gh', 'api', endpoint))


def eligible(pr, files, default):
    if pr['draft'] or pr['base']['ref'] != default or pr['head']['repo'] is None:
        return False
    if pr['head']['repo']['full_name'] != REPO or not files or len(files) > 20:
        return False
    if any(f.get('status') not in ('modified', 'added') for f in files):
        return False
    paths = {f['filename'] for f in files}
    author, branch = pr['user']['login'], pr['head']['ref']
    if author == 'github-actions[bot]':
        return ((branch == 'automation/repo-maintenance' and paths == {'VexSign/Resources/Localizable.xcstrings'})
                or (branch == 'automation/release-listing' and paths == {'app-repo.json'}))
    if author != 'dependabot[bot]' or not branch.startswith('dependabot/'):
        return False
    types = re.findall(r'update-type:\s*(version-update:semver-[a-z]+)', pr.get('body') or '')
    if not types or any(t not in ('version-update:semver-patch', 'version-update:semver-minor') for t in types):
        return False
    return paths <= {'server/requirements.txt'} or paths <= {
        'cloud-signing/package.json', 'cloud-signing/package-lock.json'}


def required_workflows(paths):
    result = ['ci.yml']  # Always full app build/simulator validation; never quick-only.
    if any(p.startswith(('server/', 'cloud-signing/')) for p in paths):
        result.append('services.yml')
    return result


def run_prs():
    global REPO
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', REPO):
        raise ValueError('GH_REPO must be owner/repository')
    default = api('')['default_branch']
    for item in api(f'pulls?state=open&base={default}&per_page=100'):
        number = item['number']
        pr = api(f'pulls/{number}')
        files = api(f'pulls/{number}/files?per_page=100')
        if not eligible(pr, files, default):
            continue
        head = pr['head']['sha']
        # Do not merge a result tested against an obsolete main. A stale PR waits
        # for a conflict-free GitHub branch refresh before validation.
        if api(f'compare/{default}...{head}')['behind_by'] != 0:
            if pr['mergeable'] is True:
                # GitHub merges main into this eligible automation branch only.
                # No checkout, force push or guessed conflict resolution.
                command('gh', 'api', '--method', 'PUT', f'repos/{REPO}/pulls/{number}/update-branch',
                        '-f', f'expected_head_sha={head}')
                print(f'#{number}: requested up-to-date branch; validate new head next pass')
            else:
                print(f'#{number}: conflict/unknown mergeability; review required')
            continue
        all_green = True
        for workflow in required_workflows([f['filename'] for f in files]):
            runs = api(f'actions/workflows/{workflow}/runs?head_sha={head}&per_page=100')['workflow_runs']
            # Restrict to the branch and full manual validation initiated by this
            # controller. A successful quick-only CI is not enough.
            runs = [r for r in runs if r['event'] == 'workflow_dispatch' and r['head_branch'] == pr['head']['ref']]
            if not runs:
                args = ['gh', 'workflow', 'run', workflow, '--repo', REPO, '--ref', pr['head']['ref']]
                if workflow == 'ci.yml':
                    args += ['-f', 'validation=full']
                command(*args)
                print(f'#{number}: dispatched {workflow}')
                all_green = False
            elif runs[0]['status'] != 'completed' or runs[0]['conclusion'] != 'success':
                all_green = False
                print(f'#{number}: {workflow} pending/failed; no merge or automatic retry')
            elif workflow == 'ci.yml':
                jobs = api(f"actions/runs/{runs[0]['id']}/jobs?per_page=100")['jobs']
                names = {j['name'] for j in jobs if j['conclusion'] == 'success'}
                if not {'build · VexSign Debug (unsigned)', 'tests · VexSignTests (simulator)'} <= names:
                    all_green = False
        if not all_green or pr['mergeable'] is not True:
            continue
        # Recheck base immediately before merge; head is pinned by gh as well.
        if api(f'compare/{default}...{head}')['behind_by'] != 0:
            continue
        subprocess.run(['gh', 'pr', 'merge', str(number), '--repo', REPO,
                        '--match-head-commit', head, '--merge'], check=True)
        # GITHUB_TOKEN merges do not trigger ordinary push workflows.
        command('gh', 'workflow', 'run', 'ci.yml', '--repo', REPO, '--ref', default, '-f', 'validation=full')
        for workflow in required_workflows([f['filename'] for f in files])[1:]:
            command('gh', 'workflow', 'run', workflow, '--repo', REPO, '--ref', default)
        print(f'Merged #{number}; main validation dispatched')
        break  # Serial merges; next hourly pass handles the next candidate.


if __name__ == '__main__':
    run_prs()
