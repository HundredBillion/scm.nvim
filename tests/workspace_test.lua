vim.opt.runtimepath:prepend(vim.uv.cwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
local function git(...)
  local args = {'git', '-C', root}
  vim.list_extend(args, {...})
  local result = vim.system(args, {text=true}):wait()
  assert(result.code == 0, result.stderr)
end
git('init', '-b', 'main')
git('config', 'user.email', 'test@example.com')
git('config', 'user.name', 'Test')
vim.fn.writefile({'before'}, root .. '/sample.lua')
git('add', '.')
git('commit', '-m', 'initial')
vim.fn.writefile({'after'}, root .. '/sample.lua')
vim.cmd.cd(root)
local scm = require('scm')
scm.setup({renderer='terminal'})
scm.toggle()
local function panel()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return win end
  end
end
assert(vim.wait(5000, function()
  local win = panel()
  if not win then return false end
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n'):find('sample.lua', 1, true)
end), 'standalone panel shows changed file without Snacks')
assert(not package.loaded.snacks and not _G.Snacks)
local win = panel()
vim.api.nvim_set_current_win(win)
vim.api.nvim_win_set_cursor(win, {4,0})
local function press(key)
  local mapping = vim.fn.maparg(key, 'n', false, true)
  assert(type(mapping.callback) == 'function', 'mapping exists: '..key)
  mapping.callback()
end
press('<CR>')
assert(vim.api.nvim_buf_get_name(0) == root .. '/sample.lua', 'opens file in editor')
assert(vim.api.nvim_get_current_win() ~= win, 'sidebar is preserved')
vim.fn.writefile({'new'}, root .. '/second.lua')
vim.api.nvim_exec_autocmds('FocusGained', {})
assert(vim.wait(5000, function()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win),0,-1,false),'\n'):find('second.lua',1,true)
end), 'refresh adds new file')
assert(vim.api.nvim_win_get_cursor(win)[1] == 4, 'refresh keeps selected file')
vim.api.nvim_set_current_win(win)
press('h')
assert(vim.api.nvim_win_get_cursor(win)[1] == 3, 'h selects repository')
press('h')
assert(vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) == 3, 'h collapses repository')
press('l')
assert(vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win)) == 5, 'l expands repository')
scm.toggle()
assert(vim.wait(1000, function() return not panel() end), 'toggle closes panel')
local function panel_text()
  return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(assert(panel())), 0, -1, false), '\n')
end
-- Reopening shows the last rows at once, before git answers, then each repository as it lands.
local core = require('scm.core')
local real_refresh, progress = core.refresh, nil
core.refresh = function(_, _, _, _, on_progress) progress = on_progress end
scm.toggle()
assert(panel_text():find('second.lua', 1, true), 'reopen shows cached rows before any git result')
assert(progress, 'the reopen refresh accepts progress')
progress({{name='repo', path=root, branch='main', ahead=0, behind=0, clean=false,
  files={{path='landed.lua', xy='.M'}}}})
assert(panel_text():find('landed.lua', 1, true), 'a repository that lands is rendered before the refresh ends')
scm.toggle()
core.refresh = real_refresh
local requested, tree_closed
package.loaded.svgtree = {root=function() return vim.fn.tempname() end, close=function() tree_closed=true end}
scm.setup({renderer='terminal', on_explorer=function(path) requested=path end})
scm.toggle()
assert(not tree_closed, 'opening the Panel leaves the file tree alone')
package.loaded.svgtree = nil
vim.api.nvim_set_current_win(assert(panel()))
press('<Space>e')
assert(requested==root, 'Explorer callback receives SCM root')
assert(panel(), 'integration callback owns handoff')
scm.toggle()
-- Without on_explorer the key explains itself and never opens a file tree.
package.loaded.svgtree = {open=function() error('SCM must not open SVGTree') end}
scm.setup({renderer='terminal'})
scm.toggle()
vim.api.nvim_set_current_win(assert(panel()))
local message
local real_notify = vim.notify
vim.notify = function(msg) message = msg end
press('<Space>e')
vim.notify = real_notify
assert(message == 'SCM: No file explorer is connected, so there\'s nothing to open. See "Connecting a file explorer" in the README.', tostring(message))
assert(panel(), 'the Panel stays open when no file explorer is connected')
scm.toggle()
package.loaded.svgtree = nil
-- The Panel follows the Working Directory of its editor window.
local second = vim.fn.tempname()
vim.fn.mkdir(second, 'p')
second = vim.uv.fs_realpath(second)
assert(vim.system({'git', '-C', second, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, second .. '/moved.lua')
scm.setup({renderer='terminal'})
local editor = vim.api.nvim_get_current_win()
scm.toggle()
assert(vim.wait(5000, function() return panel_text():find('sample.lua', 1, true) end), 'Panel starts on the first repository')
vim.api.nvim_set_current_win(editor)
vim.cmd.cd(second)
assert(vim.wait(5000, function()
  local text = panel_text()
  return text:find('moved.lua', 1, true) and not text:find('sample.lua', 1, true)
end), ':cd in the editor window moves the Panel')

vim.cmd('split')
vim.cmd.lcd(root)
vim.wait(300)
assert(panel_text():find('moved.lua', 1, true), ':lcd in another window leaves the Panel where it is')
vim.cmd('close')
vim.api.nvim_set_current_win(editor)

-- A slow scan of the old directory never replaces the new directory's rows.
local real_core_refresh, runs = core.refresh, {}
core.refresh = function(dir, _, done) runs[#runs+1] = {dir=dir, done=done} end
vim.cmd.cd(root)
assert(panel_text():find('sample.lua', 1, true), 'the new directory shows its cached rows at once')
vim.cmd.cd(second)
assert(panel_text():find('moved.lua', 1, true), 'cached rows again after moving back')
runs[1].done({{name='old', path=root, branch='main', ahead=0, behind=0, clean=false,
  files={{path='stale.lua', xy='.M'}}}})
assert(not panel_text():find('stale.lua', 1, true), 'the old directory result is discarded')
assert(vim.wait(1000, function() return runs[2] and runs[2].dir == second end), 'the new directory is scanned next')
runs[2].done({{name='new', path=second, branch='main', ahead=0, behind=0, clean=false,
  files={{path='fresh.lua', xy='.M'}}}})
assert(panel_text():find('fresh.lua', 1, true), 'the new directory result is shown')
core.refresh = real_core_refresh

scm.toggle()
local refreshed = false
core.refresh = function() refreshed = true end
vim.cmd.cd(root)
vim.wait(200)
assert(not refreshed and not panel(), 'a directory change while closed does nothing')
core.refresh = real_core_refresh
vim.fn.delete(root, 'rf')
print('OK standalone workspace')
