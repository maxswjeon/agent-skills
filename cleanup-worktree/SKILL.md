---
name: cleanup-worktree
description: Inventory all git worktrees, detect which ones have been merged into the integration branch (including squash merges where commit hashes don't match), and remove merged worktrees plus their local branches. Trigger when the user asks to "clean up worktrees", "prune worktrees", "remove merged worktrees", "delete merged branches", or any phrasing about tidying a `.worktrees/` directory or stale feature branches. Use this even when the user only says "clean up branches" if a worktrees directory is present.
---

# Cleanup merged worktrees

Inventory git worktrees, classify each as merged / active / ambiguous, confirm with the user, then remove the merged ones and delete their local branches.

The hard part is squash merges. After GitHub squashes a feature branch into `develop`, the original commits don't exist on `develop`, so `git branch --merged` and commit-hash comparisons silently report the branch as unmerged. This skill combines several signals so squash-merged branches get cleaned up too.

## 1. Determine the integration branch

Default to `develop`. If the repo has no `develop` (check `git show-ref --verify --quiet refs/heads/develop`), fall back to `main`. If the user named a different base branch, use theirs.

Fetch it before doing anything else — local `develop` is often behind:

```bash
git fetch origin <integration-branch> --quiet
```

All subsequent comparisons use `origin/<integration-branch>` so a stale local copy doesn't cause false negatives.

## 2. Inventory worktrees

```bash
git worktree list --porcelain
```

Skip:
- The **main** worktree (the one not under `.worktrees/`, usually the repo root). Never remove it.
- The **current** worktree (the one Claude is running in). Removing it will fail anyway, but flag it so the user knows.
- Any worktree on the integration branch itself.

## 3. Classify each worktree

For each candidate worktree, gather these signals in order. Stop at the first decisive one.

### A. Hard blockers — keep regardless of merge status

- **Uncommitted changes**: `git -C <path> status --porcelain` is non-empty. Never auto-remove; the user could lose work.
- **Open PR**: `gh pr list --state open --head <branch> --json number --limit 1` returns a PR. Branch is still in flight.

If either is present, classify as **active** and move on.

### B. Merge signals — any one of these means MERGED

1. **Ancestor of integration branch** (regular merge / fast-forward):
   ```bash
   git merge-base --is-ancestor <branch> origin/<integration-branch>
   ```
   Exit 0 means every commit on `<branch>` is reachable from the integration branch.

2. **Closed-as-merged PR exists**:
   ```bash
   gh pr list --state merged --head <branch> --base <integration-branch> \
     --json number,mergedAt --limit 1
   ```
   Non-empty result means GitHub squash- (or rebase-, or regular-) merged this branch. This is the most reliable squash detector when the repo lives on GitHub.

3. **Patch-equivalence test** (catches squash merges even without GitHub, and when develop hasn't moved past the merge):
   ```bash
   mb=$(git merge-base origin/<integration-branch> <branch>)
   tmp=$(mktemp -d)
   git worktree add --quiet --detach "$tmp" origin/<integration-branch>
   if git diff "$mb".."<branch>" | git -C "$tmp" apply --reverse --check 2>/dev/null; then
     echo "merged (patch already applied to develop)"
   fi
   git worktree remove --force "$tmp"
   ```
   This works because if `develop` already contains the changes the branch added since the merge-base, then those changes can be reverse-applied (i.e. removed) cleanly. If the branch has zero commits past the merge-base, treat that the same as MERGED — there's nothing to integrate.

### C. Ambiguous case

If the merged-PR signal says **yes** but the ancestor and patch-equivalence tests say **no**, that usually means: the PR was squash-merged, then `develop` evolved further, so the branch's patch no longer applies cleanly to current `develop` even though its content is in there. This is *probably* safe to clean up, but list it separately and ask before removing — the alternative explanation is that the user kept committing to the branch after the merge.

If no signals fire, classify as **active**.

## 4. Report and confirm

Show the user a grouped summary before touching anything:

```
MERGED (safe to remove):
  feat/foo            → PR #123 merged 2026-04-30
  chore/bar           → ancestor of develop
  fix/baz             → patch already in develop (squash detected)

AMBIGUOUS (PR merged but develop has diverged — confirm):
  feat/quux           → PR #110 merged, but tree differs from develop

ACTIVE (kept):
  feat/wip            → 3 uncommitted files
  feat/in-review      → open PR #200
  feat/exploring      → no merge signal found
```

Ask: "Remove the N merged worktrees? (and the M ambiguous ones?)"

Don't bundle the active ones into the question — those are never on the table.

## 5. Remove

For each confirmed worktree:

```bash
git worktree remove <path>
git branch -D <branch>
```

- Use `git worktree remove` **without** `--force` by default. If it fails because of dirty state, that's a signal to stop and re-check — something changed since classification. Only pass `--force` if the user explicitly says so.
- Use `git branch -D` (capital D, force) because `git branch -d` refuses to delete branches it can't see as merged — and squash-merged branches always look unmerged to git.
- If the branch tracks a remote that's already deleted (gone), that's expected after a PR merge; no extra action needed locally. Do **not** push deletions to the remote unless the user asks.

After removal, run `git worktree prune` to clean up any stale administrative entries.

## 6. Final report

Tell the user what was removed and what was kept, with one-line reasons for the kept ones. Keep it short — they just want to know the directory is tidy and nothing important got deleted.

## Common pitfalls

- **Forgetting to fetch.** Local `develop` lags origin. A branch that was merged this morning will look unmerged until you fetch.
- **Trusting `git branch --merged`.** It only catches fast-forward and merge-commit integration. Squash merges (the common case on GitHub) are invisible to it.
- **Using `git diff develop..branch == empty` as the only test.** This works *only if develop's tip equals the post-squash commit*. As soon as another PR merges on top, develop moves and the diff stops being empty even though the branch is fully integrated. Use the merge-base–based patch-equivalence test from §3.B.3 instead.
- **`--force` on `worktree remove`.** Skips the dirty-tree check and silently throws away uncommitted work. Only use when the user accepts that risk.
- **Pushing branch deletions.** Removing a worktree is local. Deleting the remote branch is a separate, more destructive action — don't bundle it in unless asked.
- **Removing the worktree you're running in.** Git refuses, but the error is cryptic. Detect it up front by comparing `git rev-parse --show-toplevel` to each worktree's path.
