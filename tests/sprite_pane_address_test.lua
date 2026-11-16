vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.fn.fnamemodify(assert(vim.env.SCM_SPRITE_SOURCE, 'set SCM_SPRITE_SOURCE'), ':p')
vim.opt.runtimepath:prepend(api)
local host = dofile(api .. '/tests/dock_host.lua').start()
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
assert(vim.system({'git', '-C', root, 'init', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'return true'}, root .. '/example.lua')
vim.cmd.cd(root)
local scm = require('scm')
scm.setup({renderer='auto'})
local function terminal()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return true end
  end
  return false
end
local function open()
  local count = #host:messages('list_rows')
  scm.toggle()
  assert(vim.wait(5000, function()
    for i, message in ipairs(host:messages('list_rows')) do
      if i > count then
        for _, row in ipairs(message.rows) do
          if row.text:find('example.lua', 1, true) then return true end
        end
      end
    end
    return false
  end), 'native SCM sends Git file rows through real Sprite API')
  assert(not terminal(), 'native SCM does not fall back to a terminal buffer')
end
open()
local request = host:messages('open')[1]
assert(request.pane == host.pane, 'SCM preserves full pane address')
assert(request.description.root.heading.text == 'SOURCE CONTROL', 'source control dock opens')
assert(scm.focus('left'), 'SCM accepts focus')
assert(vim.wait(3000, function() return #host:messages('focus') > 0 end), 'focus reaches host')
scm.toggle()
open()
scm.toggle()
host.refuse = true
scm.toggle()
assert(vim.wait(3000, terminal), 'host refusal falls back to terminal')
scm.toggle()
host.refuse = false
open()
scm.toggle()
host:close()
vim.cmd.cd(vim.fn.fnamemodify(root, ':h'))
vim.fn.delete(root, 'rf')
print('OK native SCM pane address')
