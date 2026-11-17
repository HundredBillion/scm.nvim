local M = {}
local core, model, scope = require('scm.core'), require('scm.model'), require('scm.scope')
local active, options
local function ui_snapshot(state)
  local ui = state.ui
  return {mode=ui.mode, folded=ui.folded, cursor=ui.cursor,
    editing=ui.editing_repo and model.input_id(ui.editing_repo) or nil}
end
local function render(state, keep_index)
  if active ~= state or not state.view then return end
  local old = state.rows and state.rows[state.view.selection and state.view:selection() or state.selected]
  local anchor = state.select_id or (not keep_index and old and old.id)
  state.select_id = nil
  local rows = model.rows(state.entries, state.ui)
  if state.error then rows = {{id='error', kind='note', depth=0, label=tostring(state.error), error=true}} end
  -- Typing ends when the commit box it was going into is no longer listed.
  local editing = state.ui.editing_repo and model.input_id(state.ui.editing_repo)
  for i, row in ipairs(rows) do
    if row.id == anchor then state.selected = i end
    if row.id == editing then editing = nil end
  end
  if editing then state.ui.editing_repo, state.ui.cursor = nil, nil end
  state.rows = rows
  state.selected = math.max(1, math.min(state.selected, #rows))
  state.view:render(rows, state.selected, ui_snapshot(state))
end
local policy = require('scm.refresh')
local function refresh(state, request)
  if active ~= state then return end
  policy.request(state, request, {
    start = function(pending, done, progress) core.refresh(state.root, options, done, pending, progress, progress) end,
    deliver = function(entries, err)
      if not err then state.entries = entries end
      state.error = err
      render(state)
    end,
    progress = function(entries)
      state.entries = entries
      render(state)
    end,
    alive = function() return active == state end,
  })
end
function M.focus(side)
  if side and side ~= 'left' then return false end
  if not active or active.tab ~= vim.api.nvim_get_current_tabpage() then return false end
  return active.view and active.view.focus and active.view:focus() or false
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
-- The commit box holds one line of at most this many bytes: the limit of a
-- row's text in the native Panel.
local MESSAGE_BYTES = 4000
local function report(err)
  if err then vim.notify('SCM: ' .. err, vim.log.levels.ERROR) end
end
-- Run `ask(done)`, which shows a Neovim prompt and calls done() when it is
-- answered. The native Panel holds the keyboard in its dock, where a Neovim
-- prompt cannot be answered, so the editor takes the keyboard for the prompt.
local function with_prompt(state, ask)
  local view = state.view
  if not (view and view.inline_edit and view.focus_editor) then ask(function() end); return end
  view:focus_editor(function()
    if active ~= state then return end
    ask(function()
      if active == state and state.view == view then view:focus() end
    end)
  end)
end
-- Ask a yes/no question; answer(true) only on the first choice. `default` is
-- the choice a bare Enter picks.
local function confirm(state, message, choices, default, answer)
  with_prompt(state, function(done)
    local yes
    if options.confirm then yes = options.confirm(message, choices)
    else yes = vim.fn.confirm(message, choices, default) == 1 end
    done()
    answer(yes)
  end)
end
-- Re-scan one repository after SCM changed it.
local function changed(state, entry)
  if active == state then refresh(state, {cached=true, paths={[entry.path]=true}}) end
end
-- The callback of a git action: report a failure, and re-scan either way,
-- because a command that failed may still have changed the repository.
local function after_git(state, entry)
  return function(err)
    report(err)
    changed(state, entry)
  end
end
local function has(entry, group)
  return #model.group_paths(entry, group) > 0
end
local function entry_at(state, path)
  for _, entry in ipairs(state.entries) do
    if entry.path == path then return entry end
  end
end
-- The repository an action without a file applies to: the one being typed
-- into, else the selected row's, else the only one.
local function repository(state, row)
  local editing = state.ui.editing_repo and entry_at(state, state.ui.editing_repo)
  if editing then return editing end
  if row and row.entry then return row.entry end
  if #state.entries == 1 then return state.entries[1] end
  vim.notify('SCM: select a repository first', vim.log.levels.INFO)
end
local function end_edit(state)
  state.ui.editing_repo, state.ui.cursor = nil, nil
end
local function begin_edit(state, entry)
  local message = state.ui.messages[entry.path] or ''
  state.select_id = model.input_id(entry.path)
  if state.view.inline_edit then
    state.ui.editing_repo, state.ui.cursor = entry.path, vim.fn.strchars(message)
    render(state)
    -- A click on a button in the dock does not give the dock the keyboard.
    state.view:focus()
    return
  end
  render(state)
  vim.ui.input({prompt='Commit message: ', default=message}, function(text)
    if text == nil or active ~= state then return end
    text = text:gsub('%c', ' '):sub(1, MESSAGE_BYTES)
    state.ui.messages[entry.path] = text ~= '' and text or nil
    render(state)
  end)
end
local function commit(state, entry)
  local message = vim.trim(state.ui.messages[entry.path] or '')
  if message == '' then
    vim.notify('SCM: enter a commit message first', vim.log.levels.INFO)
    begin_edit(state, entry)
    return
  end
  local function run(all)
    end_edit(state)
    render(state, true)
    require('scm.actions').commit(entry.path, message, {all=all}, function(err)
      -- The message is kept when the commit fails, so it can be retried.
      if not err and active == state then
        state.ui.messages[entry.path] = nil
        render(state)
      end
      after_git(state, entry)(err)
    end)
  end
  if has(entry, 'staged') then run(false); return end
  if has(entry, 'merge') then
    vim.notify('SCM: resolve and stage the merge changes before committing', vim.log.levels.WARN)
    return
  end
  if not has(entry, 'changes') then
    vim.notify('SCM: there are no changes to commit', vim.log.levels.INFO)
    return
  end
  confirm(state, 'There are no staged changes to commit.\nStage all changes and commit them?', '&Yes\n&Cancel', 1,
    function(yes) if yes and active == state then run(true) end end)
end
-- Stage or unstage what `row` stands for: a file, a directory, a whole Change
-- Group, or (a repository row) everything. A row that cannot do `name` is
-- ignored, so a key never acts on more than the row shows.
local function stage(state, row, name)
  if not row then return end
  local paths
  if row.kind == 'repo' then paths = nil
  elseif not vim.tbl_contains(row.actions or {}, name) then return
  elseif row.kind == 'group' then paths = model.group_paths(row.entry, row.group)
  else paths = row.paths end
  require('scm.actions')[name](row.entry.path, paths, after_git(state, row.entry))
end
local function stage_all(state, row, name)
  local entry = repository(state, row)
  if entry then require('scm.actions')[name](entry.path, nil, after_git(state, entry)) end
end
local function discard(state, row)
  if not row or not vim.tbl_contains(row.actions or {}, 'discard') then
    vim.notify('SCM: select a file under Changes to discard it', vim.log.levels.INFO)
    return
  end
  local question = (row.untracked and 'Delete %s?' or 'Discard changes in %s?'):format(row.path)
    .. ' This cannot be undone.'
  confirm(state, question, '&Discard\n&Cancel', 2, function(yes)
    if not yes then return end
    require('scm.actions').discard(row.entry.path, row.path, {untracked=row.untracked}, after_git(state, row.entry))
  end)
end
-- Apply one editing key to the commit message being typed. The cursor counts
-- characters, not bytes.
local function edit(state, change)
  local repo = state.ui.editing_repo
  if not repo or type(change) ~= 'table' then return end
  local text = state.ui.messages[repo] or ''
  local length = vim.fn.strchars(text)
  local cursor = math.max(0, math.min(state.ui.cursor or length, length))
  local before, after = vim.fn.strcharpart(text, 0, cursor), vim.fn.strcharpart(text, cursor)
  local op = change.op
  if op == 'insert' and type(change.text) == 'string' then
    local typed = change.text:gsub('%c', '')
    if #text + #typed > MESSAGE_BYTES then
      vim.notify(('SCM: a commit message here holds at most %d bytes'):format(MESSAGE_BYTES), vim.log.levels.WARN)
      return
    end
    before = before .. typed
  elseif op == 'backspace' then before = vim.fn.strcharpart(before, 0, math.max(0, cursor - 1))
  elseif op == 'delete' then after = vim.fn.strcharpart(after, 1)
  elseif op == 'word' then before = before:gsub('%S*%s*$', '')
  elseif op == 'clear' then before = ''
  elseif op == 'left' then
    after = vim.fn.strcharpart(before, math.max(0, cursor - 1)) .. after
    before = vim.fn.strcharpart(before, 0, math.max(0, cursor - 1))
  elseif op == 'right' then
    before, after = before .. vim.fn.strcharpart(after, 0, 1), vim.fn.strcharpart(after, 1)
  elseif op == 'home' then before, after = '', before .. after
  elseif op == 'end' then before, after = before .. after, ''
  end
  text = before .. after
  state.ui.messages[repo] = text ~= '' and text or nil
  state.ui.cursor = vim.fn.strchars(before)
  render(state, true)
end
-- Move the selection to the row that contains row `index`.
local function select_parent(state, index)
  local depth = state.rows[index].depth or 0
  for i = index - 1, 1, -1 do
    if (state.rows[i].depth or 0) < depth and state.rows[i].expanded ~= nil then
      state.selected = i
      render(state, true)
      return
    end
  end
end
local function menu(state)
  local items = {
    {state.ui.mode == 'tree' and 'View as List' or 'View as Tree', 'view'},
    {'Refresh', 'refresh'}, {'Commit', 'commit'},
    {'Stage All Changes', 'stage_all'}, {'Unstage All Changes', 'unstage_all'},
  }
  with_prompt(state, function(done)
    vim.ui.select(items, {prompt='Source Control', format_item=function(item) return item[1] end}, function(choice)
      done()
      if choice and active == state then M.act(choice[2]) end
    end)
  end)
end
-- Actions that belong to typing in the commit box. Anything else ends it.
local EDITING = {edit=true, edit_end=true, edit_next=true, commit=true}
-- `index` is the row the action is for; nil keeps the current selection, and
-- an index with no row (the terminal Panel's header lines) means no row.
local function action(state, name, index, arg)
  if active ~= state or vim.api.nvim_get_current_tabpage() ~= state.tab then return end
  state.selected = index or state.selected
  local row = state.rows and state.rows[state.selected]
  if state.ui.editing_repo and not EDITING[name] then
    end_edit(state)
    render(state, true)
  end
  if name == 'close' then M.close()
  elseif name == 'editor' then editor(state)
  elseif name == 'refresh' then refresh(state)
  elseif name == 'explorer' then
    if options.on_explorer then options.on_explorer(state.root); return end
    vim.notify('SCM: No file explorer is connected, so there\'s nothing to open. See "Connecting a file explorer" in the README.',
      vim.log.levels.INFO)
  elseif name == 'view' then
    state.ui.mode = state.ui.mode == 'tree' and 'list' or 'tree'
    render(state)
  elseif name == 'fold' then
    state.ui.folded = not state.ui.folded
    render(state)
  elseif name == 'menu' then menu(state)
  elseif name == 'edit' then edit(state, arg)
  elseif name == 'edit_end' or name == 'edit_next' then
    local repo = state.ui.editing_repo
    end_edit(state)
    if name == 'edit_next' and repo then state.select_id = model.button_id(repo) end
    render(state, true)
  elseif name == 'compose' then
    local entry = repository(state, row)
    if entry then begin_edit(state, entry) end
  elseif name == 'commit' then
    local entry = repository(state, row)
    if entry then commit(state, entry) end
  elseif name == 'stage' or name == 'unstage' then stage(state, row, name)
  elseif name == 'stage_all' then stage_all(state, row, 'stage')
  elseif name == 'unstage_all' then stage_all(state, row, 'unstage')
  elseif name == 'discard' then discard(state, row)
  elseif row and (name == 'open' or name == 'expand' or name == 'collapse') then
    if row.kind == 'input' then
      if name == 'open' then begin_edit(state, row.entry) end
    elseif row.kind == 'button' then
      if name == 'open' then commit(state, row.entry) end
    elseif row.expanded ~= nil then
      if name == 'collapse' and not row.expanded then select_parent(state, state.selected); return end
      -- "open" toggles; "expand" and "collapse" say which way.
      state.ui.collapsed[row.id] = (name == 'collapse' or (name == 'open' and row.expanded)) or nil
      render(state)
    elseif name == 'collapse' then select_parent(state, state.selected)
    elseif row.kind == 'file' and name == 'open' then
      if vim.fn.filereadable(row.file) ~= 1 then
        vim.notify('SCM: file is deleted or unavailable; historical viewing will be provided by prism.nvim', vim.log.levels.INFO)
        return
      end
      editor(state)
      vim.cmd.edit(vim.fn.fnameescape(row.file))
    end
  end
end
-- Run a Panel action by name on the selected row, for user keymaps: "open",
-- "expand", "collapse", "stage", "unstage", "stage_all", "unstage_all",
-- "discard", "compose", "commit", "view", "fold", "menu", "refresh", "close".
-- False when the Panel is closed.
function M.act(name)
  if not active or not active.view then return false end
  action(active, name, active.view.selection and active.view:selection() or active.selected)
  return true
end
function M.toggle()
  if active then M.close(); return end
  local root = scope.current()
  -- Start from what Core last saw for this root so the rows show before git answers.
  local state = {root=root, tab=vim.api.nvim_get_current_tabpage(), editor=vim.api.nvim_get_current_win(),
    entries=core.cached(root) or {}, selected=1,
    ui={mode=options.view == 'tree' and 'tree' or 'list', collapsed={}, messages={}, folded=false,
      limit=options.group_limit}}
  active = state
  local function on_action(name, index, arg) action(state, name, index, arg) end
  local docked = false
  local function ready(view)
    if active ~= state then view:close(); return end
    state.view=view
    docked = true
    render(state)
    refresh(state, {cached=true, reuse_history=true})
  end
  local function terminal(err)
    if active ~= state then return end
    -- A dock that opened and then failed is worth a word; a terminal that has
    -- no docks at all is not.
    if err and (options.renderer == 'sprite' or docked) then
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
    ScmModified={fg='#e2c08d'}, ScmAdded={fg='#81b88b'}, ScmDeleted={fg='#c74e39'},
    ScmRenamed={fg='#73c991'}, ScmUntracked={fg='#73c991'},
    ScmCommitted={fg='#75beff'}, ScmConflict={fg='#e4676b'},
    ScmDescription={fg='#8c8c8c'}, ScmPlaceholder={fg='#8c8c8c', italic=true}, ScmInput={fg='#cccccc'},
    ScmButton={bg='#007ca4', fg='#ffffff'}, ScmCount={fg='#ffffff', bg='#0080a2'},
    ScmStrike={strikethrough=true}}) do
    value.default=true
    vim.api.nvim_set_hl(0, name, value)
  end
  end
  highlights()
  local group = vim.api.nvim_create_augroup('ScmWorkspace', {clear=true})
  vim.api.nvim_create_autocmd('ColorScheme', {group=group, callback=highlights})
  vim.api.nvim_create_autocmd({'BufWritePost','FocusGained'}, {group=group, callback=function(ev)
    local state = active
    if not state then return end
    local request = {cached=true}
    if ev.event == 'BufWritePost' then request.paths = {[vim.api.nvim_buf_get_name(ev.buf)]=true} end
    policy.event(state, options, request, function(pending) refresh(state, pending) end)
  end})
  vim.api.nvim_create_autocmd('DirChanged', {group=group, callback=function()
    local state = active
    if not state then return end
    local root = scope.current(state.editor)
    if not root or root == state.root then return end
    policy.reset(state)
    state.root, state.entries, state.error, state.selected = root, core.cached(root) or {}, nil, 1
    render(state)
    refresh(state, {cached=true, reuse_history=true})
  end})
  vim.api.nvim_create_autocmd('TabLeave', {group=group, callback=M.close})
  vim.api.nvim_create_user_command('ScmToggle', M.toggle, {force=true})
  policy.warm(options)
end
return M
