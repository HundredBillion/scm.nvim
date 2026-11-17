-- The native Renderer: draws the Panel in a Sprite dock, laid out to match
-- VS Code's Source Control view. Metrics are VS Code's own: 22-pixel rows, a
-- 26-pixel commit box and button in 36-pixel rows, 8 pixels of indent a level.
local Icons = require('scm.icons')
local M = {}

-- The host feature that draws commit boxes, buttons, badges, counts and row
-- actions. A host without it gets the terminal Panel.
M.FEATURE = 'virtual-list-rows-v2'

local ROW_HEIGHT, CONTROL_ROW_HEIGHT, INDENT = 22, 36, 8
-- A Panel opening on a long list first sends this many rows, more than a
-- screen holds, and the whole list after them. The cost of a frame grows
-- with its size: two thousand rows are a megabyte, and the first screen
-- would otherwise wait for all of it.
M.FIRST_ROWS = 100
-- VS Code insets the commit box and button 11 pixels past their level's indent.
local CONTROL_INSET = 11
-- The host accepts at most this many guides on a row, and strings this long.
local MAX_GUIDES, MAX_TEXT_BYTES = 64, 4000
local BLANK_ICON = '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>'
local COLORS = {
  background='#191a1b', foreground='#bfbfbf', hover='#2a2b2c',
  selected='#363738', inactive_selected='#2e2f30', selected_foreground='#ffffff',
  focus='#107997', guide='#585858', inactive_guide='#585858', border='#2a2b2c',
  scrollbar='#424242', scrollbar_hover='#646464', scrollbar_active='#bfbfbf',
  input_background='#191a1b', input_border='#333536', input_foreground='#bfbfbf',
  input_placeholder='#8c8c8c', button_background='#007ca4', button_hover='#0a8bb5',
  button_foreground='#ffffff', button_separator='#6fb1c9',
  count_background='#0080a2', count_foreground='#ffffff', action_hover='#45474a',
}
-- VS Code's Git decoration colours, by the highlight the model names.
local BADGE_COLORS = {
  ScmModified='#e2c08d', ScmAdded='#81b88b', ScmDeleted='#c74e39', ScmRenamed='#73c991',
  ScmUntracked='#73c991', ScmConflict='#e4676b', ScmCommitted='#75beff',
}
local ACTION_ICONS = {file='go-to-file', discard='discard', stage='add', unstage='remove'}

local function colors(opts)
  return vim.tbl_extend('force', COLORS, (opts.native or {}).colors or {})
end

-- Every icon is an asset named for what it is and the colour it is drawn in,
-- because a registered asset can never be redefined. `dx` shifts it sideways.
local function control(assets, name, color, dx)
  local id = 'scm-' .. name .. '-' .. color:sub(2) .. (dx and ('-' .. dx) or '')
  if not assets[id] then assets[id] = Icons.codicon(name, color, dx) end
  return assets[id] and id or nil
end

local function blank(assets)
  assets['scm-blank'] = BLANK_ICON
  return 'scm-blank'
end

-- The host refuses a string longer than its limit, which would close the
-- dock; a row is cut to fit on a character boundary instead.
local function clip(text)
  if #text <= MAX_TEXT_BYTES then return text end
  return vim.fn.strcharpart(text, 0, vim.str_utfindex(text, 'utf-32', MAX_TEXT_BYTES, false)) .. '…'
end

-- What decides a description: the view mode and whether the section is folded.
local function description_key(ui)
  return (ui.mode or 'list') .. (ui.folded and ':folded' or '')
end

local function description(opts, ui, assets)
  local palette = colors(opts)
  local fg = palette.foreground
  local function action(id, icon) return {id=id, icon=control(assets, icon, fg)} end
  return {version=1, root={kind='virtual_list', border_side='right',
    row_height=ROW_HEIGHT, font_size=13, font_family='.SystemUIFont', icon_size=16, icon_gap=6,
    left_padding=8, right_padding=10, scrollbar_width=10, guide_visibility='hover',
    inactive_guide_opacity=0.4, scrollbar_opacity=0.4, scrollbar_hover_opacity=0.7,
    scrollbar_active_opacity=0.4, row_radius=4, input_height=26, button_height=26,
    control_radius=4, control_padding=6,
    heading={text='Source Control', height=35, font_size=13, left_padding=8},
    -- VS Code draws this chevron 2 pixels left of the row chevrons below it.
    section={text='Changes', height=ROW_HEIGHT, font_size=13, font_weight='bold', left_padding=8, icon_gap=0,
      icon=control(assets, ui.folded and 'chevron-right' or 'chevron-down', fg, -2),
      action='fold', actions={
        action('view', ui.mode == 'tree' and 'list-flat' or 'list-tree'),
        action('commit', 'check'), action('refresh', 'refresh'), action('menu', 'ellipsis'),
      }},
    colors=palette}}
end

local function placeholder(row)
  return ('Message (%s to commit on "%s")'):format(
    vim.fn.has('mac') == 1 and '⌘Enter' or 'Ctrl+Enter', row.entry and row.entry.branch or '?')
end

-- Translate the Panel's rows into the rows Sprite draws, registering every
-- icon they use in `assets`.
function M.rows(opts, rows, ui, assets)
  local palette = colors(opts)
  local fg = palette.foreground
  local theme = Icons.theme((opts.native or {}).icon_theme)
  local function file_icon(item, name, kind, open)
    local id, svg = Icons.file(theme, name, kind, open, fg)
    if svg then assets[id] = svg; item.icon = id end
  end
  local out, ancestors = {}, {}
  for i, row in ipairs(rows) do
    local depth = row.depth or 0
    for level = depth + 1, #ancestors do ancestors[level] = nil end
    local guides = {}
    for level = 1, math.min(depth, MAX_GUIDES) do
      if ancestors[level] then guides[#guides + 1] = {offset=INDENT * level, id=ancestors[level]} end
    end
    local item = {id=row.id, text=clip(row.label or ''), indent=INDENT * depth, guides=guides}
    local kind = row.kind
    if kind == 'input' or kind == 'button' then
      item.kind, item.height, item.indent = kind, CONTROL_ROW_HEIGHT, INDENT * depth + CONTROL_INSET
      if kind == 'input' then
        item.placeholder = clip(placeholder(row))
        item.trailing = control(assets, 'sparkle', fg)
        -- A cursor tells the host this box is being typed into.
        if ui.editing == row.id then item.cursor = ui.cursor or vim.fn.strchars(item.text) end
      else
        item.icon = control(assets, 'check', palette.button_foreground)
        local menu = control(assets, 'chevron-down', palette.button_foreground)
        if menu then item.actions = {{id='menu', icon=menu}} end
      end
    elseif kind == 'repo' or kind == 'group' or kind == 'dir' then
      -- VS Code draws a row's chevron 3 pixels right of centre in its slot.
      item.leading = row.expanded == nil and blank(assets)
        or control(assets, row.expanded and 'chevron-down' or 'chevron-right', fg, 3)
      item.count = row.count
      if kind == 'repo' then
        item.icon, item.bold = control(assets, 'repo', fg), true
        item.description = row.description ~= '' and clip(row.description) or nil
      elseif kind == 'dir' then
        file_icon(item, row.label, 'dir', row.expanded)
      end
      ancestors[depth + 1] = row.id
    elseif kind == 'file' then
      -- In a tree, a file keeps the space of the chevron it does not have,
      -- so its icon lines up with the folders beside it.
      if ui.mode == 'tree' then item.leading = blank(assets) end
      file_icon(item, row.label, 'file', false)
      item.description = row.description and clip(row.description) or nil
      item.strikethrough = row.strikethrough or nil
    end
    if row.badge then item.badge = {text=row.badge.text, color=BADGE_COLORS[row.badge.hl]} end
    if row.actions and kind ~= 'input' and kind ~= 'button' then
      local actions = {}
      for _, name in ipairs(row.actions) do
        local icon = control(assets, ACTION_ICONS[name], fg)
        if icon then actions[#actions + 1] = {id=name, icon=icon} end
      end
      if #actions > 0 then item.actions = actions end
    end
    -- The host refuses empty text on every row but an input.
    if item.text == '' and kind ~= 'input' then item.text = ' ' end
    out[i] = item
  end
  return out
end

-- Do, ahead of the first open, the work an open would otherwise wait for:
-- finding the icon theme and reading the icons these rows use.
function M.prewarm(opts, rows, ui)
  local assets = {}
  description(opts, ui, assets)
  M.rows(opts, rows, ui, assets)
end

-- The host's key names, in Vim notation.
local NAMED = {
  enter='<CR>', escape='<Esc>', up='<Up>', down='<Down>', left='<Left>', right='<Right>',
  backspace='<BS>', delete='<Del>', home='<Home>', ['end']='<End>', tab='<Tab>', space=' ',
  ['ctrl-b']='<C-b>', ['ctrl-shift-g']='<C-S-g>', ['ctrl-enter']='<C-CR>', ['cmd-enter']='<D-CR>',
  ['ctrl-a']='<C-a>', ['ctrl-e']='<C-e>', ['ctrl-u']='<C-u>', ['ctrl-w']='<C-w>',
}
-- What a key does while the Panel is not being typed into: the shared keys,
-- and two only this Renderer can receive.
local KEYS = vim.tbl_extend('force', require('scm.keys'), {['<Return>']='open', ['<D-CR>']='commit'})
-- What a key does while the commit box is being typed into. Any other key
-- that types text is inserted.
local EDIT_KEYS = {
  ['<Esc>']={'edit_end'}, ['<Up>']={'edit_end'},
  ['<CR>']={'edit_next'}, ['<Return>']={'edit_next'}, ['<Down>']={'edit_next'}, ['<Tab>']={'edit_next'},
  ['<C-CR>']={'commit'}, ['<D-CR>']={'commit'},
  ['<BS>']={'edit', 'backspace'}, ['<Del>']={'edit', 'delete'},
  ['<Left>']={'edit', 'left'}, ['<Right>']={'edit', 'right'},
  ['<Home>']={'edit', 'home'}, ['<End>']={'edit', 'end'},
  ['<C-a>']={'edit', 'home'}, ['<C-e>']={'edit', 'end'},
  ['<C-u>']={'edit', 'clear'}, ['<C-w>']={'edit', 'word'},
}

function M.open(opts, action, ready, failed)
  local view = {closed=false, revision=0, selected=1, rows_value={}, ui={}, registered={}, inline_edit=true}
  local function fail(err)
    if view.closed then return end
    view:close()
    failed(err)
  end
  function view:close()
    if self.closed then return end
    self.closed=true
    if self.dock then self.dock:close() end
  end
  function view:selection() return self.selected end
  -- Run fn once the host has the frame now on its way, or at once when none is.
  local waiters = {}
  local function frame_landed()
    local ready_now = waiters
    waiters = {}
    for _, fn in ipairs(ready_now) do fn() end
  end
  function view:after_frame(fn)
    if self.closed then return end
    if self.busy or self.pending then waiters[#waiters + 1] = fn else fn() end
  end
  function view:focus()
    if self.closed or not self.dock then return false end
    self.focused=true
    self.dock:focus(function(err) if err then fail(err) end end)
    return true
  end
  -- done(), when given, runs once the editor has the keyboard.
  function view:focus_editor(done)
    self.focused=true
    if not self.dock then if done then done() end; return end
    self.dock:focus_editor(function(err)
      if err then fail(err) elseif done and not self.closed then done() end
    end)
  end
  -- Register the icons in `assets` the host does not have yet, then done().
  local function register(assets, done)
    local fresh = {}
    for id, svg in pairs(assets) do
      if svg and not view.registered[id] then fresh[id] = svg end
    end
    if not next(fresh) then done(); return end
    view.dock:assets(fresh, function(err)
      if view.closed then return end
      if err then fail(err); return end
      for id in pairs(fresh) do view.registered[id] = true end
      done()
    end)
  end
  -- Send what a frame needs before its rows: new icons, then a new
  -- description when the view mode or the section's fold changed.
  local function prepare(assets, ui, done)
    register(assets, function()
      local key = description_key(ui)
      if key == view.described or not view.dock.update then view.described = key; done(); return end
      view.dock:update(description(opts, ui, assets), function(err)
        if view.closed then return end
        if err then fail(err); return end
        view.described = key
        done()
      end)
    end)
  end
  local flush
  flush = function()
    if view.closed or view.busy or not view.dock or not view.pending then return end
    local next_rows = view.pending
    view.pending=nil
    local whole
    if not view.applied and #next_rows.rows > M.FIRST_ROWS and next_rows.index <= M.FIRST_ROWS then
      whole = next_rows
      next_rows = {rows=vim.list_slice(whole.rows, 1, M.FIRST_ROWS), index=whole.index, ui=whole.ui}
    end
    local ui = next_rows.ui or {}
    local assets = {}
    -- Building the description registers the header icons it names.
    description(opts, ui, assets)
    local rows = M.rows(opts, next_rows.rows, ui, assets)
    local selected = rows[next_rows.index] and rows[next_rows.index].id
    -- A refresh that found nothing new draws the frame the host already has.
    -- Sending it again would cost a megabyte for a long list, many times over.
    if view.applied and view.sent and view.sent.selected == selected and view.described == description_key(ui)
      and vim.deep_equal(view.sent.rows, rows) then
      view.rows_value, view.ui, view.selected = next_rows.rows, ui, next_rows.index
      frame_landed()
      return
    end
    view.busy=true
    view.revision=view.revision+1
    local revision=view.revision
    prepare(assets, ui, function()
      view.dock:rows(revision, rows, selected, function(err)
        if view.closed or revision~=view.revision then return end
        view.busy=false
        if err then fail(err); return end
        view.sent={rows=rows, selected=selected}
        view.rows_value=next_rows.rows
        view.ui=ui
        view.selected=next_rows.index
        view.applied=revision
        -- The rest of a list that opened on its first screen, unless newer rows wait.
        if whole and not view.pending then view.pending = whole end
        if not view.focused then
          view.focused=true
          view.dock:focus(function(e) if e then fail(e) end end)
        end
        local delta=view.queued_delta or 0
        if delta~=0 and #(view.pending and view.pending.rows or view.rows_value)>0 then
          local pending=view.pending
          local target_rows=pending and pending.rows or view.rows_value
          local index=pending and pending.index or view.selected
          view.queued_delta=0
          index=math.max(1, math.min(#target_rows, index+delta))
          if #target_rows>0 then
            view.pending={rows=target_rows, index=index, ui=pending and pending.ui or view.ui}
          end
        elseif view.queued_activation and not view.pending then
          view.queued_activation=nil
          if view.rows_value[view.selected] then action('open', view.selected) end
        end
        -- Run last: a waiter may render, and must find this frame recorded.
        frame_landed()
        flush()
      end)
    end)
  end
  function view:render(rows, index, ui)
    self.pending={rows=rows, index=index, ui=ui or {}}
    -- Typing reaches the commit box at once, not when its rows are acknowledged.
    self.editing = (ui or {}).editing
    flush()
  end
  -- Move the selection to row `index` of the rows the host already has. Only
  -- the selection is sent; the rows are not.
  local function select(index)
    view.selected = index
    local row = view.rows_value[index]
    if not (row and view.dock.state) then view:render(view.rows_value, index, view.ui); return end
    -- The host's selection is now this row, whatever frame it last drew.
    if view.sent then view.sent.selected = row.id end
    view.dock:state(view.applied, {selected=row.id, reveal=row.id}, function(err)
      -- The host refused: what it shows is unknown, so the next frame is sent whole.
      if err then view.sent = nil end
      -- Rows that changed meanwhile carry their own selection.
      if err and not view.closed and not view.busy and not view.pending then
        view:render(view.rows_value, view.selected, view.ui)
      end
    end)
  end
  local function index_of(id)
    for i, row in ipairs(view.rows_value) do
      if row.id == id then return i end
    end
  end
  local function event(ev)
    if view.closed then return end
    if ev.type=='blur' or ev.type=='focus' then view.prefix=nil; return end
    if ev.type=='paste' and view.editing and type(ev.text)=='string' then
      -- A commit box holds one line: keep the first, without control bytes.
      action('edit', nil, {op='insert', text=(ev.text:gsub('[\r\n].*', ''):gsub('%c', ''))})
      return
    end
    local key
    if ev.type=='input' then
      key=NAMED[ev.key] or (ev.text and not ev.text:find('%c') and ev.text) or ev.key
      if view.editing then
        -- These act on the commit box itself, whatever row the host last
        -- acknowledged as selected, so no row index is passed.
        view.prefix=nil
        local edit = EDIT_KEYS[key]
        if edit then action(edit[1], nil, edit[2] and {op=edit[2]})
        elseif ev.text and not ev.text:find('%c') then action('edit', nil, {op='insert', text=ev.text}) end
        return
      end
      local now=vim.uv.now()
      if view.prefix and now-view.prefix_at > vim.o.timeoutlen then view.prefix=nil end
      if key==' ' then view.prefix=' '; view.prefix_at=now; return end
      if view.prefix then
        key=view.prefix .. key
        view.prefix=nil
        if key==' g' or key==' a' then view.prefix=key; view.prefix_at=now; return end
      end
      local mapping=((opts.native or {}).mappings or {})[key]
      if mapping then mapping(); return end
    end
    if ev.type=='input' and ev.key=='ctrl-l' and view.dock then
      view.prefix=nil
      action('editor', view.selected)
      return
    end
    if view.busy then
      if ev.type=='input' then
        local raw=ev.key
        if raw=='j' or raw=='down' or raw=='<Down>' then
          view.queued_delta=(view.queued_delta or 0)+1
        elseif raw=='k' or raw=='up' or raw=='<Up>' then
          view.queued_delta=(view.queued_delta or 0)-1
        elseif raw=='enter' or raw=='return' or raw=='<CR>' or raw=='<Return>' then
          view.queued_activation='open'
        end
      end
      return
    end
    if not view.applied then return end
    if ev.type=='list_click' and ev.revision==view.applied and ev.button=='left' then
      local i = index_of(ev.id)
      if i then
        select(i)
        action('open', i)
      end
    elseif ev.type=='list_action' and ev.revision==view.applied then
      -- A button on a row acts on that row; one in a header acts on the Panel.
      local i = ev.row and index_of(ev.row)
      if i then
        select(i)
        action(ev.action, i)
      elseif not ev.row then
        action(ev.action, view.selected)
      end
    elseif ev.type=='input' then
      if key=='j' or key=='<Down>' or key=='k' or key=='<Up>' then
        local delta=(key=='j' or key=='<Down>') and 1 or -1
        select(math.max(1, math.min(#view.rows_value, view.selected+delta)))
      else
        -- The host reports a leading space as itself; the shared keys spell it out.
        local name=KEYS[(key:gsub('^ ', '<Space>'))]
        if name then action(name, view.selected) end
      end
    end
  end
  local ok, sprite = pcall(require,'sprite')
  if not ok then fail({message='Sprite API is unavailable'}); return view end
  Icons.reset()
  local assets = {}
  local first = description(opts, {}, assets)
  sprite.open({side='left', width=opts.native_width or 300, description=first,
    on_event=event, on_close=function(reason) fail(reason) end}, function(open_err, dock)
    if view.closed then if dock then dock:close() end; return end
    if open_err then fail(open_err); return end
    if not (dock.features or {})[M.FEATURE] then
      dock:close()
      fail({message='this Sprite Terminal cannot draw the Source Control panel; update Sprite and sprite.nvim'})
      return
    end
    view.dock=dock
    view.described=description_key({})
    -- The header's icons are registered with the first frame's, in one
    -- message sent at once. The host is busy for a moment after it opens a
    -- dock, and a second message would wait that out before any row showed.
    ready(view)
    -- With no frame on its way, the header's icons are registered alone.
    if not view.busy and not view.closed then register(assets, function() end) end
  end)
  return view
end
return M
