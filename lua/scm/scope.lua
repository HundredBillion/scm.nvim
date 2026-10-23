-- The Working Directory: Neovim's current directory, which every file explorer
-- changes when it moves to a folder, so SCM follows any of them without knowing which.
local M = {}

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local real = vim.uv.fs_realpath(vim.fn.expand(path))
  if not real or vim.fn.isdirectory(real) ~= 1 then
    return nil
  end
  return vim.fs.normalize(real)
end

-- The Working Directory of `win` (default: the current window). A window that no
-- longer exists falls back to the current tab's directory.
function M.current(win)
  if win == nil then
    return normalize(vim.fn.getcwd())
  end
  if vim.api.nvim_win_is_valid(win) then
    return normalize(vim.fn.getcwd(win))
  end
  return normalize(vim.fn.getcwd(-1, 0))
end

-- The directory the startup warm-up scans.
function M.candidate()
  return M.current()
end

return M
