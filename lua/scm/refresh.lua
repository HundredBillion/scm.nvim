-- Shared event batching for renderers and legacy Panel event adapters.
-- Save bursts retain every affected path; focus and explicit refresh requests cover the whole scope.
local M = {}

function M.merge(previous, request)
  if not previous then return request end
  if not previous.cached or not request.cached then return {cached=false} end
  if not previous.paths or not request.paths then return {cached=true} end
  local paths = vim.tbl_extend("force", previous.paths, request.paths)
  return {cached=true, paths=paths}
end

function M.event(owner, options, request, callback)
  owner.pending_event = M.merge(owner.pending_event, request)
  if owner.event_scheduled then return end
  owner.event_scheduled = true
  vim.defer_fn(function()
    local pending = owner.pending_event
    owner.pending_event, owner.event_scheduled = nil, false
    callback(pending)
  end, options.repo_debounce_ms or 150)
end

local function opts()
  local panel = require("scm.panel")
  return panel.state.opts or require("scm.core").defaults
end

-- Legacy focus refreshes are throttled independently for each tab.
function M.full()
  local now = vim.uv.now()
  local previous = vim.t.scm_last_full
  if previous and now - previous < (opts().focus_debounce_ms or 1500) then
    return
  end
  vim.t.scm_last_full = now
  require("scm.panel").refresh_view(nil, {cached=true})
end

-- A lazygit terminal exited. Terminal buffer names look like
-- term://{cwd}//{pid}:{cmd} — recover the cwd, resolve its repo root, and
-- refresh just that repo. Full rescan only if recovery fails.
local function on_lazygit_close(bufname)
  local cwd = bufname:match("^term://(.-)//")
  if not cwd or cwd == "" then
    M.full()
    return
  end
  vim.system(
    { "git", "-C", vim.fn.expand(cwd), "rev-parse", "--show-toplevel" },
    { text = true },
    vim.schedule_wrap(function(out)
      local root = out.code == 0 and vim.trim(out.stdout or "") or ""
      if root ~= "" then
        require("scm.panel").refresh_repo_view(root)
      else
        M.full()
      end
    end)
  )
end

-- True when the current window is one of the SCM panel's own windows.
local function in_panel_win(picker)
  local win = vim.api.nvim_get_current_win()
  local ok, hit = pcall(function()
    return (picker.list and picker.list.win and picker.list.win.win == win)
      or (picker.input and picker.input.win and picker.input.win.win == win)
  end)
  return ok and hit
end

function M.setup()
  local aug = vim.api.nvim_create_augroup("ScmRefreshTriggers", { clear = true })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = aug,
    callback = function(ev)
      if not _G.Snacks then return end
      local panel = require("scm.panel")
      local picker = Snacks.picker.get({source="scm"})[1]
      if not picker then return end
      M.event(picker, opts(), {cached=true, paths={[vim.api.nvim_buf_get_name(ev.buf)]=true}}, function(request)
        if not picker.closed then panel.refresh_view(picker, request) end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("TermClose", {
    group = aug,
    callback = function(ev)
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if not name:find("lazygit", 1, true) then
        return
      end
      vim.schedule(function()
        on_lazygit_close(name)
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = aug,
    callback = function()
      if not _G.Snacks then
        return
      end
      local p = Snacks.picker.get({ source = "scm" })[1]
      if p and p._scm_tab and in_panel_win(p) then
        M.full()
      end
    end,
  })

  vim.api.nvim_create_autocmd("FocusGained", {
    group = aug,
    callback = function()
      if not _G.Snacks then
        return
      end
      if Snacks.picker.get({ source = "scm" })[1] then
        M.full()
      end
    end,
  })
end

return M
