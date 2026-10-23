vim.opt.runtimepath:prepend(vim.uv.cwd())
local scm = require('scm')

local ok, err = pcall(scm.setup, {renderer='snacks'})
assert(not ok, 'the snacks renderer is rejected')
assert(err == "The Snacks renderer was removed. Use renderer = 'auto' or 'terminal'.", tostring(err))

ok, err = pcall(scm.setup, {renderer='picker'})
assert(not ok and tostring(err):find('Unknown SCM renderer: picker', 1, true), tostring(err))

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
vim.cmd.cd(dir)
package.loaded.sprite = nil
package.loaded['scm'] = nil
scm = require('scm')
assert(pcall(scm.toggle), 'toggle before setup opens the Panel')
assert(package.loaded['scm.workspace'], 'the Panel is the standalone workspace')
assert(not package.loaded['scm.panel'], 'the Snacks panel is never loaded')
scm.toggle()
print('OK init')
