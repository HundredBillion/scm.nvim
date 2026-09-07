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

local function sh(cmd)
  local r = vim.system(cmd, { text = true }):wait()
  assert(r.code == 0, "setup cmd failed: " .. table.concat(cmd, " ") .. "\n" .. (r.stderr or ""))
end

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
local parent_real = assert(vim.uv.fs_realpath(parent), "canonical parent repository")
local deep_real = assert(vim.uv.fs_realpath(deep), "canonical nested worktree")

local discovered, discover_err
assert(core.discover(root, { timeout_ms = 5000 }, function(repos, err)
  discovered, discover_err = repos, err
end))
vim.wait(5000, function()
  return discovered ~= nil or discover_err ~= nil
end, 10)
eq(discover_err, nil, "discovery succeeds")
eq(discovered, { parent_real, deep_real }, "containing and arbitrary-depth repositories are canonicalized")

local root_discovered
core.discover(parent, { timeout_ms = 5000 }, function(repos, err)
  assert(not err, err)
  root_discovered = repos
end)
vim.wait(5000, function()
  return root_discovered ~= nil
end, 10)
eq(root_discovered, { parent_real, deep_real }, "Root repository is deduplicated and nested symlinks are not traversed")

local parent_link = tmp .. "/parent-link"
assert(vim.uv.fs_symlink(parent, parent_link, { dir = true }), "create symlinked Explorer Root")
local linked_discovered
core.discover(parent_link, { timeout_ms = 5000 }, function(repos, err)
  assert(not err, err)
  linked_discovered = repos
end)
vim.wait(5000, function()
  return linked_discovered ~= nil
end, 10)
eq(linked_discovered, { parent_real, deep_real }, "symlinked Explorer Root is canonicalized once before discovery")

local missing_err
core.discover(root .. "/missing", { timeout_ms = 5000 }, function(_, err)
  missing_err = err
end)
vim.wait(5000, function()
  return missing_err ~= nil
end, 10)
assert(type(missing_err) == "string" and missing_err ~= "", "discovery failures are reported")

local worktree_base = vim.fn.tempname()
local primary_repo = worktree_base .. "/primary"
local linked_worktree = worktree_base .. "/linked"
vim.fn.mkdir(primary_repo .. "/inside", "p")
sh({ "git", "-C", primary_repo, "init", "-q", "-b", "main" })
vim.fn.writefile({ "inside" }, primary_repo .. "/inside/tracked.txt")
vim.fn.writefile({ "outside" }, primary_repo .. "/outside.txt")
sh({ "git", "-C", primary_repo, "add", "." })
sh({ "git", "-C", primary_repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init" })
sh({ "git", "-C", primary_repo, "worktree", "add", "-q", "-b", "linked", linked_worktree })
eq(vim.fn.filereadable(linked_worktree .. "/.git"), 1, "linked worktree uses a valid .git file")

local worktree_discovered
core.discover(worktree_base, { timeout_ms = 5000 }, function(repos, err)
  assert(not err, err)
  worktree_discovered = repos
end)
vim.wait(5000, function()
  return worktree_discovered ~= nil
end, 10)
local expected_worktrees = {
  (assert(vim.uv.fs_realpath(primary_repo), "canonical primary repo")),
  (assert(vim.uv.fs_realpath(linked_worktree), "canonical linked worktree")),
}
table.sort(expected_worktrees)
eq(worktree_discovered, expected_worktrees, "discovery includes repository directories and worktree .git files")

vim.fn.writefile({ "changed outside Explorer Root" }, linked_worktree .. "/outside.txt")
local worktree_status
core.refresh(linked_worktree .. "/inside", { timeout_ms = 5000 }, function(entries, err)
  assert(not err, err)
  worktree_status = entries
end)
vim.wait(5000, function()
  return worktree_status ~= nil
end, 10)
eq(#worktree_status, 1, "subdirectory Explorer Root refreshes its containing worktree")
eq(worktree_status[1].path, expected_worktrees[1], "worktree Repo Entry uses canonical root")
eq(
  worktree_status[1].files,
  { { path = "outside.txt", xy = ".M" } },
  "status includes repository-wide changes outside the Explorer Root subdirectory"
)

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
vim.wait(5000, function()
  return concurrent == 2
end, 10)
eq(concurrent, 2, "Core full refreshes carry request-local state")

-- refresh(): end-to-end against two real synthetic repos
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
vim.fn.writefile({ "changed" }, dirty .. "/a.txt") -- .M
vim.fn.writefile({ "new" }, dirty .. "/untracked.txt") -- ??

local got
assert(core.refresh(work, { timeout_ms = 5000 }, function(entries)
  got = entries
end) == true, "refresh accepted")
vim.wait(5000, function()
  return got ~= nil
end, 10)
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
assert(core.refresh(work, { timeout_ms = 5000 }, function(entries)
  got = entries
end))
vim.wait(5000, function()
  return got ~= nil
end, 10)
assert(got and #got == 2, "second refresh works")

-- refresh(): per-repo error path must not short-circuit other repos.
-- A directory whose `.git` is a bare, uninitialized dir looks like a repo to
-- discovery (find sees the `.git` entry) but `git status` inside it fails.
local err_work = vim.fn.tempname()
local bad_repo, ok_repo = err_work .. "/bad_repo", err_work .. "/ok_repo"
vim.fn.mkdir(bad_repo .. "/.git", "p") -- NOT `git init` -- invalid repo
vim.fn.mkdir(ok_repo, "p")
sh({ "git", "-C", ok_repo, "init", "-q", "-b", "main" })
vim.fn.writefile({ "hello" }, ok_repo .. "/a.txt")
sh({ "git", "-C", ok_repo, "add", "." })
sh({ "git", "-C", ok_repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init" })

local err_got
assert(core.refresh(err_work, { timeout_ms = 5000 }, function(entries)
  err_got = entries
end) == true, "refresh (error path) accepted")
vim.wait(5000, function()
  return err_got ~= nil
end, 10)
assert(err_got, "refresh (error path) callback fired")

eq(#err_got, 2, "both repos still reported despite one failing")
local by_name = {}
for _, e in ipairs(err_got) do
  by_name[e.name] = e
end
assert(by_name.bad_repo, "bad_repo present")
assert(by_name.ok_repo, "ok_repo present")
assert(type(by_name.bad_repo.err) == "string" and #by_name.bad_repo.err > 0, "bad_repo has non-nil err string")
assert(by_name.ok_repo.err == nil, "ok_repo unaffected by sibling's failure")
eq(by_name.ok_repo.clean, true, "ok_repo still parsed correctly")

-- refresh(): zero-repos path -- Explorer Root contains no .git -> cb({})
local empty_dir = vim.fn.tempname()
vim.fn.mkdir(empty_dir, "p")

local empty_got
assert(core.refresh(empty_dir, { timeout_ms = 5000 }, function(entries)
  empty_got = entries
end) == true, "refresh (zero-repos) accepted")
vim.wait(5000, function()
  return empty_got ~= nil
end, 10)
eq(empty_got, {}, "zero repos -> cb({})")

-- refresh(): intra-group alphabetical tie-breaking -- two repos in the SAME
-- status group (both dirty here) must come back sorted by name, not discovery
-- order or reversed.
local sort_work = vim.fn.tempname()
local repo_zzz, repo_aaa = sort_work .. "/zzz_repo", sort_work .. "/aaa_repo"
-- create in reverse-alphabetical order to make sure any ordering leak from
-- creation/discovery order would show up as a failure
for _, r in ipairs({ repo_zzz, repo_aaa }) do
  vim.fn.mkdir(r, "p")
  sh({ "git", "-C", r, "init", "-q", "-b", "main" })
  vim.fn.writefile({ "hello" }, r .. "/a.txt")
  sh({ "git", "-C", r, "add", "." })
  sh({ "git", "-C", r, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init" })
  vim.fn.writefile({ "changed" }, r .. "/a.txt") -- both dirty (.M)
end

local sort_got
assert(core.refresh(sort_work, { timeout_ms = 5000 }, function(entries)
  sort_got = entries
end) == true, "refresh (sort) accepted")
vim.wait(5000, function()
  return sort_got ~= nil
end, 10)
assert(sort_got, "refresh (sort) callback fired")

eq(#sort_got, 2, "two dirty repos")
eq(sort_got[1].clean, false, "first is dirty")
eq(sort_got[2].clean, false, "second is dirty")
eq(sort_got[1].name, "aaa_repo", "alphabetically-first name sorts first within group")
eq(sort_got[2].name, "zzz_repo", "alphabetically-last name sorts second within group")

-- M.compare_entries(): direct unit test of the sort comparator, independent
-- of discovery's already-alphabetical repo order. Input is hand-built and
-- presented NOT-already-alphabetical within each group (reverse-alphabetical
-- for the needs-attention group, and out-of-order for the clean group), so a
-- regression that drops the name tiebreak (leaving only group-priority) would
-- actually have to move elements to pass -- table.sort would leave a
-- mis-ordered array untouched and this test would fail.
local synthetic = {
  { name = "zzz", clean = false },
  { name = "bravo", clean = true },
  { name = "mmm", clean = false },
  { name = "alpha", clean = true },
  { name = "aaa", clean = true },
  { name = "middle", clean = true, err = "boom" }, -- clean=true but errored -> needs-attention group
}
table.sort(synthetic, core.compare_entries)

local names = {}
for i, e in ipairs(synthetic) do
  names[i] = e.name
end
eq(
  names,
  { "middle", "mmm", "zzz", "aaa", "alpha", "bravo" },
  "compare_entries: needs-attention (dirty or errored) first, alphabetical within each group"
)

-- panel pure functions (no picker window needed headless)
local panel = require("scm.panel")
local scope = require("scm.scope")

local function panel_state()
  return panel.tab_state(vim.api.nvim_get_current_tabpage())
end

-- xy_display: letter = working-tree state, else index state; mixed marker
eq(panel.xy_display(".M"), { letter = "M", mixed = false, hl = "ScmModified" }, "unstaged modified")
eq(panel.xy_display("M."), { letter = "M", mixed = false, hl = "ScmStaged" }, "staged only")
eq(panel.xy_display("MM"), { letter = "M", mixed = true, hl = "ScmModified" }, "mixed state")
eq(panel.xy_display("??"), { letter = "??", mixed = false, hl = "ScmUntracked" }, "untracked")
eq(panel.xy_display("R."), { letter = "R", mixed = false, hl = "ScmStaged" }, "staged rename")
eq(panel.xy_display(".D"), { letter = "D", mixed = false, hl = "ScmDeleted" }, "deleted")
eq(panel.xy_display("UU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "conflict")
eq(panel.xy_display("DD"), { letter = "D", mixed = true, hl = "ScmConflict" }, "unmerged: both deleted")
eq(panel.xy_display("AU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "unmerged: added by us")
eq(panel.xy_display("UD"), { letter = "D", mixed = true, hl = "ScmConflict" }, "unmerged: deleted by them")
eq(panel.xy_display("UA"), { letter = "A", mixed = true, hl = "ScmConflict" }, "unmerged: added by them")
eq(panel.xy_display("DU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "unmerged: deleted by us")
eq(panel.xy_display("AA"), { letter = "A", mixed = true, hl = "ScmConflict" }, "unmerged: both added")
eq(panel.file_display({ path = "committed.lua", commit_status = "M" }), {
  letter = "M",
  marker = "✓",
  hl = "ScmCommitted",
}, "committed-only display")
eq(panel.file_display({ path = "pending.lua", xy = "M." }), {
  letter = "M",
  marker = " ",
  hl = "ScmStaged",
}, "pending display unchanged")

-- build_items: headers + files, self-identifying ctx, dup detection, sort order
local entries = {
  {
    name = "api",
    path = "/r/api",
    branch = "main",
    ahead = 1,
    behind = 0,
    clean = false,
    files = { { path = "app/models/device.rb", xy = ".M" }, { path = "top.rb", xy = "??" } },
  },
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
for i, it in ipairs(items) do
  eq(it.sort, i, "sort field " .. i)
end

-- refresh_repo(): scoped single-repo refresh with debounce + coalescing
local rwork = vim.fn.tempname()
local rrepo = rwork .. "/scoped_repo"
vim.fn.mkdir(rrepo, "p")
sh({ "git", "-C", rrepo, "init", "-q", "-b", "main" })
vim.fn.writefile({ "hello" }, rrepo .. "/a.txt")
sh({ "git", "-C", rrepo, "add", "." })
sh({ "git", "-C", rrepo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "init" })
vim.fn.writefile({ "changed" }, rrepo .. "/a.txt")

local ropts = { roots = {}, depth = 2, timeout_ms = 5000, repo_debounce_ms = 0 }
local calls = {}
local function collect(e)
  calls[#calls + 1] = e
end
assert(core.refresh_repo(rrepo, ropts, collect) == true, "scoped refresh accepted")
-- requests landing while the scan is in flight coalesce into ONE re-run
assert(core.refresh_repo(rrepo, ropts, collect) == false, "mid-flight request coalesced")
assert(core.refresh_repo(rrepo, ropts, collect) == false, "second mid-flight request also coalesced")
vim.wait(5000, function()
  return #calls >= 2
end, 10)
vim.wait(300, function()
  return #calls > 2
end, 10) -- settle: a 3rd call would be a bug
eq(#calls, 2, "exactly one coalesced re-run (no stacking)")
eq(calls[1].name, "scoped_repo", "scoped entry name")
eq(calls[1].clean, false, "scoped dirty flag")
eq(calls[1].files, { { path = "a.txt", xy = ".M" } }, "scoped File Entries")

-- debounce: an immediate follow-up inside a large window is dropped
local dropped = 0
assert(core.refresh_repo(rrepo, { roots = {}, depth = 2, timeout_ms = 5000, repo_debounce_ms = 60000 }, function()
  dropped = dropped + 1
end) == false, "debounced drop inside window")
eq(dropped, 0, "debounced call never runs")

-- A clean feature branch still exposes files committed since it diverged from
-- the repository's default branch.
local croot = vim.fn.tempname()
vim.fn.mkdir(croot, "p")
sh({ "git", "-C", croot, "init", "-q", "-b", "main" })
vim.fn.writefile({ "base" }, croot .. "/base.txt")
sh({ "git", "-C", croot, "add", "." })
sh({ "git", "-C", croot, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base" })
sh({ "git", "-C", croot, "switch", "-q", "-c", "feature" })
vim.fn.writefile({ "committed" }, croot .. "/committed.txt")
sh({ "git", "-C", croot, "add", "." })
sh({ "git", "-C", croot, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "feature" })

local committed_entry
assert(core.refresh_repo(croot, ropts, function(entry)
  committed_entry = entry
end), "committed feature refresh accepted")
assert(vim.wait(5000, function()
  return committed_entry ~= nil
end, 10), "committed feature refresh completed")
eq(
  committed_entry.files,
  { { path = "committed.txt", commit_status = "A" } },
  "clean feature branch keeps committed file"
)

vim.fn.writefile({ "pending" }, croot .. "/committed.txt")
vim.fn.writefile({ "untracked" }, croot .. "/untracked.txt")
local pending_entry
assert(core.refresh_repo(croot, ropts, function(entry)
  pending_entry = entry
end), "pending precedence refresh accepted")
assert(vim.wait(5000, function()
  return pending_entry ~= nil
end, 10), "pending precedence refresh completed")
eq(pending_entry.files, {
  { path = "committed.txt", xy = ".M" },
  { path = "untracked.txt", xy = "??" },
}, "pending state overrides committed state by path")

local fallback_root = vim.fn.tempname()
vim.fn.mkdir(fallback_root, "p")
sh({ "git", "-C", fallback_root, "init", "-q", "-b", "main" })
vim.fn.writefile({ "base" }, fallback_root .. "/base.txt")
sh({ "git", "-C", fallback_root, "add", "." })
sh({ "git", "-C", fallback_root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base" })
local fallback_base = vim.trim(vim.system({ "git", "-C", fallback_root, "rev-parse", "HEAD" }, { text = true }):wait().stdout)
sh({ "git", "-C", fallback_root, "switch", "-q", "-c", "feature" })
vim.fn.writefile({ "feature" }, fallback_root .. "/feature.txt")
sh({ "git", "-C", fallback_root, "add", "." })
sh({ "git", "-C", fallback_root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "feature" })
sh({
  "git",
  "-C",
  fallback_root,
  "symbolic-ref",
  "refs/remotes/origin/HEAD",
  "refs/remotes/origin/missing",
})
local fallback_entry
assert(core.refresh_repo(fallback_root, ropts, function(entry)
  fallback_entry = entry
end), "broken origin HEAD refresh accepted")
assert(vim.wait(5000, function()
  return fallback_entry ~= nil
end, 10), "broken origin HEAD refresh completed")
eq(fallback_entry.files, { { path = "feature.txt", commit_status = "A" } }, "broken origin HEAD falls back to main")
eq(fallback_entry.comparison_base, fallback_base, "fallback publishes the main merge base")

local squash_root = vim.fn.tempname()
vim.fn.mkdir(squash_root, "p")
sh({ "git", "-C", squash_root, "init", "-q", "-b", "main" })
vim.fn.writefile({ "base" }, squash_root .. "/base.txt")
sh({ "git", "-C", squash_root, "add", "." })
sh({ "git", "-C", squash_root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base" })
sh({ "git", "-C", squash_root, "switch", "-q", "-c", "feature" })
vim.fn.writefile({ "feature" }, squash_root .. "/feature.txt")
sh({ "git", "-C", squash_root, "add", "." })
sh({ "git", "-C", squash_root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "feature" })
sh({ "git", "-C", squash_root, "switch", "-q", "main" })
sh({ "git", "-C", squash_root, "merge", "--squash", "feature" })
sh({ "git", "-C", squash_root, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "squash feature" })
sh({ "git", "-C", squash_root, "switch", "-q", "feature" })
local squash_entry
assert(core.refresh_repo(squash_root, ropts, function(entry)
  squash_entry = entry
end), "squash-merged branch refresh accepted")
assert(vim.wait(5000, function()
  return squash_entry ~= nil
end, 10), "squash-merged branch refresh completed")
eq(squash_entry.files, {}, "squash-merged branch with identical tree is clean")

local orphan = vim.fn.tempname()
vim.fn.mkdir(orphan, "p")
sh({ "git", "-C", orphan, "init", "-q", "-b", "topic" })
vim.fn.writefile({ "staged" }, orphan .. "/only.txt")
sh({ "git", "-C", orphan, "add", "." })
local orphan_entry
assert(core.refresh_repo(orphan, ropts, function(entry)
  orphan_entry = entry
end), "no-base refresh accepted")
assert(vim.wait(5000, function()
  return orphan_entry ~= nil
end, 10), "no-base refresh completed")
eq(orphan_entry.files, { { path = "only.txt", xy = "A." } }, "no-base repository preserves pending files")
assert(orphan_entry.err == nil, "no-base repository does not report a status error")

-- error path: a broken repo yields an err entry via the scoped path too
local rbad = rwork .. "/bad_scoped"
vim.fn.mkdir(rbad .. "/.git", "p")
local bad_entry
assert(core.refresh_repo(rbad, ropts, function(e)
  bad_entry = e
end) == true, "broken repo scan accepted")
vim.wait(5000, function()
  return bad_entry ~= nil
end, 10)
assert(bad_entry and bad_entry.err and #bad_entry.err > 0, "scoped error entry has err")
eq(bad_entry.files, {}, "scoped error entry has no files")

-- Repository Section collapse navigation: visible rows, glyphs, h/l, confirm,
-- filtered-header fallback, inert headers, and session-local state.
local nav_entries = {
  {
    name = "dirty",
    path = "/repos/dirty",
    branch = "main",
    ahead = 0,
    behind = 0,
    clean = false,
    files = {
      { path = "one.lua", xy = ".M" },
      { path = "two.lua", xy = "??" },
    },
  },
  {
    name = "clean",
    path = "/repos/clean",
    branch = "main",
    ahead = 0,
    behind = 0,
    clean = true,
    files = {},
  },
  {
    name = "broken",
    path = "/repos/broken",
    branch = "?",
    ahead = 0,
    behind = 0,
    clean = true,
    err = "status failed",
    files = {},
  },
  {
    name = "dirty",
    path = "/other/dirty",
    branch = "dev",
    ahead = 0,
    behind = 0,
    clean = false,
    files = { { path = "other.lua", xy = ".M" } },
  },
}

panel_state().collapsed = {}
local function nav_items()
  return panel.build_items(nav_entries, panel_state().collapsed)
end

local expanded_nav = nav_items()
eq(#expanded_nav, 7, "expanded Repository Sections include their files")
eq(expanded_nav[1].collapsed, false, "expanded header state")
eq(panel.format_item(expanded_nav[1])[1][1], "▼ ", "expanded disclosure glyph")
local duplicate_header = panel.format_item(expanded_nav[1])
eq(duplicate_header[2][1], "dirty ", "duplicate name remains beside disclosure glyph")
assert(duplicate_header[3][1]:find("repos", 1, true), "duplicate parent remains visible with collapse glyph")

panel_state().collapsed["/repos/dirty"] = true
local collapsed_nav = nav_items()
eq(#collapsed_nav, 5, "collapsed Repository Section hides only its files")
eq(collapsed_nav[1].collapsed, true, "collapsed header state")
local collapsed_duplicate = panel.format_item(collapsed_nav[1])
eq(collapsed_duplicate[1][1], "▶ ", "collapsed disclosure glyph")
eq(collapsed_duplicate[2][1], "dirty ", "collapsed duplicate name remains beside disclosure glyph")
assert(collapsed_duplicate[3][1]:find("repos", 1, true), "collapsed duplicate parent remains visible")
eq(collapsed_nav[2].collapsed, false, "clean header is never collapsible")
eq(collapsed_nav[3].collapsed, false, "error header is never collapsible")

local function fake_picker(items, filter, finder)
  local picker = { _items = items, filter_visible = filter, finder = finder or nav_items }
  picker.list = {
    view = function(_, idx)
      picker.viewed = idx
    end,
  }
  picker.input = { win = {
    set_title = function(_, title)
      picker.title = title
    end,
  } }
  function picker:items()
    return self._items
  end
  function picker:current()
    return self._items[self.current_idx or self.viewed or 1]
  end
  function picker:find(opts)
    self.finds = (self.finds or 0) + 1
    local rebuilt = self.finder()
    self._items = self.filter_visible and self.filter_visible(rebuilt) or rebuilt
    if opts and opts.on_done then
      opts.on_done()
    end
  end
  return picker
end

-- Capture the real picker configuration so wiring and actions are tested
-- through the same boundary Snacks uses when the Panel opens.
local previous_snacks = _G.Snacks
local previous_core_refresh = core.refresh
local opened_picker = fake_picker({})
local opened_opts
local owner_during_show
local active_picker
local open_pending = {}
local open_tab = vim.api.nvim_get_current_tabpage()
opened_picker.list.win = { win = vim.api.nvim_get_current_win() }
opened_picker.input.win.win = vim.api.nvim_get_current_win()
core.refresh = function(root, opts, cb)
  open_pending[#open_pending + 1] = { root = root, opts = opts, cb = cb }
  return true
end
_G.Snacks = {
  picker = {
    pick = function(opts)
      opened_opts = opts
      opened_picker.finder = opts.finder
      opened_picker.closed = #opts.finder() == 0 and not opts.show_empty
      active_picker = opened_picker
      vim.api.nvim_exec_autocmds("WinEnter", {})
      if opts.on_show then
        opts.on_show(opened_picker)
        owner_during_show = opened_picker._scm_tab
      end
      return opened_picker
    end,
    get = function()
      return active_picker and { active_picker } or {}
    end,
  },
}
panel.state.opts = { focus_debounce_ms = 0 }
panel_state().entries = {}
panel_state().collapsed["/repos/dirty"] = true
eq(panel.open("/explorer/root"), opened_picker, "open returns the new picker")
eq(owner_during_show, open_tab, "Panel owns its tab during on_show")
eq(opened_picker.closed, false, "first open stays visible while the initial scan is empty")
eq(panel_state().collapsed, {}, "new Panel session starts fully expanded")
eq(opened_picker.title, "Source Control (scanning…)", "first open shows scanning title")
eq(#open_pending, 1, "first open starts one Core request")
local first_open_entry = vim.deepcopy(nav_entries[1])
open_pending[1].cb({ first_open_entry }, nil)
eq(#open_pending, 1, "picker registration WinEnter does not queue a duplicate first scan")
eq(opened_picker.title, "Source Control", "successful first scan clears scanning title")
eq(panel_state().entries, { first_open_entry }, "successful first scan publishes Repo Entries")

assert(panel.refresh_view(opened_picker), "discovery-error Refresh starts through real Panel path")
eq(opened_picker.title, "Source Control (scanning…)", "error-path Refresh first shows scanning title")
open_pending[2].cb(nil, "repository discovery failed")
eq(opened_picker.title, "Source Control (repository discovery failed)", "discovery error is shown in title")
eq(panel_state().entries, { first_open_entry }, "discovery error preserves successful Panel state")
assert(opened_opts and type(opened_opts.finder) == "function", "open wires the collapse-aware finder")
eq(opened_opts.win.list.keys.h, "scm_close", "open wires h")
eq(opened_opts.win.list.keys.l, "scm_open", "open wires l")
assert(type(opened_opts.actions.scm_close) == "function", "open wires close action")
assert(type(opened_opts.actions.scm_open) == "function", "open wires open action")
panel_state().entries = nav_entries
panel_state().collapsed["/repos/dirty"] = true
eq(#opened_opts.finder(), 5, "open finder honors collapsed state")
eq(panel.key_actions, nil, "picker actions remain a private implementation detail")
core.refresh = previous_core_refresh
_G.Snacks = previous_snacks

local actions = opened_opts.actions

-- In the normal view, h on a file selects its visible header first.
panel_state().collapsed = {}
expanded_nav = nav_items()
local picker = fake_picker(expanded_nav)
actions.scm_close(picker, expanded_nav[2])
eq(picker.viewed, 1, "h on file selects repository header")
eq(panel_state().collapsed["/repos/dirty"], nil, "first h does not collapse visible parent")
eq(picker.finds, nil, "selecting a visible parent does not rebuild")

-- The next h collapses; l expands; repeated h/l in the same state are no-ops.
actions.scm_close(picker, expanded_nav[1])
eq(panel_state().collapsed["/repos/dirty"], true, "h on header collapses")
eq(#picker:items(), 5, "collapse rebuild hides file rows")
eq(picker.viewed, 1, "collapse re-anchors header")
local finds = picker.finds
actions.scm_close(picker, picker:items()[1])
eq(picker.finds, finds, "h on collapsed header is a no-op")

actions.scm_open(picker, picker:items()[1])
eq(panel_state().collapsed["/repos/dirty"], nil, "l on collapsed header expands")
eq(#picker:items(), 7, "expand rebuild restores file rows")
finds = picker.finds
actions.scm_open(picker, picker:items()[1])
eq(picker.finds, finds, "l on expanded header is a no-op")

-- l and <CR> on a file use the same existing jump behavior.
local previous_picker_actions = package.loaded["snacks.picker.actions"]
local jumps = {}
package.loaded["snacks.picker.actions"] = {
  jump = function(got_picker, got_item, opts)
    jumps[#jumps + 1] = { picker = got_picker, item = got_item, cmd = opts.cmd }
  end,
}
actions.scm_open(picker, picker:items()[2])
actions.scm_confirm(picker, picker:items()[2])
eq(#jumps, 2, "l and confirm both open a file")
eq(jumps[1], { picker = picker, item = picker:items()[2], cmd = "edit" }, "l file jump")
eq(jumps[2], { picker = picker, item = picker:items()[2], cmd = "edit" }, "confirm file jump")
package.loaded["snacks.picker.actions"] = previous_picker_actions

-- Pending rows use Gitsigns' default comparison; committed-only rows use the
-- Comparison Base that Core attached to their Repo Entry.
local diff_calls = {}
local previous_gitsigns = package.loaded["gitsigns"]
previous_picker_actions = package.loaded["snacks.picker.actions"]
package.loaded["snacks.picker.actions"] = { jump = function() end }
package.loaded["gitsigns"] = {
  diffthis = function(base)
    diff_calls[#diff_calls + 1] = base or "<default>"
  end,
}
vim.api.nvim_create_user_command("Gitsigns", function(opts)
  diff_calls[#diff_calls + 1] = "command:" .. opts.args
end, { nargs = "*" })
local pending_diff = {
  kind = "file",
  entry = { comparison_base = "base-sha" },
  fentry = { path = "pending.lua", xy = ".M" },
}
local committed_diff = {
  kind = "file",
  entry = { comparison_base = "base-sha" },
  fentry = { path = "committed.lua", commit_status = "M" },
}
actions.scm_diff(picker, pending_diff)
actions.scm_diff(picker, committed_diff)
assert(vim.wait(1000, function()
  return #diff_calls == 2
end, 10), "both diff actions completed")
eq(diff_calls, { "<default>", "base-sha" }, "committed diff uses its Comparison Base")
vim.api.nvim_del_user_command("Gitsigns")
package.loaded["gitsigns"] = previous_gitsigns
package.loaded["snacks.picker.actions"] = previous_picker_actions

-- <CR> expands a collapsed header without lazygit, then opens lazygit once expanded.
local action_snacks = _G.Snacks
local lazygit_calls = {}
_G.Snacks = {
  lazygit = function(opts)
    lazygit_calls[#lazygit_calls + 1] = opts
  end,
}
panel_state().collapsed["/repos/dirty"] = true
picker = fake_picker(nav_items())
actions.scm_confirm(picker, picker:items()[1])
eq(panel_state().collapsed["/repos/dirty"], nil, "confirm expands collapsed header")
eq(#lazygit_calls, 0, "expanding does not open lazygit")
actions.scm_confirm(picker, picker:items()[1])
eq(lazygit_calls, { { cwd = "/repos/dirty" } }, "confirm on expanded header opens lazygit in its repo")

-- Clean/error headers are inert for h/l and retain header confirm behavior.
local clean_header, error_header = picker:items()[4], picker:items()[5]
finds = picker.finds
actions.scm_close(picker, clean_header)
actions.scm_open(picker, clean_header)
actions.scm_close(picker, error_header)
actions.scm_open(picker, error_header)
eq(picker.finds, finds, "h/l are inert on clean and error headers")
actions.scm_confirm(picker, clean_header)
actions.scm_confirm(picker, error_header)
actions.scm_lazygit(picker, error_header)
eq(lazygit_calls, {
  { cwd = "/repos/dirty" },
  { cwd = "/repos/clean" },
  { cwd = "/repos/broken" },
  { cwd = "/repos/broken" },
}, "confirm and g actions call Snacks lazygit directly")
eq(panel.lazygit, nil, "Panel does not export a lazygit pass-through")
_G.Snacks = action_snacks

-- If fuzzy filtering hides the header, h collapses immediately and preserves
-- the filter's visible result set instead of clearing the query.
panel_state().collapsed = {}
expanded_nav = nav_items()
local filtered = fake_picker({ expanded_nav[2] }, function()
  return {}
end)
actions.scm_close(filtered, expanded_nav[2])
eq(panel_state().collapsed["/repos/dirty"], true, "filtered file h collapses hidden parent")
eq(#filtered:items(), 0, "active filter remains applied after collapse")

-- The same collapse set is reused by refresh-style rebuilds.
eq(#nav_items(), 5, "collapse state survives rebuilds")

-- Matcher completion can arrive after a newer find. Only the latest render
-- owns cursor restoration, even when an aborted older task still calls done.
panel_state().entries = nav_entries
panel_state().collapsed = {}
local deferred = fake_picker(opened_opts.finder(), nil, opened_opts.finder)
deferred.pending = {}
deferred.matcher = { task = {} }
function deferred:find(opts)
  self.finds = (self.finds or 0) + 1
  local task = {}
  self.matcher.task = task
  self.pending[#self.pending + 1] = { opts = opts, items = self.finder(), task = task }
end
function deferred:complete(n)
  local pending = self.pending[n]
  self._items = pending.items
  pending.opts.on_done(nil, pending.task)
end
local first_header = deferred:items()[1]
local second_header
for _, item in ipairs(deferred:items()) do
  if item.kind == "header" and item.entry.path == "/other/dirty" then
    second_header = item
  end
end
assert(second_header, "second collapsible header fixture exists")
actions.scm_close(deferred, first_header)
actions.scm_close(deferred, second_header)
eq(#deferred.pending, 2, "two renders queued")
deferred.title = "Source Control (scanning…)"
deferred:complete(2)
eq(deferred.viewed, 4, "latest render restores the latest repository header")
eq(deferred.title, "Source Control", "latest action render clears a superseded scanning title")
deferred:complete(1)
eq(deferred.viewed, 4, "stale render cannot overwrite the latest cursor anchor")

panel_state().collapsed = {}
local closed_before_done = fake_picker(opened_opts.finder(), nil, opened_opts.finder)
closed_before_done.pending = {}
closed_before_done.matcher = {}
function closed_before_done:find(opts)
  local task = {}
  self.matcher.task = task
  self.pending[#self.pending + 1] = { opts = opts, task = task }
end
actions.scm_close(closed_before_done, closed_before_done:items()[1])
closed_before_done.closed = true
closed_before_done.title_touches = 0
closed_before_done.input.win.set_title = function()
  closed_before_done.title_touches = closed_before_done.title_touches + 1
end
closed_before_done.items = function()
  error("closed picker items touched")
end
local closed_done_ok = pcall(function()
  local pending = closed_before_done.pending[1]
  pending.opts.on_done(nil, pending.task)
end)
assert(closed_done_ok, "matcher completion ignores a closed picker")
eq(closed_before_done.title_touches, 0, "closed matcher completion does not touch the title")

-- A newer filter-driven matcher is outside scm's render generation. Its task
-- still owns the filtered list, so an older scm callback may finish the title
-- transition but must not move the cursor within those newer results.
panel_state().collapsed = {}
local filter_race = fake_picker(opened_opts.finder(), nil, opened_opts.finder)
filter_race.pending = {}
filter_race.matcher = { task = {} }
function filter_race:find(opts)
  local task = {}
  self.matcher.task = task
  self.pending[#self.pending + 1] = { opts = opts, task = task }
end
actions.scm_close(filter_race, filter_race:items()[1])
local scm_task = filter_race.pending[1]
filter_race.matcher.task = {} -- a subsequent matcher started from user input
filter_race._items = { second_header, first_header }
filter_race.viewed = 1
filter_race.title = "Source Control (scanning…)"
scm_task.opts.on_done(nil, scm_task.task)
eq(filter_race.viewed, 1, "superseded scm callback cannot move within newer filter results")
eq(filter_race.title, "Source Control", "completed scm render still clears its scanning title")

-- Full and scoped Core refreshes both rebuild through the collapse-aware
-- finder, preserving path-keyed presentation state when entries reorder.
local alpha = vim.deepcopy(nav_entries[1])
alpha.name = "alpha"
local beta = vim.deepcopy(nav_entries[4])
beta.name = "beta"
local previous_core_refresh = core.refresh
local previous_core_refresh_repo = core.refresh_repo
local previous_scope_current = scope.current
previous_snacks = _G.Snacks

panel_state().entries = { alpha, beta }
panel_state().collapsed = { [alpha.path] = true }
local refresh_picker = fake_picker(opened_opts.finder(), nil, opened_opts.finder)
refresh_picker._scm_tab = vim.api.nvim_get_current_tabpage()
refresh_picker.current_idx = 3 -- beta's file before the refresh reorders rows
_G.Snacks = { picker = {
  get = function()
    return { refresh_picker }
  end,
} }
scope.current = function()
  return "/explorer/root"
end
panel_state().root = scope.current()
core.refresh = function(root, opts, cb)
  eq(root, "/explorer/root", "full refresh uses current Explorer Root")
  eq(opts, panel.state.opts, "full refresh preserves Core options")
  cb({ beta, alpha })
  return true
end
panel.refresh_view(refresh_picker)
eq(panel_state().entries[1].path, beta.path, "full refresh accepts reordered entries")
eq(#refresh_picker:items(), 3, "full refresh keeps alpha's files collapsed")
eq(refresh_picker:items()[3].entry.path, alpha.path, "collapsed header survives full refresh reorder")
eq(refresh_picker.viewed, 2, "full refresh restores the surviving file anchor")

panel_state().entries = { beta, alpha }
refresh_picker = fake_picker(opened_opts.finder(), nil, opened_opts.finder)
refresh_picker._scm_tab = vim.api.nvim_get_current_tabpage()
_G.Snacks = { picker = {
  get = function()
    return { refresh_picker }
  end,
} }
core.refresh = function(_, _, cb)
  cb(nil, "repository discovery failed")
  return true
end
local refresh_ok = pcall(panel.refresh_view, refresh_picker)
assert(refresh_ok, "full refresh discovery errors do not crash the Panel")
eq(panel_state().entries, { beta, alpha }, "full refresh discovery errors preserve current entries")

panel_state().entries = { beta, alpha }
panel_state().collapsed = { [alpha.path] = true }
refresh_picker = fake_picker(opened_opts.finder(), nil, opened_opts.finder)
refresh_picker._scm_tab = vim.api.nvim_get_current_tabpage()
refresh_picker.current_idx = 2 -- beta's file
_G.Snacks = { picker = {
  get = function()
    return { refresh_picker }
  end,
} }
local updated_alpha = vim.deepcopy(alpha)
updated_alpha.ahead = 2
updated_alpha.files = { { path = "replacement.lua", xy = ".M" } }
core.refresh_repo = function(repo, _, cb)
  eq(repo, alpha.path, "scoped refresh targets one repository")
  cb(updated_alpha)
  return true
end
assert(panel.refresh_repo_view(alpha.path), "scoped refresh accepted")
eq(panel_state().entries[1].path, alpha.path, "scoped refresh re-sorts entries")
eq(#refresh_picker:items(), 3, "scoped refresh keeps alpha's replacement file collapsed")
eq(refresh_picker:items()[1].entry.path, alpha.path, "collapsed header survives scoped refresh reorder")
eq(refresh_picker.viewed, 3, "scoped refresh restores beta's surviving file anchor")

core.refresh = previous_core_refresh
core.refresh_repo = previous_core_refresh_repo
scope.current = previous_scope_current
_G.Snacks = previous_snacks

print("OK")
