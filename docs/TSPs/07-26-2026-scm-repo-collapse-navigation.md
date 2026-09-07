# SCM Repository Collapse Navigation Technical Spec

**Status:** Executed and review-hardened on 2026-07-26

**Goal:** Add Snacks-explorer-style `h`/`l` collapse navigation to SCM
Repository Sections without changing Core.

**Architecture:** `scm.panel` owns a session-local set of collapsed repository
paths. `build_items` is the single Repo Entry-to-picker-row projection. Panel
actions and Core refresh callbacks share one generation-owned render path,
which preserves the active filter. The render generation owns title updates;
the exact Snacks matcher task owns cursor restoration when filtering starts a
newer match outside the Panel's render path.

**Tech Stack:** Lua, Neovim ≥0.12, snacks.nvim picker, and the existing
plain-assert `nvim -l` harness. No runtime dependencies were added.

## Constraints

- Core and the Repo Entry contract remain unchanged and UI-free.
- Collapse state is keyed by the Repo Entry's absolute `path`.
- Collapse state survives full and single-repository refreshes while the Panel
  is open and resets when a new Panel opens.
- `h` on a visible file row selects its repository header. If filtering hides
  the header, it collapses that Repository Section without clearing the query.
- `h` collapses an expanded header; `l` expands a collapsed header; both are
  no-ops on clean/error headers.
- `l` opens file rows and is a no-op on already-expanded headers.
- `<CR>` expands collapsed headers, opens lazygit from expanded/clean/error
  headers, and opens files.
- Collapsed dirty headers render `▶`; expanded dirty headers render `▼`.
- Duplicate repository names retain their parent-directory context beside the
  disclosure glyph.
- File rows in collapsed Repository Sections do not participate in fuzzy
  filtering.
- Picker actions remain private and are tested through the configuration passed
  to `Snacks.picker.pick`.
- No collapse-all action, persistence across Panel sessions, or nested groups.

## Interfaces

- `panel.build_items(entries, collapsed_paths) -> picker_item[]` always emits a
  header and omits child rows for collapsed paths.
- Header picker items carry `collapsed: boolean` for disclosure rendering.
- `panel.state.collapsed: table<string, true>` stores Panel-only presentation
  state.
- The private action table supplies `scm_close` and `scm_open`, bound to `h`
  and `l` in the picker list window.
- The private render helper accepts a row anchor, fallback index, and optional
  title. A picker-local generation token rejects stale Panel renders, while
  matcher-task identity prevents an older Panel callback from moving within a
  newer filter result.

## Completed Work

- [x] Add path-keyed collapse state and collapse-aware item projection.
- [x] Render open/closed disclosure glyphs without regressing duplicate-name
  formatting.
- [x] Implement `h`, `l`, and `<CR>` behavior for headers, files, and filtered
  results.
- [x] Reset collapse state on Panel open and retain it across Refreshes.
- [x] Rebase onto the scoped-refresh architecture and keep the global refresh
  setup with direct `Snacks.lazygit` adapter calls.
- [x] Route actions, full refresh, and single-repository refresh through one
  render helper.
- [x] Add latest-render and exact-task ownership for delayed, aborted, and
  filter-superseded matcher callbacks.
- [x] Keep the action factory private and test the real Panel-open wiring.
- [x] Correct error fixtures to match Core's `clean = true`, `err`, and empty
  files invariant.
- [x] Add regressions for refresh reordering, interleaved matcher callbacks,
  duplicate names, disclosure glyphs, filter preservation, and inert headers.
- [x] Add a pull-request CI gate for the headless harness and whitespace
  validation.

## Verification

From the repository root:

```sh
cd phase_0/scm.nvim
nvim -l tests/core_test.lua
```

Expected output: `OK` with exit code 0.

The pull-request workflow runs the same harness with a pinned Neovim 0.12
release and runs `git diff --check` across the proposed change.

Live verification also exercises the installed Snacks matcher: collapse and
expand a dirty Repository Section, keep a filter active while collapsing a
hidden parent, refresh the Panel, and confirm the cursor remains on the newest
requested anchor.
