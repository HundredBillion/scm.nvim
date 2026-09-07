# Committed File Entries Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep branch-committed files visible in the SCM Panel alongside pending Git changes.

**Architecture:** `scm.core` remains the single Git-aware deep module. Its existing refresh interfaces resolve a Comparison Base, collect `git diff --name-status` entries, merge them with porcelain-v2 pending entries by path, and emit one Repo Entry; `scm.panel` only derives presentation from the tagged File Entry contract.

**Tech Stack:** Lua, Neovim `vim.system`, Git porcelain v2, Git name-status diff

## Global Constraints

- Show committed files from the default-branch merge base through `HEAD`.
- Keep pending raw XY Codes unchanged and give pending state precedence by path.
- Degrade to pending-only results when no Comparison Base can be resolved.
- Do not add dependencies, commit history rows, arbitrary ref selection, or Git write operations.

---

### Task 1: Core emits committed File Entries

**Files:**
- Modify: `tests/core_test.lua`
- Modify: `lua/scm/core.lua`

**Interfaces:**
- Consumes: `refs/remotes/origin/HEAD`, fallback local `main`/`master`, porcelain-v2 status, and `git diff --name-status -z`
- Produces: unchanged `core.refresh_repo(repo, opts, cb)` and `core.refresh(root, opts, cb)` interfaces emitting `{ path, xy }` pending entries or `{ path, commit_status }` committed-only entries

- [x] **Step 1: Write the failing branch-divergence integration test**

Create a temporary `main` branch with `base.txt`, create `feature`, commit `committed.txt`, and call `core.refresh_repo()` with a clean worktree:

```lua
local croot = vim.fn.tempname()
vim.fn.mkdir(croot, 'p')
sh({ 'git', '-C', croot, 'init', '-q', '-b', 'main' })
vim.fn.writefile({ 'base' }, croot .. '/base.txt')
sh({ 'git', '-C', croot, 'add', '.' })
sh({ 'git', '-C', croot, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'base' })
sh({ 'git', '-C', croot, 'switch', '-qc', 'feature' })
vim.fn.writefile({ 'committed' }, croot .. '/committed.txt')
sh({ 'git', '-C', croot, 'add', '.' })
sh({ 'git', '-C', croot, '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', 'feature' })

local committed_entry
assert(core.refresh_repo(croot, ropts, function(entry) committed_entry = entry end))
assert(vim.wait(5000, function() return committed_entry ~= nil end, 10))
eq(committed_entry.files, { { path = 'committed.txt', commit_status = 'A' } }, 'clean feature branch keeps committed file')
```

Run: `cd the repository root && nvim -l tests/core_test.lua`

Expected: FAIL because `committed_entry.files` is empty.

- [x] **Step 2: Implement default-branch resolution and committed diff collection**

Add private Core helpers with these exact responsibilities:

```lua
local function git(repo, opts, args, cb)
  local cmd = { 'git', '-C', repo }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, timeout = opts.timeout_ms }, function(out)
    vim.schedule(function() cb(out) end)
  end)
end

local function parse_name_status(stdout)
  -- Split NUL records. Ordinary statuses consume status+path; R/C statuses
  -- consume status+old+new and retain the new path.
end

local function resolve_comparison_base(repo, branch, opts, cb)
  -- Try origin/HEAD, local main, then local master. For a feature branch,
  -- return merge-base(default, HEAD). On the default branch, return the
  -- remote default ref when available. Return nil on every metadata failure.
end

local function collect_committed(repo, branch, opts, cb)
  resolve_comparison_base(repo, branch, opts, function(base)
    if not base then return cb({}) end
    git(repo, opts, { 'diff', '--name-status', '-z', base .. '..HEAD' }, function(out)
      cb(out.code == 0 and parse_name_status(out.stdout or '') or {})
    end)
  end)
end
```

Replace direct status calls in both refresh paths with one private `scan_repo(repo, opts, cb)` that runs status first, skips committed collection when status fails, otherwise merges committed entries with pending entries and calls back exactly once.

- [x] **Step 3: Run the Core test**

Run: `cd the repository root && nvim -l tests/core_test.lua`

Expected: PASS including `clean feature branch keeps committed file`.

- [x] **Step 4: Add pending-precedence and no-base tests**

After the clean committed assertion, modify `committed.txt` and create `untracked.txt`, refresh again, and assert:

```lua
eq(second.files, {
  { path = 'committed.txt', xy = '.M' },
  { path = 'untracked.txt', xy = '??' },
}, 'pending state overrides committed state by path')
```

Create an orphan repository with no `origin/HEAD`, `main`, or `master`, stage `only.txt`, and assert it remains `{ path = 'only.txt', xy = 'A.' }` without an error.

Run the Core test and expect PASS.

- [x] **Step 5: Commit Core behavior**

```bash
git add lua/scm/core.lua tests/core_test.lua
git commit -m "feat(scm): include committed branch files"
```

### Task 2: Panel distinguishes committed-only rows

**Files:**
- Modify: `tests/core_test.lua`
- Modify: `lua/scm/panel.lua`

**Interfaces:**
- Consumes: `{ path, commit_status }` File Entries from Core
- Produces: `panel.file_display(entry) -> { letter, marker, hl }`; pending rendering remains derived from `xy`

- [x] **Step 1: Write the failing presentation test**

```lua
eq(panel.file_display({ path = 'committed.lua', commit_status = 'M' }), {
  letter = 'M', marker = '✓', hl = 'ScmCommitted'
}, 'committed-only display')
eq(panel.file_display({ path = 'pending.lua', xy = 'M.' }), {
  letter = 'M', marker = ' ', hl = 'ScmStaged'
}, 'pending display unchanged')
```

Run the Core test and expect FAIL because `file_display` does not exist.

- [x] **Step 2: Implement tagged presentation**

Add `ScmCommitted = 'GitSignsChange'` to default highlights and implement:

```lua
function M.file_display(entry)
  if entry.xy then
    local display = M.xy_display(entry.xy)
    return { letter = display.letter, marker = display.mixed and '✱' or ' ', hl = display.hl }
  end
  return { letter = entry.commit_status:sub(1, 1), marker = '✓', hl = 'ScmCommitted' }
end
```

Change `format_item()` to consume `file_display(item.fentry)` instead of calling `xy_display()` directly.

- [x] **Step 3: Run tests and commit**

```bash
cd the repository root
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
nvim -l tests/handoff_test.lua
git add lua/scm/panel.lua tests/core_test.lua
git commit -m "feat(scm): render committed file entries"
```

Expected: all three scripts exit zero.

### Task 3: Verify the real repository and complete documentation

**Files:**
- Modify: `docs/TSPs/08-08-2026-committed-file-entries.md`

**Interfaces:**
- Consumes: public `core.refresh_repo()` from Tasks 1–2
- Produces: deterministic proof that Sprite's clean feature branch emits committed files

- [x] **Step 1: Run the real-repository feedback loop**

```bash
cd /home/hundredbillion/Projects/Sprite
nvim --headless "+lua require('lazy').load({plugins={'scm.nvim'}}); require('scm').toggle(); assert(vim.wait(5000, function() local s=require('scm.panel').tab_state(); return not s.refreshing and #s.entries > 0 end, 20)); local e=require('scm.panel').tab_state().entries[1]; assert(#e.files > 0, 'expected committed branch files'); print(#e.files .. ' Sprite files visible'); vim.cmd('qa!')"
```

Expected: exit zero with a positive file count.

- [x] **Step 2: Run all regression suites**

```bash
cd the repository root
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
nvim -l tests/handoff_test.lua
```

Expected: all scripts exit zero.

### Task 5: Suppress squash-merged branch content

**Files:**
- Modify: `tests/core_test.lua`
- Modify: `lua/scm/core.lua`

**Interfaces:**
- Consumes: the resolved default-branch ref and Comparison Base
- Produces: the unchanged Repo Entry interface, with no Committed File Entries when the default branch and `HEAD` have identical trees

- [x] **Step 1: Write the failing squash-merge regression test**

Create `main`, commit a base, create `feature`, commit a file, squash-merge `feature` into `main`, then switch back to the original `feature` commit. Assert that `core.refresh_repo()` returns no File Entries even though `git merge-base main HEAD` predates the feature commit.

Run: `cd the repository root && nvim -l tests/core_test.lua`

Expected: FAIL because Core currently reports files from the merge base through `HEAD` without checking whether `main` already has the same tree.

- [x] **Step 2: Add the identical-tree guard**

Return both the successful default ref and its merge base from comparison-base resolution. Before collecting committed files, run `git diff --quiet default_ref HEAD`. Return no committed files when the command exits zero; otherwise retain the existing `merge_base..HEAD` collection.

- [x] **Step 3: Verify all behavior**

```bash
cd the repository root
nvim -l tests/handoff_test.lua
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
```

Expected: all scripts exit zero, including the new squash-merge fixture and existing divergent-branch fixtures.

- [x] **Step 3: Record completion and commit**

Change every task checkbox in this TSP from `[ ]` to `[x]`, then run:

```bash
git add docs/TSPs/08-08-2026-committed-file-entries.md
git commit -m "docs: record committed file entry delivery"
```

### Task 4: Correct committed diffs and simplify the implementation

**Files:**
- Modify: `tests/core_test.lua`
- Modify: `tests/explorer_scope_test.lua`
- Modify: `lua/scm/core.lua`
- Modify: `lua/scm/panel.lua`
- Modify: `lua/scm/refresh.lua`

**Interfaces:**
- Consumes: Git comparison-base candidates and the existing `scm_diff` picker action
- Produces: Repo Entries with optional `comparison_base`; committed rows call `gitsigns.diffthis(comparison_base)` and pending rows call `gitsigns.diffthis()`

- [x] **Step 1: Write and run the committed-diff regression test**

Capture the real picker actions as the existing headless test does, provide one pending row and one committed row, stub `gitsigns.diffthis`, and assert that only the committed call receives the Repo Entry's Comparison Base.

Run: `cd the repository root && nvim -l tests/core_test.lua`

Expected: FAIL because both rows currently execute the same bare Ex command.

- [x] **Step 2: Carry the Comparison Base and use it in the Panel**

Make `build_entry(repo, out, committed, comparison_base)` publish `comparison_base` on the Repo Entry. Replace the scheduled Ex command with:

```lua
local base = item.fentry.commit_status and item.entry.comparison_base or nil
vim.schedule(function()
  require("gitsigns").diffthis(base)
end)
```

Run the Core test and expect PASS.

- [x] **Step 3: Simplify Comparison Base resolution**

Replace `first_existing_ref()`, `resolve_default_ref()`, and branch-name special cases with one function that tries these candidates in order:

```lua
local comparison_refs = {
  "refs/remotes/origin/HEAD",
  "refs/heads/main",
  "refs/heads/master",
}
```

For each candidate, run `git merge-base candidate HEAD`; return the first non-empty successful result or `nil`. Add a regression fixture where `origin/HEAD` is broken but local `main` remains usable.

- [x] **Step 4: Apply behavior-preserving concision refactors**

Restore one-line form for trivial guards in `panel.lua`. In `refresh.lua`, replace the module-level tab-handle table and invalid-handle cleanup with `vim.t.scm_last_full`, retaining per-tab debounce behavior.

Run: `cd the repository root && nvim -l tests/explorer_scope_test.lua`

Expected: PASS, including the existing per-tab debounce assertion.

- [x] **Step 5: Run all verification suites**

```bash
cd the repository root
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
nvim -l tests/handoff_test.lua
```

Expected: all scripts exit zero.
