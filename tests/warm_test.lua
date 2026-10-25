-- Warm-up: after startup, Core scans the Working Directory once so the first open has rows.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local core = require("scm.core")
local scm = require("scm")

local function eq(got, want, label)
  assert(
    vim.deep_equal(got, want),
    ("%s\nexpected: %s\ngot:      %s"):format(label or "mismatch", vim.inspect(want), vim.inspect(got))
  )
end

local function repo()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  assert(vim.system({ "git", "-C", dir, "init", "-q", "-b", "main" }):wait().code == 0)
  return vim.uv.fs_realpath(dir)
end

-- Count Core refreshes per root without changing what they do.
local real_refresh, refreshes = core.refresh, {}
core.refresh = function(root, ...)
  refreshes[root] = (refreshes[root] or 0) + 1
  return real_refresh(root, ...)
end

for _, renderer in ipairs({ "auto", "terminal" }) do
  local root = repo()
  vim.cmd.cd(root)
  scm.setup({ renderer = renderer })
  assert(vim.wait(5000, function()
    return core.cached(root) ~= nil
  end, 10), renderer .. ": warm-up fills the cache for the Working Directory without opening SCM")
  eq(refreshes[root], 1, renderer .. ": warm-up refreshes once")
  scm.setup({ renderer = renderer })
  vim.wait(100)
  eq(refreshes[root], 1, renderer .. ": setting up again does not warm a root already scanned")
end

local staged = repo()
local function git(...)
  local out = vim.system({ "git", "-C", staged, ... }):wait()
  assert(out.code == 0, out.stderr)
end
vim.fn.writefile({ "base" }, staged .. "/base.txt")
git("add", ".")
git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base")
git("checkout", "-qb", "feature")
vim.fn.writefile({ "committed" }, staged .. "/committed.txt")
git("add", ".")
git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "feature")
vim.fn.writefile({ "working" }, staged .. "/working.txt")
vim.cmd.cd(staged)
scm.setup({ renderer = "terminal" })
assert(vim.wait(5000, function()
  local entries = core.cached(staged)
  return entries and entries[1] and #entries[1].files > 0
end, 10), "startup publishes working changes")
local warm_files = core.cached(staged)[1].files
eq(#warm_files, 1, "warm-up collects status before committed history")
eq(warm_files[1].path, "working.txt", "working change is immediately visible")
local complete
core.refresh(staged, core.defaults, function(entries) complete = entries end, { cached = true })
assert(vim.wait(5000, function() return complete ~= nil end, 10), "open completes history")
eq(#complete[1].files, 2, "opening fills committed history")

-- A refresh started before the warm-up runs (an open right after a lazy load) is not doubled.
local opened = repo()
vim.cmd.cd(opened)
scm.setup({ renderer = "terminal" })
core.refresh(opened, core.defaults, function() end)
vim.wait(200)
eq(refreshes[opened], 1, "warm-up skips a root whose refresh already started")

-- warm = false turns it off; a warm-up whose discovery fails stays silent.
local off = repo()
vim.cmd.cd(off)
scm.setup({ renderer = "terminal", warm = false })
vim.wait(200)
eq(refreshes[off], nil, "warm = false does not scan at startup")

local gone = vim.fn.tempname()
vim.fn.mkdir(gone, "p")
vim.cmd.cd(gone)
local notified
local real_notify = vim.notify
vim.notify = function(msg) notified = msg end
vim.fn.delete(gone, "rf")
scm.setup({ renderer = "terminal" })
vim.wait(200)
vim.notify = real_notify
eq(notified, nil, "a failed warm-up shows nothing; the next open reports the error")

core.refresh = real_refresh
print("OK warm-up")
