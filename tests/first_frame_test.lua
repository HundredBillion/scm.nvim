-- Opening the Panel shows what Core already holds at once: the first screen of
-- rows goes to the host before the rest of a long list, and before git is
-- asked anything, because starting git processes holds Neovim.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local core, model = require('scm.core'), require('scm.model')
local sprite_view = require('scm.views.sprite')

-- Sorting files into groups in one pass agrees with the badge of every code.
local codes = {'??', 'DD', 'AU', 'UD', 'UA', 'DU', 'AA', 'UU'}
for _, x in ipairs({'.', 'M', 'T', 'A', 'D', 'R', 'C'}) do
  for _, y in ipairs({'.', 'M', 'T', 'A', 'D', 'R', 'C'}) do codes[#codes + 1] = x .. y end
end
local every = {{path='c', commit_status='M'}}
for i, xy in ipairs(codes) do every[#every + 1] = {path='f' .. i, xy=xy} end
local got, want = {}, {}
for _, row in ipairs(model.rows({{path='/r', name='r', branch='main', files=every}}, {})) do
  if row.kind == 'file' then got[row.group .. ':' .. row.path] = row.badge.text end
end
for _, group in ipairs(model.GROUPS) do
  for _, file in ipairs(every) do
    local badge = model.badge(group.key, file)
    if badge then want[group.key .. ':' .. file.path] = badge.text end
  end
end
assert(vim.deep_equal(got, want), 'every status code lands in the groups its badge names')
-- A group past its limit keeps its true count and lists only the limit.
local many = {}
for i = 1, 50 do many[i] = {path=('f%03d'):format(i), xy='.M'} end
local limited = model.rows({{path='/r', name='r', branch='main', files=many}}, {limit=10})
local listed, group_row, note = 0, nil, nil
for _, row in ipairs(limited) do
  if row.kind == 'file' then listed = listed + 1 end
  if row.kind == 'group' then group_row = row end
  if row.kind == 'note' then note = row end
end
assert(listed == 10 and group_row.count == '50' and note.label == '40 more not shown', 'a long group is counted in full and listed to its limit')

-- A repository with more rows than a first screen.
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
assert(vim.system({'git', '-C', root, 'init', '-q', '-b', 'main'}):wait().code == 0)
local total = sprite_view.FIRST_ROWS + 60
for i = 1, total do vim.fn.writefile({'x'}, ('%s/file%03d.lua'):format(root, i)) end
vim.cmd.cd(root)

local events, waiting = {}, {}
local real_system = vim.system
vim.system = function(cmd, ...)
  if cmd[1] == 'git' then events[#events + 1] = 'git' end
  return real_system(cmd, ...)
end
package.loaded.sprite = {open=function(_, cb)
  cb(nil, {
    features={['virtual-list-rows-v2']=true},
    assets=function(_, entries, done)
      events[#events + 1] = 'assets:' .. vim.tbl_count(entries)
      waiting[#waiting + 1] = done
    end,
    rows=function(_, _, rows, _, done)
      events[#events + 1] = 'rows:' .. #rows
      waiting[#waiting + 1] = done
    end,
    state=function(_, _, _, done) done() end,
    focus=function(_, done) if done then done() end end,
    focus_editor=function(_, done) if done then done() end end,
    close=function() end,
  })
end}
local function ack() while #waiting > 0 do table.remove(waiting, 1)() end end

local scm = require('scm')
scm.setup({renderer='auto'})
-- The warm-up holds the repository before the Panel is asked for.
assert(vim.wait(5000, function()
  local entries = core.cached(root)
  return entries and entries[1] and #entries[1].files == total
end, 10), 'the warm-up collects the files')
vim.wait(100)
events = {}
scm.toggle()
-- Nothing has been acknowledged: only the first screen is on its way.
assert(events[1] and events[1]:match('^assets:') and #events == 1,
  'one message registers the header\'s icons and the first rows\' together, got ' .. vim.inspect(events))
ack()
assert(events[2] == 'rows:' .. sprite_view.FIRST_ROWS, 'the first screen of rows is sent on its own, got ' .. vim.inspect(events))
assert(not vim.tbl_contains(events, 'git'), 'git is not asked anything before the first screen is acknowledged')
ack()
-- Rows: commit box, button, the Changes group, then every file.
assert(vim.wait(5000, function() ack(); return vim.tbl_contains(events, 'rows:' .. (total + 3)) end, 10),
  'the whole list follows, got ' .. vim.inspect(events))
assert(vim.wait(5000, function() return vim.tbl_contains(events, 'git') end, 10), 'and then git is asked again')
local first_git, whole
for i, event in ipairs(events) do
  if event == 'git' and not first_git then first_git = i end
  if event == 'rows:' .. (total + 3) and not whole then whole = i end
end
assert(first_git > 2, 'the rescan starts after the first screen, at event ' .. first_git)
scm.toggle()

-- A short list is sent whole, once.
vim.system = real_system
local small = vim.fn.tempname()
vim.fn.mkdir(small, 'p')
assert(vim.system({'git', '-C', small, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, small .. '/only.lua')
vim.cmd.cd(small)
events = {}
scm.setup({renderer='auto', warm=false})
scm.toggle()
assert(vim.wait(5000, function() ack(); return vim.tbl_contains(events, 'rows:4') end, 10), 'a short list is sent whole')
scm.toggle()
print('OK first frame: the first screen is sent before the rest and before git')
