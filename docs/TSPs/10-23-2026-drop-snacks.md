# Drop Snacks and File-Tree Coupling Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the standalone Panel the only Panel, remove every Snacks, lazygit, LazyVim, SVGTree, and Neo-tree touchpoint, and scan the editor window's Working Directory.

**Architecture:** `scm.init` always loads `scm.workspace`. `scm.scope` shrinks to one function that reads Neovim's current directory. `scm.workspace` drops its SVGTree hooks and lazygit trigger, and gains a `DirChanged` trigger that moves the Panel to the editor window's new directory through the existing `scm.refresh` ordering (`policy.reset` then `refresh`).

**Tech Stack:** Lua, Neovim 0.12 API (`vim.fn.getcwd`, `DirChanged`, `vim.uv`), headless tests run with `nvim -l`.

PRD: `docs/PRDs/10-22-2026-drop-snacks.md`. Glossary: `CONTEXT.md` (Working Directory, Panel, Renderer, Refresh).

## Global Constraints

- Valid renderers: `auto`, `terminal`, `sprite`. Default `auto`.
- `renderer = "snacks"` raises exactly: `The Snacks renderer was removed. Use renderer = 'auto' or 'terminal'.`
- With no `on_explorer`, the explorer key shows exactly: `SCM: No file explorer is connected, so there's nothing to open. See "Connecting a file explorer" in the README.`
- No module under `lua/scm/` reads `_G.Snacks`, `_G.LazyVim`, `package.loaded.svgtree`, `require('svgtree')`, or any `neo-tree` module.
- Code comments: concise, plain, no ticket or document references. Use the glossary terms Working Directory and Panel; never "Explorer Root".
- Error and notification text leads with a plain sentence.
- Every prose change to README, ADRs, or CONTEXT.md is shown to David and approved before it is written.
- Run every command from `~/projects/scm.nvim-drop-snacks` (branch `feat/drop-snacks`).
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## File Structure

| File | Responsibility after this change |
|---|---|
| `lua/scm/init.lua` | Public entry; validates `renderer`; always delegates to `scm.workspace`. |
| `lua/scm/scope.lua` | The Working Directory: `current(win)` and `candidate()`. Nothing else. |
| `lua/scm/workspace.lua` | The Panel: toggle, actions, save/focus/`DirChanged` triggers. |
| `lua/scm/refresh.lua` | Refresh ordering, event batching, warm-up. No Panel-specific triggers. |
| `lua/scm/core.lua` | Unchanged except the `focus_debounce_ms` default and comment wording. |
| `lua/scm/panel.lua` | Deleted. |
| `tests/init_test.lua` | New: renderer validation and toggle-before-setup. |
| `tests/scope_test.lua` | New: replaces `tests/explorer_scope_test.lua`. |
| `tests/no_dependencies_test.lua` | New: proves no Snacks/LazyVim/SVGTree/Neo-tree reads. |
| `docs/adr/0004-own-the-sidebar.md` | New ADR superseding 0001. |

Test command for the whole suite (used in every task's final run):

```bash
for t in tests/*_test.lua; do nvim -l "$t" || echo "FAILED $t"; done
```

Expected: one `OK ...` line per file and no `FAILED` line.

---

### Task 1: Remove the Snacks Panel and lazygit

**Blocked by:** None

**Files:**
- Delete: `lua/scm/panel.lua`, `tests/sidebar_handoff_pty.lua`
- Modify: `lua/scm/init.lua` (whole file), `lua/scm/refresh.lua` (header comment, `opts`, `M.full`, `on_lazygit_close`, `in_panel_win`, `M.setup`, `M.reset` comment), `lua/scm/workspace.lua:165-177`, `lua/scm/core.lua:14-17`
- Test: create `tests/init_test.lua`; modify `tests/core_test.lua`, `tests/handoff_test.lua`, `tests/explorer_scope_test.lua`, `tests/refresh_events_test.lua`, `tests/warm_test.lua`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing.
- Produces: `require('scm').setup(opts)`, `.toggle()`, `.focus(side)`, `.handoff(fn)` always backed by `scm.workspace`; `toggle()` before `setup()` sets up with defaults. `scm.refresh` exports only `merge`, `request`, `reset`, `event`, `warm`.

- [ ] **Step 1: Write the failing test** — create `tests/init_test.lua`:

```lua
vim.opt.runtimepath:prepend(vim.uv.cwd())
local scm = require('scm')

local ok, err = pcall(scm.setup, {renderer='snacks'})
assert(not ok, 'the snacks renderer is rejected')
assert(err == "The Snacks renderer was removed. Use renderer = 'auto' or 'terminal'.", tostring(err))

ok, err = pcall(scm.setup, {renderer='picker'})
assert(not ok and tostring(err):find('Unknown SCM renderer: picker', 1, true), tostring(err))

-- Toggling before setup uses the defaults instead of failing.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.cmd.cd(dir)
package.loaded.sprite = nil
package.loaded['scm'] = nil
scm = require('scm')
assert(pcall(scm.toggle), 'toggle before setup opens the Panel')
assert(package.loaded['scm.workspace'], 'the Panel is the standalone workspace')
assert(not package.loaded['scm.panel'], 'the Snacks panel is never loaded')
scm.toggle()
print('OK init')
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim -l tests/init_test.lua`
Expected: FAIL — `the snacks renderer is rejected` (the current default accepts `snacks`).

- [ ] **Step 3: Replace `lua/scm/init.lua`**

```lua
local M = {}
local backend
local function current()
  if not backend then M.setup() end
  return backend
end
function M.setup(opts)
  opts = opts or {}
  local renderer = opts.renderer or 'auto'
  if renderer == 'snacks' then
    error("The Snacks renderer was removed. Use renderer = 'auto' or 'terminal'.", 0)
  end
  assert(vim.tbl_contains({'auto', 'terminal', 'sprite'}, renderer), 'Unknown SCM renderer: ' .. renderer)
  if backend and backend.close then backend.close() end
  backend = require('scm.workspace')
  backend.setup(opts)
end
function M.focus(side)
  local impl = current()
  return impl.focus and impl.focus(side) or false
end
function M.toggle() return current().toggle() end
function M.handoff(fn) return current().handoff(fn) end
return M
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim -l tests/init_test.lua`
Expected: `OK init`

- [ ] **Step 5: Delete the Panel and its PTY test**

```bash
git rm lua/scm/panel.lua tests/sidebar_handoff_pty.lua
```

- [ ] **Step 6: Strip the Panel triggers from `lua/scm/refresh.lua`**

Change line 1 to:

```lua
-- Shared event batching for the Panel.
```

Delete these whole definitions: `local function opts()`, `function M.full()` with its comment, `local function on_lazygit_close(bufname)` with its comment, `local function in_panel_win(picker)` with its comment, and `function M.setup()`. Keep `M.merge`, `run`, `M.request`, `M.reset`, `M.event`, and `M.warm` unchanged, except the `M.reset` comment, which becomes:

```lua
-- Forget queued requests and reject the result of the run in flight, for when
-- what the owner shows changes (a different Working Directory).
```

Verify: `grep -n "panel\|Snacks\|lazygit\|full" lua/scm/refresh.lua` prints nothing.

- [ ] **Step 7: Remove the lazygit trigger from `lua/scm/workspace.lua`**

Replace the `BufWritePost`/`FocusGained`/`TermClose` autocmd (lines 165-177) with:

```lua
  vim.api.nvim_create_autocmd({'BufWritePost','FocusGained'}, {group=group, callback=function(ev)
    local state = active
    if not state then return end
    local request = {cached=true}
    if ev.event == 'BufWritePost' then request.paths = {[vim.api.nvim_buf_get_name(ev.buf)]=true} end
    policy.event(state, options, request, function(pending) refresh(state, pending) end)
  end})
```

- [ ] **Step 8: Remove `focus_debounce_ms` from `lua/scm/core.lua`**

Delete these two lines from `M.defaults`:

```lua
  -- Minimum ms between two full multi-repo rescans triggered by focus events.
  focus_debounce_ms = 1500,
```

and change `-- Scan the Explorer Root once after startup so the first open already has rows.` to `-- Scan the Working Directory once after startup so the first open already has rows.` Replace every remaining "Explorer Root" in `lua/scm/core.lua` comments with "Working Directory" (`grep -n "Explorer Root" lua/scm/core.lua` must print nothing).

- [ ] **Step 9: Repoint `tests/core_test.lua` at `scm.model`**

1. Replace

```lua
-- panel pure functions (no picker window needed headless)
local panel = require("scm.panel")
local scope = require("scm.scope")

local function panel_state()
  return panel.tab_state(vim.api.nvim_get_current_tabpage())
end
```

with

```lua
-- Row derivation shared by every Renderer
local model = require("scm.model")
```

2. Replace every `panel.xy_display(`, `panel.file_display(`, and `panel.build_items(` with `model.xy_display(`, `model.file_display(`, `model.build_items(`.
3. Change the label `"abs path for snacks jump"` to `"absolute path for opening the file"`.
4. Replace the comment `-- Repository Section collapse navigation: visible rows, glyphs, h/l, confirm,` / `-- filtered-header fallback, inert headers, and session-local state.` with `-- A collapsed Repository Section hides only its own files.`
5. Replace

```lua
panel_state().collapsed = {}
local function nav_items()
  return panel.build_items(nav_entries, panel_state().collapsed)
end
```

with

```lua
local collapsed = {}
local function nav_items()
  return model.build_items(nav_entries, collapsed)
end
```

6. Delete the four `format_item` assertions after `expanded_nav` (from `eq(panel.format_item(expanded_nav[1])[1][1], "▼ ", ...)` through the `duplicate parent remains visible with collapse glyph` assert) and the four after `collapsed_nav` (from `local collapsed_duplicate = ...` through the `collapsed duplicate parent remains visible` assert).
7. Replace `panel_state().collapsed["/repos/dirty"] = true` (the one before `local collapsed_nav = nav_items()`) with `collapsed["/repos/dirty"] = true`.
8. Delete everything from `local function fake_picker(items, filter, finder)` through the line `_G.Snacks = previous_snacks` that sits just before the final `print("OK")`. Keep `print("OK")`.

Verify: `grep -n "panel\|Snacks\|lazygit\|picker\|scope\." tests/core_test.lua` prints nothing (the lowercase `snacks` check on lines 14-15 stays).

- [ ] **Step 10: Trim `tests/handoff_test.lua`**

Delete from `  local panel = require("scm.panel")` through `  assert(panel_ok, panel_err)`, then put back one line in its place:

```lua
  assert(require("scm").open == nil, "scm.open is not part of the public interface")
```

- [ ] **Step 11: Trim `tests/explorer_scope_test.lua`**

Delete from `local panel = require("scm.panel")` through `core.refresh_repo = old_refresh_repo` (keep the final restore lines and `print("OK explorer scope")`). The remaining scope assertions still pass; Task 2 replaces this file.

- [ ] **Step 12: Remove the legacy section from `tests/refresh_events_test.lua`**

Delete from `local panel = require('scm.panel')` through `print('OK legacy events share scope cache and save policy')`. The legacy section added scans, so lower the counts in the last section:

```lua
workspace.toggle()
wait_scans(7,6)
delay=60
local before_renders, before_discovery = renders, discovery
vim.api.nvim_exec_autocmds('BufWritePost',{buffer=buf})
assert(vim.wait(1000,function() return scans['/scope/a']==8 end),'first save starts')
for _=1,12 do vim.api.nvim_exec_autocmds('BufWritePost',{buffer=buf}) end
assert(vim.wait(2000,function() return renders>before_renders end),'in-flight invalidation publishes')
assert(scans['/scope/a']==9 and scans['/scope/b']==6,'in-flight save burst schedules exactly one targeted replay')
assert(renders==before_renders+1,'superseded result does not render')
assert(discovery==before_discovery,'in-flight replay reuses discovery')
workspace.close()
print('OK in-flight save burst: one targeted replay, one publication')
```

- [ ] **Step 13: Update `tests/warm_test.lua`**

Change `for _, renderer in ipairs({ "snacks", "terminal" }) do` to `for _, renderer in ipairs({ "auto", "terminal" }) do`, and replace "Explorer Root" with "Working Directory" in its comments and labels.

- [ ] **Step 14: Run every suite in CI**

In `.github/workflows/ci.yml`, make the test step:

```yaml
      - name: Run SCM headless tests
        run: |
          nvim -l tests/init_test.lua
          nvim -l tests/handoff_test.lua
          nvim -l tests/core_test.lua
          nvim -l tests/explorer_scope_test.lua
          nvim -l tests/workspace_test.lua
          nvim -l tests/native_workspace_test.lua
          nvim -l tests/refresh_ordering_test.lua
          nvim -l tests/warm_test.lua
          nvim -l tests/refresh_events_test.lua
          nvim -l tests/refresh_races_test.lua
          nvim -l tests/refresh_policy_test.lua
          nvim -l tests/sprite_busy_input_test.lua
```

- [ ] **Step 15: Run the whole suite**

Run: `for t in tests/*_test.lua; do nvim -l "$t" || echo "FAILED $t"; done`
Expected: an `OK` line per file, no `FAILED`.

- [ ] **Step 16: Commit**

```bash
git add -A lua tests .github
git commit -m "Remove the Snacks panel and lazygit actions

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Scan the Working Directory

**Blocked by:** Task 1

**Files:**
- Modify: `lua/scm/scope.lua` (whole file), `lua/scm/workspace.lua:115-124` (`M.toggle`)
- Test: create `tests/scope_test.lua`; delete `tests/explorer_scope_test.lua`; modify `tests/workspace_test.lua`, `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 1's `scm.workspace` as the only Panel.
- Produces: `scope.current(win?)` → normalized real path string or `nil`. With no `win`, the current window's directory; with a valid window id, that window's directory; with an invalid id, the current tab's directory. `scope.candidate()` → same as `scope.current()`. `scope.remember` and `scope.establish` no longer exist.

- [ ] **Step 1: Write the failing test** — create `tests/scope_test.lua`:

```lua
vim.opt.runtimepath:prepend(vim.uv.cwd())

local function eq(got, want, label)
  assert(vim.deep_equal(got, want), ("%s\nexpected: %s\ngot: %s"):format(label, vim.inspect(want), vim.inspect(got)))
end
local function dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return vim.uv.fs_realpath(path)
end

-- Every explorer is installed, and reading any of them fails the test.
_G.Snacks = { picker = { get = function() error("SCM must not read the Snacks Explorer") end } }
_G.LazyVim = { root = function() error("SCM must not read LazyVim") end }
package.loaded.svgtree = { root = function() error("SCM must not read SVGTree") end }
package.loaded["neo-tree.sources.manager"] = { get_state = function() error("SCM must not read Neo-tree") end }

local scope = require("scm.scope")
local a, b, c = dir(), dir(), dir()

local link = vim.fn.tempname()
assert(vim.uv.fs_symlink(a, link, { dir = true }), "create a symlinked directory")
vim.cmd.cd(link)
eq(scope.current(), a, "a symlinked directory resolves to its real path")

vim.cmd.cd(a)
eq(scope.current(), a, ":cd sets the Working Directory")
eq(scope.candidate(), a, "the warm-up uses the same Working Directory")

vim.cmd("tabnew")
vim.cmd.tcd(b)
eq(scope.current(), b, ":tcd sets the Working Directory for this tab")
local editor = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local other = vim.api.nvim_get_current_win()
vim.cmd.lcd(c)
eq(scope.current(), c, ":lcd sets the Working Directory for this window")
eq(scope.current(editor), b, "another window keeps its own Working Directory")
vim.api.nvim_win_close(other, true)
eq(scope.current(other), b, "a closed window falls back to the tab's directory")
vim.cmd("tabprevious")
eq(scope.current(), a, "the first tab keeps the global directory")

local gone = dir()
vim.cmd.cd(gone)
vim.fn.delete(gone, "rf")
eq(scope.current(), nil, "a deleted directory is not a Working Directory")
print("OK scope")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim -l tests/scope_test.lua`
Expected: FAIL with `SCM must not read the Snacks Explorer`.

- [ ] **Step 3: Replace `lua/scm/scope.lua`**

```lua
-- The Working Directory: Neovim's current directory, which every file explorer
-- changes when it moves to a folder, so SCM follows any of them without knowing which.
local M = {}

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(vim.fn.expand(path))
  if not real or vim.fn.isdirectory(real) ~= 1 then
    return nil
  end
  return vim.fs.normalize(real)
end

-- The Working Directory of `win` (default: the current window). A window that no
-- longer exists falls back to the current tab's directory.
function M.current(win)
  if win == nil then
    return normalize(vim.fn.getcwd())
  end
  if vim.api.nvim_win_is_valid(win) then
    return normalize(vim.fn.getcwd(win))
  end
  return normalize(vim.fn.getcwd(-1, 0))
end

-- The directory the startup warm-up scans.
function M.candidate()
  return M.current()
end

return M
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim -l tests/scope_test.lua`
Expected: `OK scope`

- [ ] **Step 5: Write the failing Panel test** — in `tests/workspace_test.lua`, replace

```lua
local requested
scm.setup({renderer='terminal', on_explorer=function(path) requested=path end})
scm.toggle()
```

with

```lua
local requested, tree_closed
-- An open SVGTree showing another folder neither steers nor is closed by the Panel.
package.loaded.svgtree = {root=function() return vim.fn.tempname() end, close=function() tree_closed=true end}
scm.setup({renderer='terminal', on_explorer=function(path) requested=path end})
scm.toggle()
assert(not tree_closed, 'opening the Panel leaves the file tree alone')
package.loaded.svgtree = nil
```

- [ ] **Step 6: Run it to verify it fails**

Run: `nvim -l tests/workspace_test.lua`
Expected: FAIL with `opening the Panel leaves the file tree alone`.

- [ ] **Step 7: Make `M.toggle` in `lua/scm/workspace.lua` read the Working Directory**

Replace the first lines of `M.toggle` up to `active = state`:

```lua
function M.toggle()
  if active then M.close(); return end
  local root = scope.current()
  -- Start from what Core last saw for this root so the rows show before git answers.
  local state = {root=root, tab=vim.api.nvim_get_current_tabpage(), editor=vim.api.nvim_get_current_win(),
    entries=core.cached(root) or {}, collapsed={}, selected=1}
  active = state
```

(The `tree` local, `scope.remember(root)`, and `if tree and tree.close then tree.close() end` are gone; the rest of `M.toggle` is unchanged.)

- [ ] **Step 8: Run it to verify it passes**

Run: `nvim -l tests/workspace_test.lua`
Expected: `OK standalone workspace`

- [ ] **Step 9: Replace the old scope test**

```bash
git rm tests/explorer_scope_test.lua
```

In `.github/workflows/ci.yml`, change `nvim -l tests/explorer_scope_test.lua` to `nvim -l tests/scope_test.lua`.

- [ ] **Step 10: Run the whole suite**

Run: `for t in tests/*_test.lua; do nvim -l "$t" || echo "FAILED $t"; done`
Expected: an `OK` line per file, no `FAILED`.

- [ ] **Step 11: Commit**

```bash
git add -A lua tests .github
git commit -m "Scan Neovim's current directory instead of asking file trees

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Explorer key without a built-in file tree

**Blocked by:** Task 2

**Files:**
- Modify: `lua/scm/workspace.lua:91-95` (the `explorer` branch of `action`)
- Test: modify `tests/workspace_test.lua` (last block); create `tests/no_dependencies_test.lua`; modify `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: Task 2's `scope.current()`.
- Produces: the `explorer` action calls `options.on_explorer(state.root)` when set; otherwise `vim.notify(<message from Global Constraints>, vim.log.levels.INFO)` and the Panel stays open.

- [ ] **Step 1: Write the failing test** — in `tests/workspace_test.lua`, replace the last block (from `local opened` through `assert(not panel(), 'standalone Explorer fallback closes SCM')`) with:

```lua
-- Without on_explorer the key explains itself and never opens a file tree.
package.loaded.svgtree = {open=function() error('SCM must not open SVGTree') end}
scm.setup({renderer='terminal'})
scm.toggle()
vim.api.nvim_set_current_win(assert(panel()))
local message
local real_notify = vim.notify
vim.notify = function(msg) message = msg end
press('<Space>e')
vim.notify = real_notify
assert(message == 'SCM: No file explorer is connected, so there\'s nothing to open. See "Connecting a file explorer" in the README.', tostring(message))
assert(panel(), 'the Panel stays open when no file explorer is connected')
scm.toggle()
package.loaded.svgtree = nil
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim -l tests/workspace_test.lua`
Expected: FAIL at the message assertion, printing `nil` (the current code hands off to the fake SVGTree instead of showing a message).

- [ ] **Step 3: Replace the `explorer` branch in `lua/scm/workspace.lua`**

```lua
  elseif name == 'explorer' then
    if options.on_explorer then options.on_explorer(state.root); return end
    vim.notify('SCM: No file explorer is connected, so there\'s nothing to open. See "Connecting a file explorer" in the README.',
      vim.log.levels.INFO)
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim -l tests/workspace_test.lua`
Expected: `OK standalone workspace`

- [ ] **Step 5: Write the dependency test** — create `tests/no_dependencies_test.lua`:

```lua
-- Loading and using SCM never reads Snacks, LazyVim, SVGTree, or Neo-tree.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local touched = {}
setmetatable(_G, {__index=function(_, key)
  if key == 'Snacks' or key == 'LazyVim' then touched[#touched+1] = key end
end})
setmetatable(package.loaded, {__index=function(_, name)
  if name == 'snacks' or name:match('^snacks%.') or name == 'svgtree' or name:match('^svgtree%.')
    or name:match('^neo%-tree') then
    touched[#touched+1] = name
  end
end})

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
assert(vim.system({'git', '-C', root, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, root .. '/changed.lua')
vim.cmd.cd(root)

for _, name in ipairs({'scm', 'scm.core', 'scm.model', 'scm.refresh', 'scm.scope', 'scm.transition',
  'scm.workspace', 'scm.views.terminal', 'scm.views.sprite'}) do
  require(name)
end
local scm = require('scm')
scm.setup({renderer='terminal'})
scm.toggle()
local function panel()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return win end
  end
end
assert(vim.wait(5000, function()
  local win = panel()
  return win and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    :find('changed.lua', 1, true)
end), 'the Panel lists the changed file')
vim.api.nvim_exec_autocmds('FocusGained', {})
local real_notify = vim.notify
vim.notify = function() end
vim.api.nvim_set_current_win(panel())
vim.fn.maparg('<Space>e', 'n', false, true).callback()
vim.notify = real_notify
local handed = false
scm.handoff(function() handed = true end)
assert(vim.wait(1000, function() return handed end), 'handoff runs the caller action')
vim.wait(200)
assert(#touched == 0, 'SCM read ' .. table.concat(touched, ', '))
print('OK no dependencies')
```

- [ ] **Step 6: Run it to verify it passes**

Run: `nvim -l tests/no_dependencies_test.lua`
Expected: `OK no dependencies`. To confirm it can fail, temporarily add `local _ = _G.Snacks` to the top of `M.toggle` in `lua/scm/workspace.lua`, rerun, expect `SCM read Snacks`, then remove the line.

- [ ] **Step 7: Add it to CI**

In `.github/workflows/ci.yml`, add `nvim -l tests/no_dependencies_test.lua` after `nvim -l tests/init_test.lua`.

- [ ] **Step 8: Run the whole suite**

Run: `for t in tests/*_test.lua; do nvim -l "$t" || echo "FAILED $t"; done`
Expected: an `OK` line per file, no `FAILED`.

- [ ] **Step 9: Commit**

```bash
git add -A lua tests .github
git commit -m "Ask for an explorer connection instead of opening SVGTree

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Follow the editor window's Working Directory

**Blocked by:** Task 3

**Files:**
- Modify: `lua/scm/workspace.lua` (`M.setup`, after the `BufWritePost`/`FocusGained` autocmd)
- Test: modify `tests/workspace_test.lua` (new block before `vim.fn.delete(root, 'rf')`)

**Interfaces:**
- Consumes: `scope.current(win)` (Task 2); `policy.reset(owner)` and the local `refresh(state)` / `render(state)` in `workspace.lua`; `core.cached(root)`.
- Produces: while the Panel is open, a `DirChanged` that changes `scope.current(state.editor)` moves `state.root`, shows the new root's cached Repo Entries, and starts a full Refresh. Otherwise nothing happens.

- [ ] **Step 1: Write the failing test** — insert before `vim.fn.delete(root, 'rf')` in `tests/workspace_test.lua`:

```lua
-- The Panel follows the Working Directory of its editor window.
local second = vim.fn.tempname()
vim.fn.mkdir(second, 'p')
second = vim.uv.fs_realpath(second)
assert(vim.system({'git', '-C', second, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, second .. '/moved.lua')
scm.setup({renderer='terminal'})
local editor = vim.api.nvim_get_current_win()
scm.toggle()
assert(vim.wait(5000, function() return panel_text():find('sample.lua', 1, true) end), 'Panel starts on the first repository')
vim.api.nvim_set_current_win(editor)
vim.cmd.cd(second)
assert(vim.wait(5000, function()
  local text = panel_text()
  return text:find('moved.lua', 1, true) and not text:find('sample.lua', 1, true)
end), ':cd in the editor window moves the Panel')

vim.cmd('split')
vim.cmd.lcd(root)
vim.wait(300)
assert(panel_text():find('moved.lua', 1, true), ':lcd in another window leaves the Panel where it is')
vim.cmd('close')
vim.api.nvim_set_current_win(editor)

-- A slow scan of the old directory never replaces the new directory's rows.
local real_core_refresh, runs = core.refresh, {}
core.refresh = function(dir, _, done) runs[#runs+1] = {dir=dir, done=done} end
vim.cmd.cd(root)
assert(panel_text():find('sample.lua', 1, true), 'the new directory shows its cached rows at once')
vim.cmd.cd(second)
assert(panel_text():find('moved.lua', 1, true), 'cached rows again after moving back')
runs[1].done({{name='old', path=root, branch='main', ahead=0, behind=0, clean=false,
  files={{path='stale.lua', xy='.M'}}}})
assert(not panel_text():find('stale.lua', 1, true), 'the old directory result is discarded')
assert(vim.wait(1000, function() return runs[2] and runs[2].dir == second end), 'the new directory is scanned next')
runs[2].done({{name='new', path=second, branch='main', ahead=0, behind=0, clean=false,
  files={{path='fresh.lua', xy='.M'}}}})
assert(panel_text():find('fresh.lua', 1, true), 'the new directory result is shown')
core.refresh = real_core_refresh

scm.toggle()
local refreshed = false
core.refresh = function() refreshed = true end
vim.cmd.cd(root)
vim.wait(200)
assert(not refreshed and not panel(), 'a directory change while closed does nothing')
core.refresh = real_core_refresh
```

- [ ] **Step 2: Run it to verify it fails**

Run: `nvim -l tests/workspace_test.lua`
Expected: FAIL with `:cd in the editor window moves the Panel`.

- [ ] **Step 3: Add the `DirChanged` trigger** — in `M.setup` of `lua/scm/workspace.lua`, after the `BufWritePost`/`FocusGained` autocmd:

```lua
  -- Follow the editor window's Working Directory. An :lcd in another window (a
  -- terminal, a plugin) does not change it, so it leaves the Panel where it is.
  vim.api.nvim_create_autocmd('DirChanged', {group=group, callback=function()
    local state = active
    if not state then return end
    local root = scope.current(state.editor)
    if not root or root == state.root then return end
    policy.reset(state)
    state.root, state.entries, state.error, state.selected = root, core.cached(root) or {}, nil, 1
    render(state)
    refresh(state)
  end})
```

- [ ] **Step 4: Run it to verify it passes**

Run: `nvim -l tests/workspace_test.lua`
Expected: `OK standalone workspace`

- [ ] **Step 5: Run the whole suite**

Run: `for t in tests/*_test.lua; do nvim -l "$t" || echo "FAILED $t"; done`
Expected: an `OK` line per file, no `FAILED`.

- [ ] **Step 6: Commit**

```bash
git add lua/scm/workspace.lua tests/workspace_test.lua
git commit -m "Move the Panel when its editor window changes directory

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Documentation

**Blocked by:** Task 4

**Files:**
- Create: `docs/adr/0004-own-the-sidebar.md`
- Modify: `docs/adr/0001-snacks-render-layer.md` (line 2), `README.md`

**Interfaces:**
- Consumes: the behaviour from Tasks 1–4 and the message text that names the README section "Connecting a file explorer".
- Produces: docs only.

Show David each draft below as it will be written and wait for his go-ahead before writing any file in this task.

- [ ] **Step 1: Draft `docs/adr/0004-own-the-sidebar.md`**

```markdown
# Own the Panel; read no Snacks and no file tree

Supersedes ADR 0001.

ADR 0001 drew the Panel with a Snacks picker because Snacks shipped with LazyVim and gave a sidebar, focus handling, and fuzzy filtering for free. SCM is becoming a full git client that owns every view, including its own filtering and diffs, so a picker's layout and actions would be something to work around rather than build on, and requiring snacks.nvim shut out everyone without it. The standalone Panel (`scm.workspace` and its Renderers) is the only Panel; the Snacks panel and its lazygit actions are removed.

SCM also stops reading file trees. It took its folder from the Snacks Explorer, SVGTree, Neo-tree, or LazyVim's root and remembered it per tab. It now reads the Working Directory: Neovim's current directory for the editor window it opened from. Every explorer that changes folders already changes that directory, so one rule supports all of them, and Neovim's tab- and window-local directories replace SCM's per-tab memory. Keeping an explorer and the Panel from sharing the screen moves to the user's config, through `scm.handoff` and `on_explorer`.

Considered and rejected: keeping the Snacks Explorer lookup as an optional read (it still special-cases one tree, and the current directory already follows it); following every `DirChanged` (an `:lcd` in a terminal would move the Panel).

Consequences: the fuzzy filter, the `d` diff key, the lazygit keys, the "scanning…" title, and the refresh on entering the Panel are gone until SCM provides its own. An explorer that shows a folder without changing Neovim's directory does not steer SCM; `:cd` or `:tcd` there does.
```

- [ ] **Step 2: Draft the ADR 0001 line** — insert as line 2 of `docs/adr/0001-snacks-render-layer.md`:

```markdown

Superseded by [ADR 0004](0004-own-the-sidebar.md).
```

- [ ] **Step 3: Draft the README** — the full new `README.md`:

````markdown
# scm.nvim

`scm.nvim` is a multi-repository source-control panel for Neovim. It finds every
Git repository under Neovim's current directory and shows their changes in one
sidebar, drawn in a Neovim split or, with Sprite, a native dock. It needs no
other plugin and works with any file explorer.

Originally developed inside the [Sprite](https://github.com/HundredBillion/Sprite)
repository as its Phase 0 track, it now lives here as a standalone plugin.

## Install

```lua
{
  "HundredBillion/scm.nvim",
  event = "VeryLazy",
  opts = { renderer = "auto" },
  keys = { { "<leader>gs", function() require("scm").toggle() end, desc = "Source Control" } },
}
```

`auto`, the default, uses `sprite.nvim` when installed and the host supports
native docks; otherwise it opens a Neovim split. `terminal` always uses the
split. `sprite` also falls back, with a warning.

Use Enter to open a changed file or toggle a repository, h/l to collapse/expand,
r to refresh, Escape to return to the editor and q to close. Space-e or Ctrl-b
opens your file explorer once one is connected (see below). The sidebar closes
when leaving its tab. It refreshes after editor writes and when Neovim regains
focus. `width` sets terminal columns (default 36), `native_width` sets Sprite
pixels (default 300). `native.colors` overrides native list color roles such as
`background` and `foreground`; omitted roles keep their defaults.

The sidebar lists pending changes and commits relative to the existing
default-branch merge base. It does not yet include diffs, staging, filtering,
PR-target lookup, CRP, agent following, or automatic filesystem watching.
Deleted files are listed; opening their historical contents is not yet
supported.

## Which folder is scanned

SCM scans Neovim's current directory (`:pwd`) for the window you open it from,
so `:cd`, `:tcd` and `:lcd` all steer it. File explorers such as SVGTree,
Neo-tree and the Snacks explorer change that directory when they move to a
folder, so SCM follows them without knowing which one you use. While SCM is
open, changing that window's directory moves SCM to the new folder; an `:lcd`
in another window, such as a terminal, does not.

## Repository discovery

SCM finds repositories by walking the current directory and stopping at each
one, so it takes milliseconds even on large trees. Worktrees inside a repository
(such as `.worktrees/x`) are listed; clones nested inside a repository, like
vendored code, are not. The walk skips build output and dependency directories
by name and must finish within `discovery_timeout_ms` (default 15000); each
per-repository git command keeps `timeout_ms` (default 5000).

The default `discovery_exclude` list is `node_modules`, `target`, `.venv`, `venv`,
`__pycache__`, `.tox`, `.mypy_cache`, `.pytest_cache`, `.gradle`, `.next`,
`.terraform`, `.zig-cache`, `zig-cache` and `DerivedData`. A directory with one
of these names is skipped entirely, so repositories inside it, or a repository
that itself has one of these names, are not listed. The current directory itself
is always searched, even when its own name is in the list.

A list you pass replaces the default; `{}` searches everything:

```lua
opts = {
  discovery_exclude = { "node_modules", "target", "vendor" },
}
```

If discovery still exceeds `discovery_timeout_ms`, SCM shows an error rather
than a partial list. Add the heavy directory names to `discovery_exclude` or
raise `discovery_timeout_ms`.

Opening SCM shows the last known changes at once and updates them as each
repository is rescanned. After startup SCM scans the current directory once so
even the first open is instant; set `warm = false` to turn that off. With
lazy.nvim, load the plugin at startup (for example `event = "VeryLazy"`) for the
warm-up to run before the first open.

## Connecting a file explorer

SCM and a file explorer share the left side of the screen. SCM never opens or
closes an explorer itself; connect yours in your config:

```lua
local function open_explorer()
  require("scm").handoff(function()
    require("svgtree").toggle() -- or vim.cmd("Neotree"), Snacks.explorer(), ...
  end)
end

return {
  "HundredBillion/scm.nvim",
  event = "VeryLazy",
  opts = {
    renderer = "auto",
    -- Space-e or Ctrl-b inside SCM opens your explorer.
    on_explorer = open_explorer,
  },
  keys = {
    {
      "<leader>gs",
      function()
        require("svgtree").close() -- close your explorer before SCM opens
        require("scm").toggle()
      end,
      desc = "Source Control",
    },
    { "<leader>e", open_explorer, desc = "Explorer" },
  },
}
```

`scm.handoff(fn)` closes SCM, then runs `fn` on the next tick, so the two never
share the screen. `on_explorer` receives SCM's folder if your explorer needs it.
Without `on_explorer`, Space-e and Ctrl-b show a message instead. A command that
opens an explorer directly, without `scm.handoff`, can leave both open.
````

- [ ] **Step 4: After David approves, write the three files exactly as approved**

- [ ] **Step 5: Check for stale references**

Run: `grep -rn "Explorer Root\|Explorer root\|Snacks\|lazygit\|LazyVim" README.md lua tests docs/adr/0004-own-the-sidebar.md`
Expected: only the README "Which folder is scanned" and "Connecting a file explorer" mentions of the Snacks explorer, the ADR 0004 text, and test files that install fake explorers to prove they are ignored.

- [ ] **Step 6: Commit**

```bash
git add README.md docs/adr
git commit -m "Document the Snacks-free Panel and connecting a file explorer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: David's Neovim config

**Blocked by:** Task 5. Ask David before editing; this file is outside the repo, and its config repo has his own uncommitted changes that must not be touched or committed.

**Files:**
- Modify: `~/.config/nvim-lazyvim-2026-09-19/lua/plugins/scm.lua` (whole file)

**Interfaces:**
- Consumes: `require('scm').setup/toggle/handoff`, `on_explorer`; `require('svgtree').open(root)` and `.close()`.
- Produces: config only.

- [ ] **Step 1: Show David this replacement and wait for his go-ahead**

```lua
-- Multi-repo source control panel (scm.nvim, local plugin).
-- <leader>gs deliberately overrides LazyVim's single-repo git_status picker
-- (still reachable via :lua Snacks.picker.git_status()).
-- Code + docs: ~/Projects/scm.nvim
return {
  {
    -- LazyVim's snacks_picker extra also lazy-binds <leader>gs (git_status) on
    -- the snacks.nvim plugin itself. Both plugins registering the same lhs is
    -- a race the alphabetically-later one (snacks.nvim) wins, so the LazyVim
    -- mapping must be explicitly disabled for scm.nvim's binding to hold.
    "folke/snacks.nvim",
    keys = {
      { "<leader>gs", false },
    },
  },
  {
    dir = vim.fn.expand("~/Projects/scm.nvim"),
    name = "scm.nvim",
    main = "scm",
    -- Load after startup so scm.nvim's warm-up scan runs before the first <leader>gs.
    event = "VeryLazy",
    keys = {
      {
        "<leader>gs",
        function()
          -- SCM and SVGTree share the left side; close the tree before SCM opens.
          require("svgtree").close()
          require("scm").toggle()
        end,
        desc = "Source Control (all repos)",
      },
    },
    opts = {
      renderer = "auto",
      -- Space-e / Ctrl-b inside SCM: close SCM, then open SVGTree on SCM's folder.
      on_explorer = function(root)
        require("scm").handoff(function()
          require("svgtree").open(root)
        end)
      end,
    },
  },
}
```

- [ ] **Step 2: After approval, write the file and check it parses**

Run: `nvim --headless -c 'lua assert(loadfile(vim.fn.expand("~/.config/nvim-lazyvim-2026-09-19/lua/plugins/scm.lua")))' -c q`
Expected: exits with no output.

- [ ] **Step 3: Do not commit** — tell David the file changed and that `~/Projects/scm.nvim` must be on a branch containing PR #8 and this work before his Neovim runs the new code.
