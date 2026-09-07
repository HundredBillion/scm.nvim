# Perpetual Sidebar Handoff Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let SCM and the configured Explorer replace each other indefinitely while preserving Explorer-root repository scope, tab ownership, teardown failures, and complete multi-repository results.

**Architecture:** `scm.scope.current()` captures one canonical Explorer root from the current tab. `scm.core` always discovers Git repositories recursively below that root. `scm.panel` closes the outgoing Sidebar Activity synchronously, then delegates the incoming open to the one-slot `scm.transition` coalescer.

**Tech Stack:** Lua, Neovim 0.12 Lua API, Snacks Picker, optional Neo-tree/SVGTree public functions, LazyVim key specifications, assert-based `nvim -l` tests, and a real Neovim PTY.

## Global constraints

- Snacks Explorer scope comes from `picker:cwd()` only. Cursor movement must not change SCM scope.
- Entering a directory or going up changes Explorer `cwd()` and must be captured by the next SCM open.
- Core discovery is recursive and includes nested repository directories and linked-worktree `.git` files.
- SCM and Explorer remain mutually exclusive; SCM does not synchronize scope while Explorer is closed.
- Standalone SVGTree is considered only when a current-tab normal window has filetype `svgtree`.
- Teardown completes before an incoming activity is scheduled. A close failure aborts the handoff.
- A new handoff cancels stale pending work before teardown starts.
- Only `setup`, `toggle`, and `handoff` are exported from `require("scm")`; `panel.open` remains internal/testable.
- Explorer mappings belong to user configuration. SCM adds no SVGTree dependency and patches no explorer internals.
- Direct third-party commands that bypass configured handoff mappings are outside the mutual-exclusion guarantee.

---

### Task 1: Restore cwd-only Explorer scope and recursive Core discovery

**Files:**
- Modify: `lua/scm/scope.lua`
- Modify: `lua/scm/core.lua`
- Modify: `lua/scm/panel.lua`
- Modify: `lua/scm/refresh.lua`
- Modify: `tests/core_test.lua`
- Modify: `tests/explorer_scope_test.lua`
- Modify: `tests/handoff_test.lua`

**Interfaces:**
- Consumes: current-tab Snacks `picker:cwd()`, optional current-tab Neo-tree state, optional current-tab SVGTree root.
- Produces: `scope.current(): string?`, `core.discover(root, opts, cb): true`, `core.refresh(root, opts, cb): true`, and internal `panel.open(root)`.

- [ ] **Step 1: Make cwd win over cursor directory**

Add a focused scope assertion:

```lua
local dir_called, items_called = false, false
_G.Snacks = { picker = { get = function()
  return { {
    cwd = function() return second end,
    dir = function() dir_called = true end,
    items = function() items_called = true end,
  } }
end } }

eq(scope.current(), second_real, "Snacks Explorer cwd replaces tab root")
eq({ dir_called, items_called }, { false, false }, "SCM reads only the Snacks Explorer cwd")
```

Run:

```bash
cd /home/hundredbillion/.local/share/nvim/lazy/scm.nvim/the repository root
nvim -l tests/explorer_scope_test.lua
```

Expected before implementation: the cursor directory wins or rendered items are read.

- [ ] **Step 2: Reduce the Snacks scope adapter to cwd**

Use this contract in `scm.scope`:

```lua
local function snacks_root()
  if not (_G.Snacks and Snacks.picker and Snacks.picker.get) then return nil end
  local picker = Snacks.picker.get({ source = "explorer" })[1]
  if not picker then return nil end
  local ok, root = pcall(function() return picker:cwd() end)
  return ok and root or nil
end
```

Keep only one canonical root in Panel tab state. `panel.toggle()` captures `scope.current()` before closing Explorer and schedules `M.open(root)`. Delete the closed-Panel scope synchronizer and its `DirChanged` autocmd because mutually exclusive activities cannot change Explorer scope while SCM is visible.

- [ ] **Step 3: Preserve unconditional nested discovery**

Keep Core's three-argument discovery interface and always consume every `find` result:

```lua
if landed.parent.code == 0 then
  add(vim.trim(landed.parent.stdout or ""))
end
for _, git_entry in ipairs(vim.split(landed.find.stdout or "", "\n", { trimempty = true })) do
  add(vim.fs.dirname(git_entry))
end
table.sort(repos)
cb(repos, nil)
```

The unit fixture must include a containing repository and an arbitrary-depth nested worktree, with this observable result:

```lua
eq(discovered, { parent_real, deep_real }, "containing and arbitrary-depth repositories are canonicalized")
```

- [ ] **Step 4: Cover cursor, enter, and go-up capture**

Use a mutable fake `picker:cwd()` and a distinct mutable cursor directory. Assert cursor changes retain the root, then assert entering and going up change `scope.current()`. In `handoff_test.lua`, stub `scope.current()` and verify the exact root captured by each subsequent `panel.toggle()` call.

- [ ] **Step 5: Run the task tests**

```bash
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
nvim -l tests/handoff_test.lua
```

Expected: `OK`, `OK explorer scope`, and `OK sidebar handoff`; exit code `0`.

---

### Task 2: Scope standalone SVGTree and make teardown transactional

**Files:**
- Modify: `lua/scm/scope.lua`
- Modify: `lua/scm/panel.lua`
- Modify: `tests/explorer_scope_test.lua`
- Modify: `tests/handoff_test.lua`

**Interfaces:**
- Consumes: `vim.api.nvim_tabpage_list_wins(0)`, normal-window configs, buffer filetype, optional `svgtree.root()`, optional `svgtree.close()`, and Neo-tree's `manager.get_state()`/`command.execute()` interfaces.
- Produces: tab-local scope/teardown and errors prefixed with `SCM handoff failed to inspect Neo-tree:`, `SCM handoff failed to close Neo-tree:`, or `SCM handoff failed to close SVGTree:`.

- [ ] **Step 1: Add the two-tab SVGTree regression**

Create a normal `svgtree` buffer in tab A. Verify `scope.current()` reads `svgtree.root()` in A. Switch to tab B, verify the root function is not called again, request SCM, and verify `svgtree.close()` remains untouched. Return to A and verify SCM does close the standalone tree there.

Run:

```bash
nvim -l tests/explorer_scope_test.lua
nvim -l tests/handoff_test.lua
```

Expected before implementation: tab B receives tab A's SVGTree root and/or closes tab A's tree.

- [ ] **Step 2: Gate optional SVGTree access on a current-tab normal window**

Before reading the loaded module, inspect current-tab windows:

```lua
local has_svgtree = false
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_config(win).relative == ""
    and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "svgtree"
  then
    has_svgtree = true
    break
  end
end

if has_svgtree then
  local svgtree = package.loaded["svgtree"]
  if svgtree and svgtree.close then
    local closed, close_err = pcall(svgtree.close)
    if not closed then error("SCM handoff failed to close SVGTree: " .. tostring(close_err), 0) end
  end
end
```

Do not patch SVGTree or inspect its private state.

- [ ] **Step 3: Add close-failure regressions**

For each handoff/toggle-on failure path:

1. Queue a stale transition.
2. Make the active host's close raise.
3. Assert the error surfaces.
4. Flush and assert neither stale nor requested SCM open ran.
5. Restore close behavior and assert a later request runs.

Cover natural Snacks close propagation plus contextual Neo-tree inspection,
Neo-tree close, and SVGTree close errors. For Neo-tree, assert the active
current-tab filesystem state closes with this exact call:

```lua
command.execute({ action = "close", source = "filesystem" })
```

- [ ] **Step 4: Cancel before teardown and abort on close errors**

Both directions begin with cancellation:

```lua
function M.handoff(open)
  transition.cancel()
  for _, picker in ipairs(Snacks.picker.get({ source = "scm" })) do
    picker:close()
  end
  transition.request(open)
end

function M.toggle()
  local open = Snacks.picker.get({ source = "scm" })[1]
  if open then
    transition.cancel()
    open:close()
    return
  end
  transition.cancel()
  local root = scope.current()
  close_explorers()
  transition.request(function()
    M.open(root)
  end)
end
```

Do not suppress Neo-tree inspection or active Neo-tree/SVGTree close failures.
Add context and rethrow before `transition.request()` can run.

- [ ] **Step 5: Run the task tests**

```bash
nvim -l tests/handoff_test.lua
nvim -l tests/explorer_scope_test.lua
```

Expected: both exit `0`.

---

### Task 3: Narrow the public interface, extend CI, and strengthen the live regression

**Files:**
- Modify: `lua/scm/init.lua`
- Modify: `tests/handoff_test.lua`
- Modify: `tests/sidebar_handoff_pty.lua`
- Modify: `.github/workflows/scm.yml`
- Read only: `/home/hundredbillion/.config/nvim/lua/plugins/snacks-animated-scrolling-off.lua`

**Interfaces:**
- Produces: public `setup(opts)`, `toggle()`, and `handoff(open)` only.
- CI runs all three `nvim -l` suites.
- PTY runs 100 complete Explorer→SCM cycles at 69 rows × 129 columns.

- [ ] **Step 1: Lock the transition origin and public surface**

In `handoff_test.lua`, request a transition in tab A, switch to tab B, flush, and assert the callback observes tab A while tab B remains current. Also assert:

```lua
assert(require("scm").open == nil, "scm.open is not part of the public interface")
```

Remove `open = panel.open` from `scm/init.lua`; tests may continue to stub `require("scm.panel").open`.

- [ ] **Step 2: Add handoff tests to CI**

The workflow command block is:

```yaml
run: |
  nvim -l tests/handoff_test.lua
  nvim -l tests/core_test.lua
  nvim -l tests/explorer_scope_test.lua
```

- [ ] **Step 3: Exercise the configured Explorer callback**

Resolve `<leader>e` from the live mapping table and invoke its Lua callback on at least the first cycle:

```lua
local mapping = vim.fn.maparg(vim.g.mapleader .. "e", "n", false, true)
if type(mapping.callback) ~= "function" then
  return fail("configured <leader>e Lua callback is unavailable")
end
explorer_mapping = mapping.callback
```

Do not replace this checkpoint with feedkey timing.

- [ ] **Step 4: Require complete SCM content at every checkpoint**

Canonicalize `vim.uv.cwd()` as the expected repository. For each SCM open, wait for a newer Panel generation to finish and assert:

- exactly one SCM picker and no Explorer picker;
- Panel state contains a Repo Entry whose path is the real root and whose name is `svgtree.nvim`;
- picker items contain the corresponding repository header;
- `cmdheight` and full normal-window height are unchanged.

Keep all 100 cycles and repeat the layout/content assertion after the final cycle.

- [ ] **Step 5: Run the 69×129 PTY regression**

From `/home/hundredbillion/Projects/svgtree.nvim`, start a PTY with exactly 69 rows and 129 columns, then run:

```bash
nvim -c "luafile /home/hundredbillion/.local/share/nvim/lazy/scm.nvim/tests/sidebar_handoff_pty.lua" .
```

Expected: `OK sidebar handoff 100 cycles` and process exit code `0`.

---

### Task 4: Document installation and verify the cohesive remediation

**Files:**
- Create: `README.md`
- Modify: `docs/TSPs/08-08-2026-perpetual-sidebar-handoff.md`

- [ ] **Step 1: Document the current local-clone bootstrap**

The README must derive the clone location from `XDG_DATA_HOME` with a
`$HOME/.local/share` fallback, clone
`https://github.com/HundredBillion/Sprite.git` into that location, keep Lazy's
local `dir` based on `vim.fn.stdpath("data")`, and show the exact four
handoff-backed Explorer mappings.

State that direct Explorer commands bypass the guarantee and that SCM neither depends on SVGTree nor patches explorer internals.

- [ ] **Step 2: Run the final headless matrix**

```bash
cd /home/hundredbillion/.local/share/nvim/lazy/scm.nvim/the repository root
nvim -l tests/handoff_test.lua
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
nvim --headless "+lua local lhs=vim.g.mapleader..'e'; local m=vim.fn.maparg(lhs,'n',false,true); assert(type(m.callback)=='function'); require('lazy').load({plugins={'scm.nvim'}}); local s=require('scm'); assert(type(s.handoff)=='function'); assert(s.open==nil)" +qa
```

- [ ] **Step 3: Run formatting and repository checks**

Use Mason StyLua with the active Neovim formatter config on every changed Lua file:

```bash
/home/hundredbillion/.local/share/nvim/mason/bin/stylua \
  --config-path /home/hundredbillion/.config/nvim/stylua.toml \
  --check lua/scm/init.lua lua/scm/scope.lua lua/scm/panel.lua lua/scm/core.lua lua/scm/refresh.lua \
  lua/scm/transition.lua \
  tests/handoff_test.lua tests/core_test.lua tests/explorer_scope_test.lua tests/sidebar_handoff_pty.lua
git diff --check
```

- [ ] **Step 4: Commit the verified correction**

Create one focused commit without adding ignored internal reports:

```bash
git add docs/TSPs/08-08-2026-perpetual-sidebar-handoff.md the repository root
git commit -m "fix: propagate explorer teardown failures"
```

Do not push, merge, or modify the external Snacks configuration.
