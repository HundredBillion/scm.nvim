# PRD: Explorer-Scoped SCM Repository Discovery

**Date:** 2026-07-26
**Status:** Approved + grilled (2026-07-26)
**Owner:** David Lee
**Parent feature:** Multi-repo Source Control Panel (Sprite Phase 0)

## 1. Problem

The SCM Panel currently discovers repositories by scanning a manually configured
list of Roots. This makes the Panel disagree with the file explorer: a directory
can be visible in the explorer but absent from Source Control until the user adds
its parent directory to SCM configuration.

The desired behavior matches VSCode's workspace model. The file explorer defines
the active filesystem scope, and Source Control shows every Git repository within
that scope. Hiding or closing the explorer must not discard the scope.

## 2. Goals

1. Derive SCM's repository scope from the active file explorer instead of a
   manually maintained directory list.
2. Support the active Snacks explorer and provide the same behavior for Neo-tree.
3. Remember the most recently observed explorer root separately in each Neovim
   tab, including after the explorer closes.
4. Discover the Git repository containing the resolved Explorer Root plus every
   repository beneath it, including repositories nested more than two levels
   deep.
5. Preserve Core's UI independence: explorer-specific knowledge must not enter
   `scm.core`.
6. Keep repository discovery non-blocking for large directory trees.

## 3. Non-goals

- Mirroring which individual directories are expanded or collapsed in the
  explorer. Collapsed folders remain part of the workspace scope.
- Synchronizing SCM's Repository Section collapse state with explorer folders.
- Adding filesystem watchers for newly created or deleted repositories. Existing
  open, manual, and focus-triggered Refresh behavior remains responsible for
  rediscovery.
- Introducing a general workspace manager independent of the SCM Panel.
- Requiring both Snacks and Neo-tree to be installed or loaded.
- Preserving the hard-coded default Roots as a second competing source of truth.

## 4. User-visible behavior

### 4.1 Scope resolution

Each Neovim tab establishes one persistent Explorer Root in this order:

1. The root of the currently active file explorer in the current tab.
2. The project root that LazyVim would use to open its root-scoped explorer.
3. Neovim's current working directory.

The initial value persists for the life of the tab and changes only when a file
explorer in that tab establishes a different root. Buffer changes and full
Refreshes do not recalculate it. The Panel lists the Explorer Root's containing
Git repository, when one exists, plus every repository beneath it. A clean
repository is still shown.

### 4.2 Explorer lifecycle

- Opening a Snacks explorer records `picker:cwd()` for that tab.
- If an open Snacks explorer changes root, SCM reads the current `picker:cwd()`
  immediately before replacing the explorer with the SCM Panel.
- Neo-tree supplies its current filesystem root through its adapter when loaded.
- Closing either explorer leaves the remembered tab scope intact.
- Different Neovim tabs may remember different roots.
- Each tab owns its Repo Entries, Repository Section collapse state, and
  full-Refresh coordination. Activity in one tab cannot replace or rerender the
  SCM Panel in another tab.
- Opening or changing buffers does not replace the tab's Explorer Root.
- A changed Explorer Root causes the next Panel open to scan the new scope. If
  the Panel is visible when a provider reports the change, SCM begins one
  coalesced full Refresh for the new scope.

### 4.3 Repository discovery

Discovery includes:

- The Git repository containing the Explorer Root, including when `.git` is in
  an ancestor directory.
- An Explorer Root that is itself a Git repository.
- Direct child repositories.
- Repositories nested at arbitrary depth.
- Worktrees and submodules whose `.git` entry is a file rather than a directory.
- An Explorer Root reached through a symlink, after normalizing that Root to its
  real path. Recursive discovery does not follow nested directory symlinks.

The explorer's visual expansion state has no effect on discovery. A containing
repository is emitted only once if descendant discovery finds the same path.
Every discovered Repository Section shows repository-wide status; File Entries
are not filtered to the Explorer Root when that Root is a subdirectory of the
repository.

## 5. Design

### 5.1 Scope module

A new UI-side module owns scope resolution and exposes a small interface:

```lua
scope.establish()
scope.remember(path)
scope.current()
```

`establish()` initializes a tab once using the fallback order in section 4.1.
`remember(path)` normalizes a valid explorer directory, stores it as tab-local
state, and reports whether the Explorer Root changed. `current()` returns the
persistent Explorer Root and establishes it only when absent.

The module hides provider detection, path normalization, tab-local persistence,
and fallbacks from the Panel. The Panel only needs the resolved path.

### 5.2 Explorer adapters

Adapters are optional and side-effect free when their provider is unavailable:

- **Snacks:** query active pickers with source `explorer`, restricted to the
  current tab, then return the picker's `cwd()`.
- **Neo-tree:** query the current tab's filesystem state and return its root path.

The Snacks configuration's existing explorer `on_show` callback will also call
`scope.remember(picker:cwd())`. This records the root before the explorer can
close after a file is opened while preserving the existing `svgtree` callback.
Before SCM replaces a currently visible explorer, its adapter records the
provider's latest root in case the user navigated upward or changed directory
after `on_show`.

No explorer module is required eagerly. Missing providers return no result and
allow resolution to continue.

### 5.3 Core contract

`scm.core` continues to accept discovery inputs as plain Lua data and imports no
UI modules. The Panel resolves the active Explorer Root and passes it to Core.

The fixed `roots` default is removed. Full Refresh accepts the persistent
Explorer Root for that invocation. Scoped per-repository Refresh remains
unchanged because it already receives an explicit repository path.

Repository discovery becomes asynchronous. It first asks Git for the repository
containing the Explorer Root, then recursively locates `.git` entries beneath the
Explorer Root without a fixed maximum depth by running the existing
`find ... -name .git -prune` strategy through `vim.system`. The existing timeout
applies to discovery as well as the asynchronous
`git status --porcelain=v2 --branch` calls. Results are normalized and
deduplicated before status collection. Discovery and status completion still
produce one scheduled Repo Entry callback.

Only one full Refresh per tab may be in flight. Each request receives a
monotonically increasing generation and captures its Explorer Root. If another
request arrives for that tab while one is running, SCM remembers only the newest
requested Root. Results whose generation is no longer current are discarded;
after the running request lands, SCM performs exactly one queued Refresh for the
newest Root. This prevents an old workspace from replacing the current Panel
without stacking discovery processes for one tab.

### 5.4 Panel flow

```text
<leader>gs
  -> capture a visible explorer's latest Root, if present
  -> read the persistent Explorer Root for the current tab
  -> close the active explorer
  -> open SCM Panel in scanning state
  -> asynchronously discover the containing and nested repositories
  -> asynchronously collect statuses
  -> render Repo Entries
```

A manual or focus-triggered full Refresh reuses the persistent Explorer Root;
it does not derive scope from the current buffer. Existing Repository Section
collapse behavior, file actions, lazygit handoff, sorting, and formatting remain
unchanged.

### 5.5 Tab-scoped Panel state

Panel view state is keyed by Neovim tab rather than stored in one global entries
table. Each tab state contains its Explorer Root, Repo Entries, Repository
Section collapse map, current Refresh generation, and newest queued Root.

Configuration and highlight definitions remain global. Core discovery and status
operations use request-local state and do not impose a process-wide in-flight
guard. The Panel coalesces overlapping full Refreshes independently per tab.

Closing a tab invalidates its state. Any asynchronous callback that lands after
the tab or its request generation has been invalidated is discarded without
rendering. A scoped per-repository Refresh updates every live tab state already
containing that repository, while only visible SCM pickers are rerendered.

## 6. Error handling

- An unavailable explorer provider is ignored without notification.
- An invalid remembered path is discarded and fallback resolution continues.
- If no valid directory can be resolved, the Panel remains open and displays a
  clear scope error rather than reporting an empty repository list.
- A discovery process failure or timeout is reported in the Panel without
  blocking Neovim; the last successfully rendered Repo Entries remain visible.
- Per-repository Git failures continue to produce independent warning rows.
- Stale results from a Refresh started for a previous scope must not replace the
  current scope's entries.
- Closing or refreshing one tab cannot mutate another tab's Panel state.

## 7. Testing

Headless tests will cover:

1. Active Snacks root takes precedence and is remembered.
2. Active Neo-tree root takes precedence when Snacks has no active explorer.
3. Missing or unloaded providers are harmless.
4. A new tab establishes its Root from LazyVim's project root, then cwd, exactly
   once when no explorer is active.
5. Buffer changes and full Refreshes do not alter an established Explorer Root.
6. Remembered roots are isolated by tab.
7. Repo Entries, collapse state, and Refresh generations are isolated by tab.
8. A scoped repository Refresh updates each live tab containing that repository.
9. A callback landing after its tab closes is discarded safely.
10. Closing the explorer preserves the remembered root.
11. An invalid established Root is replaced using the initialization fallback
    order.
12. Discovery includes the containing repository, the Explorer Root repository,
    direct children, deeply nested repos, and `.git` files.
13. A symlinked Explorer Root is normalized, while nested directory symlinks are
    not traversed.
14. Duplicate repository paths are emitted once.
15. A containing repository reports changed files both inside and outside an
    Explorer Root that points at one of its subdirectories.
16. A scope change during Refresh cannot publish stale Repo Entries.
17. The existing Core parser, sorting, refresh, and collapse-navigation tests
    remain green.

A manual check will open Snacks at two different roots in separate tabs, close
the explorers, and confirm `<leader>gs` shows the correct repository set in each
tab on the first keypress.

## 8. Success criteria

1. Opening the file explorer at `~/Projects` and then opening SCM shows Sprite
   without configuring `~/Projects` in SCM.
2. Opening the explorer at a different directory changes SCM's repository set on
   its next open or full Refresh.
3. SCM retains that scope after the explorer closes and keeps scopes separate by
   tab.
4. Switching buffers never changes an established Explorer Root.
5. SCM contents and interactions in one tab never overwrite another tab's Panel.
6. The repository containing the Explorer Root and arbitrarily nested
   repositories beneath it are discoverable.
7. Discovery never blocks the Neovim UI.
8. `scm.core` remains usable without Snacks, Neo-tree, or LazyVim imports.

## 9. Intentional differences from VSCode

- VSCode can prompt before opening a repository above a workspace folder. SCM
  always includes the repository containing the Explorer Root, as approved for
  this workflow.
- VSCode exposes repository scan depth and ignored-folder settings. SCM scans the
  complete Explorer Root subtree without a depth cap; visual folder expansion
  and collapse do not affect discovery.
- VSCode maintains repository state continuously. Phase 0 retains SCM's existing
  event-driven model: full Refresh on Panel open, manual request, focus events,
  or Explorer Root change; scoped Refresh after lazygit exits.
