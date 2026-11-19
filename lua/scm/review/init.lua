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
local Ui = require('scm.ui')
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
local answers = {}     -- Review key -> "row:question:service:style" -> an answer already given
local waiting = {}     -- the same, joined -> a question about one line still being answered
local last_diff        -- the window of the diff the reader was last in

-- The colours of the Review. Text is never brighter than the editor's own:
-- a heading is bold, not whiter.
function M.highlights()
  local mix, color = Ui.mix, Ui.color
  local dark = vim.o.background == 'dark'
  local bg = color('Normal', 'bg', dark and 0x1e1f22 or 0xffffff)
  local fg = color('Normal', 'fg', dark and 0xacb2be or 0x333333)
  -- On a light background each hue is darkened to stay readable.
  local function hue(value) return dark and value or mix(value, 0x000000, 0.6) end
  local blue, amber, teal, violet = hue(0x73ade9), hue(0xd9a35c), hue(0x7fc9c0), hue(0xa78bd0)
  local green, red = hue(0x8fbf7a), hue(0xd07277)
  local function soft(alpha) return mix(fg, bg, alpha) end
  local current = mix(blue, bg, 0.26)
  -- The Pane is a surface a step lighter than the code, with a quiet border.
  local pane = soft(0.09)
  local bar = mix(blue, bg, 0.17)
  local tour = soft(0.055)
  -- Bold carries weight, not brightness: bold text is a shade under the editor's own.
  local strong = soft(0.97)
  -- "If paused here" is a faintly warm block inside the Pane.
  local warm = mix(amber, pane, 0.045)
  for name, value in pairs({
    ScmReviewCurrentLine={bg=current},
    ScmReviewPane={fg=soft(0.92), bg=pane}, ScmReviewPaneBorder={fg=soft(0.31), bg=pane},
    ScmReviewPaneLine={fg=blue, bg=pane, bold=true},
    ScmReviewPaneAdded={fg=green, bg=mix(green, pane, 0.13), bold=true},
    ScmReviewPaneRemoved={fg=red, bg=mix(red, pane, 0.13), bold=true},
    ScmReviewPaneLabel={fg=soft(0.7)}, ScmReviewPaneText={fg=soft(0.86)}, ScmReviewPaneGist={fg=strong, bold=true},
    ScmReviewPaneProse={fg=soft(0.92)}, ScmReviewPaneStrong={fg=strong, bold=true},
    ScmReviewPaneTitle={fg=strong, bold=true}, ScmReviewPanePredicted={fg=amber, bg=mix(amber, warm, 0.13)},
    ScmReviewPaneEdge={fg=amber}, ScmReviewPaneTint={bg=warm}, ScmReviewPaneGloss={fg=soft(0.8), italic=true},
    ScmReviewPaneValue={fg=teal, bold=true}, ScmReviewPaneKey={fg=strong, bold=true},
    ScmReviewPaneMore={fg=soft(0.72), italic=true}, ScmReviewCut={fg=soft(0.72)},
    ScmReviewTourRow={fg=soft(0.8), bg=tour}, ScmReviewTourEdge={fg=blue, bg=tour},
    ScmReviewTourName={fg=blue, bg=tour, bold=true}, ScmReviewTourCount={fg=soft(0.72), bg=tour},
    ScmReviewTourNow={fg=blue, bg=tour}, ScmReviewTourDone={fg=mix(blue, bg, 0.28), bg=tour},
    ScmReviewTourTodo={fg=mix(blue, soft(0.24), 0.12), bg=tour},
    ScmReviewTourTitle={fg=strong, bg=tour, bold=true}, ScmReviewTourSummary={fg=soft(0.8), bg=tour},
    ScmReviewTourLines={fg=soft(0.64), bg=tour}, ScmReviewTourError={fg=red, bg=tour, bold=true},
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
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local line = view.meta[row]
  local number = line and line.new
  -- On a removed line, the step is the one its change belongs to.
  if not number and line and line.kind == '-' then
    while view.meta[row] and view.meta[row].kind == '-' do row = row + 1 end
    number = view.meta[row] and view.meta[row].new
  end
  if not number then return nil end
  -- Steps may overlap: the one the reader walked to holds while the cursor is in it.
  local held = state.steps[win]
  local step = held and state.data.tour[held]
  if step and number >= step.from and number <= step.to then return held end
  return Schema.step_at(state.data, number)
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
  if not bar then return end
  -- The window scrolls by its own rules again: the reader's, if they set any.
  if bar.scrolloff ~= nil and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value('scrolloff', bar.scrolloff, {win=win, scope='local'})
  end
  Ui.close(bar.win)
end

-- A row list as one string, to tell whether what is on screen changed.
local function signature(rows)
  local parts = {}
  for _, row in ipairs(rows) do
    for _, piece in ipairs(row) do parts[#parts + 1] = piece[1] .. '\1' .. (piece[2] or '') end
    parts[#parts + 1] = '\2' .. (row.line_hl or '')
  end
  return table.concat(parts, '\3')
end

-- What the Tour bar of window `win` says: `lead`, the pieces it starts
-- with; for a Tour step, its `title` and `summary`; and `right`, the lines
-- the step covers, at the right of the first row. `width` is the bar's.
local function bar_text(state, win, width)
  local service = Explainers.active()
  local name = service and service.name or 'an Explainer'
  if state.status == 'asking' then
    local seconds = math.floor((vim.uv.now() - state.started) / 1000)
    return {lead={{name .. ' is reading this change… ', 'ScmReviewTourTitle'}, {seconds .. 's', 'ScmReviewTourCount'}}}
  elseif state.status == 'failed' then
    return {lead={{'Could not explain this change: ', 'ScmReviewTourError'}, {state.error or '', 'ScmReviewTourRow'},
      {'   \\e', 'ScmReviewTourTitle'}, {' try again', 'ScmReviewTourCount'}}}
  elseif state.status ~= 'ready' then
    return {lead={{'\\e', 'ScmReviewTourTitle'}, {' explain this change with ' .. name, 'ScmReviewTourCount'}}}
  end
  local tour = state.data.tour
  if #tour == 0 then
    return {lead={{'Review', 'ScmReviewTourName'}, {'  the pane at the right explains the line you are on', 'ScmReviewTourCount'}}}
  end
  local at = state.steps[win]
  local lead = {{'Tour', 'ScmReviewTourName'},
    {at and ('  %d of %d  '):format(at, #tour) or ('  %d steps  '):format(#tour), 'ScmReviewTourCount'}}
  -- The progress: a heavy segment for each step done and the one you are on, a thin one for each to come.
  local cells = width >= 110 and 3 or width >= 70 and 2 or 1
  for i = 1, #tour do
    if i > 1 then lead[#lead + 1] = {' ', 'ScmReviewTourRow'} end
    if i == at then lead[#lead + 1] = {('━'):rep(cells), 'ScmReviewTourNow'}
    elseif state.visited[i] then lead[#lead + 1] = {('━'):rep(cells), 'ScmReviewTourDone'}
    else lead[#lead + 1] = {('─'):rep(cells), 'ScmReviewTourTodo'} end
  end
  local step = at and tour[at]
  if not step then
    vim.list_extend(lead, {{'   ]t', 'ScmReviewTourTitle'}, {' start the tour', 'ScmReviewTourCount'}})
    return {lead=lead}
  end
  return {lead=lead, title={{step.title, 'ScmReviewTourTitle'}}, summary=step.summary,
    right=step.from == step.to and ('line ' .. step.from) or ('lines ' .. step.from .. '–' .. step.to)}
end

-- The most rows the Tour bar takes.
local BAR_ROWS = 4
local EDGE = {'▍ ', 'ScmReviewTourEdge'}

-- The Tour bar's rows, `width` cells wide and at most `most` of them. Every
-- row starts with the blue edge. A step's title follows the progress; its
-- summary goes beside the title when both fit on the first row, and all of
-- it under the title when not. What wraps hangs under where it started.
local function bar_rows(spec, width, most)
  local right = spec.right or ''
  local lead_cells = 0
  for _, piece in ipairs(spec.lead) do lead_cells = lead_cells + Ui.cells(piece[1]) end
  -- The cells the first row has before the lines at its right.
  local first = width - Ui.cells(EDGE[1]) - (right ~= '' and Ui.cells(right) + 4 or 1)
  local inner = width - Ui.cells(EDGE[1]) - 1
  local rows
  if not spec.title then
    rows = Ui.wrap_pieces(spec.lead, inner, {first=first})
  else
    local indent = lead_cells + 3
    local function hang(pieces) return vim.list_extend({{(' '):rep(indent), 'ScmReviewTourRow'}}, pieces) end
    local title = Ui.wrap_pieces(spec.title, inner - indent, {first=first - indent})
    local summary = spec.summary
    if summary and #title == 1 then
      local used = 0
      for _, piece in ipairs(title[1]) do used = used + Ui.cells(piece[1]) end
      if used + 3 + Ui.cells(summary) <= first - indent then
        title[1][#title[1] + 1] = {' — ' .. summary, 'ScmReviewTourSummary'}
        summary = nil
      end
    end
    rows = {vim.list_extend(vim.list_extend({}, spec.lead), {{'   ', 'ScmReviewTourRow'}})}
    vim.list_extend(rows[1], title[1] or {})
    for i = 2, #title do rows[#rows + 1] = hang(title[i]) end
    for _, part in ipairs(summary and Ui.wrap(summary, inner - indent) or {}) do
      rows[#rows + 1] = hang({{part, 'ScmReviewTourSummary'}})
    end
  end
  if #rows == 0 then rows[1] = {} end
  -- Only a window too short for it leaves any of the bar unsaid.
  if #rows > most then
    rows = vim.list_slice(rows, 1, most)
    local last = rows[most]
    last[#last + 1] = {'…', 'ScmReviewTourRow'}
  end
  for _, row in ipairs(rows) do table.insert(row, 1, EDGE) end
  if right ~= '' then
    local used = 0
    for _, piece in ipairs(rows[1]) do used = used + Ui.cells(piece[1]) end
    rows[1][#rows[1] + 1] = {(' '):rep(math.max(1, width - used - Ui.cells(right) - 1)), 'ScmReviewTourRow'}
    rows[1][#rows[1] + 1] = {right, 'ScmReviewTourLines'}
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
  local rows = bar_rows(bar_text(state, win, info.width), info.width, math.max(1, math.min(BAR_ROWS, info.height - 3)))
  local bar = Ui.anchored(bars[win], {relative='win', win=win, row=0, col=0, width=info.width, height=#rows},
    'ScmReviewTourRow', {zindex=21})
  bars[win], bar.rows = bar, #rows
  local drawn = signature(rows)
  if bar.changed or bar.drawn ~= drawn then
    bar.drawn = drawn
    Ui.write(bar.buf, bar_ns, rows)
  end
end

-- As many blank rows wait above line 1 of a diff as the tallest Tour bar
-- over it covers, and no more.
local function fill_top(view, state)
  local rows = state.key and 1 or 0
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do rows = math.max(rows, bar_height(win)) end
  if rows == state.filler or not vim.api.nvim_buf_is_valid(view.buf) then return end
  state.filler = rows
  if rows == 0 or vim.api.nvim_buf_line_count(view.buf) == 0 then
    pcall(vim.api.nvim_buf_del_extmark, view.buf, static, 1)
    return
  end
  local blank = {}
  for i = 1, rows do blank[i] = {{'', 'Normal'}} end
  vim.api.nvim_buf_set_extmark(view.buf, static, 0, 0, {id=1, virt_lines=blank, virt_lines_above=true})
end

-- The Tour bar covers the window's first rows, so the file's first lines
-- are kept under it by blank rows drawn above line 1.
local function keep_first_line(win)
  local rows = bar_height(win)
  -- What the reader had set for this window is put back when the bar goes.
  local bar = bars[win]
  local buf = vim.api.nvim_win_get_buf(win)
  if bar.scrolloff == nil then
    local value = vim.api.nvim_get_option_value('scrolloff', {win=win, scope='local'})
    -- A window takes the options a buffer last had in any window, so a value
    -- set here for an earlier bar may arrive with the diff. That one is not the reader's.
    if value == vim.b[buf].scm_review_scrolloff then value = -1 end
    bar.scrolloff = value
  end
  -- The cursor's line is kept out from under the bar everywhere else by
  -- never letting it be among the window's first rows.
  local own = bar.scrolloff >= 0 and bar.scrolloff or vim.go.scrolloff
  local want = math.max(own, rows)
  if vim.wo[win].scrolloff ~= want then
    vim.api.nvim_set_option_value('scrolloff', want, {win=win, scope='local'})
  end
  if vim.b[buf].scm_review_scrolloff ~= want then vim.b[buf].scm_review_scrolloff = want end
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
  if pane then Ui.close(pane.win) end
end

-- Take the Pane of `win` off the screen but remember which side it was on.
local function hide_pane(win, state)
  local pane = panes[win]
  if pane and pane.win then
    Ui.close(pane.win)
    pane.win, pane.shape, pane.drawn = nil, nil, nil
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
  local title = Pane.title(about)
  local pad = (' '):rep(Pane.PAD)
  -- A Pane that stands alone in a narrow window is no wider than its words and title.
  local text_width = Pane.WIDTH
  if alone then
    text_width = 0
    for _, piece in ipairs(rows[1]) do text_width = text_width + Ui.cells(piece[1]) end
    local title_width = 2
    for _, piece in ipairs(title) do title_width = title_width + Ui.cells(piece[1]) end
    text_width = math.max(text_width, title_width - 2 * Pane.PAD)
  end
  -- Two cells of space at each side. A row of "if paused here" is a warm
  -- block from its amber edge to the end of the text.
  local out = {}
  for i, pieces in ipairs(rows) do
    local row = {{pad}}
    local used = 0
    for _, piece in ipairs(pieces) do
      row[#row + 1] = piece
      used = used + Ui.cells(piece[1])
    end
    if pieces.tint then
      row[#row + 1] = {(' '):rep(math.max(0, text_width - used))}
      row.fill = {#pad, 'ScmReviewPaneTint'}
    end
    out[i] = row
  end
  local width = math.min(text_width + 2 * Pane.PAD, info.width - 6)
  if width < 12 then hide_pane(win, state); return end
  -- The Pane sits against the overview strip, which keeps the window's last two cells.
  local col = info.width - width - 4
  local row = side == 'home' and bar_height(win) or info.height - #out - 2
  local place = {relative='win', win=win, row=row, col=col, width=width, height=#out}
  local frame = {zindex=20, border={'╭', '─', '╮', '│', '╯', '─', '╰', '│'}, title=title, title_pos='left',
    footer=not alone and Pane.FOOTER or nil, footer_pos=not alone and 'right' or nil}
  pane = Ui.anchored(pane, place, 'ScmReviewPane', frame)
  panes[win] = pane
  -- The title names the line, so it changes as the cursor moves.
  local framed = signature({title}) .. tostring(alone)
  if pane.framed ~= framed then
    pane.framed = framed
    vim.api.nvim_win_set_config(pane.win, {title=title, title_pos='left', footer=not alone and Pane.FOOTER or '',
      footer_pos='right'})
  end
  local drawn = signature(out)
  if pane.changed or pane.drawn ~= drawn then
    pane.drawn = drawn
    Ui.write(pane.buf, pane_ns, out)
  end
  -- A line of code that runs under the Pane is marked as cut.
  local text_col = col - info.textoff
  local leftcol = vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().leftcol end)
  local cut = {}
  for number = info.topline, info.botline do
    -- The Pane's rows are counted from the first row of text, under the window's own heading.
    local at_row = vim.fn.screenpos(win, number, 1).row - info.winrow - info.winbar
    if at_row >= row and at_row <= row + #out + 1 then
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

-- Whether the strip shows one row of the map: the reader's choice, or what fits.
local function brief_map()
  if map_brief == nil then return Strip.short() end
  return map_brief
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
  local seen = {}
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
      seen[view] = state
    end
  end
  -- Line 1 is kept under the bars once every bar over the diff is known.
  for view, state in pairs(seen) do fill_top(view, state) end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local view = vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == ''
      and lookup(vim.api.nvim_win_get_buf(win))
    if view and seen[view] then
      if bars[win] then keep_first_line(win) end
      draw_pane(win, view, seen[view])
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
  local brief = brief_map()
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

-- Stop asking for the Review of `state`, if it is being asked for.
local function stop_asking(state)
  if state.cancel then state.cancel(); state.cancel = nil end
  if state.timer then
    if not state.timer:is_closing() then state.timer:close() end
    state.timer = nil
  end
  if state.status == 'asking' then state.status = 'none' end
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
  if again then
    Prompt.forget(key)
    answers[key] = nil
  end
  state.status, state.started, state.error = 'asking', vim.uv.now(), nil
  -- The bar counts the seconds while the Explainer reads.
  local timer = vim.uv.new_timer()
  state.timer = timer
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if state.timer ~= timer or view.review ~= state or state.status ~= 'asking' or state.key ~= key then
      if not timer:is_closing() then timer:close() end
      if state.timer == timer then state.timer = nil end
      return
    end
    M.sync()
  end))
  M.sync()
  local ok, cancel = pcall(function()
    return Explainers.ask(service, Prompt.build(view.spec.path, question, service.kind == 'claude_code', service.style),
      {cwd=view.spec.repo}, function(err, answer)
        state.cancel = nil
        if state.timer == timer then state.timer = nil end
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
  end)
  if not ok then
    -- A service set up wrongly fails here, and the bar says so: it never waits for an answer that cannot come.
    stop_asking(state)
    state.status, state.error = 'failed', tostring(cancel):gsub('^.-:%d+: ', '')
    M.sync()
    return false
  end
  state.cancel = cancel
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
    stop_asking(state)
    if state.key then answers[state.key] = nil end
    state.key, state.data, state.steps, state.visited, state.cuts = key, nil, {}, {}, nil
    state.status, state.error = key and 'none' or 'nothing', nil
    local kept = key and Prompt.kept(key)
    if kept then take(view, state, kept) elseif key and options.auto then M.explain(view) end
  end
  -- The blank row that keeps line 1 out from under the Tour bar.
  vim.api.nvim_buf_clear_namespace(view.buf, static, 0, -1)
  state.filler = 0
  fill_top(view, state)
  -- Lines already on screen are painted again, now with the Review's marks.
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do redraw(win) end
  M.sync()
end

function M.detach(view)
  local state = view.review
  if state then
    stop_asking(state)
    if state.key then answers[state.key] = nil end
  end
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
  map_brief = not brief_map()
  M.sync()
end

-- Put `lines` in float `win`, wrapped to its width, and make it as tall as they need.
local function fill(win, buf, lines)
  local width = vim.api.nvim_win_get_width(win)
  local wrapped = {}
  for _, line in ipairs(lines) do
    if line == '' then wrapped[#wrapped + 1] = '' end
    for _, part in ipairs(Ui.wrap(line, width - 4)) do wrapped[#wrapped + 1] = '  ' .. part end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, wrapped)
  vim.bo[buf].modifiable = false
  local height = math.max(1, math.min(#wrapped, vim.o.lines - 6))
  vim.api.nvim_win_set_config(win, {relative='editor', width=width, height=height,
    row=math.max(0, math.floor((vim.o.lines - height) / 2) - 1), col=math.max(0, math.floor((vim.o.columns - width) / 2))})
end

-- A small window in the middle of the editor holding `lines`.
local function float(title, lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local win = Ui.centered(buf, {title=title, width=math.max(20, math.min(76, vim.o.columns - 8)), height=1,
    keys={'<CR>'}})
  vim.wo[win].wrap = true
  fill(win, buf, lines)
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
  -- A longer explanation starts with what the Review already says, which the Pane may have had no room for.
  local known = {}
  if not question and state.data then
    local about = Pane.about(state.data, view.meta, row)
    known = about and Pane.plain(about) or {}
    if #known > 0 then known[#known + 1] = '' end
  end
  local function with_known(lines) return vim.list_extend(vim.list_extend({}, known), lines) end
  local slot = answers[state.key] or {}
  answers[state.key] = slot
  local asked = table.concat({row, question or '', service.name, service.style or ''}, ':')
  if slot[asked] then float(title, with_known(vim.split(slot[asked], '\n'))); return end
  -- The same question asked again while it is being answered goes back to the window waiting for it.
  local id = state.key .. ':' .. asked
  local pending = waiting[id]
  if pending and vim.api.nvim_win_is_valid(pending.win) then vim.api.nvim_set_current_win(pending.win); return end
  local prompt = question and Prompt.question(view.spec.path, context, number, text, question, service.style)
    or Prompt.more(view.spec.path, context, number, text, service.style)
  local waiting_win, buf = float(title, with_known({service.name .. ' is thinking…'}))
  local entry = {win=waiting_win}
  waiting[id] = entry
  local ok, cancel = pcall(Explainers.ask, service, prompt, {cwd=view.spec.repo}, function(err, answer)
    if waiting[id] == entry then waiting[id] = nil end
    local lines = err and {'Could not answer: ' .. err} or vim.split(vim.trim(answer or ''), '\n')
    if not err then slot[asked] = table.concat(lines, '\n') end
    -- The answer goes into the window that waited for it, without moving the cursor.
    if vim.api.nvim_win_is_valid(waiting_win) and vim.api.nvim_win_get_buf(waiting_win) == buf then
      fill(waiting_win, buf, with_known(lines))
    end
  end)
  if not ok then
    waiting[id] = nil
    fill(waiting_win, buf, with_known({'Could not answer: ' .. tostring(cancel):gsub('^.-:%d+: ', '')}))
    return
  end
  entry.cancel = cancel
  -- Closing the window before the answer comes takes the question back.
  vim.api.nvim_create_autocmd('BufWipeout', {buffer=buf, once=true, callback=function()
    if waiting[id] == entry then
      waiting[id] = nil
      cancel()
    end
  end})
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
    for _, entry in pairs(waiting) do entry.cancel() end
    waiting, answers = {}, {}
    Strip.close()
    pcall(vim.api.nvim_del_augroup_by_name, 'ScmReview')
    pcall(vim.api.nvim_del_user_command, 'ScmExplainers')
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local view = vim.api.nvim_buf_is_valid(buf) and find(buf)
      if view then
        if view.review then stop_asking(view.review) end
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
