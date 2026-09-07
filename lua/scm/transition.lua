local M = {}
local pending
local scheduled = false

local function flush()
  local request = pending
  pending = nil
  scheduled = false
  if not request or not vim.api.nvim_tabpage_is_valid(request.tab) then
    return
  end
  local win = vim.api.nvim_tabpage_get_win(request.tab)
  vim.api.nvim_win_call(win, request.open)
end

function M.request(open)
  assert(type(open) == "function", "scm handoff requires an open function")
  pending = { open = open, tab = vim.api.nvim_get_current_tabpage() }
  if scheduled then
    return
  end
  scheduled = true
  vim.schedule(flush)
end

function M.cancel()
  pending = nil
end

return M
