# Drop Snacks and file-tree coupling

## Summary

`scm.nvim` currently ships two sidebars that draw the same Repo Entries: the legacy
Panel, built on a Snacks picker, and the standalone Workspace (`auto`, `terminal`,
`sprite` renderers). The Panel is the default, so installing the plugin pulls in
snacks.nvim, and its actions open lazygit. The scanned folder comes from whichever
file tree it recognises: the Snacks Explorer, SVGTree, Neo-tree, or LazyVim's root.

`scm.nvim` is growing into its own git client. It will own every view it shows,
will not hand work to lazygit, and will not depend on any particular file tree.
This change removes the Panel, every Snacks and lazygit integration, and every
file-tree and LazyVim lookup. The standalone Workspace becomes the only sidebar,
and it scans Neovim's current directory.

This is the first of several sub-projects. Later sub-projects add git actions,
diffs and hunk staging, history and branches, remotes and stash, and rebase. Each
gets its own PRD.

## User outcome

- `<leader>gs` still opens the sidebar listing every repository and its changed
  files, with the instant-open behaviour from the previous change.
- The plugin loads and runs with no snacks.nvim, LazyVim, SVGTree, or Neo-tree
  installed, and behaves the same whichever of them is installed.
- The sidebar scans Neovim's current directory, and follows it when it changes.

## Out of scope

The Panel's fuzzy filter, its `d` diff key, and its lazygit keys (`g`, `<CR>` on a
repository header) are removed and not replaced here. The user will build their
own filter and diff in later sub-projects.

The Panel's "scanning…" title is also removed and not replaced: the standalone
Panel shows no in-progress indicator. Where a busy signal belongs is part of the
user's later Panel design.

## Interface

- `require("scm").setup(opts)` defaults to `renderer = "auto"`. Valid renderers
  are `auto`, `terminal`, and `sprite`.
- `renderer = "snacks"` raises: `The Snacks renderer was removed. Use renderer =
  'auto' or 'terminal'.`
- `require("scm").toggle()`, `.focus(side)`, and `.handoff(fn)` keep their current
  behaviour, always backed by `scm.workspace`.
- `on_explorer = function(root) ... end` stays the only way the sidebar's explorer
  key opens a file tree. With no `on_explorer`, the key shows: `SCM: No file
  explorer is connected, so there's nothing to open. See "Connecting a file
  explorer" in the README.`
- The module `scm.panel` no longer exists. A config that names it fails to load,
  which is intended.

## Scanned folder rule

The sidebar scans Neovim's current directory of the editor window it was opened
from (`vim.fn.getcwd()`), which honours `:cd`, `:tcd`, and `:lcd`. It knows no file
tree. Every explorer that changes folders (SVGTree, Neo-tree, the Snacks Explorer)
already does so by changing that directory, so the sidebar follows any of them.

- `scope.current()` and `scope.candidate()` both return the normalized real path of
  the current directory.
- The per-tab memory (`vim.t.scm_explorer_root`, `scope.remember()`,
  `scope.establish()`) is removed; Neovim's tab- and window-local directories
  replace it.
- While the sidebar is open, any `DirChanged` event re-reads the directory of the
  editor window the Panel tracks (`state.editor`), or the tab's directory when that
  window is gone. If it differs from the Panel's root, the Panel moves to it and
  refreshes, showing the new folder's cached rows first when it has any. It calls
  `policy.reset` first, so a scan of the old directory still running cannot
  replace the new directory's rows. An `:lcd` in another window (a terminal, a
  plugin) leaves the Panel where it is. Moving between windows with different
  local directories fires no `DirChanged`, so the Panel picks up the new window's
  directory the next time it opens.
- The startup warm-up scans the current directory at startup.

## Sharing the left side with a file tree

The plugin no longer opens or closes any file tree itself. Keeping one sidebar on
screen at a time is the user's config's job, using the existing pieces:

- Opening SCM: the config's `<leader>gs` mapping closes its tree, then calls
  `require("scm").toggle()`.
- Opening the tree from SCM: the config passes `on_explorer`, which typically calls
  `require("scm").handoff(function() <open the tree> end)`.

## Code changes

| File | Change |
|---|---|
| `lua/scm/panel.lua` | Deleted. |
| `lua/scm/init.lua` | Always loads `scm.workspace`; default `auto`; the `snacks` error above. |
| `lua/scm/refresh.lua` | Remove the legacy Panel autocmds (save, focus, window enter) and the lazygit `TermClose` re-scan. Keep the refresh policy and the warm-up. |
| `lua/scm/workspace.lua` | Remove the lazygit `TermClose` trigger, the SVGTree root read and close in `toggle()`, and the SVGTree fallback in the explorer action. Add the `DirChanged` trigger. Keep the save and focus triggers. |
| `lua/scm/scope.lua` | Reduced to the current-directory rule above. |
| `lua/scm/core.lua` | Remove the `focus_debounce_ms` default; only the removed Panel triggers read it. Moving the cursor into the Panel no longer refreshes. |

## Tests

- `core_test`: point the display and item-building assertions at `scm.model`.
  Delete the assertions that exercise Snacks picker actions and lazygit calls.
- `explorer_scope_test`: replaced by a scope test covering `:cd`, `:tcd`, and
  `:lcd`, with a Snacks Explorer, Neo-tree, and SVGTree loaded but ignored.
- `workspace_test`: the explorer key calls `on_explorer` with the root, and
  shows the no-explorer message without it. A `:cd`, `:tcd`, or `:lcd` in the editor window while open
  re-scans the new directory and shows its cached rows first. An `:lcd` in another
  window leaves the Panel unchanged. A `DirChanged` while closed does nothing. A
  slow scan of the old directory landing after the move is not rendered.
- `refresh_events_test`: delete the legacy Panel section.
- `warm_test`: run only the standalone renderers.
- `handoff_test`: delete the Panel half; keep the `scm.transition` checks.
- `sidebar_handoff_pty`: delete. It drives Snacks pickers and is not run in CI.
- New: load every `scm.*` module, set up, toggle open and closed, and assert that
  `snacks`, `LazyVim`, `svgtree`, and `neo-tree` were never loaded or read.
- `init`: `renderer = "snacks"` raises the removal message.
- The CI workflow lists the remaining suites.

## Documentation

- New ADR `0004-own-the-sidebar.md`, superseding `0001-snacks-render-layer.md`.
  It records both decisions: no Snacks, and no file-tree knowledge. ADR 0001 gets
  a "Superseded by 0004" line.
- README: replace the "Legacy Snacks install" and Snacks Explorer handoff sections
  with a standalone install and a "Connecting a file explorer" section (the
  name the no-explorer message points to) showing a generic handoff example.
- CONTEXT.md: the Panel and Renderer entries describe the Workspace only. The
  Explorer Root entry becomes the Working Directory entry.
- Drafts of all prose changes are shown before they are applied.

## User config

`~/.config/nvim-lazyvim-2026-09-19/lua/plugins/scm.lua` changes to `main = "scm"`,
`opts = { renderer = "auto", on_explorer = ... }`, drops the `folke/snacks.nvim`
dependency, and maps `<leader>gs` to close SVGTree, then call
`require("scm").toggle()`. The block that disables LazyVim's own `<leader>gs`
stays.

## Delivery

Branch `feat/drop-snacks`, stacked on `perf/instant-open` (PR #8). The PR targets
that branch and is retargeted to `main` after PR #8 merges.
