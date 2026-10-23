-- Loading and using SCM never reads Snacks, LazyVim, SVGTree, or Neo-tree.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local touched = {}
setmetatable(_G, {__index=function(_, key)
  if key == 'Snacks' or key == 'LazyVim' then touched[#touched+1] = key end
end})
setmetatable(package.loaded, {__index=function(_, name)
  if name == 'snacks' or name:match('^snacks%.') or name == 'svgtree' or name:match('^svgtree%.')
    or name:match('^neo%-tree') then
    touched[#touched+1] = name
  end
end})

local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
assert(vim.system({'git', '-C', root, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, root .. '/changed.lua')
vim.cmd.cd(root)

for _, name in ipairs({'scm', 'scm.core', 'scm.model', 'scm.refresh', 'scm.scope', 'scm.transition',
  'scm.workspace', 'scm.views.terminal', 'scm.views.sprite'}) do
  require(name)
end
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
  return win and table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false), '\n')
    :find('changed.lua', 1, true)
end), 'the Panel lists the changed file')
vim.api.nvim_exec_autocmds('FocusGained', {})
local real_notify = vim.notify
vim.notify = function() end
vim.api.nvim_set_current_win(panel())
vim.fn.maparg('<Space>e', 'n', false, true).callback()
vim.notify = real_notify
local handed = false
scm.handoff(function() handed = true end)
assert(vim.wait(1000, function() return handed end), 'handoff runs the caller action')
vim.wait(200)
assert(#touched == 0, 'SCM read ' .. table.concat(touched, ', '))
print('OK no dependencies')
