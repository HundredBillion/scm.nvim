local M = {}
local core, model, scope = require('scm.core'), require('scm.model'), require('scm.scope')
local active, options
local function row_id(item)
  return item.kind .. ':' .. item.entry.path .. (item.kind == 'file' and '/' .. item.fentry.path or '')
end
local function render(state, keep_index)
  if active ~= state or not state.view then return end
  local old = state.items and state.items[state.view.selection and state.view:selection() or state.selected]
  local anchor = not keep_index and old and row_id(old)
  state.items = model.build_items(state.entries, state.collapsed)
  local rows = {}
  for i, item in ipairs(state.items) do
    local text, hl
    if item.kind == 'header' then
      local e = item.entry
      text = (item.collapsed and ' ▸ ' or ' ▾ ') .. e.name .. '  ' .. (e.branch or '')
      if e.err then text = text .. '  ! ' .. e.err
      elseif e.clean then text = text .. '  ✓'
      else text = text .. '  (' .. #(e.files or {}) .. ')' end
      hl = e.err and 'DiagnosticWarn' or 'Title'
    else
      local display = model.file_display(item.fentry)
      text = '   ' .. display.letter .. display.marker .. ' ' .. item.fentry.path
      hl = display.hl
    end
    rows[i] = {id=row_id(item), text=text:gsub('[\r\n]', ' '), hl=hl}
    if row_id(item) == anchor then state.selected = i end
  end
  if state.error then rows = {{id='error', text=' ! ' .. tostring(state.error), hl='DiagnosticError'}} end
  state.selected = math.max(1, math.min(state.selected, #rows))
  state.view:render(rows, state.selected)
end
local function refresh(state)
  if active ~= state then return end
  if state.scanning then state.again = true; return end
  state.scanning = true
  core.refresh(state.root, options, function(entries, err)
    if active ~= state then return end
    state.scanning = false
    state.entries, state.error = entries or {}, err
    render(state)
    if state.again then state.again = false; refresh(state) end
  end)
end
function M.close()
  local old = active
  active = nil
  if old and old.view then old.view:close() end
end
local function editor(state)
  local function valid(win)
    return win and vim.api.nvim_win_is_valid(win)
      and vim.api.nvim_win_get_tabpage(win) == state.tab
      and vim.api.nvim_win_get_config(win).relative == ''
      and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ''
  end
  local win = vim.api.nvim_get_current_win()
  if not valid(win) then win = state.editor end
  if not valid(win) then
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
      if valid(candidate) then win = candidate; break end
    end
  end
  if not valid(win) then
    vim.cmd('botright vsplit')
    win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
  end
  vim.api.nvim_set_current_win(win)
  state.editor = win
  if state.view.focus_editor then state.view:focus_editor() end
end
local function action(state, name, index)
  if active ~= state or vim.api.nvim_get_current_tabpage() ~= state.tab then return end
  state.selected = index or state.selected
  local item = state.items and state.items[state.selected]
  if name == 'close' then M.close()
  elseif name == 'editor' then editor(state)
  elseif name == 'refresh' then refresh(state)
  elseif name == 'explorer' then
    local ok, tree = pcall(require, 'svgtree')
    if ok then M.handoff(function() tree.open(state.root) end)
    else vim.notify('SCM: SVGTree is not installed', vim.log.levels.INFO) end
  elseif item and (name == 'open' or name == 'expand' or name == 'collapse') then
    if item.kind == 'header' then
      state.collapsed[item.entry.path] = name == 'collapse' or (name == 'open' and not item.collapsed)
      render(state)
    elseif name == 'collapse' then
      for i, row in ipairs(state.items) do
        if row.kind == 'header' and row.entry.path == item.entry.path then state.selected=i; break end
      end
      render(state, true)
    else
      if vim.fn.filereadable(item.file) ~= 1 then
        vim.notify('SCM: file is deleted or unavailable; historical viewing will be provided by prism.nvim', vim.log.levels.INFO)
        return
      end
      editor(state)
      vim.cmd.edit(vim.fn.fnameescape(item.file))
    end
  end
end
function M.toggle()
  if active then M.close(); return end
  local tree = package.loaded.svgtree
  local root = tree and tree.root and tree.root() or scope.current()
  scope.remember(root)
  local state = {root=root, tab=vim.api.nvim_get_current_tabpage(), editor=vim.api.nvim_get_current_win(),
    entries={}, collapsed={}, selected=1}
  if tree and tree.close then tree.close() end
  active = state
  local function on_action(name, index) action(state, name, index) end
  local function ready(view)
    if active ~= state then view:close(); return end
    state.view=view
    render(state)
    refresh(state)
  end
  local function terminal(err)
    if active ~= state then return end
    if err and options.renderer == 'sprite' then
      vim.notify('SCM Sprite unavailable: ' .. tostring(err.message or err.kind or err), vim.log.levels.WARN)
    end
    ready(require('scm.views.terminal').open(options, on_action,
      function() if active == state then active=nil end end))
  end
  if options.renderer == 'terminal' then terminal()
  else
    local pending = require('scm.views.sprite').open(options, on_action, ready, terminal)
    if not state.view then state.view=pending end
  end
end
function M.handoff(fn)
  M.close()
  require('scm.transition').request(fn)
end
function M.setup(opts)
  M.close()
  options = vim.tbl_deep_extend('force', core.defaults, {renderer='auto', width=36}, opts or {})
  local function highlights()
  for name, value in pairs({ScmBackground={bg='#181818',fg='#cccccc'}, ScmSelection={bg='#04395e'},
    ScmModified={fg='#e2c08d'}, ScmAdded={fg='#73c991'}, ScmDeleted={fg='#f14c4c'},
    ScmRenamed={fg='#73c991'}, ScmUntracked={fg='#73c991'}, ScmStaged={fg='#73c991'},
    ScmCommitted={fg='#75beff'}, ScmConflict={fg='#f14c4c'}}) do
    value.default=true
    vim.api.nvim_set_hl(0, name, value)
  end
  end
  highlights()
  local group = vim.api.nvim_create_augroup('ScmWorkspace', {clear=true})
  vim.api.nvim_create_autocmd('ColorScheme', {group=group, callback=highlights})
  vim.api.nvim_create_autocmd({'BufWritePost','FocusGained','TermClose'}, {group=group, callback=function()
    if active then refresh(active) end
  end})
  vim.api.nvim_create_autocmd('TabLeave', {group=group, callback=M.close})
  vim.api.nvim_create_user_command('ScmToggle', M.toggle, {force=true})
end
return M
