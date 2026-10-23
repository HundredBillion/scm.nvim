vim.opt.runtimepath:prepend(vim.uv.cwd())
local core = require('scm.core')
local discovery, scans, renders = 0, {}, 0
local delay = 5
core.discover = function(_, _, cb)
  discovery = discovery + 1
  vim.schedule(function() cb({'/scope/a','/scope/b'}) end)
  return true
end
vim.system = function(cmd, _, cb)
  if cmd[4] == 'status' then scans[cmd[3]] = (scans[cmd[3]] or 0) + 1 end
  vim.defer_fn(function() cb({code=cmd[4] == 'status' and 0 or 1,
    stdout='# branch.head main\n', stderr=''}) end, delay)
end
local rows, action
package.loaded['scm.views.terminal'] = {open=function(_, callback)
  action = callback
  return {render=function(_, value) rows=value; renders=renders+1 end, close=function() end}
end}
require('scm.scope').current = function() return '/scope' end
-- The warm-up targets the same root, so opening in the same tick must leave it nothing to do.
require('scm.scope').candidate = function() return '/scope' end
local workspace = require('scm.workspace')
workspace.setup({renderer='terminal', repo_debounce_ms=20})
workspace.toggle()
local function wait_scans(a,b)
  assert(vim.wait(2000, function() return scans['/scope/a']==a and scans['/scope/b']==b end), vim.inspect(scans))
  vim.wait(100, function() return false end)
end
wait_scans(1,1)
local buf = vim.api.nvim_create_buf(true,false)
vim.api.nvim_buf_set_name(buf, '/scope/a/file.lua')
for _=1,12 do vim.api.nvim_exec_autocmds('BufWritePost',{buffer=buf}) end
wait_scans(2,1)
assert(discovery==1, 'save burst reuses discovery')
for _=1,12 do vim.api.nvim_exec_autocmds('FocusGained',{}) end
wait_scans(3,2)
assert(discovery==1, 'focus burst reuses discovery')
action('refresh')
wait_scans(4,3)
assert(discovery==2, 'explicit refresh discovers')
vim.api.nvim_exec_autocmds('BufWritePost',{buffer=buf})
workspace.close()
local before = renders
vim.wait(100, function() return false end)
assert(renders==before and scans['/scope/a']==4, 'closed view discards delayed event')
workspace.toggle()
workspace.close()
before = renders
vim.wait(150, function() return false end)
assert(renders==before, 'closed view discards in-flight result')
workspace.toggle()
wait_scans(6,5)
assert(rows[1].text:find('a',1,true), 'reopened view receives fresh entries')
workspace.close()
print('OK refresh events: 12 saves = 1 scan; 12 focus events = 2 scans; no rediscovery')

workspace.toggle()
wait_scans(7,6)
delay=60
local before_renders, before_discovery = renders, discovery
vim.api.nvim_exec_autocmds('BufWritePost',{buffer=buf})
assert(vim.wait(1000,function() return scans['/scope/a']==8 end),'first save starts')
for _=1,12 do vim.api.nvim_exec_autocmds('BufWritePost',{buffer=buf}) end
assert(vim.wait(2000,function() return renders>before_renders end),'in-flight invalidation publishes')
assert(scans['/scope/a']==9 and scans['/scope/b']==6,'in-flight save burst schedules exactly one targeted replay')
assert(renders==before_renders+1,'superseded result does not render')
assert(discovery==before_discovery,'in-flight replay reuses discovery')
workspace.close()
print('OK in-flight save burst: one targeted replay, one publication')
