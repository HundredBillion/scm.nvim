-- scm.core — the UI-free Core.
-- Emits Repo Entries; never requires any UI module.
local M = {}

M.defaults = {
  timeout_ms = 5000,
  -- Limit for the repository-discovery walk alone. Large roots of real source
  -- trees still take several seconds after exclusions, so this is longer than
  -- timeout_ms, which bounds each per-repo git command.
  discovery_timeout_ms = 15000,
  -- Minimum ms between two refreshes of the SAME repo (event storms from
  -- autocmds must never stack git processes for one repo).
  repo_debounce_ms = 150,
  -- Collect working changes after startup so the first open already has rows.
  warm = true,
  -- Directory names discovery never descends into. Build output and dependency
  -- trees can hold millions of files and would push the walk past discovery_timeout_ms.
  -- A list given in setup replaces this one; {} searches everything.
  discovery_exclude = {
    "node_modules", "target", ".venv", "venv", "__pycache__", ".tox", ".mypy_cache",
    ".pytest_cache", ".gradle", ".next", ".terraform", ".zig-cache", "zig-cache", "DerivedData",
  },
}

-- Git prints a path holding non-ASCII bytes as a quoted, escaped string unless
-- told not to. Paths are shown to the user and handed back to git, so they
-- must be the real names. Set through the environment, which leaves the
-- command line as it was.
--
-- Core only reads. `git status` would otherwise take the index lock to save a
-- refreshed index, and a stage or commit the user starts at that moment would
-- fail on the lock; GIT_OPTIONAL_LOCKS=0 is git's switch for background readers.
M.git_env = {
  GIT_CONFIG_COUNT = "1", GIT_CONFIG_KEY_0 = "core.quotepath", GIT_CONFIG_VALUE_0 = "false",
  GIT_OPTIONAL_LOCKS = "0",
}

-- Walk the Working Directory for repositories without a subprocess. A directory holding a
-- .git entry (a directory, or a worktree's .git file) is a repository and ends the
-- search there: walking its working tree for nested clones is what made discovery take
-- seconds. Symlinked and excluded directories are not entered. Calls cb(repos) or
-- cb(nil, err) once; any unreadable directory fails the whole walk, never a partial list.
local function walk(root, exclude, limit, cb)
  local skip = {}
  for _, name in ipairs(exclude) do
    skip[name] = true
  end
  local repos, pending, finished = {}, 0, false
  local timer = vim.uv.new_timer()
  local function finish(found, err)
    if finished then
      return
    end
    finished = true
    timer:stop()
    timer:close()
    cb(found, err)
  end
  timer:start(limit, 0, function()
    finish(nil, string.format(
      "repository discovery timed out after %g s; add large folders to discovery_exclude",
      limit / 1000
    ))
  end)
  local function visit(dir)
    pending = pending + 1
    vim.uv.fs_scandir(dir, function(err, handle)
      if finished then
        return
      end
      if err then
        finish(nil, err)
        return
      end
      local subdirs, is_repo = {}, false
      while true do
        local name, kind = vim.uv.fs_scandir_next(handle)
        if not name then
          break
        end
        if name == ".git" then
          is_repo = true
        elseif kind == "directory" and not skip[name] then
          subdirs[#subdirs + 1] = dir .. "/" .. name
        end
      end
      if is_repo then
        repos[#repos + 1] = dir
      else
        for _, sub in ipairs(subdirs) do
          visit(sub)
        end
      end
      pending = pending - 1
      if pending == 0 then
        finish(repos)
      end
    end)
  end
  visit(root)
end

-- Parse `git status --porcelain=v2 --branch` output into branch/ahead/behind
-- plus File Entries carrying the raw XY Code verbatim.
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
      if h then
        branch = h
      end
      local o = l:match("^# branch%.oid (%S+)")
      if o then
        oid = o
      end
      local a, b = l:match("^# branch%.ab %+(%d+) %-(%d+)$")
      if a then
        ahead, behind = tonumber(a), tonumber(b)
      end
    elseif first == "1" then
      local xy, path = l:match("^1 (..) %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then
        files[#files + 1] = { path = path, xy = xy }
      end
    elseif first == "2" then
      local xy, rest = l:match("^2 (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then
        -- A rename or copy lists the new path, a tab, then the path it came from.
        files[#files + 1] = { path = rest:match("^([^\t]+)"), orig = rest:match("\t(.+)$"), xy = xy }
      end
    elseif first == "u" then
      local xy, path = l:match("^u (..) %S+ %S+ %S+ %S+ %S+ %S+ %S+ %S+ (.+)$")
      if xy then
        files[#files + 1] = { path = path, xy = xy }
      end
    elseif first == "?" then
      local p = l:match("^%? (.+)$")
      if p then
        files[#files + 1] = { path = p, xy = "??" }
      end
    end
  end
  if branch == "(detached)" and oid then
    branch = oid:sub(1, 7)
  end
  return { branch = branch, ahead = ahead, behind = behind, files = files }
end

local function parse_name_status(stdout)
  local fields = vim.split(stdout, "\0", { plain = true, trimempty = true })
  local files, index = {}, 1
  while index <= #fields do
    local status = fields[index]
    index = index + 1
    -- A rename or copy lists the name it came from, then its name now.
    local path, orig
    if status:match("^[RC]") then
      orig = fields[index]
      index = index + 1
    end
    path = fields[index]
    index = index + 1
    if path then
      files[#files + 1] = { path = path, orig = orig, commit_status = status }
    end
  end
  -- Sorted once here, so every later merge with the working changes is a
  -- single pass and not a sort of the whole list.
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
end

-- The committed files and the working changes as one list sorted by path; a
-- file in both is listed as its working change. `committed` is sorted and is
-- never changed: a branch can be tens of thousands of files from its base,
-- and this runs on every refresh.
local function merge_files(committed, pending)
  if #pending == 0 then
    return committed
  end
  local by_path = {}
  for _, file in ipairs(pending) do
    by_path[file.path] = file
  end
  local working = vim.tbl_values(by_path)
  table.sort(working, function(a, b)
    return a.path < b.path
  end)
  if #committed == 0 then
    return working
  end
  local files, next_working = {}, 1
  for i = 1, #committed do
    local file = committed[i]
    while working[next_working] and working[next_working].path < file.path do
      files[#files + 1] = working[next_working]
      next_working = next_working + 1
    end
    if not by_path[file.path] then
      files[#files + 1] = file
    end
  end
  for i = next_working, #working do
    files[#files + 1] = working[i]
  end
  return files
end

-- The walk stops at a repository, so worktrees placed inside one (such as .worktrees/x)
-- come from git instead. Only a repository whose .git directory holds a worktrees/
-- folder has any, so the rest cost no subprocess. Calls cb(paths) with each worktree
-- under root whose directory still exists; a failed git call adds nothing.
local function linked_worktrees(repos, root, timeout, cb)
  local found, pending = {}, 1
  local function settle()
    pending = pending - 1
    if pending == 0 then
      cb(found)
    end
  end
  for _, repo in ipairs(repos) do
    local stat = vim.uv.fs_stat(repo .. "/.git/worktrees")
    if stat and stat.type == "directory" then
      pending = pending + 1
      vim.system({ "git", "-C", repo, "worktree", "list", "--porcelain", "-z" }, { text = true, timeout = timeout }, function(out)
        if out.code == 0 then
          for _, field in ipairs(vim.split(out.stdout or "", "\0", { plain = true, trimempty = true })) do
            local path = field:match("^worktree (.+)$")
            path = path and vim.uv.fs_realpath(path)
            if path and path ~= repo and (path == root or path:sub(1, #root + 1) == root .. "/") then
              found[#found + 1] = path
            end
          end
        end
        settle()
      end)
    end
  end
  settle()
end

function M.discover(root, opts, cb)
  root = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.expand(root)) or vim.fn.expand(root))
  local landed, pending = {}, 2
  local function finish(kind, out)
    landed[kind] = out
    pending = pending - 1
    if pending ~= 0 then
      return
    end
    vim.schedule(function()
      if landed.walk.err then
        local msg = vim.trim(landed.walk.err)
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
      for _, repo in ipairs(landed.walk.repos) do
        add(repo)
      end
      for _, worktree in ipairs(landed.walk.worktrees) do
        add(worktree)
      end
      table.sort(repos)
      cb(repos, nil)
    end)
  end
  vim.system(
    { "git", "-C", root, "rev-parse", "--show-toplevel" },
    { text = true, timeout = opts.timeout_ms },
    function(out)
      finish("parent", out)
    end
  )
  walk(
    root,
    opts.discovery_exclude or M.defaults.discovery_exclude,
    opts.discovery_timeout_ms or M.defaults.discovery_timeout_ms,
    function(repos, err)
      if err then
        finish("walk", { err = err })
        return
      end
      linked_worktrees(repos, root, opts.timeout_ms, function(worktrees)
        finish("walk", { repos = repos, worktrees = worktrees })
      end)
    end
  )
  return true
end

-- Sort comparator for Repo Entries: needs-attention (dirty OR errored) first,
-- alphabetical by name within each group. Exposed as M.compare_entries (not
-- local) so tests can exercise the tiebreak directly with hand-built entries,
-- independent of repository discovery order.
function M.compare_entries(a, b)
  local aa = (not a.clean) or a.err ~= nil
  local bb = (not b.clean) or b.err ~= nil
  if aa ~= bb then
    return aa
  end
  return a.name < b.name
end

-- Build one Repo Entry from a finished `git status` subprocess result. Runs
-- on the main loop (callers vim.schedule this) — never in vim.system's
-- fast-event callback context.
local function build_entry(repo, out, committed, comparison_base, comparison_fingerprint)
  local name = repo:match("[^/]+$") or repo
  if out.code == 0 then
    local p = M.parse_status(vim.split(out.stdout or "", "\n", { trimempty = true }))
    local files = merge_files(committed or {}, p.files)
    return {
      name = name,
      path = repo,
      branch = p.branch,
      ahead = p.ahead,
      behind = p.behind,
      files = files,
      clean = #files == 0,
      comparison_base = comparison_base,
      _committed = committed,
      -- What `_committed` was collected for: HEAD's commit and the comparison refs'.
      _comparison_fingerprint = comparison_fingerprint,
    }
  end
  local msg = (out.stderr or ""):match("^[^\n]*")
  return {
    name = name,
    path = repo,
    branch = "?",
    ahead = 0,
    behind = 0,
    files = {},
    clean = true,
    err = (msg and #msg > 0) and msg or "git failed",
  }
end

local function run_git(repo, opts, args, cb)
  local cmd = { "git", "-C", repo }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, timeout = opts.timeout_ms, env = M.git_env }, function(out)
    vim.schedule(function()
      cb(out)
    end)
  end)
end

local comparison_refs = { "refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master" }
-- What a repository's committed files depend on, from one git process: the
-- commit HEAD is at and the commit of each comparison ref that exists, as
-- "<commit> <ref>" lines. nil when git fails. `show-ref` exits 1 when it has
-- nothing to list, as in a repository with no commit yet.
local function comparison_fingerprint(repo, opts, cb)
  local args = { "show-ref", "--head" }
  vim.list_extend(args, comparison_refs)
  run_git(repo, opts, args, function(out)
    cb((out.code == 0 or out.code == 1) and (out.stdout or "") or nil)
  end)
end

local function resolve_comparison_base(repo, opts, index, cb, available)
  local ref = comparison_refs[index]
  if not ref then
    cb(nil, nil)
    return
  end
  if available and not available[ref] then
    resolve_comparison_base(repo, opts, index + 1, cb, available)
    return
  end
  run_git(repo, opts, { "merge-base", ref, "HEAD" }, function(out)
    local base = vim.trim(out.stdout or "")
    if out.code == 0 and base ~= "" then
      cb(base, ref)
    else
      resolve_comparison_base(repo, opts, index + 1, cb, available)
    end
  end)
end

local function collect_committed(repo, opts, cb, fingerprint)
  local available
  if fingerprint then
    available = {}
    for line in fingerprint:gmatch("[^\n]+") do
      local ref = line:match("^%x+ (%S+)$")
      if ref then available[ref] = true end
    end
  end
  resolve_comparison_base(repo, opts, 1, function(base, default_ref)
    if not base then
      cb({}, nil)
      return
    end
    run_git(repo, opts, { "diff", "--quiet", default_ref, "HEAD" }, function(tree_diff)
      if tree_diff.code == 0 then
        cb({}, base)
        return
      end
      run_git(repo, opts, { "diff", "--name-status", "-z", base .. "..HEAD" }, function(out)
        cb(out.code == 0 and parse_name_status(out.stdout or "") or {}, base)
      end)
    end)
  end, available)
end

-- Scan one repository. Its status and its committed history are read at the
-- same time: in a large repository each takes about as long as the other, and
-- one after the other they made the Panel wait twice. A scan whose history
-- is reused runs two git processes.
local function scan_repo(repo, opts, cb, status_only, partial, prior, reuse_history)
  local status, history, finished
  local function settle()
    if finished or not status then
      return
    end
    if status.code ~= 0 or status_only then
      finished = true
      cb(build_entry(repo, status))
    elseif history then
      finished = true
      cb(build_entry(repo, status, history.committed, history.base, history.fingerprint))
    end
  end
  -- Every untracked file is listed by name, as VS Code lists them, where git
  -- would otherwise show a new directory as one entry.
  run_git(repo, opts, { "status", "--porcelain=v2", "--branch", "--untracked-files=all" }, function(out)
    status = out
    if out.code == 0 and not status_only and not history and partial then
      partial(build_entry(repo, out))
    end
    settle()
  end)
  if status_only then
    return
  end
  comparison_fingerprint(repo, opts, function(fingerprint)
    -- The same commit compared against the same refs has the same history.
    -- The fingerprint names both, so one comparison decides.
    if reuse_history and prior and prior._committed and fingerprint
      and fingerprint == prior._comparison_fingerprint then
      history = { committed = prior._committed, base = prior.comparison_base, fingerprint = fingerprint }
      settle()
      return
    end
    collect_committed(repo, opts, function(committed, comparison_base)
      history = { committed = committed, base = comparison_base, fingerprint = fingerprint }
      settle()
    end, fingerprint)
  end)
end

-- A repository waiting in the queue has one job that every caller asking for it joins,
-- so overlapping refreshes (an open during the startup warm-up) do not scan it twice.
-- A queued scan starts after every request that joined it, so its result is current for
-- all of them. A running scan may predate a newer request and is never joined.
local scan_queue, scans_running, queued_scans = {}, 0, {}
-- How many repositories are scanned at once: half the processors, since a
-- scan runs two git commands side by side, but at least 4 and at most 8.
M.SCAN_LIMIT = math.max(4, math.min(8, math.floor((vim.uv.available_parallelism and vim.uv.available_parallelism() or 8) / 2)))
-- Starting a git process holds Neovim for a millisecond or more, and a scan
-- starts two. One scan is started per turn of the event loop, so a refresh
-- of many repositories never freezes the editor, or the Panel's first frame,
-- for the tens of milliseconds a burst of them would.
local drain_scheduled = false
local drain_scans
local function start_scan()
  if scans_running < M.SCAN_LIMIT and #scan_queue > 0 then
    local job = table.remove(scan_queue, 1)
    queued_scans[job.repo] = nil
    scans_running = scans_running + 1
    scan_repo(job.repo, job.opts, function(entry)
      scans_running = scans_running - 1
      for _, cb in ipairs(job.cbs) do
        cb(entry)
      end
      drain_scans()
    end, job.status_only, function(entry)
      for _, cb in ipairs(job.partial_cbs) do cb(entry) end
    end, job.prior, job.reuse_history)
  end
end
drain_scans = function()
  if drain_scheduled or scans_running >= M.SCAN_LIMIT or #scan_queue == 0 then
    return
  end
  drain_scheduled = true
  vim.schedule(function()
    drain_scheduled = false
    start_scan()
    drain_scans()
  end)
end
local function enqueue_scan(repo, opts, cb, status_only, partial, prior, reuse_history)
  local job = queued_scans[repo]
  if job then
    job.cbs[#job.cbs + 1] = cb
    job.status_only = job.status_only and status_only
    job.reuse_history = job.reuse_history and reuse_history
    if prior and prior._committed then job.prior = prior end
    if partial then job.partial_cbs[#job.partial_cbs + 1] = partial end
    return
  end
  job = {repo=repo, opts=opts, cbs={cb}, status_only=status_only,
    partial_cbs=partial and {partial} or {}, prior=prior, reuse_history=reuse_history}
  queued_scans[repo] = job
  scan_queue[#scan_queue + 1] = job
  drain_scans()
end

-- Request order protects cached entries from older scans that finish after newer scans.
local scopes, refresh_sequence = {}, 0
local repo_last, repo_in_flight, repo_again = {}, {}, {}

local function within(path, root)
  return path == root or path:sub(1, #root + 1) == root .. "/" or root == "/"
end


-- Scoped refresh: re-scan ONE repo, deliver its fresh Repo Entry via a
-- scheduled callback. Debounced per repo, and a request arriving while a scan
-- for the same repo is in flight coalesces into exactly one re-run when the
-- scan lands (instead of stacking a git process per request). Returns false
-- when the call was debounced or coalesced.
function M.refresh_repo(repo, opts, cb)
  local now = vim.uv.now()
  if now - (repo_last[repo] or 0) < (opts.repo_debounce_ms or 0) then
    return false
  end
  if repo_in_flight[repo] then
    repo_again[repo] = true
    return false
  end
  repo_in_flight[repo] = true
  repo_last[repo] = now
  refresh_sequence = refresh_sequence + 1
  local version = refresh_sequence
  enqueue_scan(repo, opts, function(entry)
    repo_in_flight[repo] = nil
    -- Discovery and initial scans may not have populated the scope yet.
    for root, cached in pairs(scopes) do
      local in_scope = within(repo, root) or within(root, repo)
      if in_scope and version >= (cached.versions[repo] or 0) then
        cached.entries[repo], cached.versions[repo] = entry, version
      end
    end
    cb(entry)
    if repo_again[repo] then
      repo_again[repo] = nil
      -- Reset the stamp so the coalesced re-run isn't itself dropped by
      -- the debounce window it would otherwise still be inside.
      repo_last[repo] = 0
      M.refresh_repo(repo, opts, cb)
    end
  end)
  return true
end

-- The newest Repo Entries Core holds for root, sorted like a refresh delivers them, or
-- nil before root's first discovery. Renderers show these while a refresh runs, so opening
-- the Panel never waits on git. Scoped refreshes of one repository are included.
function M.cached(root)
  root = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.expand(root)) or vim.fn.expand(root))
  local cached = scopes[root]
  if not cached or not cached.repos then
    return nil
  end
  local entries = {}
  for _, repo in ipairs(cached.repos) do
    entries[#entries + 1] = cached.entries[repo]
  end
  table.sort(entries, M.compare_entries)
  return entries
end

-- Collect everything the first open shows, committed history included, so the Panel
-- opens with its files and does not wait on git. Each repository's status is kept as
-- soon as it is known, for an open that comes before the warm-up ends.
-- An open during warm-up joins queued scans instead of starting duplicate Git work.
-- Returns true when it started one. A failure is dropped; the next open reports it.
-- done(), when given, runs once the warm-up it started has finished.
function M.warm(root, opts, done)
  root = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.expand(root)) or vim.fn.expand(root))
  if scopes[root] then
    return false
  end
  return M.refresh(root, opts, function(entries)
    if entries and done then
      done()
    end
  end, {})
end

-- Omitting request preserves the public full-discovery refresh behavior.
-- Renderers pass cached=true and optional paths to reuse discovery for ordinary editor events.
-- progress(entries), when given, is called as each repository lands before the last;
-- preliminary(entries) publishes a new repository's status before committed history lands.
-- cb is still called exactly once.
function M.refresh(root, opts, cb, request, progress, preliminary)
  root = vim.fs.normalize(vim.uv.fs_realpath(vim.fn.expand(root)) or vim.fn.expand(root))
  local cached = scopes[root]
  if not cached then
    cached = {entries={}, versions={}, membership_version=0}
    scopes[root] = cached
  end
  refresh_sequence = refresh_sequence + 1
  local version = refresh_sequence
  local targets = {}
  local discover = not request or not request.cached or not cached.repos
  if not discover and request.paths then
    for path in pairs(request.paths) do
      path = vim.fs.normalize(vim.uv.fs_realpath(path) or path)
      local containing
      for _, repo in ipairs(cached.repos) do
        if within(path, repo) and (not containing or #repo > #containing) then containing = repo end
      end
      if containing then targets[containing] = true
      elseif within(path, root) then discover = true end
    end
  end
  local function collect(repos, err)
    if err then cb(nil, err); return end
    if discover and version >= cached.membership_version then
      cached.repos, cached.membership_version = repos, version
    end
    local snapshot = {}
    for _, repo in ipairs(repos) do
      snapshot[repo] = cached.entries[repo]
    end
    local selected = {}
    for _, repo in ipairs(repos) do
      if discover or not request.paths or targets[repo] or not snapshot[repo] then
        selected[#selected + 1] = repo
      end
    end
    local pending = #selected
    -- Before the last repository lands, progress gets the same list with each repository
    -- not scanned yet showing its cached entry, or left out on a root never seen before.
    local function publish(deliver)
      local entries = {}
      for _, repo in ipairs(repos) do
        entries[#entries + 1] = cached.entries[repo] or snapshot[repo]
      end
      table.sort(entries, M.compare_entries)
      deliver(entries, nil)
    end
    if pending == 0 then publish(cb); return end
    for _, repo in ipairs(selected) do
      enqueue_scan(repo, opts, function(entry)
        snapshot[repo] = entry
        if version >= (cached.versions[repo] or 0) then
          cached.entries[repo], cached.versions[repo] = entry, version
        end
        pending = pending - 1
        if pending == 0 then
          publish(cb)
        elseif progress then
          publish(progress)
        end
      end, request and request.status_only, not snapshot[repo] and function(entry)
        snapshot[repo] = entry
        -- A repository seen for the first time is cached by its status alone
        -- until its history lands, so an open meanwhile has something to show.
        if cached.entries[repo] == nil then
          cached.entries[repo] = entry
        end
        if preliminary then
          publish(preliminary)
        end
      end, snapshot[repo], request and request.reuse_history)
    end
  end
  if discover then return M.discover(root, opts, collect) end
  collect(cached.repos)
  return true
end

return M
