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
eq(root_discovered, { parent_real }, "a Root that is a repository is not searched below and is listed once")

local parent_link = tmp .. "/parent-link"
assert(vim.uv.fs_symlink(parent, parent_link, { dir = true }), "create symlinked Working Directory")
local linked_discovered
core.discover(parent_link, { timeout_ms = 5000 }, function(repos, err)
  assert(not err, err)
  linked_discovered = repos
end)
vim.wait(5000, function()
  return linked_discovered ~= nil
end, 10)
eq(linked_discovered, { parent_real }, "symlinked Working Directory is canonicalized once before discovery")

local missing_err
core.discover(root .. "/missing", { timeout_ms = 5000 }, function(_, err)
  missing_err = err
end)
vim.wait(5000, function()
  return missing_err ~= nil
end, 10)
assert(type(missing_err) == "string" and missing_err ~= "", "discovery failures are reported")

local function discover_now(dir, opts)
  local repos, err, done
  core.discover(dir, opts, function(r, e)
    repos, err, done = r, e, true
  end)
  vim.wait(5000, function()
    return done
  end, 10)
  assert(done, "discovery finished for " .. dir)
  return repos, err
end

-- discover(): build and dependency trees are pruned; other nested repos are found.
local heavy = vim.fn.tempname()
local function repo_at(path)
  vim.fn.mkdir(path, "p")
  sh({ "git", "-C", path, "init", "-q", "-b", "main" })
  return (assert(vim.uv.fs_realpath(path), "canonical " .. path))
end
local heavy_app = repo_at(heavy .. "/app")
local heavy_lib = repo_at(heavy .. "/libs/deep/lib")
local heavy_custom = repo_at(heavy .. "/generated/inner")
repo_at(heavy .. "/app/node_modules/dep")
repo_at(heavy .. "/rust/target/debug/build/vendored")
repo_at(heavy .. "/py/.venv/src/pkg")
vim.fn.mkdir(heavy .. "/rust/target/release", "p")
vim.fn.writefile({ "gitdir: /elsewhere" }, heavy .. "/rust/target/release/.git")
local heavy_repos, heavy_err = discover_now(heavy, { timeout_ms = 5000 })
eq(heavy_err, nil, "default exclusions still succeed")
eq(heavy_repos, { heavy_app, heavy_custom, heavy_lib }, "repos inside excluded directories are skipped by default")

local custom_repos = discover_now(heavy, { timeout_ms = 5000, discovery_exclude = { "generated" } })
local heavy_pkg = assert(vim.uv.fs_realpath(heavy .. "/py/.venv/src/pkg"))
assert(vim.tbl_contains(custom_repos, heavy_pkg), "a custom exclusion list replaces the defaults")
assert(not vim.tbl_contains(custom_repos, heavy_custom), "a custom exclusion list prunes its own names")

-- The Working Directory is searched even when its own name is excluded.
local named_root_repos = discover_now(heavy .. "/rust/target", { timeout_ms = 5000 })
eq(named_root_repos, {
  (assert(vim.uv.fs_realpath(heavy .. "/rust/target/debug/build/vendored"))),
  (assert(vim.uv.fs_realpath(heavy .. "/rust/target/release"))),
}, "exclusions apply below the Working Directory, not to the root itself")

-- discover(): a repository ends the search; clones nested inside it are not listed.
local stops = vim.fn.tempname()
local stops_outer = repo_at(stops .. "/outer")
repo_at(stops .. "/outer/vendor/clone")
local stops_deep = repo_at(stops .. "/plain/folders/deep")
eq(discover_now(stops, { timeout_ms = 5000 }), { stops_outer, stops_deep }, "a repository is not searched for nested clones")

-- A walk that runs past its limit is an error even when it already found repositories.
local real_system = vim.system
local real_scandir = vim.uv.fs_scandir
vim.uv.fs_scandir = function(dir, cb)
  if dir:match("/libs$") then
    return -- this directory never answers
  end
  return real_scandir(dir, cb)
end
local timed_out_repos, timed_out_err = discover_now(heavy, { timeout_ms = 5000, discovery_timeout_ms = 50 })
vim.uv.fs_scandir = real_scandir
eq(timed_out_repos, nil, "timed-out discovery delivers no partial repository list")
eq(
  timed_out_err,
  "repository discovery timed out after 0.05 s; add large folders to discovery_exclude",
  "timed-out discovery says it timed out and how to fix it"
)

-- A directory that cannot be read fails discovery; a failure without a message stays generic.
vim.uv.fs_scandir = function(dir, cb)
  if dir:match("/libs$") then
    return real_scandir(dir .. "/missing", cb)
  end
  return real_scandir(dir, cb)
end
local unreadable_repos, unreadable_err = discover_now(heavy, { timeout_ms = 5000 })
vim.uv.fs_scandir = function(dir, cb)
  if dir:match("/libs$") then
    vim.schedule(function() cb("") end)
    return
  end
  return real_scandir(dir, cb)
end
local _, failed_err = discover_now(heavy, { timeout_ms = 5000 })
vim.uv.fs_scandir = real_scandir
eq(unreadable_repos, nil, "an unreadable directory delivers no partial repository list")
assert(unreadable_err:match("ENOENT"), "an unreadable directory reports why: " .. tostring(unreadable_err))
eq(failed_err, "repository discovery failed", "non-timeout failure keeps the generic error")

-- The walk has its own limit and runs no subprocess; git commands keep timeout_ms.
local seen = {}
vim.system = function(cmd, sys_opts, cb)
  seen[cmd[1]] = sys_opts.timeout
  return real_system(cmd, sys_opts, cb)
end
discover_now(heavy, { timeout_ms = 5000 })
vim.system = real_system
eq(core.defaults.discovery_timeout_ms, 15000, "discovery allows 15 s by default")
eq(seen, { git = 5000 }, "discovery spawns only git, which keeps timeout_ms")

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

-- Worktrees git knows about are listed even inside their repository, unlike nested clones.
-- Worktrees outside the Working Directory, or whose directory is gone, are not.
local nested_wt = primary_repo .. "/.worktrees/feature"
local gone_wt = primary_repo .. "/.worktrees/gone"
sh({ "git", "-C", primary_repo, "worktree", "add", "-q", "-b", "feature", nested_wt })
sh({ "git", "-C", primary_repo, "worktree", "add", "-q", "-b", "gone", gone_wt })
vim.fn.delete(gone_wt, "rf")
local outside_wt = vim.fn.tempname()
sh({ "git", "-C", primary_repo, "worktree", "add", "-q", "-b", "outside", outside_wt })
local primary_real = assert(vim.uv.fs_realpath(primary_repo))
local nested_real = assert(vim.uv.fs_realpath(nested_wt))
local nested_expected = vim.list_extend({ nested_real }, expected_worktrees)
table.sort(nested_expected)
eq(discover_now(worktree_base, { timeout_ms = 5000 }), nested_expected, "worktrees inside a repository are listed")
eq(
  discover_now(primary_repo, { timeout_ms = 5000 }),
  { primary_real, nested_real },
  "a Root that is a repository still lists its own worktrees below it"
)

vim.fn.writefile({ "changed outside Working Directory" }, linked_worktree .. "/outside.txt")
local worktree_status
core.refresh(linked_worktree .. "/inside", { timeout_ms = 5000 }, function(entries, err)
  assert(not err, err)
  worktree_status = entries
end)
vim.wait(5000, function()
  return worktree_status ~= nil
end, 10)
eq(#worktree_status, 1, "subdirectory Working Directory refreshes its containing worktree")
eq(worktree_status[1].path, expected_worktrees[1], "worktree Repo Entry uses canonical root")
eq(
  worktree_status[1].files,
  { { path = "outside.txt", xy = ".M" } },
  "status includes repository-wide changes outside the Working Directory subdirectory"
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

-- cached(): the last published Repo Entries for a root, for a renderer to show at once.
eq(core.cached(vim.fn.tempname()), nil, "a root never refreshed has nothing cached")
eq(core.cached(work), got, "cached entries match the last refresh, in its order")
eq(core.cached(vim.uv.fs_realpath(work)), got, "cached entries are found through the canonical root too")
vim.fn.writefile({ "changed too" }, cleanrepo .. "/a.txt")
got = nil
core.refresh(work, { timeout_ms = 5000 }, function(entries)
  got = entries
end)
vim.wait(5000, function()
  return got ~= nil
end, 10)
local cached_clean
for _, entry in ipairs(core.cached(work)) do
  if entry.name == "clean_repo" then cached_clean = entry end
end
eq(#cached_clean.files, 1, "a later refresh replaces the cached entries")
vim.fn.writefile({ "hello" }, cleanrepo .. "/a.txt")

-- progress: each repository's entry is published as it lands, before the final callback.
local function refresh_with_progress(dir)
  local calls, final, late = {}, nil, false
  core.refresh(dir, { timeout_ms = 5000 }, function(entries)
    final = entries
  end, nil, function(entries)
    if final then late = true end
    calls[#calls + 1] = vim.tbl_map(function(e) return e.name end, entries)
  end)
  vim.wait(5000, function()
    return final ~= nil
  end, 10)
  assert(final, "refresh with progress finished for " .. dir)
  return calls, late
end
local progress_root = vim.fn.tempname()
repo_at(progress_root .. "/first")
repo_at(progress_root .. "/second")
local first_calls, first_late = refresh_with_progress(progress_root)
eq(#first_calls, 1, "one progress update for two repositories: the last one is the final callback")
eq(#first_calls[1], 1, "on a new root the first repository shows before the last one lands")
eq(first_late, false, "no progress arrives after the final callback")
local again_calls = refresh_with_progress(progress_root)
eq(again_calls, { { "first", "second" } }, "on a cached root, repositories not rescanned yet keep their cached rows")
local warm_preliminary, warm_final = 0, false
core.refresh(progress_root, { timeout_ms = 5000 }, function(entries)
  warm_final = entries ~= nil
end, { cached = true }, nil, function()
  warm_preliminary = warm_preliminary + 1
end)
assert(vim.wait(5000, function() return warm_final end, 10), "cached refresh finishes")
eq(warm_preliminary, 0, "cached entries do not cause redundant preliminary renders")
local cold_preliminary, cold_final = 0, false
local cold_root = vim.fn.tempname()
repo_at(cold_root .. "/new")
core.refresh(cold_root, { timeout_ms = 5000 }, function(entries)
  cold_final = entries ~= nil
end, nil, nil, function(entries)
  cold_preliminary = cold_preliminary + 1
  eq(#entries, 1, "cold preliminary status has a visible repository")
end)
assert(vim.wait(5000, function() return cold_final end, 10), "cold refresh finishes")
eq(cold_preliminary, 1, "cold repository publishes preliminary status")

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

-- refresh(): zero-repos path -- Working Directory contains no .git -> cb({})
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

local model = require("scm.model")

-- xy_display: letter = working-tree state, else index state; mixed marker
eq(model.xy_display(".M"), { letter = "M", mixed = false, hl = "ScmModified" }, "unstaged modified")
eq(model.xy_display("M."), { letter = "M", mixed = false, hl = "ScmStaged" }, "staged only")
eq(model.xy_display("MM"), { letter = "M", mixed = true, hl = "ScmModified" }, "mixed state")
eq(model.xy_display("??"), { letter = "??", mixed = false, hl = "ScmUntracked" }, "untracked")
eq(model.xy_display("R."), { letter = "R", mixed = false, hl = "ScmStaged" }, "staged rename")
eq(model.xy_display(".D"), { letter = "D", mixed = false, hl = "ScmDeleted" }, "deleted")
eq(model.xy_display("UU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "conflict")
eq(model.xy_display("DD"), { letter = "D", mixed = true, hl = "ScmConflict" }, "unmerged: both deleted")
eq(model.xy_display("AU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "unmerged: added by us")
eq(model.xy_display("UD"), { letter = "D", mixed = true, hl = "ScmConflict" }, "unmerged: deleted by them")
eq(model.xy_display("UA"), { letter = "A", mixed = true, hl = "ScmConflict" }, "unmerged: added by them")
eq(model.xy_display("DU"), { letter = "U", mixed = true, hl = "ScmConflict" }, "unmerged: deleted by us")
eq(model.xy_display("AA"), { letter = "A", mixed = true, hl = "ScmConflict" }, "unmerged: both added")
eq(model.file_display({ path = "committed.lua", commit_status = "M" }), {
  letter = "M",
  marker = "✓",
  hl = "ScmCommitted",
}, "committed-only display")
eq(model.file_display({ path = "pending.lua", xy = "M." }), {
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
local items = model.build_items(entries)
eq(#items, 5, "3 headers + 2 files")
eq(items[1].kind, "header", "header first")
eq(items[1].dup, true, "name collision flagged")
eq(items[2].kind, "file", "file after its header")
eq(items[2].text, "api/app/models/device.rb", "match text includes repo")
eq(items[2].ctx, "api/app/models", "ctx column repo/dir")
eq(items[2].file, "/r/api/app/models/device.rb", "absolute path for opening the file")
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
local initial_cached
core.refresh(croot, ropts, function(entries) initial_cached = entries end)
assert(vim.wait(5000, function() return initial_cached ~= nil end, 10), "initial history refresh")
local original_system, cached_git_calls = vim.system, 0
vim.system = function(args, ...)
  if args[1] == "git" then cached_git_calls = cached_git_calls + 1 end
  return original_system(args, ...)
end
local reopened
core.refresh(croot, ropts, function(entries) reopened = entries end,
  { cached = true, reuse_history = true })
assert(vim.wait(5000, function() return reopened ~= nil end, 10), "cached reopen refresh")
vim.system = original_system
eq(cached_git_calls, 2, "same-HEAD reopen checks status and comparison refs")
eq(reopened[1].files, committed_entry.files, "same-HEAD reopen retains committed changes")
local main_before = vim.trim(vim.system({ "git", "-C", croot, "rev-parse", "main" },
  { text = true }):wait().stdout)
sh({ "git", "-C", croot, "branch", "-f", "main", "feature" })
local moved_base
core.refresh(croot, ropts, function(entries) moved_base = entries end,
  { cached = true, reuse_history = true })
assert(vim.wait(5000, function() return moved_base ~= nil end, 10), "moved base refresh")
eq(moved_base[1].files, {}, "reopen drops committed rows after comparison branch catches up")
sh({ "git", "-C", croot, "branch", "-f", "main", main_before })
vim.fn.writefile({ "untracked" }, croot .. "/untracked.txt")
local changed_on_reopen
core.refresh(croot, ropts, function(entries) changed_on_reopen = entries end,
  { cached = true, reuse_history = true })
assert(vim.wait(5000, function() return changed_on_reopen ~= nil end, 10), "changed reopen refresh")
eq(changed_on_reopen[1].files, {
  { path = "committed.txt", commit_status = "A" },
  { path = "untracked.txt", xy = "??" },
}, "reopen updates working changes without losing committed history")

vim.fn.writefile({ "pending" }, croot .. "/committed.txt")
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
vim.fn.writefile({ "next" }, croot .. "/next.txt")
sh({ "git", "-C", croot, "add", "next.txt" })
sh({ "git", "-C", croot, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "next" })
local changed_head
core.refresh(croot, ropts, function(entries) changed_head = entries end,
  { cached = true, reuse_history = true })
assert(vim.wait(5000, function() return changed_head ~= nil end, 10), "changed HEAD refresh")
eq(changed_head[1].files, {
  { path = "committed.txt", xy = ".M" },
  { path = "next.txt", commit_status = "A" },
  { path = "untracked.txt", xy = "??" },
}, "changed HEAD recomputes committed history")

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

local collapsed = {}
local function nav_items()
  return model.build_items(nav_entries, collapsed)
end

local expanded_nav = nav_items()
eq(#expanded_nav, 7, "expanded Repository Sections include their files")
eq(expanded_nav[1].collapsed, false, "expanded header state")
collapsed["/repos/dirty"] = true
local collapsed_nav = nav_items()
eq(#collapsed_nav, 5, "collapsed Repository Section hides only its files")
eq(collapsed_nav[1].collapsed, true, "collapsed header state")
eq(collapsed_nav[2].collapsed, false, "clean header is never collapsible")
eq(collapsed_nav[3].collapsed, false, "error header is never collapsible")

print("OK")
