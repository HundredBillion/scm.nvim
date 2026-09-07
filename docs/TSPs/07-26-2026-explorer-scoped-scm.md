# Explorer-Scoped SCM Repository Discovery Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Approved requirements; TSP self-reviewed and grilled on 2026-07-26.

**Goal:** Make each Neovim tab's persistent Explorer Root determine which Git repositories appear in the SCM Panel, without manual directory configuration.

**Architecture:** A new UI-side `scm.scope` module observes Snacks or Neo-tree and stores one normalized Explorer Root in native tab-local state. Core receives that Root as plain data and asynchronously discovers its containing and nested repositories. Panel view and Refresh coordination become tab-scoped so separate tabs cannot overwrite each other.

**Tech Stack:** Lua, Neovim 0.12+, `vim.system`, Git, POSIX/BSD `find`, snacks.nvim picker, optional Neo-tree adapter, and the existing plain-assert `nvim -l` harness. No new runtime dependency.

## Global Constraints

- Core must not import Snacks, Neo-tree, LazyVim, or any UI module.
- An Explorer Root persists for the life of its tab and changes only when a file explorer reports a different root.
- Buffer changes and full Refreshes must not recalculate an established Explorer Root.
- Repository discovery includes the Git repository containing the Explorer Root and every repository beneath it at arbitrary depth.
- A discovered repository always reports repository-wide File Entries, including files outside an Explorer Root that points to a subdirectory.
- Normalize a symlinked Explorer Root; do not follow nested directory symlinks.
- Explorer collapse/expansion state does not constrain discovery.
- Each tab owns its Repo Entries, Repository Section collapse state, and full-Refresh generation.
- Full discovery must be asynchronous; only one full Refresh per tab may run, with at most one newest request queued.
- Existing scoped lazygit Refresh, Repository Section navigation, sorting, formatting, and first-open behavior remain intact.
- macOS and Linux are supported; no Windows-specific discovery implementation is required in Phase 0.

---

## File Structure

- Create `phase_0/scm.nvim/lua/scm/scope.lua`: explorer adapters, normalization, and native tab-local Explorer Root persistence.
- Modify `phase_0/scm.nvim/lua/scm/core.lua`: replace configured/depth-limited scanning with request-local asynchronous discovery and status collection.
- Modify `phase_0/scm.nvim/lua/scm/panel.lua`: tab-scoped view state, explorer capture, per-tab full-Refresh coalescing, and error rendering.
- Modify `phase_0/scm.nvim/lua/scm/refresh.lua`: keep full Refresh current-tab scoped and fan scoped repository results into every interested tab.
- Modify `phase_0/scm.nvim/tests/core_test.lua`: adapt the existing Core and Panel regression suite to the new interfaces.
- Create `phase_0/scm.nvim/tests/explorer_scope_test.lua`: focused Explorer Root, provider, tab-isolation, and stale-generation tests.
- Modify `.github/workflows/scm.yml`: run both headless suites.
- Modify `/Users/dalee/.config/nvim/lua/plugins/snacks.lua`: remember the Snacks explorer root without replacing the existing `svgtree` hook.
- Modify `/Users/dalee/.config/nvim/lua/plugins/neo-tree.lua`: remember the Neo-tree filesystem root on its public window-open event if Neo-tree is enabled later.
- Modify `/Users/dalee/.config/nvim/lua/plugins/scm.lua`: remove the stale configured-Roots comment.

### Task 1: Persistent Explorer Root module

**Files:**
- Create: `phase_0/scm.nvim/lua/scm/scope.lua`
- Create: `phase_0/scm.nvim/tests/explorer_scope_test.lua`

**Interfaces:**
- Consumes: active Snacks picker `picker:cwd()`, loaded Neo-tree filesystem state `{ path, winid }`, `LazyVim.root()`, and `vim.fn.getcwd()`.
- Produces: `scope.remember(path) -> normalized_root|nil, changed:boolean`; `scope.establish() -> normalized_root|nil`; `scope.current() -> normalized_root|nil`.

- [ ] **Step 1: Write the failing scope tests**

Create `tests/explorer_scope_test.lua` with the complete initial harness:

```lua
vim.opt.runtimepath:prepend(vim.uv.cwd())

local function eq(got, want, label)
  assert(vim.deep_equal(got, want), ("%s\nexpected: %s\ngot: %s"):format(label, vim.inspect(want), vim.inspect(got)))
end

local scope = require("scm.scope")
local old_snacks, old_lazyvim = _G.Snacks, _G.LazyVim
local old_manager = package.loaded["neo-tree.sources.manager"]
local first, second, third = vim.fn.tempname(), vim.fn.tempname(), vim.fn.tempname()
vim.fn.mkdir(first, "p")
vim.fn.mkdir(second, "p")
vim.fn.mkdir(third, "p")
local first_real, second_real, third_real = vim.uv.fs_realpath(first), vim.uv.fs_realpath(second), vim.uv.fs_realpath(third)

local remembered, changed = scope.remember(first)
eq(remembered, first_real, "remember normalizes a valid directory")
eq(changed, true, "first remembered root changes scope")
eq(select(2, scope.remember(first)), false, "remembering the same root is stable")
eq(scope.remember(first .. "/missing"), nil, "invalid roots are rejected")
local link = vim.fn.tempname()
assert(vim.uv.fs_symlink(first, link, { dir = true }), "create Explorer Root symlink")
eq(scope.remember(link), first_real, "symlinked Explorer Root resolves to its real path")
vim.t.scm_explorer_root = first .. "/missing"
_G.LazyVim = { root = function() return first end }
eq(scope.establish(), first_real, "invalid remembered root falls back during establishment")

vim.cmd("tabnew")
_G.LazyVim = { root = function() return second end }
eq(scope.establish(), second_real, "new tab establishes LazyVim root")
_G.LazyVim.root = function() return third end
eq(scope.current(), second_real, "established root survives project-root changes")

_G.Snacks = { picker = { get = function(opts)
  eq(opts, { source = "explorer" }, "Snacks query is current-tab scoped")
  return { { cwd = function() return third end } }
end } }
eq(scope.current(), third_real, "visible Snacks explorer replaces tab root")
_G.Snacks = nil
eq(scope.current(), third_real, "Snacks root persists after explorer closes")

local win = vim.api.nvim_get_current_win()
package.loaded["neo-tree.sources.manager"] = {
  get_state = function(source)
    eq(source, "filesystem", "Neo-tree filesystem source")
    return { path = first, winid = win }
  end,
}
eq(scope.current(), first_real, "visible Neo-tree explorer replaces tab root")

vim.cmd("tabprevious")
eq(scope.current(), first_real, "original tab retains its independent root")

_G.Snacks, _G.LazyVim = old_snacks, old_lazyvim
package.loaded["neo-tree.sources.manager"] = old_manager
print("OK explorer scope")
```

- [ ] **Step 2: Run the test to verify it fails**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
```

Expected: FAIL with `module 'scm.scope' not found`.

- [ ] **Step 3: Implement the minimal scope module**

Create `lua/scm/scope.lua`:

```lua
local M = {}
local KEY = "scm_explorer_root"

local function normalize(path)
  if type(path) ~= "string" or path == "" then return nil end
  local real = vim.uv.fs_realpath(vim.fn.expand(path))
  if not real or vim.fn.isdirectory(real) ~= 1 then return nil end
  return vim.fs.normalize(real)
end

function M.remember(path)
  local root = normalize(path)
  if not root then return nil, false end
  local changed = vim.t[KEY] ~= root
  vim.t[KEY] = root
  return root, changed
end

local function snacks_root()
  if not (_G.Snacks and Snacks.picker and Snacks.picker.get) then return nil end
  local picker = Snacks.picker.get({ source = "explorer" })[1]
  if not picker then return nil end
  local ok, root = pcall(function() return picker:cwd() end)
  return ok and root or nil
end

local function neotree_root()
  local manager = package.loaded["neo-tree.sources.manager"]
  if not manager then return nil end
  local ok, state = pcall(manager.get_state, "filesystem")
  if not ok or not state or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then return nil end
  if vim.api.nvim_win_get_tabpage(state.winid) ~= vim.api.nvim_get_current_tabpage() then return nil end
  return state.path
end

function M.establish()
  local remembered = normalize(vim.t[KEY])
  if remembered then return remembered end
  vim.t[KEY] = nil
  local root
  if _G.LazyVim and LazyVim.root then
    local ok, value = pcall(LazyVim.root)
    if ok then root = value end
  end
  local established = M.remember(root or vim.fn.getcwd())
  return established
end

function M.current()
  local active = snacks_root() or neotree_root()
  if active then
    local remembered = M.remember(active)
    return remembered
  end
  return M.establish()
end

return M
```

- [ ] **Step 4: Run the focused and baseline tests**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
/Users/dalee/.local/bin/nvim-nightly -l tests/core_test.lua
```

Expected: `OK explorer scope`, then `OK`, both with exit code 0.

- [ ] **Step 5: Commit the scope module**

```sh
git add phase_0/scm.nvim/lua/scm/scope.lua phase_0/scm.nvim/tests/explorer_scope_test.lua
git commit -m "feat(scm): remember explorer roots per tab"
```

### Task 2: Asynchronous containing-and-nested repository discovery

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/core.lua:5-14,61-81,83,145-181`
- Modify: `phase_0/scm.nvim/tests/core_test.lua:56-195`

**Interfaces:**
- Consumes: one normalized Explorer Root string and Core options containing `timeout_ms`.
- Produces: `core.discover(root, opts, cb) -> true`, where `cb(repos, err)` is scheduled with sorted unique absolute paths or a discovery error; `core.refresh(root, opts, cb) -> true`, where `cb(entries, err)` returns Repo Entries or a discovery error.

- [ ] **Step 1: Replace the old depth-limited tests with failing asynchronous discovery tests**

Replace the existing `scan()` fixture section with:

```lua
-- discover(): containing repo + root repo + arbitrary-depth worktree, deduplicated.
local tmp = vim.fn.tempname()
local parent = tmp .. "/parent"
local root = parent .. "/visible/subdir"
local deep = root .. "/one/two/three/worktree"
local external = tmp .. "/external"
vim.fn.mkdir(root, "p")
vim.fn.mkdir(deep, "p")
vim.fn.mkdir(external, "p")
sh({ "git", "-C", parent, "init", "-q", "-b", "main" })
sh({ "git", "-C", external, "init", "-q", "-b", "main" })
vim.fn.writefile({ "gitdir: /elsewhere" }, deep .. "/.git")
assert(vim.uv.fs_symlink(external, root .. "/linked-external", { dir = true }), "create nested directory symlink")

local discovered, discover_err
assert(core.discover(root, { timeout_ms = 5000 }, function(repos, err)
  discovered, discover_err = repos, err
end))
vim.wait(5000, function() return discovered ~= nil or discover_err ~= nil end, 10)
eq(discover_err, nil, "discovery succeeds")
eq(discovered, { parent, deep }, "containing and arbitrary-depth repositories are found once")

local root_discovered
core.discover(parent, { timeout_ms = 5000 }, function(repos, err)
  assert(not err, err)
  root_discovered = repos
end)
vim.wait(5000, function() return root_discovered ~= nil end, 10)
eq(root_discovered, { parent, deep }, "Root repository is deduplicated and nested symlinks are not traversed")

local missing_err
core.discover(root .. "/missing", { timeout_ms = 5000 }, function(_, err) missing_err = err end)
vim.wait(5000, function() return missing_err ~= nil end, 10)
assert(type(missing_err) == "string" and missing_err ~= "", "discovery failures are reported")

-- Two request-local full refreshes may run concurrently; Panel owns coalescing.
local concurrent = 0
core.refresh(root, { timeout_ms = 5000 }, function(_, err)
  assert(not err, err)
  concurrent = concurrent + 1
end)
core.refresh(root, { timeout_ms = 5000 }, function(_, err)
  assert(not err, err)
  concurrent = concurrent + 1
end)
vim.wait(5000, function() return concurrent == 2 end, 10)
eq(concurrent, 2, "Core full refreshes carry request-local state")
```

Move the existing `sh(cmd)` helper above this block. Change every later full Refresh call from:

```lua
core.refresh({ roots = { work }, depth = 2, timeout_ms = 5000 }, callback)
```

to:

```lua
core.refresh(work, { timeout_ms = 5000 }, callback)
```

Delete the old assertion that a second Core Refresh is dropped; Task 3 tests per-tab coalescing at the Panel seam.

- [ ] **Step 2: Run the Core test to verify it fails**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/core_test.lua
```

Expected: FAIL because `core.discover` is undefined or `core.refresh` still expects configured Roots.

- [ ] **Step 3: Replace configured scanning with request-local asynchronous discovery**

Remove `roots`, `depth`, `M.scan`, and the module-level full-Refresh `in_flight` flag. Keep the debounce options and add the following:

```lua
M.defaults = {
  timeout_ms = 5000,
  repo_debounce_ms = 150,
  focus_debounce_ms = 1500,
}

function M.discover(root, opts, cb)
  local landed, pending = {}, 2
  local function finish(kind, out)
    landed[kind] = out
    pending = pending - 1
    if pending ~= 0 then return end
    vim.schedule(function()
      if landed.find.code ~= 0 then
        local msg = vim.trim(landed.find.stderr or "")
        cb(nil, msg ~= "" and msg or "repository discovery failed")
        return
      end
      local seen, repos = {}, {}
      local function add(repo)
        repo = vim.fs.normalize(repo)
        if repo ~= "" and not seen[repo] then
          seen[repo] = true
          repos[#repos + 1] = repo
        end
      end
      if landed.parent.code == 0 then
        add(vim.trim(landed.parent.stdout or ""))
      end
      for _, git_entry in ipairs(vim.split(landed.find.stdout or "", "\n", { trimempty = true })) do
        add(vim.fs.dirname(git_entry))
      end
      table.sort(repos)
      cb(repos, nil)
    end)
  end
  vim.system(
    { "git", "-C", root, "rev-parse", "--show-toplevel" },
    { text = true, timeout = opts.timeout_ms },
    function(out) finish("parent", out) end
  )
  vim.system(
    { "find", root, "-name", ".git", "-prune", "-print" },
    { text = true, timeout = opts.timeout_ms },
    function(out) finish("find", out) end
  )
  return true
end
```

Replace `M.refresh` with:

```lua
function M.refresh(root, opts, cb)
  return M.discover(root, opts, function(repos, discover_err)
    if discover_err then
      cb(nil, discover_err)
      return
    end
    if #repos == 0 then
      cb({}, nil)
      return
    end
    local raw, pending = {}, #repos
    for i, repo in ipairs(repos) do
      vim.system(
        { "git", "-C", repo, "status", "--porcelain=v2", "--branch" },
        { text = true, timeout = opts.timeout_ms },
        function(out)
          raw[i] = out
          pending = pending - 1
          if pending == 0 then
            vim.schedule(function()
              local entries = {}
              for j, path in ipairs(repos) do
                entries[#entries + 1] = build_entry(path, raw[j])
              end
              table.sort(entries, M.compare_entries)
              cb(entries, nil)
            end)
          end
        end
      )
    end
  end)
end
```

- [ ] **Step 4: Run Core and scope tests**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/core_test.lua
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
```

Expected: both print their `OK` line and exit 0.

- [ ] **Step 5: Commit asynchronous discovery**

```sh
git add phase_0/scm.nvim/lua/scm/core.lua phase_0/scm.nvim/tests/core_test.lua
git commit -m "feat(scm): discover repositories from explorer root"
```

### Task 3: Tab-scoped Panel state and full-Refresh coordination

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/panel.lua:72-94,221-344`
- Modify: `phase_0/scm.nvim/tests/core_test.lua:338-597`
- Modify: `phase_0/scm.nvim/tests/explorer_scope_test.lua`
- Modify: `/Users/dalee/.config/nvim/lua/plugins/snacks.lua:32-48`
- Modify: `/Users/dalee/.config/nvim/lua/plugins/neo-tree.lua:6-16`

**Interfaces:**
- Consumes: `scope.current()`, `core.refresh(root, opts, cb)`, and picker-local `_scm_tab`.
- Produces: `panel.tab_state(tab?) -> { root, entries, collapsed, refreshing, generation, queued_root }`; `panel.root_changed(root) -> boolean`; `panel.refresh_view(picker?) -> boolean` with per-tab newest-request coalescing.

- [ ] **Step 1: Add failing tab-state and stale-generation tests**

Append to `tests/explorer_scope_test.lua` before its final cleanup/print:

```lua
local panel = require("scm.panel")
local core = require("scm.core")
local tab_a = vim.api.nvim_get_current_tabpage()
local state_a = panel.tab_state(tab_a)
state_a.entries = { { path = "/a", name = "a", clean = true, files = {} } }
state_a.collapsed["/a"] = true
vim.cmd("tabnew")
local tab_b = vim.api.nvim_get_current_tabpage()
local state_b = panel.tab_state(tab_b)
eq(state_b.entries, {}, "Repo Entries are isolated by tab")
eq(state_b.collapsed, {}, "collapse state is isolated by tab")

local pending = {}
local old_refresh = core.refresh
core.refresh = function(root, _, cb)
  pending[#pending + 1] = { root = root, cb = cb }
  return true
end
local picker = {
  _scm_tab = tab_b,
  input = { win = { set_title = function() end } },
  current = function() return nil end,
  items = function() return {} end,
}
_G.Snacks = { picker = { get = function() return {} end } }
state_b.root = second_real
state_b.entries = { { path = "/old-scope", name = "old-scope", clean = true, files = {} } }
assert(panel.root_changed(third_real), "provider root change is accepted")
eq(state_b.root, third_real, "provider root change updates current tab")
eq(state_b.entries, {}, "provider root change clears entries from previous scope")
state_b.root = second_real
assert(panel.refresh_view(picker), "first tab refresh starts")
state_b.root = third_real
assert(not panel.refresh_view(picker), "overlap is coalesced")
eq(#pending, 1, "overlap does not stack Core requests")
pending[1].cb({ { path = "/stale", name = "stale", clean = true, files = {} } }, nil)
eq(#pending, 2, "newest queued root starts after old request lands")
eq(pending[2].root, third_real, "queued request uses newest Explorer Root")
eq(state_b.entries, {}, "stale generation does not publish")
pending[2].cb({ { path = "/fresh", name = "fresh", clean = true, files = {} } }, nil)
eq(state_b.entries[1].path, "/fresh", "newest generation publishes")
assert(panel.refresh_view(picker), "error-path refresh starts")
pending[#pending].cb(nil, "repository discovery failed")
eq(state_b.entries[1].path, "/fresh", "discovery error preserves last successful entries")

vim.cmd("tabnew")
local tab_c = vim.api.nvim_get_current_tabpage()
local state_c = panel.tab_state(tab_c)
state_c.root = second_real
local closed_picker = {
  _scm_tab = tab_c,
  input = { win = { set_title = function() end } },
  current = function() return nil end,
  items = function() return {} end,
}
assert(panel.refresh_view(closed_picker), "closing-tab refresh starts")
local closed_request = pending[#pending]
vim.cmd("tabclose")
closed_request.cb({ { path = "/closed", name = "closed", clean = true, files = {} } }, nil)
eq(state_c.entries, {}, "callback after tab close is discarded")
core.refresh = old_refresh
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
```

Expected: FAIL because `panel.tab_state` does not exist and Panel state is still global.

- [ ] **Step 3: Introduce tab-keyed state**

Replace the current Panel state declaration with:

```lua
M.state = { opts = nil, tabs = {} }

function M.tab_state(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  for handle in pairs(M.state.tabs) do
    if not vim.api.nvim_tabpage_is_valid(handle) then M.state.tabs[handle] = nil end
  end
  if not M.state.tabs[tab] then
    M.state.tabs[tab] = {
      root = nil,
      entries = {},
      collapsed = {},
      refreshing = false,
      generation = 0,
      queued_root = nil,
    }
  end
  return M.state.tabs[tab]
end
```

In every picker action, derive state with:

```lua
local state = M.tab_state(picker._scm_tab)
```

Replace reads/writes of `M.state.entries` and `M.state.collapsed` with that state. Keep `M.state.opts` global.

Use the tab state explicitly in the collapse mutations:

```lua
local function set_collapsed(picker, item, collapsed)
  local state = M.tab_state(picker._scm_tab)
  state.collapsed[item.entry.path] = collapsed and true or nil
  rerender(picker, item.entry.path, index_of(picker:items(), item.entry.path), "Source Control")
end
```

Inside `scm_close`, replace the file-row mutation with:

```lua
local state = M.tab_state(picker._scm_tab)
state.collapsed[item.entry.path] = true
rerender(picker, item.entry.path, nil, "Source Control")
```

- [ ] **Step 4: Capture Explorer Root before replacing the explorer**

At the start of `toggle()`, resolve the scope before closing any provider:

```lua
local scope = require("scm.scope")

function M.toggle()
  local open = Snacks.picker.get({ source = "scm" })[1]
  if open then
    open:close()
    return
  end
  local root = scope.current()
  for _, picker in ipairs(Snacks.picker.get({ source = "explorer" })) do picker:close() end
  local manager = package.loaded["neo-tree.sources.manager"]
  local command = package.loaded["neo-tree.command"]
  if manager and command then
    local ok, state = pcall(manager.get_state, "filesystem")
    if ok and state and state.winid and vim.api.nvim_win_is_valid(state.winid) then
      pcall(command.execute, { action = "close" })
    end
  end
  M.open(root)
end
```

Change `open()` to `open(root)`, capture the current tab, reset only that tab's collapse map, store `state.root = root or scope.current()`, set `picker._scm_tab = tab`, and close over `state` in the finder:

```lua
function M.open(root)
  M.setup(M.state.opts)
  local tab = vim.api.nvim_get_current_tabpage()
  local state = M.tab_state(tab)
  local next_root = root or scope.current()
  if state.root ~= next_root then state.entries = {} end
  state.root = next_root
  state.collapsed = {}
  local picker = Snacks.picker.pick({
    source = "scm",
    title = "Source Control",
    show_empty = true,
    finder = function() return M.build_items(state.entries, state.collapsed) end,
    format = M.format_item,
    layout = { preset = "sidebar", preview = false },
    focus = "list",
    jump = { close = false },
    auto_close = false,
    matcher = { sort_empty = false, fuzzy = true },
    sort = { fields = { "sort" } },
    confirm = "scm_confirm",
    actions = key_actions(),
    win = {
      list = {
        keys = {
          ["h"] = "scm_close",
          ["l"] = "scm_open",
          ["d"] = "scm_diff",
          ["g"] = "scm_lazygit",
          ["r"] = "scm_refresh",
        },
      },
      input = { keys = { ["<c-r>"] = { "scm_refresh", mode = { "i", "n" } } } },
    },
  })
  picker._scm_tab = tab
  M.refresh_view(picker)
  return picker
end
```

- [ ] **Step 5: Implement per-tab full-Refresh coalescing**

Add a current-tab-independent picker lookup and replace `refresh_view`:

```lua
local function picker_for_tab(tab)
  for _, picker in ipairs(Snacks.picker.get({ source = "scm", tab = false })) do
    if picker._scm_tab == tab and not picker.closed then return picker end
  end
end

local function run_full_refresh(tab, state)
  local generation, root = state.generation, state.queued_root
  state.queued_root = nil
  state.refreshing = true
  local picker = picker_for_tab(tab)
  local anchor, anchor_idx
  if picker then anchor, anchor_idx = capture_anchor(picker) end
  core.refresh(root, M.state.opts, function(entries, err)
    state.refreshing = false
    if vim.api.nvim_tabpage_is_valid(tab) and generation == state.generation then
      if not err then state.entries = entries end
      local current = picker_for_tab(tab)
      if current then
        local title = err and ("Source Control (" .. err .. ")")
          or (#entries == 0 and "Source Control (no repositories under Explorer Root)" or "Source Control")
        rerender(current, anchor, anchor_idx, title)
      end
    end
    if state.queued_root and vim.api.nvim_tabpage_is_valid(tab) then run_full_refresh(tab, state) end
  end)
end

function M.refresh_view(picker)
  picker = picker or Snacks.picker.get({ source = "scm" })[1]
  if not picker then return false end
  local tab = picker._scm_tab or vim.api.nvim_get_current_tabpage()
  local state = M.tab_state(tab)
  if not state.root then
    set_title(picker, "Source Control (Explorer Root unavailable)")
    return false
  end
  state.generation = state.generation + 1
  state.queued_root = state.root
  set_title(picker, "Source Control (scanning…)")
  if state.refreshing then return false end
  run_full_refresh(tab, state)
  return true
end
```

- [ ] **Step 6: Connect provider events to the Panel's Root**

Add after `refresh_view`:

```lua
function M.root_changed(root)
  local tab = vim.api.nvim_get_current_tabpage()
  local state = M.tab_state(tab)
  if not root or state.root == root then return false end
  state.root = root
  state.entries = {}
  state.collapsed = {}
  local picker = picker_for_tab(tab)
  if picker then return M.refresh_view(picker) end
  return true
end
```

Replace the existing Snacks `on_show` callback with:

```lua
on_show = function(picker)
  local root, changed = require("scm.scope").remember(picker:cwd())
  if changed then require("scm.panel").root_changed(root) end
  require("svgtree.adapters.snacks").on_show(picker)
end,
```

Add this handler before the existing `file_opened` handler in `neo-tree.lua`:

```lua
{
  event = "neo_tree_window_after_open",
  handler = function(args)
    if args.source ~= "filesystem" then return end
    local state = require("neo-tree.sources.manager").get_state("filesystem")
    if not state or not state.path then return end
    local root, changed = require("scm.scope").remember(state.path)
    if changed then require("scm.panel").root_changed(root) end
  end,
},
```

- [ ] **Step 7: Adapt existing Panel regression tests to tab state**

At the start of the Panel section in `tests/core_test.lua`, add:

```lua
local function panel_state()
  return panel.tab_state(vim.api.nvim_get_current_tabpage())
end
```

Mechanically replace `panel.state.entries` with `panel_state().entries` and `panel.state.collapsed` with `panel_state().collapsed`. Update the Core stub signature to `core.refresh = function(_, _, cb)` and make mocked `Snacks.picker.get` accept `{ tab = false }`.

For each fake SCM picker used by full-Refresh tests, set its owner explicitly:

```lua
refresh_picker._scm_tab = vim.api.nvim_get_current_tabpage()
```

- [ ] **Step 8: Run both suites**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/core_test.lua
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
```

Expected: both `OK` lines, exit 0.

- [ ] **Step 9: Commit tab-scoped Panel behavior**

```sh
git add phase_0/scm.nvim/lua/scm/panel.lua phase_0/scm.nvim/tests/core_test.lua phase_0/scm.nvim/tests/explorer_scope_test.lua
git commit -m "feat(scm): isolate panel state by explorer tab"
```

The user-local Snacks and Neo-tree configuration changes remain outside the repository commit.

### Task 4: Scoped-refresh fanout, CI, and live integration

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/panel.lua:346-370`
- Modify: `phase_0/scm.nvim/lua/scm/refresh.lua:17-29,76-90`
- Modify: `phase_0/scm.nvim/tests/explorer_scope_test.lua`
- Modify: `.github/workflows/scm.yml:29-31`
- Modify: `/Users/dalee/.config/nvim/lua/plugins/scm.lua:17`

**Interfaces:**
- Consumes: `core.refresh_repo(repo, opts, cb)` and `panel.state.tabs`.
- Produces: `panel.refresh_repo_view(repo) -> boolean`, updating every live tab that already contains the repository and rerendering only that tab's visible picker.

- [ ] **Step 1: Write the failing scoped-fanout test**

Append before the final cleanup in `tests/explorer_scope_test.lua`:

```lua
local old_refresh_repo = core.refresh_repo
local updated = { path = "/shared", name = "shared", branch = "main", clean = false, files = { { path = "x", xy = ".M" } } }
local untouched = { path = "/other", name = "other", branch = "main", clean = true, files = {} }
panel.state.tabs[tab_a].entries = { vim.deepcopy(updated) }
panel.state.tabs[tab_b].entries = { untouched }
core.refresh_repo = function(repo, _, cb)
  eq(repo, "/shared", "scoped fanout repo")
  cb(updated)
  return true
end
assert(panel.refresh_repo_view("/shared"), "scoped refresh accepted")
eq(panel.state.tabs[tab_a].entries[1].files, updated.files, "interested tab updates")
eq(panel.state.tabs[tab_b].entries, { untouched }, "uninterested tab does not gain repo")
core.refresh_repo = old_refresh_repo
```

- [ ] **Step 2: Run the focused test to verify it fails**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
```

Expected: FAIL because `refresh_repo_view` still updates one global entries list.

- [ ] **Step 3: Fan scoped results into interested tab states**

Replace `refresh_repo_view` with:

```lua
function M.refresh_repo_view(repo)
  return core.refresh_repo(repo, M.state.opts, function(entry)
    for tab, state in pairs(M.state.tabs) do
      if vim.api.nvim_tabpage_is_valid(tab) then
        local found
        for index, existing in ipairs(state.entries) do
          if existing.path == entry.path then
            state.entries[index] = entry
            found = true
            break
          end
        end
        if found then
          table.sort(state.entries, core.compare_entries)
          local picker = picker_for_tab(tab)
          if picker then
            local anchor, anchor_idx = capture_anchor(picker)
            rerender(picker, anchor, anchor_idx, "Source Control")
          end
        end
      end
    end
  end)
end
```

Keep `refresh.lua`'s full Refresh current-tab scoped. Update its comments to say that overlap is coalesced per tab rather than dropped.

Replace the comment above `M.full()` with:

```lua
-- Full Refresh, debounced for the current tab. The Panel no-ops while closed
-- and coalesces overlapping requests independently for each tab.
```

- [ ] **Step 4: Run both headless suites**

Run:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/core_test.lua
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
```

Expected: both print their `OK` line and exit 0.

- [ ] **Step 5: Add the focused suite to CI**

Change the workflow test step to:

```yaml
      - name: Run SCM headless tests
        working-directory: phase_0/scm.nvim
        run: |
          nvim -l tests/core_test.lua
          nvim -l tests/explorer_scope_test.lua
```

Update `/Users/dalee/.config/nvim/lua/plugins/scm.lua` to:

```lua
opts = {}, -- Explorer Root is derived from the active file tree per tab
```

- [ ] **Step 6: Verify the real nvim-nightly configuration and original symptom**

Run the complete suites through the real binary:

```sh
cd /Users/dalee/Projects/Sprite/phase_0/scm.nvim
/Users/dalee/.local/bin/nvim-nightly -l tests/core_test.lua
/Users/dalee/.local/bin/nvim-nightly -l tests/explorer_scope_test.lua
git diff --check
```

Then start a fresh interactive `nvim-nightly` in `/Users/dalee/Projects/Sprite` and verify:

1. `<leader>e` opens Snacks at Sprite; `<leader>gs` opens SCM on the first press and includes Sprite.
2. Open Snacks at `/Users/dalee/Projects`; `<leader>gs` includes every repository beneath Projects.
3. Close the explorer, switch buffers, and reopen SCM; the same Explorer Root persists.
4. Use two tabs with different explorer roots; Repo Entries and `h` collapse state remain independent.
5. Press `r` rapidly twice; only the newest queued result renders.
6. Exit lazygit for a repository visible in both tabs; both stored Repo Entries update.

Expected: every item passes; neither headless suite reports an assertion; `git diff --check` emits no output.

- [ ] **Step 7: Commit integration and CI**

```sh
git add phase_0/scm.nvim/lua/scm/panel.lua phase_0/scm.nvim/lua/scm/refresh.lua phase_0/scm.nvim/tests/explorer_scope_test.lua .github/workflows/scm.yml
git commit -m "test(scm): verify explorer-scoped refresh behavior"
```

The user-local `scm.lua` and `snacks.lua` changes remain outside the repository commit.
