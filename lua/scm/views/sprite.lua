local M = {}
local function description(opts)
  return {version=1, root={kind='virtual_list', border_side='right',
    row_height=22, font_size=13, font_family='system', icon_size=16, icon_gap=6,
    left_padding=8, right_padding=8, scrollbar_width=10, guide_visibility='hover',
    inactive_guide_opacity=0.4, scrollbar_opacity=0.4, scrollbar_hover_opacity=0.7,
    scrollbar_active_opacity=0.4,
    heading={text='SOURCE CONTROL', height=35, font_size=11, left_padding=20},
    colors=vim.tbl_extend('force', {background='#181818', foreground='#cccccc', hover='#2a2d2e',
      selected='#04395e', inactive_selected='#37373d', selected_foreground='#ffffff',
      focus='#0078d4', guide='#585858', inactive_guide='#585858', border='#2b2b2b',
      scrollbar='#424242', scrollbar_hover='#646464', scrollbar_active='#bfbfbf'}, (opts.native or {}).colors or {})}}
end
function M.open(opts, action, ready, failed)
  local view = {closed=false, revision=0, selected=1, rows_value={}}
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
  function view:focus()
    if self.closed or not self.dock then return false end
    self.focused=true
    self.dock:focus(function(err) if err then fail(err) end end)
    return true
  end
  function view:focus_editor()
    self.focused=true
    if self.dock then self.dock:focus_editor(function(err) if err then fail(err) end end) end
  end
  local flush
  flush = function()
    if view.closed or view.busy or not view.dock or not view.pending then return end
    local next_rows = view.pending
    view.pending=nil
    view.busy=true
    view.revision=view.revision+1
    local revision=view.revision
    local rows={}
    for i, row in ipairs(next_rows.rows) do
      rows[i]={id=row.id, text=row.text, indent=0, guides={}}
    end
    view.dock:rows(revision, rows, rows[next_rows.index] and rows[next_rows.index].id, function(err)
      if view.closed or revision~=view.revision then return end
      view.busy=false
      if err then fail(err); return end
      view.rows_value=next_rows.rows
      view.selected=next_rows.index
      view.applied=revision
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
          view.pending={rows=target_rows, index=index}
        end
      elseif view.queued_activation then
        view.queued_activation=nil
        if view.rows_value[view.selected] then action('open', view.selected) end
      end
      flush()
    end)
  end
  function view:render(rows, index)
    self.pending={rows=rows, index=index}
    flush()
  end
  local function event(ev)
    if view.closed then return end
    if ev.type=='input' and ev.key=='ctrl-l' and view.dock then
      view.prefix=nil
      action('editor', view.selected)
      return
    end
    if view.busy then
      if ev.type=='input' then
        local key=ev.key
        if key=='j' or key=='down' or key=='<Down>' then
          view.queued_delta=(view.queued_delta or 0)+1
        elseif key=='k' or key=='up' or key=='<Up>' then
          view.queued_delta=(view.queued_delta or 0)-1
        elseif key=='enter' or key=='return' or key=='<CR>' or key=='<Return>' then
          view.queued_activation='open'
        end
      end
      return
    end
    if not view.applied then return end
    if ev.type=='blur' or ev.type=='focus' then view.prefix=nil; return end
    if ev.type=='list_click' and ev.revision==view.applied and ev.button=='left' then
      for i,row in ipairs(view.rows_value) do
        if row.id==ev.id then
          view.selected=i
          action('open',i)
          return
        end
      end
    elseif ev.type=='input' then
      local key=ev.key
      local named={enter='<CR>', escape='<Esc>', up='<Up>', down='<Down>',
        ['ctrl-b']='<C-b>', ['ctrl-shift-g']='<C-S-g>', space=' '}
      key=named[key] or (ev.text and not ev.text:find('%c') and ev.text) or key
      local now=vim.uv.now()
      if view.prefix and now-view.prefix_at > vim.o.timeoutlen then view.prefix=nil end
      if key==' ' then view.prefix=' '; view.prefix_at=now; return end
      if view.prefix then
        key=view.prefix .. key
        view.prefix=nil
        if key==' g' then view.prefix=key; view.prefix_at=now; return end
      end
      if key=='j' or key=='<Down>' or key=='k' or key=='<Up>' then
        local delta=(key=='j' or key=='<Down>') and 1 or -1
        view.selected=math.max(1, math.min(#view.rows_value, view.selected+delta))
        view:render(view.rows_value, view.selected)
      else
        local name=({['<CR>']='open', ['<Return>']='open', l='expand', h='collapse', r='refresh',
          q='close', ['<Esc>']='editor', [' gs']='close', ['<C-S-g>']='close',
          [' e']='explorer', ['<C-b>']='explorer'})[key]
        if name then action(name, view.selected) end
      end
    end
  end
  local ok, sprite = pcall(require,'sprite')
  if not ok then fail({message='Sprite API is unavailable'}); return view end
  sprite.open({side='left', width=opts.native_width or 300, description=description(opts),
    on_event=event, on_close=function(reason) fail(reason) end}, function(open_err, dock)
    if view.closed then if dock then dock:close() end; return end
    if open_err then fail(open_err); return end
    view.dock=dock
    dock:assets({}, function(asset_err)
      if view.closed then return end
      if asset_err then fail(asset_err); return end
      ready(view)
    end)
  end)
  return view
end
return M
