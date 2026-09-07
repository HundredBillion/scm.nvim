# Committed File Entries

## Summary

The SCM Panel must show every file changed on the current branch, whether the change is already committed or remains pending in Git's index or working tree.

## User outcome

When the Panel opens for a feature branch, its Repository Section lists:

- files committed since the branch diverged from the repository's default branch;
- staged, unstaged, untracked, renamed, deleted, and conflicted files;
- each path at most once, with pending state taking precedence over committed-only state.

Committing a pending file must not make it disappear while that commit remains part of the branch's divergence from the default branch.

## Comparison base

Core tries `refs/remotes/origin/HEAD`, local `main`, and local `master` in that order. A candidate is usable when Git can calculate its merge base with `HEAD`; metadata lookup and ref validation are left to Git rather than duplicated in Core.

For a non-default branch, committed files are calculated from the merge base of the default branch and `HEAD` through `HEAD`. For the default branch itself, Core compares its remote default ref with `HEAD`, allowing local commits that have not been pushed to remain visible.

Before reporting merge-base changes, Core compares the current branch tree with the resolved default-branch tree. If those trees are identical, Core emits no Committed File Entries. This covers squash-merged and rebased branches whose content is fully present on the default branch even though their original commits are not ancestors of it.

If no comparison base can be resolved, or the repository has no commits, Core continues returning pending files without treating base-resolution failure as a repository error.

## Core contract

A File Entry is one of two source states:

```lua
{ path = "lua/scm/core.lua", xy = ".M" }
{ path = "lua/scm/core.lua", commit_status = "M" }
```

`xy` remains Git's raw porcelain-v2 XY Code for pending files. `commit_status` remains Git's raw `diff --name-status` code for committed-only files. Core does not synthesize an XY Code for committed files.

When Core resolves a Comparison Base, the Repo Entry carries it as `comparison_base`. Renderers may use that value to open a committed-file diff without reimplementing Git branch policy.

When both scans contain the same path, Core emits the pending File Entry. The Repo Entry is clean only when the merged File Entry list is empty.

## Panel presentation

Pending File Entries keep their current letter, color, and Mixed State marker.

Committed-only File Entries display their `git diff --name-status` letter and a `✓` marker using a dedicated `ScmCommitted` highlight. Their diff action compares the file against the Repo Entry's Comparison Base. Pending File Entries keep the existing index/working-tree diff, while untracked files continue to report that no diff is available. Repository expand/collapse, filtering, file opening, and lazygit actions continue to operate on both entry types.

## Refresh and failure behavior

Every repository refresh runs the pending-status scan and committed-branch scan as one logical operation. The callback receives one merged Repo Entry and fires once.

Failure of `git status` remains a repository error. Failure to resolve a default branch, merge base, or committed diff degrades to pending-only results so repositories without conventional branch metadata remain usable.

## Verification

Tests must prove:

1. A clean feature branch with committed divergence emits committed File Entries.
2. Committing a formerly pending file does not remove it from the Repo Entry.
3. Pending state overrides committed-only state for the same path.
4. Staged, unstaged, untracked, renamed, deleted, and conflicted XY behavior remains unchanged.
5. Default-branch fallback and no-base degradation preserve pending files.
6. The Panel renders committed-only entries distinctly without changing pending rendering.
7. The real Sprite feature branch reports its committed files through the public refresh interface.
8. A committed-only row opens Gitsigns against its Comparison Base while a pending row keeps the default Gitsigns comparison.
9. A squash-merged feature branch with the same tree as the default branch emits no Committed File Entries.

## Out of scope

- Commit history, commit rows, log browsing, or blame.
- Comparing arbitrary user-selected refs.
- Replacing lazygit or implementing Git write operations in SCM.
- Showing files whose changes are already merged into the default branch.
