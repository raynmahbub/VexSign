# Rewriting merge commit messages

Git commit messages are part of the commit hash. Renaming an existing
`Merge pull request #N from …` commit therefore rewrites that commit and every
commit after it. This repository keeps the merge topology but lets maintainers
replace those merge messages with the message of the commit that was merged
(the merge's second parent).

`tools/rewrite-merge-messages.sh` does this in a throwaway clone, remaps the
tags onto the rewritten commits, verifies the result, writes a bundle, and
prints the force-push command. It never pushes.

The operation is **destructive to history**: it requires an atomic force-push
to the default branch and its tags, every collaborator must re-sync, and open
pull requests need rebasing. It is not part of a normal release.

## Why not a fully linear history?

A linear rewrite is not just "drop the merge commits". At least eight merges in
this repository contain manual conflict resolutions — changes present in
neither parent, proven with `git show --remerge-diff`:

```
ad5d3036  merge: Resolve conflicts with main
118b0ed2  Merge branch 'main' into arena/7381b2a7-vexsign
4839eb30  Merge remote-tracking branch 'origin/main' into arena/01a0c12c-vexsign
f2820b0d  Merge origin/main: combine stability passes, keep customizable legacy tabs
b59f11c0  Merge main and resolve README conflict with updated feature coverage
2f4f286a  merge: resolve conflicts with origin/main — preserve atomic key redemption …
5258d627  merge: resolve with origin/main — keep QuickLook/hash-verify and IPSW browser …
3dbbbdae  merge: resolve main conflicts in certificate import flow
```

Flattening those commits deletes the resolutions from every intermediate
state. The tip tree could be forced to match, but the commits in between would
be a history that never existed and may not build — which breaks `git bisect`,
the main reason to want clean history in the first place.

The merge topology also preserves pull-request and upstream-sync boundaries.
`git log --first-parent main` is an 80-commit release narrative; the full graph
is 278 commits with 78 merges. Renaming the 23 noisy `Merge pull request`
messages fixes the actual readability problem without losing any of that.

## Tool

```bash
# Show the plan. Rewrites main and remaps all tags into a bundle.
tools/rewrite-merge-messages.sh

# Keep issue numbers: "fix: the last five unused bindings (#74)"
tools/rewrite-merge-messages.sh --pr-numbers

# Branch only, no tags (testing only: releases would be left behind)
tools/rewrite-merge-messages.sh --no-tags

# Explicit repository/branch/output
tools/rewrite-merge-messages.sh \
  --source https://github.com/raynmahbub/VexSign.git \
  --branch main \
  --bundle /tmp/vexsign-main-rewritten.bundle
```

The script:

1. clones `--source` (a full history is required) into a temporary directory,
2. replaces only merge commits whose subject starts with `Merge pull request`,
   using the full message of `<merge>^2`,
3. asserts that the branch tree, commit count and merge count are unchanged,
4. asserts that no `Merge pull request` subject remains and that every
   non-merge commit message is byte-identical,
5. remaps every tag onto its rewritten commit by default and asserts that each
   tag keeps its type, target tree, tagger and message,
6. writes a complete bundle containing the branch **and tags**, verifies it,
   and prints its SHA-256 plus an atomic, leased push command.

Merge commits with hand-written messages are left alone. Non-merge commits are
never edited. Annotated tag objects are recreated with the same tagger and
message; their object IDs change. PGP-signed tags fail verification because
filter-branch strips the signature (this repository's tags are unsigned).

This repository currently has 20 tags: 19 synthetic annotated tags
(`v0.0.1`–`v0.0.18`, `v1.0.0`) that all point at one commit, and the
lightweight `v1.0` tag used by the GitHub release. All 20 are remapped.

## Review

Run the script, then clone its bundle somewhere disposable:

```bash
git clone /tmp/vexsign-main-rewritten.bundle /tmp/vexsign-main-review
cd /tmp/vexsign-main-review
git log --oneline -20
git rev-parse HEAD^{tree}      # must match the tree printed by the script
git rev-list --count HEAD      # 278 for the current history
git tag -l
```

The bundle clone contains exactly the rewritten branch and tags. Its `origin`
is the bundle file, not GitHub; the push command printed by the script names
the GitHub URL explicitly, so no remote needs to be added.

## Apply

Use the push command printed by the script. It pushes the branch and every tag
in one `--atomic` transaction, with `--force-with-lease` pinned to the current
remote value of each ref. If `main` or any tag has moved since the script ran,
the whole push aborts and the bundle must be regenerated.

Back up the old tip first:

```bash
git branch backup/main-before-rewrite 0bb7edf4300cda27cba6eb0aad71c88010b57f65
```

If `main` or its tags are protected, temporarily allow force pushes (or use an
admin account), run the push, then restore the rule. Do not use plain
`--force`, and do not push the branch and tags separately unless you accept a
window where releases point at commits that are no longer on `main`.

Afterwards, every clone must move both the branch and the tags:

```bash
git fetch --prune --tags --force
git reset --hard origin/main
```

`git fetch` alone will refuse to move the existing tags; `--force` is required
for the tag refs. Open pull requests based on the old history must be rebased
onto the new `main`. Forks need the same reset.

## Releases and GitHub

- The `v1.0` release follows its tag name. After the push it points at the
  rewritten commit; its notes and assets are unchanged.
- Pull-request timelines still reference the old commits. The code tree is
  identical, but commit links in old discussions may show rewritten hashes.
- Old commits can remain reachable through pull-request refs and reflogs. This
  is a history cleanup, not a way to erase content.
- Keep `backup/main-before-rewrite` until all collaborators and CI references
  have moved.

## Going forward: linear history without another rewrite

The useful part of "linear history" can be had from now on without touching
the past:

1. In **Settings → General → Pull Requests**, allow **Squash merging** (and
   optionally **Rebase merging**), and disable **Merge commits**.
2. In the `main` branch protection rule or ruleset, enable **Require linear
   history**. This rejects merge commits on the branch.
3. Set the squash-merge default to the pull-request title and description so
   the resulting commit message is useful.

Each new PR then lands as one commit on `main`; the existing 78 merges remain
as historical record. This avoids replaying old conflict resolutions, keeps
bisect working, and does not require anyone to force-push.

Do not combine this with a linearizing rewrite. If a fully linear history is
ever genuinely required, it needs a commit-by-commit replay with conflict
re-resolution and a build at every step — not a mechanical filter, and not this
script.
