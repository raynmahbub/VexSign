#!/usr/bin/env python3
"""Free diagnostics and offline proposal validation; hosted inference is disabled."""
import argparse
import datetime as dt
import difflib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
MAX_FILES = 3
MAX_CHANGED_LINES = 200
MAX_CONTENT = 24000
MAX_DAILY = 2
WORKFLOWS = {'.github/workflows/ci.yml', '.github/workflows/platform-check.yml'}


def command(*args):
    return subprocess.check_output(list(args), cwd=ROOT, text=True).strip()


def api(path, *args):
    return json.loads(command('gh', 'api', path, *args))


def repo():
    value = os.environ['GH_REPO']
    if not re.fullmatch(r'[\w.-]+/[\w.-]+', value):
        raise ValueError('Invalid repository')
    return value


def source_path(path):
    p = PurePosixPath(path)
    if str(p) != path or p.is_absolute() or '..' in p.parts or '\\' in path:
        return False
    return (p.suffix == '.swift' and (
        p.parent == PurePosixPath('VexSign/DesignSystem') or
        p.parent == PurePosixPath('NimbleKit/Sources/NimbleViews/Views') or
        path == 'NimbleKit/Sources/NimbleViews/NBMetrics.swift'))


def test_path(path):
    return bool(re.fullmatch(r'VexSignTests/Repair[A-Za-z0-9]+Tests\.swift', path))


def regular_file(root, path):
    target = root / path
    if not target.resolve().is_relative_to(root.resolve()):
        raise ValueError('Path escapes checkout')
    for parent in [target, *target.parents]:
        if parent == root:
            break
        if parent.is_symlink():
            raise ValueError('Symlinks are forbidden')
    return target


def validate(proposal, root=ROOT):
    if not isinstance(proposal, dict) or set(proposal) != {'summary', 'edits'}:
        raise ValueError('Invalid proposal schema')
    if not isinstance(proposal['summary'], str) or not 1 <= len(proposal['summary']) <= 1000:
        raise ValueError('Invalid summary')
    edits = proposal['edits']
    if not isinstance(edits, list) or not 1 <= len(edits) <= MAX_FILES:
        raise ValueError('No bounded repair proposed')
    seen, changed, sources, tests = set(), 0, 0, 0
    for edit in edits:
        if not isinstance(edit, dict) or set(edit) != {'path', 'before_sha256', 'content'}:
            raise ValueError('Invalid edit schema')
        path, content = edit['path'], edit['content']
        if not isinstance(path, str) or path in seen or not isinstance(content, str):
            raise ValueError('Invalid/duplicate edit')
        seen.add(path)
        if '\x00' in content or len(content.encode()) > MAX_CONTENT:
            raise ValueError('Oversized/binary content')
        target = regular_file(root, path)
        old = ''
        if source_path(path):
            if not target.is_file():
                raise ValueError('Only existing presentation files can be repaired')
            raw = target.read_bytes()
            if hashlib.sha256(raw).hexdigest() != edit['before_sha256']:
                raise ValueError('Source checksum mismatch')
            old = raw.decode('utf-8')
            sources += 1
        elif test_path(path):
            if target.exists() or edit['before_sha256'] is not None:
                raise ValueError('Existing tests cannot be modified')
            if ('import XCTest' not in content or
                not re.search(r'class\s+\w+\s*:\s*XCTestCase\b', content) or
                not re.search(r'func\s+test\w*\s*\(', content) or 'XCTAssert' not in content):
                raise ValueError('New XCTest regression coverage required')
            tests += 1
        else:
            raise ValueError('Path outside presentation repair allowlist')
        if content == old or not content.strip():
            raise ValueError('Empty/no-op edits forbidden')
        changed += sum(1 for line in difflib.ndiff(old.splitlines(), content.splitlines())
                       if line.startswith(('+ ', '- ')))
    if not sources or not tests or changed > MAX_CHANGED_LINES:
        raise ValueError('Require source + new regression test within line budget')
    return edits


def redact(text):
    text = re.sub(r'(?i)(bearer\s+|(?:password|token|secret|authorization)\s*[:=]\s*)\S+', r'\1[REDACTED]', text)
    text = re.sub(r'\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|sk-[A-Za-z0-9_-]+)\b', '[REDACTED]', text)
    text = re.sub(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', '[EMAIL]', text, flags=re.I)
    return text[:4000]


def output(**values):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as handle:
        for key, value in values.items():
            handle.write(f'{key}={value}\n')


def current_run(run_id):
    r = repo()
    info = api(f'repos/{r}')
    run = api(f'repos/{r}/actions/runs/{run_id}')
    if (info['private'] or run['head_repository']['full_name'] != r or
        run['head_branch'] != info['default_branch'] or run['conclusion'] != 'failure' or
        run['event'] not in ('push', 'workflow_dispatch') or run['path'] not in WORKFLOWS):
        raise ValueError('Only supported public-repository main failures are admitted')
    if api(f'repos/{r}/commits/{info["default_branch"]}')['sha'] != run['head_sha']:
        raise ValueError('Obsolete failure; main has advanced')
    return run, info


def admit(run_id):
    run, _ = current_run(run_id)
    r, sha = repo(), run['head_sha']
    title = f'Repair attempt: {sha}'
    # Both open and closed issues count, so closing an attempt never resets budget.
    pages = json.loads(command('gh', 'api', '--paginate', '--slurp',
        f'repos/{r}/issues?state=all&creator=github-actions%5Bbot%5D&per_page=100'))
    issues = [issue for page in pages for issue in page]
    if any(i['title'] == title for i in issues):
        print('An attempt for this source commit already exists; no repeat')
        return
    today = dt.datetime.now(dt.timezone.utc).date().isoformat()
    if sum(i['title'].startswith('Repair attempt: ') and i['created_at'].startswith(today) for i in issues) >= MAX_DAILY:
        print('Daily repair budget exhausted; ordinary CI triage remains available')
        return
    issue = api(f'repos/{r}/issues', '--method', 'POST', '-f', f'title={title}', '-f',
                f'body=Free diagnostics for {run["html_url"]}. No hosted inference or paid coding agent is invoked. '
                'Inspect failed jobs, reproduce the failure, add regression coverage, and open a reviewed fix PR. '
                'This issue is the deduplicated escalation record; automatic code generation is disabled.')
    output(admitted='true', source_sha=sha, issue=issue['number'])


def propose(run_id, destination):
    # Hard stop, not an environment-variable opt-in: no hosted inference client
    # exists in free-only mode. Retain CLI compatibility for old invocations.
    raise RuntimeError('Hosted inference is unavailable in free-only mode; use diagnostics and a human/local repair')


def publish(run_id, issue, proposal_file):
    run, info = current_run(run_id)
    sha = run['head_sha']
    if command('git', 'rev-parse', 'HEAD') != sha or proposal_file.stat().st_size > 100000:
        raise ValueError('Stale checkout or oversized artifact')
    data = json.loads(proposal_file.read_text())
    if set(data) != {'source_sha', 'proposal'} or data['source_sha'] != sha:
        raise ValueError('Untrusted artifact source mismatch')
    edits = validate(data['proposal'])
    # No tests, model code, package installation or build scripts run in this job.
    branch = 'automation/repair-' + sha[:12]
    command('git', 'switch', '-c', branch)
    for edit in edits:
        regular_file(ROOT, edit['path']).write_text(edit['content'])
    command('git', 'config', 'user.name', 'github-actions[bot]')
    command('git', 'config', 'user.email', '41898282+github-actions[bot]@users.noreply.github.com')
    command('git', 'add', '--', *[e['path'] for e in edits])
    command('git', 'commit', '-m', 'fix(ui): propose bounded repair with regression coverage')
    command('gh', 'auth', 'setup-git')
    command('git', 'push', 'origin', f'HEAD:refs/heads/{branch}')
    url = command('gh', 'pr', 'create', '--repo', repo(), '--base', info['default_branch'], '--head', branch,
                  '--title', 'fix(ui): proposed agent repair with regression coverage', '--body',
                  f'Agent proposal for {run["html_url"]}; tracking #{issue}.\n\n'
                  'Presentation-only path/size policy passed; semantic correctness is NOT established. '
                  'A new regression test is included. Full CI and companion validation are dispatched separately. '
                  'Human review is required; autopilot does not merge repair branches. '
                  'The agent has not performed physical-device acceptance.')
    command('gh', 'issue', 'comment', str(issue), '--repo', repo(), '--body', f'Repair proposal: {url}. Review validation and semantics before merging.')
    for workflow in ('ci.yml', 'platform-check.yml'):
        args = ['gh', 'workflow', 'run', workflow, '--repo', repo(), '--ref', branch]
        if workflow == 'ci.yml':
            args += ['-f', 'validation=full']
        command(*args)
    print(url)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=('admit', 'propose', 'publish'))
    parser.add_argument('--run-id', required=True, type=int)
    parser.add_argument('--issue', type=int)
    parser.add_argument('--proposal', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.mode == 'admit':
        admit(args.run_id)
    elif args.mode == 'propose':
        propose(args.run_id, args.output)
    else:
        publish(args.run_id, args.issue, args.proposal)
