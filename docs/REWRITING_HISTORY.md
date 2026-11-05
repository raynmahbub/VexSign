# Rewriting merge commit messages

Git commit messages are part of the commit hash. Renaming an existing
`Merge pull request #N from …` commit therefore rewrites that commit and every
commit after it. This repository keeps the merge topology but lets maintainers
replace those merge messages with the message of the commit that was merged
(the merge's second parent).

The operation is **destructive to history**: it requires a force-push to the
default branch, every collaborator must re-sync, and open pull requests need
rebasing. It is not part of a normal release.

## Tool

`tools/rewrite-merge-messages.sh` runs the rewrite in a throwaway clone and
never pushes. It writes a verified bundle and prints the force-push command for
a maintainer to review and run.

```bash
# What will change, why it is safe, and where the bundle is written
tools/rewrite-merge-messages.sh

# Keep the issue numbers: "fix: the last five unused bindings (#74)"
tools/rewrite-merge-messages.sh --pr-numbers

# Explicit repository/branch/output
tools/rewrite-merge-messages.sh \
  --source https://github.com/raynmahbub/VexSign.git \
  --branch main \
  --bundle /tmp/vexsign-main-rewritten.bundle
```

The script:

1. clones `--source` (full history required),
2. replaces only merge commits whose subject starts with `Merge pull request`,
   using the full message of `<merge>^2`,
3. asserts that the tree, commit count and merge count are unchanged and that
   no `Merge pull request` subject remains,
4. asserts that no non-merge commit message changed,
5. writes a complete bundle and prints its SHA-256 plus the push command.

Merge commits with hand-written messages are left alone. Non-merge commits are
never edited.

## Apply

Review first:

```bash
git fetch /tmp/vexsign-main-rewritten.bundle main:refs/heads/main-rewritten
git diff --stat main main-rewritten          # must be empty
git log --oneline -20 main-rewritten
```

Back up the old tip and force-push with a lease:

```bash
git branch backup/main-before-rewrite 0bb7edf4300cda27cba6eb0aad71c88010b57f65
git push --force-with-lease=main:0bb7edf4300cda27cba6eb0aad71c88010b57f65 \
  origin main-rewritten:main
```

If `main` is protected, temporarily allow force pushes (or use an admin
account), then restore the rule. Keep `backup/main-before-rewrite` until all
collaborators have moved. Do not use plain `--force`.

Afterwards:

```bash
git fetch
git reset --hard origin/main
```

Everyone else must run the same reset; open PRs based on the old history must
be rebased onto the new `main`.

## Notes

- The issue number is lost unless `--pr-numbers` is used. The pure variant
  produces two commits with the same subject: the renamed merge and the
  original commit it merged.
- GitHub keeps pull-request timelines tied to the old commits. The tree is
  identical, so the code is unchanged, but the timeline can look odd.
- Running the script twice is a no-op after the first rewrite: no
  `Merge pull request` subjects remain.
- The script requires bash and git; `git filter-branch` is deprecated upstream
  but is available everywhere this repo is built. A future migration to
  `git filter-repo` should preserve these validations.
