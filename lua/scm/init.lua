local M = {}
local backend
local function current()
  backend = backend or require('scm.panel')
  return backend
end
function M.setup(opts)
  opts = opts or {}
  local renderer = opts.renderer or 'snacks'
  assert(vim.tbl_contains({'snacks', 'auto', 'terminal', 'sprite'}, renderer), 'Unknown SCM renderer: ' .. renderer)
  if backend and backend.close then backend.close() end
  backend = require(renderer == 'snacks' and 'scm.panel' or 'scm.workspace')
  backend.setup(opts)
end
function M.focus(side)
  local impl = current()
  return impl.focus and impl.focus(side) or false
end
function M.toggle() return current().toggle() end
function M.handoff(fn) return current().handoff(fn) end
return M
