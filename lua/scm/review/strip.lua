-- scm.review.strip — the strip under a diff that holds the Flow Map and the
-- row of keys. In a Sprite Terminal that can dock a Surface under the editor
-- the map is a picture; anywhere else it is a small window of characters.
-- There is one strip, under the diff the reader is in.
local Flow = require('scm.review.flow')
local M = {}
local ns = vim.api.nvim_create_namespace('scm.review.strip')

-- The host feature that docks a Surface under the editor.
M.FEATURE = 'dock-bottom-v1'
-- The picture is this many pixels tall, and a short editor shows one row instead.
local DOCK_HEIGHT, SHORT_LINES = 252, 36
-- A diff keeps at least this many rows when the strip opens under it.
local MIN_DIFF = 8
-- Pixels of the dock kept free under the picture.
local DOCK_SPARE = 24

local strip   -- the window of characters: {win, buf, parent}
local dock    -- the picture: {handle, width, opening, sent}
local options = {}
local shown   -- what is on screen now, to skip drawing it again
local closes = 0  -- how many times the host has closed the dock
local dock_height, dock_width  -- the height the picture needs at the dock's last known width, and that width

function M.setup(opts)
  options = opts or {}
  -- A dock refused under other options may be tried again.
  if dock == false then dock = nil end
  closes = 0
end

local function close_window()
  local old = strip
  strip = nil
  if not (old and vim.api.nvim_win_is_valid(old.win)) then return end
  if pcall(vim.api.nvim_win_close, old.win, true) then return end
  vim.schedule(function()
    if not vim.api.nvim_win_is_valid(old.win) or pcall(vim.api.nvim_win_close, old.win, true) then return end
    -- The strip is the last window left, which cannot be closed: it becomes
    -- an ordinary empty one.
    vim.api.nvim_win_call(old.win, function() vim.cmd('enew') end)
    for name, value in pairs({winbar='', statusline='', winhighlight='', winfixheight=false, winfixwidth=false}) do
      pcall(vim.api.nvim_set_option_value, name, value, {win=old.win, scope='local'})
    end
  end)
end

local function close_dock()
  local old = dock
  dock = nil
  if old and old.handle then old.handle:close() end
end

function M.close()
  close_window()
  close_dock()
  shown = nil
end

-- Whether a window too short for the map shows one row of it instead.
function M.short()
  -- The dock takes its rows from the editor. Counting the editor as short
  -- because of that would close the dock, which gives the rows back, which
  -- opens it again: so while the picture is up only a very short editor counts.
  if dock then return vim.o.lines < 12 end
  return vim.o.lines < SHORT_LINES
end

-- The rows `parent` has to share with a strip of characters under it.
local function room(parent)
  local rows = vim.api.nvim_win_get_height(parent)
  if strip and strip.parent == parent and vim.api.nvim_win_is_valid(strip.win) then
    rows = rows + vim.api.nvim_win_get_height(strip.win) + 1
  end
  return rows
end

-- Rows of pieces as buffer lines and the highlights over them.
local function write(buf, rows)
  local lines, marks = {}, {}
  for i, pieces in ipairs(rows) do
    local text = ''
    for _, piece in ipairs(pieces) do
      if piece[1] ~= '' then
        marks[#marks + 1] = {i - 1, #text, #text + #piece[1], piece[2]}
        text = text .. piece[1]
      end
    end
    lines[i] = text
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], {end_col=mark[3], hl_group=mark[4]})
  end
end

local function escape(text) return (text:gsub('%%', '%%%%')) end

-- Show `rows` in a window under `parent`, with `heading` above them.
local function window(parent, rows, heading)
  if strip and not (vim.api.nvim_win_is_valid(strip.win) and strip.parent == parent) then close_window() end
  if not strip then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
    vim.b[buf].scm_review_strip = true
    local win = vim.api.nvim_open_win(buf, false, {split='below', win=parent, height=#rows, noautocmd=true})
    for name, value in pairs({number=false, relativenumber=false, signcolumn='no', foldcolumn='0', wrap=false,
      cursorline=false, spell=false, list=false, statuscolumn='', winfixheight=true,
      -- A fixed-width window is never taken for a file or a diff.
      winfixwidth=true, statusline='%#ScmReviewStrip#',
      winhighlight='Normal:ScmReviewStrip,EndOfBuffer:ScmReviewStrip'}) do
      vim.api.nvim_set_option_value(name, value, {win=win, scope='local'})
    end
    strip = {win=win, buf=buf, parent=parent}
  end
  local bar = ''
  if heading then
    -- A heading too long for the window loses its end, not its start.
    local room = vim.api.nvim_win_get_width(strip.win) - 28
    if vim.fn.strdisplaywidth(heading) > room then
      heading = vim.fn.strcharpart(heading, 0, math.max(0, room - 1)) .. '…'
    end
    bar = '%#ScmReviewBarTitle# HOW THIS LINE GETS RUN  %#ScmReviewPredictedBar#≈ %#ScmReviewBarDim#' .. escape(heading)
  end
  if vim.wo[strip.win].winbar ~= bar then vim.wo[strip.win].winbar = bar end
  -- The heading is a row of the window too.
  local height = #rows + (heading and 1 or 0)
  if vim.api.nvim_win_get_height(strip.win) ~= height then
    pcall(vim.api.nvim_win_set_height, strip.win, height)
  end
  write(strip.buf, rows)
end

local function description(svg, background)
  return {version=1, root={kind='box', style='size_full overflow_hidden', bg=background,
    children={{kind='image', svg=svg, style='w_full h_full'}}}}
end

-- Draw the picture in the dock, opening it first. Returns false when this
-- host cannot dock one, so the caller draws characters instead.
local function picture(content)
  if options.map == 'text' or dock == false then return false end
  local ok, sprite = pcall(require, 'sprite')
  if not ok or type(sprite.open) ~= 'function' then dock = false; return false end
  local Svg = require('scm.review.flowsvg')
  local function draw()
    local width = dock.width or 1200
    local key = table.concat({content.key, width}, ':')
    if dock.sent == key then return end
    dock.sent = key
    local svg, height = Svg.svg(content.flow, {width=width / (options.map_scale or 1), file=content.file,
      line=content.line, hints=content.hints, mono=options.font, colors=options.colors,
      -- The host paints the picture at its own size, so it is drawn at
      -- twice the dock's and scaled down to stay sharp.
      density=options.map_density or 2})
    -- A narrow dock scales the picture down, which leaves the dock taller
    -- than it. Once the dock's width is known it is opened again at the
    -- picture's own height, so no empty band is left above the map.
    -- A little more than the picture: hosts differ by a few pixels in how
    -- they fit a picture to its room, and the row of keys is its last row.
    local fitted = math.max(64, math.ceil(height * (options.map_scale or 1))) + DOCK_SPARE
    if dock.width and math.abs(fitted - dock.height) > 3 and not dock.refitted then
      dock_height, dock_width = fitted, dock.width
      close_dock()
      shown = nil
      vim.schedule(M.refresh)
      return
    end
    dock.handle:update(description(svg, (options.colors or {}).background or Svg.COLORS.background), function(err)
      if err and dock then dock.sent = nil end
    end)
  end
  -- What a later change of the dock's width draws again.
  if dock then dock.content = content end
  if dock and dock.handle then draw(); return true end
  if dock and dock.opening then return true end
  local asked = dock_height or (math.floor(DOCK_HEIGHT * (options.map_scale or 1)) + DOCK_SPARE)
  -- A dock opened at a fitted height is not fitted again until its width changes.
  dock = {opening=true, content=content, height=asked, refitted=dock_height ~= nil, width=dock_width}
  local opening = dock
  sprite.open({side='bottom', height=asked,
    description=description('<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"/>',
      (options.colors or {}).background or Svg.COLORS.background),
    on_event=function(event)
      if dock ~= opening then return end
      if event.type == 'resize' and type(event.width) == 'number' and event.width ~= dock.width then
        -- The first width a dock reports is the one it was opened for.
        if dock.width then dock.refitted = false end
        dock.width = event.width
        if dock.content then content = dock.content; draw() end
      elseif event.type == 'focus' or event.type == 'input' then
        -- The map is only looked at: the keyboard goes back to the editor.
        dock.handle:focus_editor()
      end
    end,
    on_close=function()
      if dock ~= opening then return end
      -- The host took the dock away, as it does when the editor is put to
      -- sleep. It is asked for again the next time the map is drawn; a host
      -- that keeps closing it gets characters.
      closes = closes + 1
      dock, shown = closes > 2 and false or nil, nil
      if dock == false then M.refresh() end
    end,
  }, function(err, handle)
    if dock ~= opening then if handle then handle:close() end; return end
    if err then
      -- This host has no dock for the map: characters from here on.
      dock, shown = false, nil
      M.refresh()
      return
    end
    dock.opening, dock.handle = nil, handle
    content = dock.content or content
    draw()
  end)
  return true
end

local last  -- what M.show was last asked for, to draw again after a dock fails

function M.refresh()
  if last then M.show(last.parent, last.content) end
end

-- Show the strip under window `parent`. `content` holds:
--   key     what the strip shows, so the same thing is not drawn twice
--   flow    the Flow Map, or nil when there is none for this line
--   file, line  the file's name and the reader's line
--   hints   the keys: {{text, strong}...}
--   brief   true to show one row instead of the map
-- With no content the strip is taken away.
function M.show(parent, content)
  if not content then last = nil; M.close(); return end
  last = {parent=parent, content=content}
  -- The strip never leaves the diff with fewer rows than MIN_DIFF.
  local available = room(parent)
  local key = table.concat({parent, content.key, tostring(content.brief), tostring(dock), available}, ':')
  if shown == key and (strip == nil or vim.api.nvim_win_is_valid(strip.win)) then return end
  shown = key
  local hints = {}
  for _, hint in ipairs(content.hints) do hints[#hints + 1] = {hint[1], hint[2] and 'ScmReviewHintKey' or 'ScmReviewHint'} end
  table.insert(hints, 1, {' ', 'ScmReviewHint'})
  -- A dock already up is left alone: closing it would give the rows back and open it again.
  if available < MIN_DIFF + 2 and not dock then close_window(); return end
  if not content.flow then
    close_dock()
    window(parent, {hints})
    return
  end
  local rows = not content.brief and Flow.text(content.flow, content.line)
  -- The map in characters is tall: a diff with no room for it gets one row.
  local fits = rows and available - (#rows + 3) >= MIN_DIFF
  if rows and not fits and (options.map == 'text' or dock == false) then rows = nil end
  if not rows then
    close_dock()
    local row = Flow.brief(content.flow, content.line)
    table.insert(row, 1, {' ', 'ScmReviewDim'})
    vim.list_extend(row, {{'    \\m', 'ScmReviewHintKey'}, {' map', 'ScmReviewHint'}})
    window(parent, {row})
    return
  end
  if picture(content) then close_window(); return end
  if not fits then
    -- No picture after all, and no room for the map in characters.
    shown = nil
    return M.show(parent, vim.tbl_extend('force', content, {brief=true}))
  end
  for _, row in ipairs(rows) do table.insert(row, 1, {' ', 'ScmReviewDim'}) end
  rows[#rows + 1] = hints
  window(parent, rows, Flow.caption(content.flow, content.file))
end

-- The window the strip is under, or nil when there is no strip.
function M.parent()
  if strip and vim.api.nvim_win_is_valid(strip.win) then return strip.parent end
  return dock and last and last.parent or nil
end

-- The strip's window of characters, or nil.
function M.window() return strip and vim.api.nvim_win_is_valid(strip.win) and strip.win or nil end
-- Whether the map is being shown as a picture.
function M.docked() return dock and true or false end

return M
