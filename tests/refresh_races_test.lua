vim.opt.runtimepath:prepend(vim.uv.cwd())
local core = require('scm.core')
local repos, pending = {'/scope/a','/scope/b'}, {}
local failure
core.discover = function(_, _, cb) cb(vim.deepcopy(repos), failure); return true end
vim.system = function(cmd, _, cb)
  if cmd[4] == 'status' then
    pending[#pending+1] = {repo=cmd[3], cb=cb}
  else
    vim.schedule(function() cb({code=1,stdout='',stderr=''}) end)
  end
end
local function finish(repo, branch, code)
  for i, job in ipairs(pending) do
    if job.repo==repo then
      table.remove(pending,i)
      job.cb({code=code or 0,stdout='# branch.head ' .. branch .. '\n',stderr='failed Git'})
      vim.wait(20, function() return false end)
      return
    end
  end
  error('no pending scan for ' .. repo)
end
local opts, latest = {repo_debounce_ms=0}, nil
local function refresh(request)
  core.refresh('/scope', opts, function(entries, err) latest={entries=entries,err=err} end, request)
end
local function branches()
  local result={}
  for _, e in ipairs(latest.entries) do result[e.path]=e.branch end
  return result
end
refresh()
finish('/scope/a','initial-a'); finish('/scope/b','initial-b')
refresh()
refresh({cached=true,paths={['/scope/b/file']=true}})
local old_b = table.remove(pending,2)
finish('/scope/b','new-b')
finish('/scope/a','old-a')
old_b.cb({code=0,stdout='# branch.head old-b\n',stderr=''})
vim.wait(20,function() return false end)
refresh({cached=true,paths={['/scope/a/file']=true}})
finish('/scope/a','new-a')
assert(branches()['/scope/b']=='new-b','older full result cannot poison cached sibling')
core.refresh_repo('/scope/b',opts,function() end)
finish('/scope/b','scoped-b')
refresh({cached=true,paths={['/scope/a/file']=true}})
finish('/scope/a','new-a')
assert(branches()['/scope/b']=='scoped-b','legacy scoped update survives targeted save')
refresh()
repos={'/scope/a','/scope/new'}
refresh()
local old_a, removed_b = table.remove(pending,1), table.remove(pending,1)
finish('/scope/a','new'); finish('/scope/new','new')
old_a.cb({code=0,stdout='# branch.head older\n',stderr=''})
removed_b.cb({code=0,stdout='# branch.head older\n',stderr=''})
vim.wait(20,function() return false end)
refresh({cached=true,paths={['/scope/a/file']=true}})
finish('/scope/a','new')
assert(branches()['/scope/new'] and not branches()['/scope/b'],'new membership survives older refresh')
failure='discovery failed'
refresh()
assert(latest.err=='discovery failed','discovery failure delivered')
failure=nil
refresh({cached=true,paths={['/scope/a/file']=true}})
finish('/scope/a','?',1)
assert(latest.entries[1].err=='failed Git','Git error remains a Repo Entry')
assert(branches()['/scope/new']=='new','discovery failure preserves cached membership')
print('OK refresh races and errors')
