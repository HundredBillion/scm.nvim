-- scm.files — JSON files SCM keeps for itself, such as its settings and the
-- Reviews it was given. They are written whole or not at all, and only the
-- user can read them: they may hold explanations of private code, or
-- commands SCM later runs.
local M = {}

-- `text` decoded as JSON, with JSON null and empty objects as nil; nil when
-- it is not JSON.
function M.decode(text)
  if type(text) ~= 'string' then return nil end
  local ok, value = pcall(vim.json.decode, text, {luanil={object=true, array=true}})
  if ok then return value end
end

-- The value in JSON file `path`, or nil when there is none.
function M.read(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local text = file:read('*a')
  file:close()
  return M.decode(text)
end

-- Make directory `dir`, and every one above it, readable by this user only.
function M.private_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, 'p', 448) end
  vim.uv.fs_chmod(dir, 448)
end

-- Write `value` to `path` as JSON. It goes to a file beside it first, so a
-- reader never sees half of it. Returns true, or nil and why.
function M.write(path, value)
  M.private_dir(vim.fs.dirname(path))
  local temp = ('%s.%d.tmp'):format(path, vim.uv.os_getpid())
  local fd, err = vim.uv.fs_open(temp, 'w', 384)
  if not fd then return nil, err end
  local ok = vim.uv.fs_write(fd, vim.json.encode(value))
  vim.uv.fs_close(fd)
  if ok then ok, err = vim.uv.fs_rename(temp, path) end
  if not ok then
    vim.uv.fs_unlink(temp)
    return nil, err
  end
  -- A file made before files were kept private is made private now.
  vim.uv.fs_chmod(path, 384)
  return true
end

return M
