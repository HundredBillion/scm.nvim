vim.opt.runtimepath:prepend(vim.uv.cwd())
local core = require('scm.core')
local discovery, scans, active, peak, scanning, scan_peak = 0, {}, 0, 0, 0, 0
local repos = {'/scope/a', '/scope/b'}
core.discover = function(_, _, cb)
  discovery = discovery + 1
  vim.schedule(function() cb(vim.deepcopy(repos)) end)
  return true
end
vim.system = function(cmd, _, cb)
  local repo, operation = cmd[3], cmd[4]
  active = active + 1
  peak = math.max(peak, active)
  if operation == 'status' then
    scans[repo] = (scans[repo] or 0) + 1
    scanning = scanning + 1
    scan_peak = math.max(scan_peak, scanning)
  end
  vim.defer_fn(function()
    active = active - 1
    if operation == 'status' then scanning = scanning - 1 end
    cb({code=operation == 'status' and 0 or 1, stdout='# branch.head main\n', stderr=''})
  end, 5)
end
local function refresh(request)
  local done, result
  core.refresh('/scope', {timeout_ms=5000}, function(entries, err)
    assert(not err, err)
    result, done = entries, true
  end, request)
  assert(vim.wait(2000, function() return done end), 'refresh completes')
  return result
end
refresh()
refresh({cached=true, paths={['/scope/a/file.lua']=true}})
assert(discovery == 1, 'save should reuse discovery; got ' .. discovery)
assert(scans['/scope/a'] == 2 and scans['/scope/b'] == 1, 'save scans only containing repo')
refresh({cached=true, paths={['/outside/file']=true}})
assert(scans['/scope/a'] == 2 and scans['/scope/b'] == 1, 'outside save does not scan')
refresh({cached=true})
assert(discovery == 1, 'focus reuses discovery')
repos[#repos+1] = '/scope/new'
assert(#refresh({cached=true, paths={['/scope/new/file']=true}}) == 3, 'unknown repo save rediscovers')
assert(discovery == 2, 'unknown path discovers once')
refresh()
assert(discovery == 3, 'explicit refresh rediscovers')
for i=1,12 do repos[#repos+1] = '/scope/r' .. i end
refresh()
assert(core.SCAN_LIMIT >= 4 and core.SCAN_LIMIT <= 8, 'between four and eight repositories are scanned at once')
assert(scan_peak <= core.SCAN_LIMIT, 'repository scans are bounded; peak=' .. scan_peak)
-- A scan reads status beside history: at most two git commands at a time.
assert(peak <= core.SCAN_LIMIT * 2, 'git processes are bounded; peak=' .. peak)
local done
core.refresh('/other', {}, function() done=true end, {cached=true})
assert(vim.wait(2000,function() return done end), 'new root completes')
assert(discovery == 5, 'root change discovers its own scope')
repos[#repos+1] = '/scope/a/nested'
refresh()
local parent_scans = scans['/scope/a']
refresh({cached=true,paths={['/scope/a/nested/file']=true}})
assert(scans['/scope/a']==parent_scans, 'nested save selects deepest containing repository')
-- Overlapping refreshes (an open during the startup warm-up) share scans still waiting in
-- the queue, which start after both requests. Scans start one per turn of the event loop,
-- so two refreshes made together share every scan.
local before, results = vim.deepcopy(scans), {}
for i = 1, 2 do
  core.refresh('/scope', {timeout_ms=5000}, function(entries) results[i] = entries end, {cached=true})
end
assert(vim.wait(2000, function() return results[1] and results[2] end), 'overlapping refreshes complete')
local added, rescanned = 0, 0
for _, repo in ipairs(repos) do
  local delta = (scans[repo] or 0) - (before[repo] or 0)
  added = added + delta
  if delta == 2 then rescanned = rescanned + 1 end
end
assert(#results[1] == #repos and #results[2] == #repos, 'both refreshes deliver every repository')
assert(rescanned == 0, 'no repository is scanned twice; got ' .. rescanned)
assert(added == #repos, 'queued scans are shared; status calls=' .. added .. ' for ' .. #repos .. ' repos')
-- Scans already running are not shared: they may predate the newer request.
before, results = vim.deepcopy(scans), {}
core.refresh('/scope', {timeout_ms=5000}, function(entries) results[1] = entries end, {cached=true})
assert(vim.wait(2000, function() return scanning > 0 end, 1), 'the first refresh starts scanning')
local running = scanning
core.refresh('/scope', {timeout_ms=5000}, function(entries) results[2] = entries end, {cached=true})
assert(vim.wait(2000, function() return results[1] and results[2] end), 'staggered refreshes complete')
rescanned = 0
for _, repo in ipairs(repos) do
  if (scans[repo] or 0) - (before[repo] or 0) == 2 then rescanned = rescanned + 1 end
end
assert(rescanned >= running and rescanned <= core.SCAN_LIMIT,
  'only scans already running are repeated; running=' .. running .. ' repeated=' .. rescanned)
print('OK refresh policy: discovery=' .. discovery .. ', peak Git jobs=' .. peak)
