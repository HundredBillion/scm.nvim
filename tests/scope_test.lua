vim.opt.runtimepath:prepend(vim.uv.cwd())

local function eq(got, want, label)
  assert(vim.deep_equal(got, want), ("%s\nexpected: %s\ngot: %s"):format(label, vim.inspect(want), vim.inspect(got)))
end
local function dir()
  local path = vim.fn.tempname()
  vim.fn.mkdir(path, "p")
  return vim.uv.fs_realpath(path)
end

-- Every explorer is installed, and reading any of them fails the test.
_G.Snacks = { picker = { get = function() error("SCM must not read the Snacks Explorer") end } }
_G.LazyVim = { root = function() error("SCM must not read LazyVim") end }
package.loaded.svgtree = { root = function() error("SCM must not read SVGTree") end }
package.loaded["neo-tree.sources.manager"] = { get_state = function() error("SCM must not read Neo-tree") end }

local scope = require("scm.scope")
local a, b, c = dir(), dir(), dir()

local link = vim.fn.tempname()
assert(vim.uv.fs_symlink(a, link, { dir = true }), "create a symlinked directory")
vim.cmd.cd(link)
eq(scope.current(), a, "a symlinked directory resolves to its real path")

vim.cmd.cd(a)
eq(scope.current(), a, ":cd sets the Working Directory")
eq(scope.candidate(), a, "the warm-up uses the same Working Directory")

vim.cmd("tabnew")
vim.cmd.tcd(b)
eq(scope.current(), b, ":tcd sets the Working Directory for this tab")
local editor = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local other = vim.api.nvim_get_current_win()
vim.cmd.lcd(c)
eq(scope.current(), c, ":lcd sets the Working Directory for this window")
eq(scope.current(editor), b, "another window keeps its own Working Directory")
vim.api.nvim_win_close(other, true)
eq(scope.current(other), b, "a closed window falls back to the tab's directory")
vim.cmd("tabprevious")
eq(scope.current(), a, "the first tab keeps the global directory")

local gone = dir()
vim.cmd.cd(gone)
vim.fn.delete(gone, "rf")
eq(scope.current(), nil, "a deleted directory is not a Working Directory")
print("OK scope")
