-- Opening a file from the Panel uses the window of a throwaway page, such as
-- an editor's start screen, instead of leaving that page beside the file.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
assert(vim.system({'git', '-C', root, 'init', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, root .. '/hello.lua')
vim.cmd.cd(root)
local hello = vim.uv.fs_realpath(root) .. '/hello.lua'

-- A start screen as VSVim makes one: an unlisted scratch buffer wiped when hidden.
local function start_screen()
  vim.cmd('silent! only')
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].filetype = 'welcome'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {'welcome'})
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
  return buf, vim.api.nvim_get_current_win()
end
local function filetypes()
  local found = {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    found[#found + 1] = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
  end
  table.sort(found)
  return found
end

local request, dock
local waiting = {}
package.loaded.sprite = {open=function(opts, cb)
  request = opts
  dock = {
    features={['virtual-list-rows-v2']=true},
    assets=function(_, _, done) done() end,
    rows=function(_, revision, rows, selected, done)
      dock.revision, dock.rows_value, dock.selected = revision, rows, selected
      waiting[#waiting + 1] = done
    end,
    state=function(_, _, state, done) dock.selected = state.selected; waiting[#waiting + 1] = done end,
    focus=function(_, done) if done then done() end end,
    focus_editor=function(_, done) if done then done() end end,
    close=function() end,
  }
  cb(nil, dock)
end}
local function ack() while #waiting > 0 do table.remove(waiting, 1)() end end
local function file_row()
  for _, row in ipairs(dock and dock.rows_value or {}) do
    if row.text == 'hello.lua' then return row end
  end
end
local scm = require('scm')
-- The windows that hold text: a diff's overview strip floats over its window.
local function windows()
  return #vim.tbl_filter(function(win) return vim.api.nvim_win_get_config(win).relative == '' end,
    vim.api.nvim_tabpage_list_wins(0))
end
-- Selecting a file shows its diff, once git has answered.
local function diff_shown()
  return vim.wait(5000, function() return vim.api.nvim_buf_get_name(0) == 'scm://' .. hello .. ' (diff)' end, 20)
end

-- Native Panel: the dock is not a window, so the start screen is the only one.
local welcome, window = start_screen()
scm.setup({renderer='auto'})
scm.toggle()
assert(vim.wait(5000, function() ack(); return file_row() end, 20), 'the dock lists the file')
request.on_event({type='list_click', revision=dock.revision, id=file_row().id, count=1, button='left', modifiers=''})
ack()
assert(diff_shown(), 'native: the file opens')
assert(windows() == 1, 'native: no window is added, got ' .. vim.inspect(filetypes()))
assert(vim.api.nvim_get_current_win() == window, 'native: the file takes the start screen window')
assert(not vim.api.nvim_buf_is_valid(welcome), 'native: the start screen is gone')
scm.toggle()
vim.cmd('silent! bwipeout! ' .. vim.fn.bufnr(hello))

-- Terminal Panel: its own split is a scratch buffer too and must not be taken.
welcome, window = start_screen()
scm.setup({renderer='terminal'})
scm.toggle()
local function panel()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return win end
  end
end
local function line_of(text)
  for number, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel()), 0, -1, false)) do
    if line:find(text, 1, true) then return number end
  end
end
assert(vim.wait(5000, function() return panel() and line_of('hello.lua') end), 'the terminal Panel lists the file')
local side = panel()
vim.api.nvim_set_current_win(side)
vim.api.nvim_win_set_cursor(side, {line_of('hello.lua'), 0})
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false)
assert(diff_shown(), 'terminal: the file opens')
assert(windows() == 2, 'terminal: Panel and file only, got ' .. vim.inspect(filetypes()))
assert(vim.api.nvim_get_current_win() == window, 'terminal: the file takes the start screen window')
assert(vim.api.nvim_win_is_valid(side) and vim.bo[vim.api.nvim_win_get_buf(side)].filetype == 'scm', 'terminal: the Panel keeps its split')
scm.toggle()

-- A scratch buffer that is kept when hidden is not a throwaway page.
vim.cmd('silent! only')
local notes = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(notes)
vim.bo[notes].bufhidden = 'hide'
vim.api.nvim_buf_set_lines(notes, 0, -1, false, {'notes'})
dock, request = nil, nil
scm.setup({renderer='auto'})
scm.toggle()
assert(vim.wait(5000, function() ack(); return file_row() end, 20), 'the dock lists the file again')
request.on_event({type='list_click', revision=dock.revision, id=file_row().id, count=1, button='left', modifiers=''})
ack()
assert(diff_shown(), 'the file opens beside kept scratch text')
assert(vim.api.nvim_buf_is_valid(notes) and windows() == 2, 'kept scratch text keeps its window')
print('OK editor window: a file opens over a start screen, not beside it')
