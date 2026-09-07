# Multi-Repo SCM Panel Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A persistent left-sidebar Neovim panel showing all changes across all configured git repos (VSCode SCM look), read-oriented, delegating writes to lazygit.

**Architecture:** UI-free `scm.core` scans Roots and emits Repo Entries (plain Lua tables, raw porcelain XY codes — ADR 0002); `scm.panel` renders them as a custom snacks picker source with the explorer's sidebar layout (ADR 0001). One-way data flow, refresh on open/`r`/panel-launched-lazygit-close only.

**Tech Stack:** Pure Lua, Neovim ≥0.12 built-ins (`vim.system`, `vim.fn`), snacks.nvim (already installed via LazyVim), gitsigns (diff), lazygit (write ops). No new dependencies.

## Global Constraints

- Plugin root: `/Users/davidlee/Projects/Sprite/phase_0/scm.nvim` (inside the Sprite git repo; ALL commits happen in `/Users/davidlee/Projects/Sprite`)
- `~/.config/nvim` is NOT a git repo — the one file there (Task 6's spec) is not committed anywhere; everything else must be committed to the Sprite repo
- `scm/core.lua` must never `require` snacks or any UI module (PRD goal 3; verified by test in Task 1)
- File Entries carry raw `xy` codes verbatim (`.M`, `MM`, `??`, `R.`, `UU`) — never derived fields (ADR 0002)
- Defaults: `roots = { "~/MyServe1.0", "~/Code" }`, `depth = 2`, git timeout 5000ms
- Tests run headless: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua` → exits 0 printing `OK`, non-zero on any assert failure
- Terminology per `phase_0/CONTEXT.md`: Core, Panel, Renderer, Root, Repo Entry, File Entry, XY Code, Mixed State, Panel-Launched lazygit

---

### Task 1: Core — porcelain-v2 parser

**Files:**
- Create: `phase_0/scm.nvim/lua/scm/core.lua`
- Create: `phase_0/scm.nvim/tests/core_test.lua`

**Interfaces:**
- Produces: `require("scm.core").parse_status(lines: string[]) -> { branch: string, ahead: integer, behind: integer, files: { {path: string, xy: string} } }`
  (used by Task 3's `refresh`; `files` entries are File Entries per CONTEXT.md)

- [ ] **Step 1: Write the failing test**

Create `phase_0/scm.nvim/tests/core_test.lua`:

```lua
-- Headless test harness: run with `nvim -l tests/core_test.lua` from the
-- plugin root. Plain asserts, no framework.
vim.opt.runtimepath:prepend(vim.uv.cwd())

local function eq(got, want, label)
  assert(
    vim.deep_equal(got, want),
    ("%s\nexpected: %s\ngot:      %s"):format(label or "mismatch", vim.inspect(want), vim.inspect(got))
  )
end

local core = require("scm.core")

-- core must be UI-free: loading it must not have pulled in snacks
assert(package.loaded["snacks"] == nil, "scm.core must not require snacks")

-- 1. Ordinary repo: headers + changed/renamed/unmerged/untracked entries
local parsed = core.parse_status({
  "# branch.oid 63929384f952e4a052dec332a948695334703d38",
  "# branch.head main",
  "# branch.upstream origin/main",
  "# branch.ab +2 -1",
  "1 .M N... 100644 100644 100644 abc123 abc123 app/models/device.rb",
  "1 MM N... 100644 100644 100644 abc123 def456 lib/staged_and_edited.rb",
  "1 M. N... 100644 100644 100644 abc123 def456 lib/staged_only.rb",
  "2 R. N... 100644 100644 100644 abc123 def456 R100 lib/new_name.rb\tlib/old_name.rb",
  "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflicted.rb",
  "? scratch.rb",
})
eq(parsed.branch, "main", "branch")
eq(parsed.ahead, 2, "ahead")
eq(parsed.behind, 1, "behind")
eq(parsed.files, {
  { path = "app/models/device.rb", xy = ".M" },
  { path = "lib/staged_and_edited.rb", xy = "MM" },
  { path = "lib/staged_only.rb", xy = "M." },
  { path = "lib/new_name.rb", xy = "R." },
  { path = "conflicted.rb", xy = "UU" },
  { path = "scratch.rb", xy = "??" },
}, "files (raw xy preserved, rename keeps NEW path, one entry per file)")

-- 2. Detached HEAD: branch falls back to short oid
local detached = core.parse_status({
  "# branch.oid 0123456789abcdef0123456789abcdef01234567",
  "# branch.head (detached)",
})
eq(detached.branch, "0123456", "detached -> short sha")
eq(detached.files, {}, "clean detached")

-- 3. No upstream: missing branch.ab -> zeros
local noup = core.parse_status({
  "# branch.oid aaaa",
  "# branch.head feature/x",
  "1 .M N... 100644 100644 100644 abc abc file.txt",
})
eq(noup.ahead, 0, "no upstream ahead")
eq(noup.behind, 0, "no upstream behind")

-- 4. Empty output (clean repo)
local clean = core.parse_status({})
eq(clean.files, {}, "empty -> no files")

print("OK")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: FAIL — `module 'scm.core' not found`

- [ ] **Step 3: Write minimal implementation**

Create `phase_0/scm.nvim/lua/scm/core.lua`:

```lua
-- scm.core — the UI-free Core (see phase_0/CONTEXT.md).
-- Emits Repo Entries; never requires any UI module (ADR 0001/0002).
local M = {}

M.defaults = {
  roots = { "~/MyServe1.0", "~/Code" },
  depth = 2,
  timeout_ms = 5000,
}

-- Parse `git status --porcelain=v2 --branch` output into branch/ahead/behind
-- plus File Entries carrying the raw XY Code verbatim (ADR 0002).
-- Line shapes (see `git help status`, Porcelain Format Version 2):
--   # branch.oid <sha> | # branch.head <name|(detached)> | # branch.ab +A -B
--   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
--   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <Xscore> <new>\t<orig>
--   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
--   ? <path>
function M.parse_status(lines)
  local branch, oid = "?", nil
  local ahead, behind = 0, 0
  local files = {}
  for _, l in ipairs(lines) do
    local first = l:sub(1, 1)
    if first == "#" then
      local h = l:match("^# branch%.head (.+)$")
      if h then branch = h end
      local o = l:match("^# branch%.oid (%S+)")
      if o then oid = o end
      local a, b = l:match("^# branch%.ab %+(%d+) %-(%d+)$")
      if a then
        ahead, behind = tonumber(a), tonumber(b)
      end
    elseif first == "1" then
      local xy, path = l:match("^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then files[#files + 1] = { path = path, xy = xy } end
    elseif first == "2" then
      local xy, rest = l:match("^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then
        files[#files + 1] = { path = rest:match("^([^\t]+)"), xy = xy }
      end
    elseif first == "u" then
      local xy, path = l:match("^u (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then files[#files + 1] = { path = path, xy = xy } end
    elseif first == "?" then
      local p = l:match("^%? (.+)$")
      if p then files[#files + 1] = { path = p, xy = "??" } end
    end
  end
  if branch == "(detached)" and oid then
    branch = oid:sub(1, 7)
  end
  return { branch = branch, ahead = ahead, behind = behind, files = files }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: prints `OK`, exit code 0

- [ ] **Step 5: Commit**

```bash
cd /Users/davidlee/Projects/Sprite
git add phase_0/scm.nvim
git commit -m "feat(scm): porcelain-v2 parser with raw xy File Entries"
```

---

### Task 2: Core — repo scanner

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/core.lua` (append before `return M`)
- Modify: `phase_0/scm.nvim/tests/core_test.lua` (append before `print("OK")`)

**Interfaces:**
- Consumes: `M.defaults` from Task 1
- Produces: `core.scan(opts: {roots: string[], depth: integer}) -> string[]` — sorted absolute repo paths (used by Task 3)

- [ ] **Step 1: Write the failing test**

Append to `tests/core_test.lua` (before `print("OK")`):

```lua
-- scan(): finds .git dirs AND .git files (worktrees), respects depth, sorts
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/beta/.git", "p")
vim.fn.mkdir(tmp .. "/alpha", "p")
vim.fn.writefile({ "gitdir: /elsewhere" }, tmp .. "/alpha/.git") -- worktree-style .git FILE
vim.fn.mkdir(tmp .. "/too/deep/nested/.git", "p") -- beyond depth 2 from tmp
vim.fn.mkdir(tmp .. "/not_a_repo", "p")

local repos = core.scan({ roots = { tmp, tmp .. "/does-not-exist" }, depth = 2 })
eq(repos, { tmp .. "/alpha", tmp .. "/beta" }, "scan finds dir+file .git, sorted, depth-limited, missing root skipped")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: FAIL — `attempt to call field 'scan' (a nil value)`

- [ ] **Step 3: Write minimal implementation**

Append to `lua/scm/core.lua` before `return M`:

```lua
-- Find repositories: any directory directly containing `.git` (dir OR file —
-- worktrees and submodules use a .git file) up to `depth` levels under each
-- Root. Missing roots are skipped silently (PRD §5).
function M.scan(opts)
  local repos = {}
  for _, root in ipairs(opts.roots) do
    root = vim.fn.expand(root)
    if vim.fn.isdirectory(root) == 1 then
      local out = vim.fn.systemlist({
        "find", root, "-maxdepth", tostring(opts.depth), "-name", ".git", "-prune",
      })
      if vim.v.shell_error == 0 then
        for _, g in ipairs(out) do
          repos[#repos + 1] = vim.fn.fnamemodify(g, ":h")
        end
      end
    end
  end
  table.sort(repos)
  return repos
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: prints `OK`, exit code 0

- [ ] **Step 5: Commit**

```bash
cd /Users/davidlee/Projects/Sprite
git add phase_0/scm.nvim
git commit -m "feat(scm): repo scanner over configured Roots"
```

---

### Task 3: Core — async refresh (Repo Entry assembly)

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/core.lua` (append before `return M`)
- Modify: `phase_0/scm.nvim/tests/core_test.lua` (append before `print("OK")`)

**Interfaces:**
- Consumes: `M.scan`, `M.parse_status`, `M.defaults` (Tasks 1-2)
- Produces: `core.refresh(opts, cb) -> boolean` — `false` if a refresh is already in flight (call dropped), else `true`; `cb(entries)` runs later on the main loop with the sorted Repo Entry list:
  `{ name, path, branch, ahead, behind, files = { {path, xy} }, clean: boolean, err: string|nil }`
  Sorted needs-attention-first (dirty or errored, alpha within group), clean repos after (alpha). Used by Task 4/5.

- [ ] **Step 1: Write the failing test**

Append to `tests/core_test.lua` (before `print("OK")`):

```lua
-- refresh(): end-to-end against two real synthetic repos
local function sh(cmd)
  local r = vim.system(cmd, { text = true }):wait()
  assert(r.code == 0, "setup cmd failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
end

local work = vim.fn.tempname()
local dirty, cleanrepo = work .. "/dirty_repo", work .. "/clean_repo"
vim.fn.mkdir(dirty, "p")
vim.fn.mkdir(cleanrepo, "p")
for _, r in ipairs({ dirty, cleanrepo }) do
  sh({ "git", "-C", r, "init", "-q", "-b", "main" })
  vim.fn.writefile({ "hello" }, r .. "/a.txt")
  sh({ "git", "-C", r, "add", "." })
  sh({ "git", "-C", r, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init" })
end
vim.fn.writefile({ "changed" }, dirty .. "/a.txt")     -- .M
vim.fn.writefile({ "new" }, dirty .. "/untracked.txt") -- ??

local got
assert(core.refresh({ roots = { work }, depth = 2, timeout_ms = 5000 }, function(entries)
  got = entries
end) == true, "refresh accepted")
-- second call while in flight must be dropped
assert(core.refresh({ roots = { work }, depth = 2, timeout_ms = 5000 }, function() end) == false, "in-flight drop")
vim.wait(5000, function() return got ~= nil end, 10)
assert(got, "refresh callback fired")

eq(#got, 2, "two repos")
eq(got[1].name, "dirty_repo", "needs-attention first")
eq(got[1].clean, false, "dirty flagged")
eq(got[1].branch, "main", "branch parsed")
eq(got[1].files, {
  { path = "a.txt", xy = ".M" },
  { path = "untracked.txt", xy = "??" },
}, "dirty repo File Entries")
eq(got[2].name, "clean_repo", "clean repo second")
eq(got[2].clean, true, "clean flagged")
eq(got[2].files, {}, "clean repo no files")
assert(got[1].err == nil and got[2].err == nil, "no errors")

-- refresh usable again after completion
got = nil
assert(core.refresh({ roots = { work }, depth = 2, timeout_ms = 5000 }, function(entries) got = entries end))
vim.wait(5000, function() return got ~= nil end, 10)
assert(got and #got == 2, "second refresh works")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: FAIL — `attempt to call field 'refresh' (a nil value)`

- [ ] **Step 3: Write minimal implementation**

Append to `lua/scm/core.lua` before `return M`:

```lua
local in_flight = false

-- Refresh: scan Roots, fan out one async `git status --porcelain=v2 --branch`
-- per repo, assemble sorted Repo Entries, deliver via ONE scheduled callback.
-- CAUTION: vim.system's on_exit runs in a fast-event context where vim.fn.*
-- is forbidden — raw outputs are collected there and ALL processing happens
-- inside the final vim.schedule.
function M.refresh(opts, cb)
  if in_flight then
    return false
  end
  in_flight = true
  local repos = M.scan(opts)
  if #repos == 0 then
    in_flight = false
    vim.schedule(function() cb({}) end)
    return true
  end
  local raw, pending = {}, #repos
  for i, repo in ipairs(repos) do
    vim.system(
      { "git", "-C", repo, "status", "--porcelain=v2", "--branch" },
      { text = true, timeout = opts.timeout_ms },
      function(out) -- fast context: store only
        raw[i] = out
        pending = pending - 1
        if pending == 0 then
          vim.schedule(function()
            local entries = {}
            for j, r in ipairs(repos) do
              local o = raw[j]
              local name = r:match("[^/]+$") or r
              if o.code == 0 then
                local p = M.parse_status(vim.split(o.stdout or "", "\n", { trimempty = true }))
                entries[#entries + 1] = {
                  name = name, path = r, branch = p.branch,
                  ahead = p.ahead, behind = p.behind,
                  files = p.files, clean = #p.files == 0,
                }
              else
                local msg = (o.stderr or ""):match("^[^\n]*")
                entries[#entries + 1] = {
                  name = name, path = r, branch = "?", ahead = 0, behind = 0,
                  files = {}, clean = true,
                  err = (msg and #msg > 0) and msg or "git failed",
                }
              end
            end
            table.sort(entries, function(a, b)
              local aa = (not a.clean) or a.err ~= nil
              local bb = (not b.clean) or b.err ~= nil
              if aa ~= bb then return aa end
              return a.name < b.name
            end)
            in_flight = false
            cb(entries)
          end)
        end
      end
    )
  end
  return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: prints `OK`, exit code 0

- [ ] **Step 5: Commit**

```bash
cd /Users/davidlee/Projects/Sprite
git add phase_0/scm.nvim
git commit -m "feat(scm): async refresh assembling sorted Repo Entries"
```

---

### Task 4: Panel — display derivation + item building (pure part)

**Files:**
- Create: `phase_0/scm.nvim/lua/scm/panel.lua`
- Modify: `phase_0/scm.nvim/tests/core_test.lua` (append before `print("OK")`)

**Interfaces:**
- Consumes: Repo Entry shape from Task 3
- Produces (used by Task 5's picker wiring):
  - `panel.xy_display(xy: string) -> { letter: string, mixed: boolean, hl: string }`
  - `panel.build_items(entries) -> item[]` where each item is
    `{ kind = "header"|"file", entry = <RepoEntry>, fentry = <FileEntry|nil>, file = <abs path|nil>, text = <match text>, ctx = <dimmed "repo/dir" col|nil>, dup = <boolean|nil>, sort = <integer> }`
    (`file` is the absolute path string — the field snacks' jump action reads; `sort` preserves display order under `sort = { fields = { "sort" } }`)

- [ ] **Step 1: Write the failing test**

Append to `tests/core_test.lua` (before `print("OK")`):

```lua
-- panel pure functions (no picker window needed headless)
local panel = require("scm.panel")

-- xy_display: letter = working-tree state, else index state; mixed marker
eq(panel.xy_display(".M"), { letter = "M", mixed = false, hl = "ScmModified" }, "unstaged modified")
eq(panel.xy_display("M."), { letter = "M", mixed = false, hl = "ScmStaged" }, "staged only")
eq(panel.xy_display("MM"), { letter = "M", mixed = true, hl = "ScmModified" }, "mixed state")
eq(panel.xy_display("??"), { letter = "??", mixed = false, hl = "ScmUntracked" }, "untracked")
eq(panel.xy_display("R."), { letter = "R", mixed = false, hl = "ScmStaged" }, "staged rename")
eq(panel.xy_display(".D"), { letter = "D", mixed = false, hl = "ScmDeleted" }, "deleted")
eq(panel.xy_display("UU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "conflict")

-- build_items: headers + files, self-identifying ctx, dup detection, sort order
local entries = {
  { name = "api", path = "/r/api", branch = "main", ahead = 1, behind = 0, clean = false,
    files = { { path = "app/models/device.rb", xy = ".M" }, { path = "top.rb", xy = "??" } } },
  { name = "api", path = "/other/api", branch = "dev", ahead = 0, behind = 0, clean = true, files = {} },
  { name = "web", path = "/r/web", branch = "main", ahead = 0, behind = 0, clean = true, files = {} },
}
local items = panel.build_items(entries)
eq(#items, 5, "3 headers + 2 files")
eq(items[1].kind, "header", "header first")
eq(items[1].dup, true, "name collision flagged")
eq(items[2].kind, "file", "file after its header")
eq(items[2].text, "api/app/models/device.rb", "match text includes repo")
eq(items[2].ctx, "api/app/models", "ctx column repo/dir")
eq(items[2].file, "/r/api/app/models/device.rb", "abs path for snacks jump")
eq(items[3].ctx, "api", "top-level file ctx = repo only")
eq(items[5].dup, nil, "unique name not flagged")
for i, it in ipairs(items) do eq(it.sort, i, "sort field " .. i) end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: FAIL — `module 'scm.panel' not found`

- [ ] **Step 3: Write minimal implementation**

Create `phase_0/scm.nvim/lua/scm/panel.lua`:

```lua
-- scm.panel — the snacks Renderer for Core's Repo Entries (ADR 0001).
-- This file may use snacks; scm.core never does. Pure derivation/item
-- building lives at the top (headlessly testable); picker wiring below.
local M = {}

-- Derive display fields from a raw XY Code (ADR 0002). Letter shows the
-- working-tree state (Y) when set, else the index state (X); the Mixed
-- State (both set) additionally gets the ✱ marker.
function M.xy_display(xy)
  if xy == "??" then
    return { letter = "??", mixed = false, hl = "ScmUntracked" }
  end
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  local letter = (y ~= ".") and y or x
  local mixed = x ~= "." and y ~= "."
  local hl
  if letter == "U" then
    hl = "ScmConflict"
  elseif y == "." then
    hl = "ScmStaged"
  else
    hl = ({ M = "ScmModified", A = "ScmAdded", D = "ScmDeleted", R = "ScmRenamed" })[letter] or "ScmModified"
  end
  return { letter = letter, mixed = mixed, hl = hl }
end

-- Flatten Repo Entries into picker items. Every file row is self-identifying
-- (text and ctx carry the repo name) so filtering may orphan headers freely.
function M.build_items(entries)
  local dup = {}
  for _, e in ipairs(entries) do
    dup[e.name] = (dup[e.name] or 0) + 1
  end
  local items = {}
  local function add(it)
    it.sort = #items + 1
    items[#items + 1] = it
  end
  for _, e in ipairs(entries) do
    add({ kind = "header", entry = e, text = e.name .. " " .. (e.branch or ""), dup = dup[e.name] > 1 or nil })
    for _, f in ipairs(e.files or {}) do
      local dir = f.path:match("^(.*)/[^/]+$")
      add({
        kind = "file",
        entry = e,
        fentry = f,
        file = e.path .. "/" .. f.path,
        text = e.name .. "/" .. f.path,
        ctx = dir and (e.name .. "/" .. dir) or e.name,
      })
    end
  end
  return items
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: prints `OK`, exit code 0

- [ ] **Step 5: Commit**

```bash
cd /Users/davidlee/Projects/Sprite
git add phase_0/scm.nvim
git commit -m "feat(scm): xy display derivation and picker item building"
```

---

### Task 5: Panel — picker wiring (open/toggle, format, keys, refresh plumbing)

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/panel.lua` (append before `return M`)

**Interfaces:**
- Consumes: `core.refresh` (Task 3), `M.xy_display`/`M.build_items` (Task 4), snacks APIs verified against installed source: `Snacks.picker.pick(opts)`, `Snacks.picker.get({source=...})`, `picker:find()`, `picker:current()`, `picker.list:view(idx)`, `picker.list.win:set_title(t)`, `require("snacks.picker.actions").jump(picker, item, action)`
- Produces: `panel.setup(opts)`, `panel.toggle()`, `panel.open()`, `panel.refresh_view(picker?)`, `panel.lazygit(repo_path)` (Task 6 binds `toggle` to `<leader>gs`; `lazygit` gains the TermClose hook in Task 6)

No headless test — this is window plumbing; Task 6 carries the manual checklist. Keep every function under ~40 lines.

- [ ] **Step 1: Append state, highlights, and helpers**

Append to `lua/scm/panel.lua` before `return M`:

```lua
local core = require("scm.core")

M.state = { entries = {}, opts = nil }

function M.setup(opts)
  M.state.opts = vim.tbl_deep_extend("force", core.defaults, opts or {})
  local hls = {
    ScmModified = "GitSignsChange",
    ScmAdded = "GitSignsAdd",
    ScmDeleted = "GitSignsDelete",
    ScmRenamed = "DiagnosticWarn",
    ScmUntracked = "GitSignsAdd",
    ScmStaged = "GitSignsAdd",
    ScmConflict = "DiagnosticError",
    ScmMarker = "GitSignsAdd",
  }
  for name, link in pairs(hls) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
  end
end

local function set_title(picker, title)
  pcall(function()
    picker.list.win:set_title(title)
  end)
end

-- Anchor key for cursor stability across refreshes (PRD §4.4).
local function item_key(item)
  if not item then return nil end
  if item.kind == "file" then
    return item.entry.path .. "//" .. item.fentry.path
  end
  return item.entry.path
end
```

- [ ] **Step 2: Append the row formatter**

```lua
-- One row per item, VSCode SCM anatomy (PRD §4.4).
function M.format_item(item)
  if item.kind == "header" then
    local e = item.entry
    if e.err then
      return {
        { "⚠ ", "DiagnosticWarn" },
        { ("%-24s "):format(e.name), "Comment" },
        { e.err, "Comment" },
      }
    end
    local parts = {}
    if e.clean then
      parts[#parts + 1] = { "▶ ", "Comment" }
      parts[#parts + 1] = { ("%-24s "):format(e.name), "Comment" }
      parts[#parts + 1] = { e.branch .. "  ", "Comment" }
      parts[#parts + 1] = { "─", "Comment" }
    else
      parts[#parts + 1] = { "▼ ", "Directory" }
      parts[#parts + 1] = { ("%-24s "):format(e.name), "Title" }
      parts[#parts + 1] = { e.branch .. " ", "Function" }
      if e.ahead > 0 then parts[#parts + 1] = { "↑" .. e.ahead, "DiagnosticInfo" } end
      if e.behind > 0 then parts[#parts + 1] = { "↓" .. e.behind, "DiagnosticWarn" } end
      parts[#parts + 1] = { ("  %d"):format(#e.files), "Number" }
    end
    if item.dup then
      parts[#parts + 1] = { "  " .. vim.fn.fnamemodify(e.path, ":h:t"), "Comment" }
    end
    return parts
  end
  -- file row: indent, letter+marker, filename, dimmed repo/dir ctx
  local d = M.xy_display(item.fentry.xy)
  local fname = item.fentry.path:match("[^/]+$") or item.fentry.path
  return {
    { "    " },
    { d.letter, d.hl },
    { d.mixed and "✱" or " ", "ScmMarker" },
    { (" %-28s "):format(fname), "Normal" },
    { item.ctx, "Comment" },
  }
end
```

- [ ] **Step 3: Append actions, open, toggle, refresh plumbing**

```lua
local sactions = function() return require("snacks.picker.actions") end

function M.lazygit(repo) -- Task 6 adds the TermClose refresh hook here
  Snacks.lazygit({ cwd = repo })
end

local function key_actions()
  return {
    scm_confirm = function(picker, item)
      if not item then return end
      if item.kind == "file" then
        sactions().jump(picker, item, { cmd = "edit" })
      else
        M.lazygit(item.entry.path)
      end
    end,
    scm_diff = function(picker, item)
      if not item or item.kind ~= "file" then return end
      sactions().jump(picker, item, { cmd = "edit" })
      if item.fentry.xy == "??" then
        vim.notify("untracked — no diff", vim.log.levels.INFO)
      else
        vim.schedule(function() vim.cmd("Gitsigns diffthis") end)
      end
    end,
    scm_lazygit = function(_, item)
      if item then M.lazygit(item.entry.path) end
    end,
    scm_refresh = function(picker) M.refresh_view(picker) end,
  }
end

function M.open()
  M.setup(M.state.opts) -- idempotent; ensures defaults when spec passed no opts
  local picker = Snacks.picker.pick({
    source = "scm",
    title = "Source Control",
    finder = function() return M.build_items(M.state.entries) end,
    format = M.format_item,
    layout = { preset = "sidebar", preview = false },
    focus = "list",
    jump = { close = false },  -- panel persists across file opens (PRD §4.4)
    auto_close = false,
    matcher = { sort_empty = false, fuzzy = true },
    sort = { fields = { "sort" } }, -- preserve build_items order when unfiltered
    confirm = "scm_confirm",
    actions = key_actions(),
    win = {
      list = { keys = { ["d"] = "scm_diff", ["g"] = "scm_lazygit", ["r"] = "scm_refresh" } },
      input = { keys = { ["<c-r>"] = { "scm_refresh", mode = { "i", "n" } } } },
    },
  })
  M.refresh_view(picker)
  return picker
end

function M.toggle()
  local open = Snacks.picker.get({ source = "scm" })[1]
  if open then
    open:close()
    return
  end
  for _, p in ipairs(Snacks.picker.get({ source = "explorer" })) do
    p:close() -- one left-rail activity at a time (PRD §4.4)
  end
  M.open()
end

function M.refresh_view(picker)
  picker = picker or Snacks.picker.get({ source = "scm" })[1]
  if not picker then return end
  local anchor = item_key(picker:current())
  set_title(picker, "Source Control (scanning…)")
  local accepted = core.refresh(M.state.opts, function(entries)
    M.state.entries = entries
    local p = Snacks.picker.get({ source = "scm" })[1]
    if not p then return end -- panel closed mid-refresh
    p:find()
    -- PRD §5: zero repos -> informational state instead of a blank window
    set_title(p, #entries == 0 and "Source Control (no repositories under configured roots)" or "Source Control")
    if anchor then -- best-effort cursor re-anchor (PRD §4.4)
      vim.schedule(function()
        for idx, it in ipairs(p:items()) do
          if item_key(it) == anchor then
            pcall(function() p.list:view(idx) end)
            return
          end
        end
      end)
    end
  end)
  if not accepted then
    set_title(picker, "Source Control") -- refresh already in flight
  end
end
```

- [ ] **Step 4: Sanity-run the test suite (pure parts unbroken)**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: prints `OK` (wiring code must not break headless loading — `Snacks` is only referenced inside functions, never at module load)

- [ ] **Step 5: Commit**

```bash
cd /Users/davidlee/Projects/Sprite
git add phase_0/scm.nvim
git commit -m "feat(scm): snacks picker wiring — sidebar panel, keys, refresh plumbing"
```

---

### Task 6: Plugin spec, post-lazygit refresh, end-to-end verification

**Files:**
- Modify: `phase_0/scm.nvim/lua/scm/panel.lua` (replace `M.lazygit`)
- Create: `/Users/davidlee/.config/nvim/lua/plugins/scm.lua` (NOT committed — config is not a repo)

**Interfaces:**
- Consumes: `panel.toggle`, `panel.refresh_view`, `panel.setup` (Task 5)
- Produces: `<leader>gs` end-user keybinding; Panel-Launched lazygit → refresh behavior

- [ ] **Step 1: Replace `M.lazygit` with the TermClose-hooked version**

In `lua/scm/panel.lua`, replace the Task-5 `M.lazygit` function with:

```lua
-- Panel-Launched lazygit (CONTEXT.md): its close triggers one refresh so the
-- panel reflects whatever was staged/committed. Lazygits opened outside the
-- panel are untouched (PRD §4.4).
function M.lazygit(repo)
  local lg = Snacks.lazygit({ cwd = repo })
  if lg and lg.on then
    lg:on("TermClose", function()
      vim.schedule(function() M.refresh_view() end)
    end, { buf = true })
  end
end
```

- [ ] **Step 2: Create the config spec**

Create `/Users/davidlee/.config/nvim/lua/plugins/scm.lua`:

```lua
-- Sprite Phase 0.1: multi-repo source control panel (scm.nvim, local plugin).
-- <leader>gs deliberately overrides LazyVim's single-repo git_status picker
-- (still reachable via :lua Snacks.picker.git_status()).
-- Code + docs: ~/Projects/Sprite/phase_0/scm.nvim
return {
  {
    dir = vim.fn.expand("~/Projects/Sprite/phase_0/scm.nvim"),
    name = "scm.nvim",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      {
        "<leader>gs",
        function() require("scm.panel").toggle() end,
        desc = "Source Control (all repos)",
      },
    },
    opts = {}, -- roots/depth defaults live in scm.core.defaults
    config = function(_, opts) require("scm.panel").setup(opts) end,
  },
}
```

- [ ] **Step 3: Run the full headless suite one final time**

Run: `cd /Users/davidlee/Projects/Sprite/phase_0/scm.nvim && nvim -l tests/core_test.lua`
Expected: prints `OK`, exit code 0

- [ ] **Step 4: Manual verification checklist (PRD §6/§7 — run in a real Neovim)**

Restart Neovim, then verify each:

1. `<leader>gs` opens the left sidebar; dirty repos first with branch/↑↓/count, clean repos dimmed below; total scan feels < ~1s
2. `<leader>gs` again closes it; open the explorer (`<leader>e`), then `<leader>gs` — explorer closes, SCM opens
3. `<CR>` on a file row opens the file; **panel stays open**
4. `d` on a modified file opens it in a gitsigns diff; `d` on a `??` file opens it + "untracked — no diff" notification
5. `<CR>` on a repo header opens lazygit in that repo; stage or commit something; quit lazygit → panel refreshes itself (counts change, committed repo may sink to clean section)
6. `r` refreshes; cursor stays on (or near) the row it was on
7. Type in the input: fuzzy filtering across all changed files; file rows remain identifiable by their dimmed `repo/dir` column
8. A file staged AND re-edited (`git add f` then edit f) shows `M✱`
9. Create a name-collision repo temporarily (e.g. `mkdir -p ~/Code/krypton-api && git -C ~/Code/krypton-api init`) → both headers show dimmed parent dirs; remove it after
10. Break a repo temporarily (`mv x/.git/HEAD x/.git/HEAD.bak`) → ⚠ row, others fine; restore

Record any failures; fix before proceeding (return to the relevant task's code).

- [ ] **Step 5: Final commit**

```bash
cd /Users/davidlee/Projects/Sprite
git add phase_0/scm.nvim
git commit -m "feat(scm): panel-launched lazygit refresh hook; v1 complete"
```

---

## Post-plan notes for the executor

- If `picker.list.win:set_title` silently does nothing under the sidebar
  layout, drop the scanning-title feature (it's pcall-guarded) — do NOT
  restructure windows for it.
- If `Snacks.lazygit(...)` returns nil or lacks `:on` in the installed
  version, fall back to a buffer-local autocmd:
  `vim.api.nvim_create_autocmd("TermClose", { buffer = lg.buf, once = true, callback = ... })`.
- `vim.fn.*` is forbidden inside `vim.system` callbacks (fast context) — the
  Task 3 implementation already routes all processing through `vim.schedule`;
  keep it that way when modifying.
