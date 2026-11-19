-- scm.review — reading a diff to learn from it. A Review is an Explainer's
-- account of one file's change: a Tour through the changes, a Pane that
-- explains the line the cursor is on and predicts its values, and a Flow Map
-- of how that line gets run. This module
-- asks for Reviews, keeps them, and shows them around the diff.
local Schema = require('scm.review.schema')
local Prompt = require('scm.review.prompt')
local Explainers = require('scm.review.explainers')
local Pane = require('scm.review.pane')
local Strip = require('scm.review.strip')
local M = {}
local static = vim.api.nvim_create_namespace('scm.review.static')
local bar_ns = vim.api.nvim_create_namespace('scm.review.bar')
local pane_ns = vim.api.nvim_create_namespace('scm.review.pane')
local paint_ns = vim.api.nvim_create_namespace('scm.review')

local options = {enabled=true, auto=false}
local lookup = function() return nil end  -- buffer -> the diff's view
local shown = true     -- whether the Pane is shown
local map_brief        -- the reader's choice of one row or the whole map; nil follows the window
local bars = {}        -- window -> the Tour bar floating at its top
local panes = {}       -- window -> the Pane floating at its right, and the side it is on
local answers = {}     -- "key:row:question" -> an answer already given
local last_diff        -- the window of the diff the reader was last in

local function mix(top, bottom, alpha)
  local out = 0
  for shift = 16, 0, -8 do
    local t, b = bit.band(bit.rshift(top, shift), 255), bit.band(bit.rshift(bottom, shift), 255)
    out = out + bit.lshift(math.floor(t * alpha + b * (1 - alpha) + 0.5), shift)
  end
  return out
end

-- The colours of the Review. Text is never brighter than the editor's own:
-- a heading is bold, not whiter.
function M.highlights()
  local function color(name, key, fallback)
    return vim.api.nvim_get_hl(0, {name=name, link=false})[key] or fallback
  end
  local dark = vim.o.background == 'dark'
  local bg = color('Normal', 'bg', dark and 0x1e1f22 or 0xffffff)
  local fg = color('Normal', 'fg', dark and 0xacb2be or 0x333333)
  -- On a light background each hue is darkened to stay readable.
  local function hue(value) return dark and value or mix(value, 0x000000, 0.6) end
  local blue, amber, teal, violet = hue(0x73ade9), hue(0xd9a35c), hue(0x7fc9c0), hue(0xa78bd0)
  local green, red = hue(0x8fbf7a), hue(0xd07277)
  local function soft(alpha) return mix(fg, bg, alpha) end
  local current = mix(blue, bg, 0.26)
  local pane = soft(0.05)
  local bar = mix(blue, bg, 0.17)
  for name, value in pairs({
    ScmReviewCurrentLine={bg=current},
    ScmReviewPane={fg=soft(0.92), bg=pane}, ScmReviewPaneBorder={fg=mix(blue, bg, 0.34), bg=pane},
    ScmReviewPaneHead={bg=mix(blue, pane, 0.13)}, ScmReviewPaneLine={fg=blue, bold=true},
    ScmReviewPaneAdd={fg=green, bold=true}, ScmReviewPaneDelete={fg=red, bold=true},
    ScmReviewPaneLabel={fg=soft(0.8)}, ScmReviewPaneText={fg=soft(0.96)}, ScmReviewPaneGist={fg=fg, bold=true},
    ScmReviewPaneProse={fg=soft(0.9)}, ScmReviewPaneStrong={fg=fg, bold=true},
    ScmReviewPaneTitle={fg=fg, bold=true}, ScmReviewPanePredicted={fg=amber}, ScmReviewPaneBar={fg=amber},
    ScmReviewPaneValue={fg=teal, bold=true}, ScmReviewPaneKey={fg=fg, bold=true},
    ScmReviewPaneMore={fg=soft(0.72), italic=true}, ScmReviewCut={fg=soft(0.72)},
    ScmReviewBar={fg=soft(0.9), bg=bar}, ScmReviewBarTitle={fg=fg, bg=bar, bold=true},
    ScmReviewBarDim={fg=soft(0.86), bg=bar}, ScmReviewBarDone={fg=green, bg=bar},
    ScmReviewBarDot={fg=blue, bg=bar}, ScmReviewPredictedBar={fg=amber, bg=bar},
    ScmReviewBarError={fg=red, bg=bar},
    ScmReviewTour={fg=blue}, ScmReviewTourBar={fg=mix(blue, bg, 0.62)},
    ScmReviewStrip={fg=fg, bg=bg}, ScmReviewDim={fg=soft(0.86)}, ScmReviewName={fg=fg, bold=true},
    ScmReviewHere={fg=blue, bold=true}, ScmReviewLater={fg=violet}, ScmReviewRule={fg=soft(0.55)},
    ScmReviewLane={fg=soft(0.86), bold=true}, ScmReviewKey={fg=fg, bg=soft(0.17)},
    ScmReviewHint={fg=soft(0.86)}, ScmReviewHintKey={fg=fg, bold=true},
    ScmReviewFloat={fg=soft(0.96), bg=soft(0.05)}, ScmReviewFloatTitle={fg=fg, bg=soft(0.05), bold=true},
  }) do
    value.default = true
    vim.api.nvim_set_hl(0, name, value)
  end
end

local function state_of(view)
  view.review = view.review or {status='none', visited={}, steps={}}
  return view.review
end

-- The diff the cursor is in: its window, view and state.
local function here()
  local win = vim.api.nvim_get_current_win()
  local view = lookup(vim.api.nvim_win_get_buf(win))
  if not view then return nil end
  return win, view, state_of(view)
end

-- The row of the diff that shows line `number` of the new file.
local function row_of(view, number)
  for row, line in ipairs(view.meta) do
    if line.new == number then return row end
  end
end

local function current_step(view, state, win)
  local line = view.meta[vim.api.nvim_win_get_cursor(win)[1]]
  local at = line and line.new and Schema.step_at(state.data, line.new)
  -- On a removed line, the step is the one its change belongs to.
  if not at and line and line.kind == '-' then
    local row = vim.api.nvim_win_get_cursor(win)[1]
    while view.meta[row] and view.meta[row].kind == '-' do row = row + 1 end
    local next_line = view.meta[row]
    at = next_line and next_line.new and Schema.step_at(state.data, next_line.new) or nil
  end
  return at
end

-- What the prefix of the gutter shows for `row`: a mark on the line the
-- reader is on and a bar beside the other lines of the Tour step.
function M.gutter(view, row, cursor)
  local state = view.review
  -- While a gutter is drawn, the window it belongs to is the current one.
  local at = state and state.steps[vim.api.nvim_get_current_win()]
  if not (options.enabled and state and state.data and at) then return ' ' end
  local step = state.data.tour[at]
  if not step then return ' ' end
  local line = view.meta[row]
  local inside = line and line.new and line.new >= step.from and line.new <= step.to
  if row == cursor and inside then return '%#ScmReviewTour#▶' end
  if inside then return '%#ScmReviewTourBar#▏' end
  return ' '
end

-- Whether the gutter needs the extra cell M.gutter fills.
function M.has_gutter(view)
  local state = view.review
  return options.enabled and state ~= nil and state.data ~= nil and #state.data.tour > 0
end

-- The Flow Map for the line the cursor is on in `win`, or failing that for
-- the Tour step it is in. Also returns the line's number and the step.
local function flow_here(view, state, win)
  local line = view.meta[vim.api.nvim_win_get_cursor(win)[1]]
  local number = line and line.new
  local flow = number and Schema.flow_at(state.data, number)
  local at = state.steps[win]
  if not flow and at and state.data.tour[at] then flow = Schema.flow_at(state.data, state.data.tour[at].from) end
  return flow, number, at
end

-- The keys shown under the diff, in at most `width` cells. A window too
-- narrow for all of them drops whole keys, the least needed first, so that
-- none is cut in the middle.
local function hints(state, at, mapped, width)
  local keys = {}
  -- `keep` orders what goes when there is no room: the lowest goes first.
  local function add(key, text, keep) keys[#keys + 1] = {key=key, text=text, keep=keep} end
  local tour = state.data.tour
  if #tour > 1 then
    local next_step = (at or 0) % #tour + 1
    add(']t', (' next step (%d of %d)'):format(next_step, #tour), 7)
    add('[t', ' previous', 1)
  end
  add('K', ' full explanation', 5)
  add('\\a', ' ask', 2)
  -- The key is offered only where it does something.
  if mapped then add('\\m', ' map', 4) elseif #state.data.flows > 0 then add('', 'no map for this line', 0) end
  add('\\e', ' pane: ' .. (shown and 'on' or 'off'), 3)
  add('g?', ' all keys', 6)
  local function cells()
    local total = 1
    for _, item in ipairs(keys) do total = total + vim.fn.strdisplaywidth(item.key .. item.text) + 3 end
    return total - 3
  end
  while #keys > 1 and cells() > width do
    local least = 1
    for i, item in ipairs(keys) do
      if item.keep < keys[least].keep then least = i end
    end
    table.remove(keys, least)
  end
  local out = {}
  for i, item in ipairs(keys) do
    if item.key ~= '' then out[#out + 1] = {item.key, true} end
    out[#out + 1] = {item.text .. (i < #keys and '   ' or '')}
  end
  return out
end

local function close_bar(win)
  local bar = bars[win]
  bars[win] = nil
  -- The window scrolls by its own rules again.
  if bar and bar.scrolloff and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value('scrolloff', -1, {win=win, scope='local'})
  end
  if not (bar and vim.api.nvim_win_is_valid(bar.win)) then return end
  if not pcall(vim.api.nvim_win_close, bar.win, true) then
    vim.schedule(function() pcall(vim.api.nvim_win_close, bar.win, true) end)
  end
end

-- What the Tour bar of window `win` says: pieces at the left, and text at the right.
local function bar_text(state, win)
  local service = Explainers.active()
  local name = service and service.name or 'an Explainer'
  if state.status == 'asking' then
    local seconds = math.floor((vim.uv.now() - state.started) / 1000)
    return {{' ' .. name .. ' is reading this change… ', 'ScmReviewBarTitle'}, {seconds .. 's', 'ScmReviewBarDim'}}, ''
  elseif state.status == 'failed' then
    return {{' Could not explain this change: ', 'ScmReviewBarError'}, {state.error or '', 'ScmReviewBar'},
      {'   \\e', 'ScmReviewBarTitle'}, {' try again', 'ScmReviewBarDim'}}, ''
  elseif state.status ~= 'ready' then
    return {{' \\e', 'ScmReviewBarTitle'}, {' explain this change with ' .. name, 'ScmReviewBarDim'}}, ''
  end
  local tour = state.data.tour
  if #tour == 0 then
    return {{' REVIEW', 'ScmReviewBarTitle'}, {' · the pane at the right explains the line you are on', 'ScmReviewBarDim'}}, ''
  end
  local at = state.steps[win]
  local pieces = {{' TOUR', 'ScmReviewBarTitle'},
    {at and (' · step %d of %d  '):format(at, #tour) or (' · %d steps  '):format(#tour), 'ScmReviewBarTitle'}}
  for i = 1, #tour do
    if i == at then pieces[#pieces + 1] = {'● ', 'ScmReviewBarDot'}
    elseif state.visited[i] then pieces[#pieces + 1] = {'✓ ', 'ScmReviewBarDone'}
    else pieces[#pieces + 1] = {'○ ', 'ScmReviewBarDim'} end
  end
  local step = at and tour[at]
  if not step then
    pieces[#pieces + 1] = {' ]t', 'ScmReviewBarTitle'}
    pieces[#pieces + 1] = {' start the tour', 'ScmReviewBarDim'}
    return pieces, ''
  end
  pieces[#pieces + 1] = {' ' .. step.title, 'ScmReviewBarTitle'}
  if step.summary then pieces[#pieces + 1] = {'   ' .. step.summary, 'ScmReviewBar'} end
  local lines = step.from == step.to and ('line ' .. step.from) or ('lines ' .. step.from .. '–' .. step.to)
  return pieces, lines .. ' '
end

-- The most rows the Tour bar takes.
local BAR_ROWS = 4

-- Break the Tour bar's pieces into rows `width` cells wide, at spaces. The
-- first row leaves `first` cells free at its end; later rows start one cell in.
local function bar_rows(pieces, width, first, most)
  local rows, row, used = {}, {}, 0
  local function limit() return #rows == 0 and width - first - 1 or width - 1 end
  for _, piece in ipairs(pieces) do
    for space, word in piece[1]:gmatch('(%s*)(%S*)') do
      if space ~= '' or word ~= '' then
        local token = space .. word
        if used > 1 and used + vim.fn.strdisplaywidth(token) > limit() then
          rows[#rows + 1] = row
          row, used, token = {{' ', piece[2]}}, 1, word
        end
        -- A word wider than a whole row is broken where the row ends.
        while vim.fn.strdisplaywidth(token) > limit() - used and limit() - used > 1 do
          local part = vim.fn.strcharpart(token, 0, limit() - used)
          while vim.fn.strdisplaywidth(part) > limit() - used do part = vim.fn.strcharpart(part, 0, vim.fn.strchars(part) - 1) end
          if part == '' then break end
          row[#row + 1] = {part, piece[2]}
          rows[#rows + 1] = row
          token = vim.fn.strcharpart(token, vim.fn.strchars(part))
          row, used = {{' ', piece[2]}}, 1
        end
        if token ~= '' then
          row[#row + 1] = {token, piece[2]}
          used = used + vim.fn.strdisplaywidth(token)
        end
      end
    end
  end
  if #row > 0 then rows[#rows + 1] = row end
  if #rows == 0 then rows[1] = {} end
  -- Only a window too short for it leaves any of the bar unsaid.
  if #rows > most then
    rows = vim.list_slice(rows, 1, most)
    local last = rows[most]
    last[#last + 1] = {'…', last[#last] and last[#last][2] or 'ScmReviewBar'}
  end
  return rows
end

-- The rows the Tour bar of `win` covers.
local function bar_height(win)
  return bars[win] and bars[win].rows or 0
end

-- Draw the Tour bar across the top of the diff in `win`. It is one row
-- unless what it says needs more.
local function draw_bar(win, state)
  if state.status == 'nothing' then close_bar(win); return end
  local info = vim.fn.getwininfo(win)[1]
  if info.height < 4 or info.width < 30 then close_bar(win); return end
  local pieces, right = bar_text(state, win)
  local rows = bar_rows(pieces, info.width, vim.fn.strdisplaywidth(right), math.max(1, math.min(BAR_ROWS, info.height - 3)))
  local place = {relative='win', win=win, row=0, col=0, width=info.width, height=#rows}
  local shape = info.width .. ':' .. #rows
  local bar = bars[win]
  if bar and vim.api.nvim_win_is_valid(bar.win) then
    if bar.shape ~= shape then vim.api.nvim_win_set_config(bar.win, place) end
  else
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    place.focusable, place.style, place.zindex, place.noautocmd = false, 'minimal', 21, true
    bar = {win=vim.api.nvim_open_win(buf, false, place), buf=buf, scrolloff=true}
    vim.wo[bar.win].winhighlight = 'Normal:ScmReviewBar,NormalFloat:ScmReviewBar'
    vim.wo[bar.win].wrap = false
    bars[win] = bar
  end
  bar.shape, bar.rows = shape, #rows
  local lines, marks = {}, {}
  for i, row in ipairs(rows) do
    local text = ''
    for _, piece in ipairs(row) do
      marks[#marks + 1] = {i - 1, #text, #text + #piece[1], piece[2]}
      text = text .. piece[1]
    end
    if i == 1 then
      local before = #text + math.max(1, info.width - vim.fn.strdisplaywidth(right) - vim.fn.strdisplaywidth(text))
      text = text .. (' '):rep(before - #text) .. right
      marks[#marks + 1] = {0, before, #text, 'ScmReviewBarDim'}
    end
    lines[i] = text
  end
  local all = table.concat(lines, '\n')
  if bar.line ~= all then
    bar.line = all
    vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(bar.buf, bar_ns, 0, -1)
    for _, mark in ipairs(marks) do
      if mark[3] > mark[2] then
        vim.api.nvim_buf_set_extmark(bar.buf, bar_ns, mark[1], mark[2], {end_col=mark[3], hl_group=mark[4]})
      end
    end
  end
  -- As many blank rows wait above line 1 as the tallest bar over this diff needs.
  if #rows > (state.filler or 0) then
    state.filler = #rows
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_line_count(buf) > 0 then
      local blank = {}
      for i = 1, #rows do blank[i] = {{'', 'Normal'}} end
      vim.api.nvim_buf_set_extmark(buf, static, 0, 0, {id=1, virt_lines=blank, virt_lines_above=true})
    end
  end
end

-- The Tour bar covers the window's first rows, so the file's first lines
-- are kept under it by blank rows drawn above line 1.
local function keep_first_line(win)
  local rows = bar_height(win)
  -- The cursor's line is kept out from under the bar everywhere else by
  -- never letting it be among the window's first rows.
  local want = math.max(vim.go.scrolloff, rows)
  if vim.wo[win].scrolloff ~= want then
    vim.api.nvim_set_option_value('scrolloff', want, {win=win, scope='local'})
  end
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    -- Only while the cursor would be under the bar: with the cursor lower, the
    -- reader may scroll line 1 under the bar like any other line.
    if view.topline == 1 and view.topfill < rows and vim.fn.winline() <= rows then
      vim.fn.winrestview({topfill=rows})
    end
  end)
end

local function redraw(win)
  if vim.api.nvim__redraw then
    pcall(vim.api.nvim__redraw, {win=win, valid=false, statuscolumn=true})
  else
    vim.cmd('redraw!')
  end
end

local function close_pane(win)
  local pane = panes[win]
  panes[win] = nil
  if not (pane and pane.win and vim.api.nvim_win_is_valid(pane.win)) then return end
  if not pcall(vim.api.nvim_win_close, pane.win, true) then
    vim.schedule(function() pcall(vim.api.nvim_win_close, pane.win, true) end)
  end
end

-- Take the Pane of `win` off the screen but remember which side it was on.
local function hide_pane(win, state)
  local pane = panes[win]
  if pane and pane.win then
    local float = pane.win
    pane.win, pane.shape, pane.text = nil, nil, nil
    if vim.api.nvim_win_is_valid(float) and not pcall(vim.api.nvim_win_close, float, true) then
      vim.schedule(function() pcall(vim.api.nvim_win_close, float, true) end)
    end
  end
  if state and state.cuts and state.cuts[win] then
    state.cuts[win] = nil
    redraw(win)
  end
end

-- Draw the Pane of the diff in `win`: what the Review says about the line
-- the cursor is on.
local function draw_pane(win, view, state)
  if not (shown and state.data) then hide_pane(win, state); return end
  local info = vim.fn.getwininfo(win)[1]
  local cursor = vim.api.nvim_win_get_cursor(win)[1]
  local about = Pane.about(state.data, view.meta, cursor)
  if not about then hide_pane(win, state); return end
  local at = vim.api.nvim_win_call(win, vim.fn.winline)
  local narrow = info.width < Pane.NARROW
  local pane = panes[win] or {}
  panes[win] = pane
  local need = #Pane.rows(about, Pane.WIDTH, math.huge, narrow) + 2
  local side, room = Pane.place(need, at, info.height, pane.where, bar_height(win))
  if room < 3 then hide_pane(win, state); return end
  pane.where = side
  local rows, alone = Pane.rows(about, Pane.WIDTH, room - 2, narrow)
  local lines, marks = {}, {}
  for i, pieces in ipairs(rows) do
    local text = pieces.bar and '▌' or ' '
    if pieces.bar then marks[#marks + 1] = {i - 1, 0, #text, 'ScmReviewPaneBar'} end
    for _, piece in ipairs(pieces) do
      marks[#marks + 1] = {i - 1, #text, #text + #piece[1], piece[2]}
      text = text .. piece[1]
    end
    if pieces.band then marks[#marks + 1] = {i - 1, 0, #text, 'ScmReviewPaneHead', true} end
    lines[i] = text
  end
  -- A heading that stands alone in a narrow window is no wider than its words.
  local width = Pane.WIDTH
  if alone and narrow then width = vim.fn.strdisplaywidth(lines[1]) + 1 end
  width = math.min(width, info.width - 6)
  if width < 12 then hide_pane(win, state); return end
  -- The overview strip keeps the window's last two cells.
  local col = info.width - width - 4
  local row = side == 'home' and bar_height(win) or info.height - #lines - 2
  local place = {relative='win', win=win, row=row, col=col, width=width, height=#lines}
  local shape = table.concat({row, col, width, #lines}, ':')
  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    if pane.shape ~= shape then vim.api.nvim_win_set_config(pane.win, place) end
  else
    pane.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[pane.buf].bufhidden = 'wipe'
    place.focusable, place.style, place.zindex, place.noautocmd, place.border = false, 'minimal', 20, true, 'single'
    pane.win = vim.api.nvim_open_win(pane.buf, false, place)
    vim.wo[pane.win].winhighlight = 'Normal:ScmReviewPane,NormalFloat:ScmReviewPane,FloatBorder:ScmReviewPaneBorder'
    vim.wo[pane.win].wrap = false
    pane.text = nil
  end
  pane.shape = shape
  local text = table.concat(lines, '\n')
  if pane.text ~= text then
    pane.text = text
    vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(pane.buf, pane_ns, 0, -1)
    for _, mark in ipairs(marks) do
      if mark[5] then
        vim.api.nvim_buf_set_extmark(pane.buf, pane_ns, mark[1], 0, {line_hl_group=mark[4]})
      elseif mark[3] > mark[2] then
        vim.api.nvim_buf_set_extmark(pane.buf, pane_ns, mark[1], mark[2], {end_col=mark[3], hl_group=mark[4]})
      end
    end
  end
  -- A line of code that runs under the Pane is marked as cut.
  local text_col = col - info.textoff
  local leftcol = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
  local cut = {}
  for number = info.topline, info.botline do
    -- The Pane's rows are counted from the first row of text, under the window's own heading.
    local at_row = vim.fn.screenpos(win, number, 1).row - info.winrow - info.winbar
    if at_row >= row and at_row <= row + #lines + 1 then
      local code = vim.api.nvim_buf_get_lines(view.buf, number - 1, number, false)[1] or ''
      if vim.fn.strdisplaywidth(code) - leftcol > text_col - 2 then cut[#cut + 1] = number end
    end
  end
  state.cuts = state.cuts or {}
  local key = text_col .. ':' .. table.concat(cut, ',')
  local before = state.cuts[win]
  if not before or before.key ~= key then
    local set = {}
    for _, number in ipairs(cut) do set[number] = true end
    state.cuts[win] = {key=key, col=math.max(0, text_col - 2), lines=set}
    redraw(win)
  end
end

-- Mark, as a window is painted, the line the reader is on and the lines of
-- code that run under the Pane.
local function paint()
  vim.api.nvim_set_decoration_provider(paint_ns, {
    on_win=function(_, win, buf)
      local view = lookup(buf)
      local state = view and view.review
      if not (options.enabled and state and state.data) then return false end
      state.paint = {cursor=vim.api.nvim_win_get_cursor(win)[1], cuts=state.cuts and state.cuts[win]}
      return true
    end,
    on_line=function(_, _, buf, row)
      local view = lookup(buf)
      local paint_now = view and view.review and view.review.paint
      if not paint_now then return end
      if row + 1 == paint_now.cursor then
        vim.api.nvim_buf_set_extmark(buf, paint_ns, row, 0, {ephemeral=true, end_row=row + 1, end_col=0, strict=false,
          hl_eol=true, hl_group='ScmReviewCurrentLine', priority=160})
      end
      local cuts = paint_now.cuts
      if cuts and cuts.lines[row + 1] then
        vim.api.nvim_buf_set_extmark(buf, paint_ns, row, 0, {ephemeral=true, virt_text={{'… ', 'ScmReviewCut'}},
          virt_text_win_col=cuts.col, hl_mode='combine', priority=250})
      end
    end,
  })
end

-- Bring everything around the diffs on screen up to date: the Tour bars, the
-- Panes, and the strip under the diff the reader is in.
function M.sync()
  if not options.enabled then return end
  for win in pairs(bars) do
    if not (vim.api.nvim_win_is_valid(win) and lookup(vim.api.nvim_win_get_buf(win))) then close_bar(win) end
  end
  for win in pairs(panes) do
    if not (vim.api.nvim_win_is_valid(win) and lookup(vim.api.nvim_win_get_buf(win))) then close_pane(win) end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    -- Drawing one bar may close another window in this list.
    local view = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == ''
      and lookup(vim.api.nvim_win_get_buf(win))
    if view then
      local state = state_of(view)
      if state.data then
        local at = current_step(view, state, win)
        if at then state.steps[win], state.visited[at] = at, true end
      end
      draw_bar(win, state)
      if bars[win] then keep_first_line(win) end
      draw_pane(win, view, state)
    end
  end
  -- The strip stays under the diff the reader was last in while they look
  -- at another window, and goes when that diff does.
  local win, view, state = here()
  if win then
    last_diff = win
  elseif last_diff and vim.api.nvim_win_is_valid(last_diff) and lookup(vim.api.nvim_win_get_buf(last_diff)) then
    win = last_diff
    view = lookup(vim.api.nvim_win_get_buf(win))
    state = state_of(view)
  else
    last_diff = nil
    Strip.show(nil, nil)
    return
  end
  if not state.data then Strip.show(nil, nil); return end
  local flow, number, at = flow_here(view, state, win)
  local brief = map_brief
  if brief == nil then brief = Strip.short() end
  Strip.show(win, {
    key=table.concat({view.buf, view.revision, state.generation or 0, at or 0, number or 0, tostring(shown), vim.api.nvim_win_get_width(win),
      flow and flow.from or 0}, ':'),
    flow=flow, file=vim.fs.basename(view.spec.path), line=number, hints=hints(state, at, flow ~= nil, vim.api.nvim_win_get_width(win)), brief=brief,
  })
end

local function take(view, state, raw)
  local review, why = Schema.normalise(raw)
  if not review then
    state.status, state.error, state.data = 'failed', why, nil
    return false
  end
  -- A step that names a line the file does not have cannot be walked to.
  local reachable = {}
  for _, step in ipairs(review.tour) do
    if row_of(view, step.from) then reachable[#reachable + 1] = step end
  end
  review.tour = reachable
  state.status, state.data, state.error = 'ready', review, nil
  state.generation = (state.generation or 0) + 1
  state.steps, state.visited, state.cuts = {}, {}, nil
  return true
end

local function numbered(view)
  return Prompt.numbered(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), view.meta, view.hunks)
end

local function refresh_windows(view)
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do redraw(win) end
  M.sync()
end

-- Ask the Explainer in use for a Review of the diff in `view`. `again` asks
-- even when a Review is kept.
function M.explain(view, again)
  local state = state_of(view)
  if not options.enabled or state.status == 'asking' or state.status == 'nothing' then return false end
  local service = Explainers.active()
  local question = numbered(view)
  if not (service and question) then return false end
  local key = state.key
  if again then Prompt.forget(key) end
  state.status, state.started, state.error = 'asking', vim.uv.now(), nil
  local timer = vim.uv.new_timer()
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if state.status ~= 'asking' or state.key ~= key then
      if not timer:is_closing() then timer:close() end
      return
    end
    M.sync()
  end))
  M.sync()
  state.cancel = Explainers.ask(service, Prompt.build(view.spec.path, question, service.kind == 'claude_code', service.style),
    {cwd=view.spec.repo}, function(err, answer)
      state.cancel = nil
      if not timer:is_closing() then timer:close() end
      -- The file changed, or was closed, while the Explainer was reading it.
      if state.key ~= key or view.review ~= state then return end
      local raw, why = nil, err
      if not err then raw, why = Schema.decode(answer) end
      if not raw then
        state.status, state.error = 'failed', why
      elseif take(view, state, raw) then
        Prompt.keep(key, raw)
      end
      if vim.api.nvim_buf_is_valid(view.buf) then refresh_windows(view) end
    end)
  return true
end

-- A diff was shown or its file changed: find the Review kept for it.
function M.attach(view)
  if not options.enabled then return end
  local state = state_of(view)
  local readable = type(view.old) ~= 'table' and type(view.new) ~= 'table' and #view.hunks > 0
  local service = Explainers.active()
  local key = readable and Prompt.key(view.spec.path, view.old, view.new, service and service.style) or nil
  if key ~= state.key or not key then
    -- An Explainer still reading the text this replaces is stopped: its answer would not be used.
    if state.cancel then state.cancel(); state.cancel = nil end
    state.key, state.data, state.steps, state.visited, state.cuts = key, nil, {}, {}, nil
    state.status, state.error = key and 'none' or 'nothing', nil
    local kept = key and Prompt.kept(key)
    if kept then take(view, state, kept) elseif key and options.auto then M.explain(view) end
  end
  -- The blank row that keeps line 1 out from under the Tour bar.
  vim.api.nvim_buf_clear_namespace(view.buf, static, 0, -1)
  state.filler = 0
  if key and vim.api.nvim_buf_line_count(view.buf) > 0 then
    state.filler = 1
    vim.api.nvim_buf_set_extmark(view.buf, static, 0, 0, {id=1, virt_lines={{{'', 'Normal'}}}, virt_lines_above=true})
  end
  -- Lines already on screen are painted again, now with the Review's marks.
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do redraw(win) end
  M.sync()
end

function M.detach(view)
  local state = view.review
  if state and state.cancel then state.cancel() end
  view.review = nil
  vim.schedule(M.sync)
end

-- The service in use, or how it explains, changed: each diff finds the
-- Review kept for it as it is now explained.
function M.restyle()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local view = vim.api.nvim_buf_is_valid(buf) and lookup(buf)
    if view then M.attach(view) end
  end
  M.sync()
end

-- Go to the next (1) or previous (-1) step of the Tour.
function M.step(direction)
  local win, view, state = here()
  if not (options.enabled and win and state.data) or #state.data.tour == 0 then return false end
  local tour = state.data.tour
  local at = state.steps[win]
  local target = at and ((at - 1 + direction) % #tour + 1) or (direction > 0 and 1 or #tour)
  local row = row_of(view, tour[target].from)
  if not row then return false end
  state.steps[win], state.visited[target] = target, true
  -- A step always opens the same way: the Pane tries its home first.
  if panes[win] then panes[win].where = nil end
  vim.api.nvim_win_set_cursor(win, {row, 0})
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zz') end)
  redraw(win)
  M.sync()
  return true
end

-- Show or hide the Pane, or ask for a Review when there is none.
function M.pane()
  local win, view, state = here()
  if not (options.enabled and win) then return end
  if not state.data then M.explain(view); return end
  shown = not shown
  -- A Pane shown again starts at its home.
  for _, pane in pairs(panes) do pane.where = nil end
  M.sync()
  vim.api.nvim_echo({{'Explanation pane ' .. (shown and 'on' or 'off') .. '   (\\e changes it)', 'ScmReviewDim'}}, false, {})
end

-- Switch the strip between the whole map and one row of it.
function M.map()
  local win, view, state = here()
  if not (options.enabled and win and state.data) then return end
  if not flow_here(view, state, win) then
    -- Nothing to fold or open here, and the choice is not changed unseen.
    local where = #state.data.flows > 0 and 'this line has no map: ]t goes to a step that may' or 'this change has no maps'
    vim.api.nvim_echo({{'How this line gets run: ' .. where, 'ScmReviewDim'}}, false, {})
    return
  end
  local brief = map_brief
  if brief == nil then brief = Strip.short() end
  map_brief = not brief
  M.sync()
end

-- A small window in the middle of the editor holding `lines`.
local function float(title, lines)
  local width = math.min(76, vim.o.columns - 8)
  local wrapped = {}
  for _, line in ipairs(lines) do
    if line == '' then wrapped[#wrapped + 1] = '' end
    for _, part in ipairs(Pane.wrap(line, width - 4)) do wrapped[#wrapped + 1] = '  ' .. part end
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, wrapped)
  vim.bo[buf].modifiable = false
  local height = math.min(#wrapped, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {relative='editor', width=width, height=math.max(1, height),
    row=math.floor((vim.o.lines - height) / 2) - 1, col=math.floor((vim.o.columns - width) / 2),
    style='minimal', border='rounded', title=' ' .. title .. ' ', title_pos='left'})
  vim.wo[win].winhighlight = 'Normal:ScmReviewFloat,FloatBorder:ScmReviewFloat,FloatTitle:ScmReviewFloatTitle'
  vim.wo[win].wrap = true
  for _, key in ipairs({'q', '<Esc>', '<CR>'}) do
    vim.keymap.set('n', key, function() pcall(vim.api.nvim_win_close, win, true) end, {buffer=buf, nowait=true})
  end
  return win, buf
end

-- Ask the Explainer about the line under the cursor: `question` when given,
-- or for a longer explanation of it.
function M.ask(question)
  local win, view, state = here()
  if not (options.enabled and win and state.key) then return end
  local service = Explainers.active()
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = view.meta[row]
  local context = numbered(view)
  if not (service and line and context) then return end
  local text = vim.api.nvim_buf_get_lines(view.buf, row - 1, row, false)[1] or ''
  local number = line.new or line.old or row
  local title = ('Line %d · %s'):format(number, service.name)
  local cache = table.concat({state.key, row, question or '', service.style or ''}, ':')
  -- A longer explanation starts with what the Review already says, which the Pane may have had no room for.
  local known = {}
  if not question and state.data then
    local about = Pane.about(state.data, view.meta, row)
    known = about and Pane.plain(about) or {}
    if #known > 0 then known[#known + 1] = '' end
  end
  local function with_known(lines) return vim.list_extend(vim.list_extend({}, known), lines) end
  if answers[cache] then float(title, with_known(vim.split(answers[cache], '\n'))); return end
  local prompt = question and Prompt.question(view.spec.path, context, number, text, question, service.style)
    or Prompt.more(view.spec.path, context, number, text, service.style)
  local waiting, buf = float(title, with_known({service.name .. ' is thinking…'}))
  Explainers.ask(service, prompt, {cwd=view.spec.repo}, function(err, answer)
    local lines = err and {'Could not answer: ' .. err} or vim.split(vim.trim(answer or ''), '\n')
    if not err then answers[cache] = table.concat(lines, '\n') end
    if not (vim.api.nvim_win_is_valid(waiting) and vim.api.nvim_win_get_buf(waiting) == buf) then return end
    pcall(vim.api.nvim_win_close, waiting, true)
    float(title, with_known(lines))
  end)
end

-- Type a question about the line under the cursor.
function M.question()
  local win = here()
  if not (options.enabled and win) then return end
  vim.ui.input({prompt='Ask about this line: '}, function(text)
    if text and vim.trim(text) ~= '' then M.ask(vim.trim(text)) end
  end)
end

local KEYS = {
  {']t', 'next step of the tour'}, {'[t', 'previous step of the tour'},
  {']c', 'next change'}, {'[c', 'previous change'},
  {'\\e', 'explain this change; then show or hide the explanation pane'},
  {'\\R', 'explain this change again'},
  {'\\m', 'show the whole map of how this line gets run, or one row of it'},
  {'K', 'the full explanation of the line under the cursor'},
  {'\\a', 'ask a question about the line under the cursor'},
  {'\\s', 'choose the service that explains (the admin page)'},
  {'Enter, gf', 'open the file at this line'},
}

function M.keys_help()
  local lines = {}
  for _, key in ipairs(KEYS) do lines[#lines + 1] = ('%-10s %s'):format(key[1], key[2]) end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'Values marked "predicted" are an Explainer\'s guess, not a recording of a real run.'
  local _, buf = float('Keys in a diff', {})
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.tbl_map(function(line) return '  ' .. line end, lines))
  vim.bo[buf].modifiable = false
  vim.api.nvim_win_set_height(0, #lines)
end

-- The keys the Review binds in a diff.
local BOUND = {']t', '[t', '\\e', '\\m', '\\a', 'K', 'g?', '\\R', '\\s'}

-- Bind the Review's keys in a diff's buffer.
function M.keys(buf)
  if not options.enabled then return end
  for key, run in pairs({
    [']t']=function() M.step(1) end, ['[t']=function() M.step(-1) end,
    ['\\e']=M.pane, ['\\m']=M.map, ['\\a']=M.question, ['K']=function() M.ask() end, ['g?']=M.keys_help,
    ['\\R']=function()
      local _, view = here()
      if view then M.explain(view, true) end
    end,
    ['\\s']=function() require('scm.review.admin').open() end,
  }) do
    vim.keymap.set('n', key, run, {buffer=buf, nowait=true})
  end
end

-- Whether the Pane is shown, and the window it floats in over `win`.
function M.shown() return shown end
function M.pane_window(win)
  local pane = panes[win]
  return pane and pane.win and vim.api.nvim_win_is_valid(pane.win) and pane.win or nil
end

-- `opts` is the `review` table of SCM's options; `find` gives a buffer's diff.
function M.setup(opts, find)
  if opts == false then opts = {enabled=false} end
  if type(opts) ~= 'table' then opts = {} end
  options = vim.tbl_extend('force', {enabled=true, auto=false}, opts)
  lookup = find
  if not options.enabled then
    -- Take away what an earlier setup put on screen and bound.
    for win in pairs(bars) do close_bar(win) end
    for win in pairs(panes) do close_pane(win) end
    Strip.close()
    pcall(vim.api.nvim_del_augroup_by_name, 'ScmReview')
    pcall(vim.api.nvim_del_user_command, 'ScmExplainers')
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local view = vim.api.nvim_buf_is_valid(buf) and find(buf)
      if view then
        if view.review and view.review.cancel then view.review.cancel() end
        view.review = nil
        vim.api.nvim_buf_clear_namespace(buf, static, 0, -1)
        for _, key in ipairs(BOUND) do pcall(vim.keymap.del, 'n', key, {buffer=buf}) end
      end
    end
    return
  end
  Explainers.setup({use=options.explainer, services=options.explainers})
  Strip.setup({map=options.map, map_scale=options.map_scale, map_density=options.map_density, font=options.font, colors=options.colors})
  M.highlights()
  paint()
  local group = vim.api.nvim_create_augroup('ScmReview', {clear=true})
  vim.api.nvim_create_autocmd('ColorScheme', {group=group, callback=M.highlights})
  vim.api.nvim_create_autocmd('CursorMoved', {group=group, callback=function(ev)
    local view = lookup(ev.buf)
    if not (view and view.review and view.review.data) then return end
    redraw(vim.api.nvim_get_current_win())
    M.sync()
  end})
  vim.api.nvim_create_autocmd({'BufWinEnter', 'BufEnter', 'WinEnter', 'WinScrolled'},
    {group=group, callback=function() M.sync() end})
  -- A window of another width has its Pane at another column: every line is painted again.
  vim.api.nvim_create_autocmd({'WinResized', 'VimResized'}, {group=group, callback=function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      local view = lookup(vim.api.nvim_win_get_buf(win))
      if view and view.review and view.review.data then redraw(win) end
    end
    M.sync()
  end})
  vim.api.nvim_create_autocmd('WinClosed', {group=group, callback=function() vim.schedule(M.sync) end})
  -- Quitting the diff quits what the reader sees as one window: its strip
  -- goes first, so it is never the window left behind.
  vim.api.nvim_create_autocmd('QuitPre', {group=group, callback=function()
    if Strip.parent() == vim.api.nvim_get_current_win() then Strip.show(nil, nil) end
  end})
  vim.api.nvim_create_user_command('ScmExplainers', function() require('scm.review.admin').open() end,
    {desc='Choose and connect the services that explain changes'})
end

return M
