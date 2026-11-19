local M = {}
local backend
local function current()
  if not backend then M.setup() end
  return backend
end
function M.setup(opts)
  opts = opts or {}
  local renderer = opts.renderer or 'auto'
  if renderer == 'snacks' then
    error("The Snacks renderer was removed. Use renderer = 'auto' or 'terminal'.", 0)
  end
  assert(vim.tbl_contains({'auto', 'terminal', 'sprite'}, renderer), 'Unknown SCM renderer: ' .. renderer)
  if backend and backend.close then backend.close() end
  backend = require('scm.workspace')
  backend.setup(opts)
end
function M.focus(side)
  local impl = current()
  return impl.focus and impl.focus(side) or false
end
function M.toggle() return current().toggle() end
-- Run a Panel action by name on the selected row, for your own keymaps:
-- "stage", "unstage", "stage_all", "unstage_all", "discard", "compose",
-- "commit", "view", "fold", "menu", "refresh", "open", "file", "expand", "collapse".
-- False when the Panel is closed.
function M.act(name) return current().act(name) end
function M.handoff(fn) return current().handoff(fn) end
-- Open the admin page: the services that explain changes, and which is in use.
function M.explainers()
  current()
  return require('scm.review.admin').open()
end
return M
