vim.opt.runtimepath:prepend(vim.uv.cwd())
local core = require('scm.core')
local discovery, scans, active, peak = 0, {}, 0, 0
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
  if operation == 'status' then scans[repo] = (scans[repo] or 0) + 1 end
  vim.defer_fn(function()
    active = active - 1
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
assert(peak <= 4, 'repository scans bounded to four; peak=' .. peak)
local done
core.refresh('/other', {}, function() done=true end, {cached=true})
assert(vim.wait(2000,function() return done end), 'new root completes')
assert(discovery == 5, 'root change discovers its own scope')
repos[#repos+1] = '/scope/a/nested'
refresh()
local parent_scans = scans['/scope/a']
refresh({cached=true,paths={['/scope/a/nested/file']=true}})
assert(scans['/scope/a']==parent_scans, 'nested save selects deepest containing repository')
print('OK refresh policy: discovery=' .. discovery .. ', peak Git jobs=' .. peak)
