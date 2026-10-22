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
  -- Minimum ms between two full multi-repo rescans triggered by focus events.
  focus_debounce_ms = 1500,
  -- Directory names discovery never descends into. Build output and dependency
  -- trees can hold millions of files and would push the walk past discovery_timeout_ms.
  -- A list given in setup replaces this one; {} searches everything.
  discovery_exclude = {
    "node_modules", "target", ".venv", "venv", "__pycache__", ".tox", ".mypy_cache",
    ".pytest_cache", ".gradle", ".next", ".terraform", ".zig-cache", "zig-cache", "DerivedData",
  },
}

-- find arguments: skip excluded directory names below the root, then stop at each
-- .git entry (a directory, or a worktree's .git file) and print it.
local function find_args(root, exclude)
  local args = { "find", root, "-mindepth", "1" }
  if #exclude > 0 then
    vim.list_extend(args, { "-type", "d", "(" })
    for i, name in ipairs(exclude) do
      if i > 1 then
        args[#args + 1] = "-o"
      end
      vim.list_extend(args, { "-name", name })
    end
    vim.list_extend(args, { ")", "-prune", "-o" })
  end
  vim.list_extend(args, { "-name", ".git", "-prune", "-print" })
  return args
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
        files[#files + 1] = { path = rest:match("^([^\t]+)"), xy = xy }
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
    local path
    if status:match("^[RC]") then
      index = index + 1
      path = fields[index]
      index = index + 1
    else
      path = fields[index]
      index = index + 1
    end
    if path then
      files[#files + 1] = { path = path, commit_status = status }
    end
  end
  return files
end

local function merge_files(committed, pending)
  local by_path = {}
  for _, file in ipairs(committed) do
    by_path[file.path] = file
  end
  for _, file in ipairs(pending) do
    by_path[file.path] = file
  end
  local files = vim.tbl_values(by_path)
  table.sort(files, function(a, b)
    return a.path < b.path
  end)
  return files
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
      if landed.find.code ~= 0 then
        -- vim.system reports a killed-on-timeout process as exit code 124.
        if landed.find.code == 124 then
          local limit = opts.discovery_timeout_ms or M.defaults.discovery_timeout_ms
          cb(nil, string.format(
            "repository discovery timed out after %g s; add large folders to discovery_exclude",
            limit / 1000
          ))
          return
        end
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
    function(out)
      finish("parent", out)
    end
  )
  vim.system(
    find_args(root, opts.discovery_exclude or M.defaults.discovery_exclude),
    { text = true, timeout = opts.discovery_timeout_ms or M.defaults.discovery_timeout_ms },
    function(out)
      finish("find", out)
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
local function build_entry(repo, out, committed, comparison_base)
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
  vim.system(cmd, { text = true, timeout = opts.timeout_ms }, function(out)
    vim.schedule(function()
      cb(out)
    end)
  end)
end

local comparison_refs = { "refs/remotes/origin/HEAD", "refs/heads/main", "refs/heads/master" }

local function resolve_comparison_base(repo, opts, index, cb)
  local ref = comparison_refs[index]
  if not ref then
    cb(nil, nil)
    return
  end
  run_git(repo, opts, { "merge-base", ref, "HEAD" }, function(out)
    local base = vim.trim(out.stdout or "")
    if out.code == 0 and base ~= "" then
      cb(base, ref)
    else
      resolve_comparison_base(repo, opts, index + 1, cb)
    end
  end)
end

local function collect_committed(repo, opts, cb)
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
  end)
end

local function scan_repo(repo, opts, cb)
  run_git(repo, opts, { "status", "--porcelain=v2", "--branch" }, function(out)
    if out.code ~= 0 then
      cb(build_entry(repo, out))
      return
    end
    collect_committed(repo, opts, function(committed, comparison_base)
      cb(build_entry(repo, out, committed, comparison_base))
    end)
  end)
end

local scan_queue, scans_running = {}, 0
local function drain_scans()
  while scans_running < 4 and #scan_queue > 0 do
    local job = table.remove(scan_queue, 1)
    scans_running = scans_running + 1
    scan_repo(job.repo, job.opts, function(entry)
      scans_running = scans_running - 1
      job.cb(entry)
      drain_scans()
    end)
  end
end
local function enqueue_scan(repo, opts, cb)
  scan_queue[#scan_queue + 1] = {repo=repo, opts=opts, cb=cb}
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

-- Omitting request preserves the public full-discovery refresh behavior.
-- Renderers pass cached=true and optional paths to reuse discovery for ordinary editor events.
function M.refresh(root, opts, cb, request)
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
    local function publish()
      local entries = {}
      for _, repo in ipairs(repos) do
        entries[#entries + 1] = cached.entries[repo] or snapshot[repo]
      end
      table.sort(entries, M.compare_entries)
      cb(entries, nil)
    end
    if pending == 0 then publish(); return end
    for _, repo in ipairs(selected) do
      enqueue_scan(repo, opts, function(entry)
        snapshot[repo] = entry
        if version >= (cached.versions[repo] or 0) then
          cached.entries[repo], cached.versions[repo] = entry, version
        end
        pending = pending - 1
        if pending == 0 then publish() end
      end)
    end
  end
  if discover then return M.discover(root, opts, collect) end
  collect(cached.repos)
  return true
end

return M
