# PRD: Multi-Repo Source Control Panel (Sprite Phase 0.1)

**Date:** 2026-07-20
**Status:** Approved + grilled (2026-07-20). Glossary: `phase_0/CONTEXT.md`; ADRs 0001-0002.
**Owner:** David Lee
**Working name:** `scm` (Lua module namespace; standalone plugin name decided at
promotion time)
**Parent plan:** `~/Downloads/terminal-project-brief.md` §6 Phase 0.1, §7

---

## 1. Problem

David works across ~13 git repositories simultaneously (`~/MyServe1.0`
microservices plus `~/Code`). Switching between repos is solved (existing
`<leader>gR` snacks picker in `git-repos.lua`). **Scanning is not**: there is
no way to see all changes across all repos at a glance, the way VSCode's and
Zed's Source Control panels do. Today that requires visiting repos one at a
time. The Neovim ecosystem has no multi-repo answer (gitsigns, fugitive,
neogit, diffview are all single-repo) — this niche is validated open.

## 2. Goals

1. A persistent left-sidebar panel that **visually reads like VSCode's Source
   Control panel**: dirty repos with branch/ahead-behind/count, expanded into
   changed-file rows with status letters and colors.
2. **Read-oriented panel, lazygit for muscle**: anything write-shaped is one
   keypress into lazygit, cd'd into the right repo. The panel never
   reimplements git operations.
3. **Portable core** (Sprite Principle 4): all git/scanning logic in a
   UI-free module emitting plain Lua data, so the render layer can be swapped
   (snacks today → bare-Neovim renderer for a future distro → Sprite native
   panel in Phase 5.2) without touching the brain.

### Non-goals (v1 cut line — explicit)

- Stage/unstage, commit, push/pull from the panel (lazygit's job)
- File watchers, timers, auto-refresh (refresh on open + manual `r` only)
- Commit graph, log views
- Collapsing/expanding repo sections (dirty-first ordering suffices at ~13 repos)
- Rust/`gix` core
- Standalone plugin packaging (promote from config when stable)
- Icons beyond status letters (svgtree/native icons are a later-phase concern)
- CRDT/collab anything

## 3. Users & context

- Single user initially (David), LazyVim + snacks.nvim, lazygit 0.62 installed,
  gitsigns present. macOS (M5) and Arch Linux.
- Existing partial art in config: `lua/plugins/git-repos.lua` — repo scanner
  (`find -maxdepth 2 -name .git -prune` over roots), fast branch reader (raw
  `.git/HEAD` with git fallback for worktrees), snacks picker, lazygit handoff.
  The scanner and branch reader are lifted into the new core; the `<leader>gR`
  picker remains untouched (switching stays solved separately).

## 4. Design

### 4.1 Components

```
~/Projects/Sprite/phase_0/scm.nvim/lua/scm/core.lua    -- portable brain: scan, status, refresh. NO UI imports.
~/Projects/Sprite/phase_0/scm.nvim/lua/scm/panel.lua   -- snacks picker render layer (disposable face)
~/Projects/Sprite/phase_0/scm.nvim/tests/core_test.lua -- headless assert tests (nvim -l)
~/.config/nvim/lua/plugins/scm.lua                     -- thin spec: dir=<plugin path>, <leader>gs key, opts
```

The plugin is a real plugin directory inside the Sprite repo (versioned from
day one; ~/.config/nvim is not a git repo), loaded via lazy.nvim local `dir`.
`<leader>gs` deliberately overrides LazyVim's single-repo git_status picker
(decided at grilling; the old picker stays reachable via
`:lua Snacks.picker.git_status()`).

Config: `roots = { "~/MyServe1.0", "~/Code" }`, `depth = 2` (same defaults as
git-repos.lua).

### 4.2 Core data contract

`core.refresh(cb)` → `cb(results)` where `results` is a list sorted
dirty-repos-first (alpha within group), each entry:

```lua
{
  name   = "krypton-api",
  path   = "/Users/davidlee/MyServe1.0/krypton-api",
  branch = "main",           -- or short SHA when detached
  ahead  = 2, behind = 1,    -- 0 when no upstream
  files  = {                 -- empty when clean; ONE entry per file
    { path = "app/models/device.rb", xy = ".M" },  -- raw porcelain XY code (ADR 0002)
    { path = "lib/staged_and_edited.rb", xy = "MM" },
    { path = "spec/new_spec.rb",     xy = "??" },
  },
  clean  = false,
  err    = nil,              -- string when git failed for this repo
}
```

This table is the renderer contract for snacks (now), a bare-Neovim renderer
(possible future distro), and Sprite's native panel (Phase 5.2). The XY code
is stored verbatim; display letters/markers/colors are derived per renderer
(ADR 0002).

### 4.3 Core behavior

- `scan()`: find `.git` under roots (dirs and files — worktrees/submodules
  have `.git` files), depth-limited, prune.
- `status(repo, cb)`: async `git -C <repo> status --porcelain=v2 --branch`
  via `vim.system`, 5s timeout. Porcelain v2 supplies branch head, upstream,
  `ab +N -M`, and typed entries (`1` changed, `2` renamed, `u` unmerged,
  `?` untracked) with XY staged/unstaged codes — one call per repo, no
  follow-ups.
- `refresh(cb)`: scan → fan out all `status` calls concurrently → aggregate →
  single `vim.schedule`d callback. In-flight guard: refresh requested while
  one is running is dropped.

### 4.4 Panel (snacks render layer)

Custom snacks picker source using the explorer's sidebar layout preset
(persistent left rail). Items = repo header rows + indented file rows.

Row anatomy (VSCode SCM visual language):

```
 ▼ krypton-api  main ↑2↓1                 4     ← bold name, branch, arrows only when ≠0, count badge
     M   device.rb        krypton-api/app/models
     M✱  staged_edited.rb krypton-api/lib        ← mixed state: letter + ✱ marker
     ??  scratch.rb       krypton-api
 ▶ argon.simplexmobility.com  main         ─    ← clean repo: dimmed one-liner
 ⚠ broken-repo  git: not a repository           ← per-repo error row, dimmed
```

Status display (derived from the raw XY code, per renderer):
- Letter = working-tree state (Y) when set, else index state (X).
- `✱` marker appended only in the mixed state (both X and Y set, e.g. `MM`).
- Colors: M = orange, A/?? = green, D = red, R = yellow; staged-only
  (`M.`-style) tinted green.
- Filename first; the dimmed trailing column is always `repo/dir` so every
  file row is self-identifying (survives filter orphaning — see Filtering).
- Repo headers show a dimmed parent-path suffix only when two repos share a
  name across roots.

**Filtering:** typing filters the flat item list; repo headers that don't
match drop out and file rows stand alone — acceptable because rows are
self-identifying. Headers remain matchable by repo name.

**Persistence:** `jump = { close = false }`, `auto_close = false` (the
explorer preset's defaults) — opening a file keeps the panel open; the
scanning loop is open-glance-open-next. `<leader>gs` toggles it away.

**Post-lazygit refresh:** a panel-launched lazygit triggers one
`core.refresh()` on its TermClose. Lazygits launched outside the panel don't.

**Cursor stability:** after any refresh, the cursor re-anchors to the same
repo+file when still present, else the nearest surviving row (refresh can
reorder — a committed repo sinks to the clean section).

Keys:

| Key | File row | Repo header |
|---|---|---|
| `<CR>` | open file | open lazygit cd'd into repo |
| `d` | open file + `:Gitsigns diffthis` (`??` files: open + notify "untracked — no diff") | — |
| `g` | lazygit for the file's repo | lazygit for repo |
| `r` | refresh | refresh |
| typing | snacks fuzzy filter across all changed files in all repos | |

Error (`⚠`) rows behave like repo headers: `<CR>`/`g` still open lazygit
cd'd there (the repo may be usable even when porcelain parsing failed);
`d` is a no-op.

`<leader>gs` toggle mechanics: if the SCM panel is open, close it; otherwise
close any open explorer picker, then open SCM (one left-rail activity at a
time, VSCode-style). Explorer's `<leader>e` opening over the SCM panel is
acceptable (last-opened wins).

### 4.5 Data flow

```
<leader>gs → panel.toggle()
  → close explorer picker if open
  → open picker titled "Source Control (scanning…)"
  → core.refresh(cb) → items rebuilt → title "Source Control"
r → core.refresh → items swap in place
```

No caches, no background work. Staleness bounded by last open/`r`.

## 5. Error handling

- Per-repo git failure/timeout → `err` set → ⚠ row; other repos unaffected.
- Missing root dir → skipped silently (matches existing behavior).
- Zero repos → single informational row.
- git not on PATH → one `vim.notify` error; panel doesn't open.
- Concurrent refresh → dropped (in-flight flag).

## 6. Testing

- `tests/core_test.lua`, run via `nvim -l` (plain asserts, no framework):
  - Porcelain-v2 parser fixtures: ordinary changes, mixed state (`MM` — one
    entry, xy preserved raw), renames (tab-separated paths), untracked,
    unmerged, detached HEAD, no upstream (missing `ab` header), empty output
    (clean).
  - Integration: temp dir with two synthetic repos (one dirty, one clean) →
    `refresh` returns correctly sorted/shaped results.
- Panel: manual checklist — open/toggle, swap-with-explorer, fuzzy filter,
  all keys, error row, clean-repo row, ~13-repo scan latency acceptable.

## 7. Success criteria

1. `<leader>gs` shows the state of all ~13 repos in one glance, correctly,
   in under ~1s on the M5.
2. Every changed file across every repo is reachable (open/diff) in ≤3
   keypresses from anywhere.
3. lazygit opens cd'd into the right repo from any row.
4. `core.lua` imports nothing from snacks/UI and passes its headless tests —
   proven portable by construction.
5. It replaces the VSCode-window-on-the-side habit for multi-repo scanning.

## 8. Future work (post-v1, explicitly deferred)

- Stage/unstage toggle in-panel (first write action, needs re-sync design)
- Bare-Neovim renderer (activates if the future distro drops snacks)
- Sprite native panel port (Phase 5.2 — the same core, third face)
- Standalone plugin extraction + publication (the multi-repo niche is open)
- svgtree/native file icons in rows
- Focus-return auto-refresh

## 9. References

- Sprite build plan: `~/Downloads/terminal-project-brief.md` §6 (Phase 0.1), §7
- Existing art: `~/.config/nvim/lua/plugins/git-repos.lua`
- git porcelain v2 format: `git help status`, "Porcelain Format Version 2"

---

## 10. Amendment — Tier 2 refresh triggers (2026-07-22)

Supersedes the v1 refresh model ("on open + manual `r` + panel-launched
lazygit close" — §2 non-goals, §4.4/§4.5). Daily use surfaced staleness in
practice (committed in lazygit, panel kept showing old state), and a handoff
spec requested event-driven refresh. Now implemented:

- **Scoped per-repo refresh** (`core.refresh_repo` + `panel.refresh_repo_view`):
  one async `git status` for one repo, spliced into the entry list and
  re-sorted. Debounced per repo (`repo_debounce_ms`, default 150); a request
  landing mid-scan coalesces into exactly one re-run (never stacks processes).
- **TermClose trigger** (`scm/refresh.lua`): ANY lazygit terminal exiting —
  panel-launched or opened by hand in any :terminal — resolves its repo root
  from the `term://{cwd}//` buffer name (`git rev-parse --show-toplevel`) and
  does a scoped refresh; full rescan only when recovery fails. This replaced
  the v1 per-window `:on("TermClose")` hook and its reuse-dedup guard.
- **Focus safety nets**: WinEnter on the panel's own windows, and FocusGained
  (Neovim regains OS focus) → full rescan, debounced (`focus_debounce_ms`,
  default 1500). Both no-op when the panel is closed.
- Performance invariants preserved: all git via async `vim.system`, no UI
  blocking, fast-context discipline unchanged.
- Explicitly out of scope (Tier 3): `vim.uv.fs_event` watchers per repo. The
  trigger layer sits behind the same two entrypoints so Tier 3 can slot in
  without restructuring.
