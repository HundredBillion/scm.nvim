-- scm.review — reading a diff to learn from it. A Review is an Explainer's
-- account of one file's change: a Tour through the changes, a few words
-- beside each changed line, a paragraph and predicted values for the line
-- the cursor is on, and a Flow Map of how that line gets run. This module
-- asks for Reviews, keeps them, and shows them around the diff.
local Schema = require('scm.review.schema')
local Prompt = require('scm.review.prompt')
local Explainers = require('scm.review.explainers')
local Rail = require('scm.review.rail')
local Strip = require('scm.review.strip')
local M = {}
local static = vim.api.nvim_create_namespace('scm.review.static')
local bar_ns = vim.api.nvim_create_namespace('scm.review.bar')

local options = {enabled=true, auto=false}
local lookup = function() return nil end  -- buffer -> the diff's view
local mode = 'full'    -- how much the Rail shows
local map_brief        -- the reader's choice of one row or the whole map; nil follows the window
local bars = {}        -- window -> the Tour bar floating at its top
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
  local head, paused, paused_head = soft(0.07), soft(0.07), mix(amber, bg, 0.14)
  local bar = mix(blue, bg, 0.17)
  for name, value in pairs({
    ScmReviewRail={fg=soft(0.88), bg=bg}, ScmReviewGist={fg=soft(0.88), bg=bg},
    ScmReviewGistCurrent={fg=fg, bg=current, bold=true}, ScmReviewCurrentLine={bg=current},
    ScmReviewEdge={fg=soft(0.2), bg=bg}, ScmReviewEdgeAdd={fg=green, bg=bg},
    ScmReviewEdgeDelete={fg=red, bg=bg}, ScmReviewEdgeCurrent={fg=blue, bg=current},
    ScmReviewHead={fg=soft(0.86), bg=head}, ScmReviewHeadStrong={fg=fg, bg=head, bold=true},
    ScmReviewHeadAdd={fg=green, bg=head, bold=true}, ScmReviewHeadDelete={fg=red, bg=head, bold=true},
    ScmReviewProse={fg=soft(0.96), bg=bg}, ScmReviewVar={fg=mix(blue, fg, 0.7), bg=bg},
    ScmReviewPausedHead={fg=soft(0.96), bg=paused_head}, ScmReviewPausedTitle={fg=fg, bg=paused_head, bold=true},
    ScmReviewPredictedHead={fg=amber, bg=paused_head}, ScmReviewPausedBarHead={fg=amber, bg=paused_head},
    ScmReviewPausedBar={fg=amber, bg=paused}, ScmReviewPaused={fg=soft(0.9), bg=paused},
    ScmReviewPausedName={fg=mix(blue, fg, 0.7), bg=paused}, ScmReviewValue={fg=teal, bg=paused, bold=true},
    ScmReviewPausedNote={fg=soft(0.9), bg=paused}, ScmReviewPausedEnd={fg=mix(amber, bg, 0.44), bg=bg},
    ScmReviewPredictedInline={fg=mix(amber, fg, 0.72), bg=current}, ScmReviewValueInline={fg=teal, bg=current},
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

local function hints(state, at, mapped)
  local out = {}
  local function add(key, text) out[#out + 1] = {key, true}; out[#out + 1] = {text} end
  local tour = state.data.tour
  if #tour > 1 then
    local next_step = (at or 0) % #tour + 1
    add(']t', (' next tour step (%d of %d)   '):format(next_step, #tour))
    add('[t', ' previous step   ')
  end
  -- The key is offered only where it does something.
  if mapped then add('\\m', ' map   ') elseif #state.data.flows > 0 then out[#out + 1] = {'no map for this line   '} end
  add('\\e', ' rail: ' .. mode .. '   ')
  add('g?', ' all keys')
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
    return {{' REVIEW', 'ScmReviewBarTitle'}, {' · a few words beside each changed line', 'ScmReviewBarDim'}}, ''
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

-- Draw the Tour bar across the top of the diff in `win`.
local function draw_bar(win, state)
  if state.status == 'nothing' then close_bar(win); return end
  local info = vim.fn.getwininfo(win)[1]
  if info.height < 4 or info.width < 30 then close_bar(win); return end
  local place = {relative='win', win=win, row=0, col=0, width=info.width, height=1}
  local shape = tostring(info.width)
  local bar = bars[win]
  if bar and vim.api.nvim_win_is_valid(bar.win) then
    if bar.shape ~= shape then vim.api.nvim_win_set_config(bar.win, place) end
  else
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = 'wipe'
    place.focusable, place.style, place.zindex, place.noautocmd = false, 'minimal', 21, true
    bar = {win=vim.api.nvim_open_win(buf, false, place), buf=buf, scrolloff=true}
    vim.wo[bar.win].winhighlight = 'Normal:ScmReviewBar,NormalFloat:ScmReviewBar'
    bars[win] = bar
  end
  bar.shape = shape
  local pieces, right = bar_text(state, win)
  local text, marks = '', {}
  for _, piece in ipairs(pieces) do
    marks[#marks + 1] = {#text, #text + #piece[1], piece[2]}
    text = text .. piece[1]
  end
  local room = info.width - vim.fn.strdisplaywidth(right)
  if vim.fn.strdisplaywidth(text) > room - 1 then
    while vim.fn.strdisplaywidth(text) > room - 2 and text ~= '' do
      text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
    end
    text = text .. '…'
  end
  local line = text .. (' '):rep(math.max(1, room - vim.fn.strdisplaywidth(text))) .. right
  if bar.line == line then return end
  bar.line = line
  vim.api.nvim_buf_set_lines(bar.buf, 0, -1, false, {line})
  vim.api.nvim_buf_clear_namespace(bar.buf, bar_ns, 0, -1)
  for _, mark in ipairs(marks) do
    if mark[1] < #text then
      vim.api.nvim_buf_set_extmark(bar.buf, bar_ns, 0, mark[1], {end_col=math.min(mark[2], #text), hl_group=mark[3]})
    end
  end
  vim.api.nvim_buf_set_extmark(bar.buf, bar_ns, 0, #line - #right, {end_col=#line, hl_group='ScmReviewBarDim'})
end

-- The Tour bar covers the window's first row, so the file's first line is
-- kept under it by a blank row drawn above line 1.
local function keep_first_line(win)
  -- The cursor's line is kept out from under the bar everywhere else by
  -- never letting it be the window's first.
  if vim.wo[win].scrolloff < 1 then
    vim.api.nvim_set_option_value('scrolloff', 1, {win=win, scope='local'})
  end
  vim.api.nvim_win_call(win, function()
    local view = vim.fn.winsaveview()
    -- Only while the cursor is on line 1: with the cursor lower, the reader
    -- may scroll line 1 under the bar like any other line.
    if view.lnum == 1 and view.topline == 1 and view.topfill == 0 then vim.fn.winrestview({topfill=1}) end
  end)
end

local function redraw(win)
  if vim.api.nvim__redraw then
    pcall(vim.api.nvim__redraw, {win=win, valid=false, statuscolumn=true})
  else
    vim.cmd('redraw!')
  end
end

-- Bring everything around the diffs on screen up to date: the Tour bars,
-- and the strip under the diff the reader is in.
function M.sync()
  if not options.enabled then return end
  for win in pairs(bars) do
    if not (vim.api.nvim_win_is_valid(win) and lookup(vim.api.nvim_win_get_buf(win))) then close_bar(win) end
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
  Rail.tail(view, win, mode)
  Strip.show(win, {
    key=table.concat({view.buf, view.revision, state.generation or 0, at or 0, number or 0, mode,
      flow and flow.from or 0}, ':'),
    flow=flow, file=vim.fs.basename(view.spec.path), line=number, hints=hints(state, at, flow ~= nil), brief=brief,
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
  state.steps, state.visited, state.rail_key = {}, {}, nil
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
  state.cancel = Explainers.ask(service, Prompt.build(view.spec.path, question, service.kind == 'claude_code'),
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
  local key = readable and Prompt.key(view.spec.path, view.old, view.new) or nil
  if key ~= state.key or not key then
    -- An Explainer still reading the text this replaces is stopped: its answer would not be used.
    if state.cancel then state.cancel(); state.cancel = nil end
    state.key, state.data, state.steps, state.visited, state.rail_key = key, nil, {}, {}, nil
    state.status, state.error = key and 'none' or 'nothing', nil
    local kept = key and Prompt.kept(key)
    if kept then take(view, state, kept) elseif key and options.auto then M.explain(view) end
  end
  -- The blank row that keeps line 1 out from under the Tour bar.
  vim.api.nvim_buf_clear_namespace(view.buf, static, 0, -1)
  if key and vim.api.nvim_buf_line_count(view.buf) > 0 then
    vim.api.nvim_buf_set_extmark(view.buf, static, 0, 0, {virt_lines={{{'', 'Normal'}}}, virt_lines_above=true})
  end
  -- Lines already on screen are painted again, now with the Rail beside them.
  for _, win in ipairs(vim.fn.win_findbuf(view.buf)) do redraw(win) end
  M.sync()
end

function M.detach(view)
  local state = view.review
  if state and state.cancel then state.cancel() end
  view.review = nil
  vim.schedule(M.sync)
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
  vim.api.nvim_win_set_cursor(win, {row, 0})
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zz') end)
  redraw(win)
  M.sync()
  return true
end

-- Show more or less in the Rail, or ask for a Review when there is none.
function M.rail()
  local win, view, state = here()
  if not (options.enabled and win) then return end
  if not state.data then M.explain(view); return end
  for i, name in ipairs(Rail.MODES) do
    if name == mode then mode = Rail.MODES[i % #Rail.MODES + 1]; break end
  end
  state.rail_key = nil
  redraw(win)
  M.sync()
  -- The key that asked for the Review is the one that folds the Rail, so say what it just did.
  local says = {full='full: gists, the paragraph and predicted values', gists='gists only', off='off'}
  vim.api.nvim_echo({{'Rail ' .. says[mode] .. '   (\\e changes it)', 'ScmReviewDim'}}, false, {})
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
    for _, part in ipairs(Rail.wrap(line, width - 4)) do wrapped[#wrapped + 1] = '  ' .. part end
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
  local cache = table.concat({state.key, row, question or ''}, ':')
  if answers[cache] then float(title, vim.split(answers[cache], '\n')); return end
  local prompt = question and Prompt.question(view.spec.path, context, number, text, question)
    or Prompt.more(view.spec.path, context, number, text)
  local waiting, buf = float(title, {service.name .. ' is thinking…'})
  Explainers.ask(service, prompt, {cwd=view.spec.repo}, function(err, answer)
    local lines = err and {'Could not answer: ' .. err} or vim.split(vim.trim(answer or ''), '\n')
    if not err then answers[cache] = table.concat(lines, '\n') end
    if not (vim.api.nvim_win_is_valid(waiting) and vim.api.nvim_win_get_buf(waiting) == buf) then return end
    pcall(vim.api.nvim_win_close, waiting, true)
    float(title, lines)
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
  {'\\e', 'explain this change; then show more or less in the rail'},
  {'\\R', 'explain this change again'},
  {'\\m', 'show the whole map of how this line gets run, or one row of it'},
  {'K', 'more about the line under the cursor'},
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
    ['\\e']=M.rail, ['\\m']=M.map, ['\\a']=M.question, ['K']=function() M.ask() end, ['g?']=M.keys_help,
    ['\\R']=function()
      local _, view = here()
      if view then M.explain(view, true) end
    end,
    ['\\s']=function() require('scm.review.admin').open() end,
  }) do
    vim.keymap.set('n', key, run, {buffer=buf, nowait=true})
  end
end

function M.mode() return mode end

-- `opts` is the `review` table of SCM's options; `find` gives a buffer's diff.
function M.setup(opts, find)
  if opts == false then opts = {enabled=false} end
  if type(opts) ~= 'table' then opts = {} end
  options = vim.tbl_extend('force', {enabled=true, auto=false}, opts)
  lookup = find
  if not options.enabled then
    -- Take away what an earlier setup put on screen and bound.
    for win in pairs(bars) do close_bar(win) end
    Strip.close()
    Rail.setup(function() return nil end, function() return 'off' end)
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
  Rail.setup(lookup, function() return mode end)
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
  -- A window of another width has its Rail at another column: every line is painted again.
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
