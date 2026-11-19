-- scm.review.rail — the Rail: the column at the right of a diff that says, in
-- a few words beside each changed line, what that line does. Under the lines
-- of the change the reader is on it adds a paragraph about the line the
-- cursor is on and, when the Explainer could tell, what the values would be
-- if the program were stopped there. The Rail is drawn over the window as it
-- is painted and is never text in the buffer.
local M = {}
local ns = vim.api.nvim_create_namespace('scm.review')

-- The Rail is this many cells wide, and is shown only while this much is left for the code.
M.WIDTH, M.MIN_CODE = 46, 40
M.MODES = {'full', 'gists', 'off'}

local function cells(text) return vim.fn.strdisplaywidth(text) end

-- Fit a row of {text, highlight} pieces to exactly `width` cells: cut what
-- runs past it and fill what is left with `fill`.
local function fit(pieces, width, fill)
  local out, used = {}, 0
  for _, piece in ipairs(pieces) do
    local text = piece[1]
    local room = width - used
    if room <= 0 then break end
    if cells(text) > room then
      text = vim.fn.strcharpart(text, 0, math.max(0, room - 1))
      while cells(text) > room - 1 do text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1) end
      text = text .. '…'
    end
    out[#out + 1] = {text, piece[2]}
    used = used + cells(text)
  end
  if used < width then out[#out + 1] = {(' '):rep(width - used), fill} end
  return out
end

-- Break `text` into lines no wider than `width`, at spaces.
function M.wrap(text, width)
  local lines, line = {}, ''
  for word in text:gmatch('%S+') do
    if line ~= '' and cells(line) + 1 + cells(word) > width then
      lines[#lines + 1] = line
      line = word
    else
      line = line == '' and word or (line .. ' ' .. word)
    end
  end
  if line ~= '' then lines[#lines + 1] = line end
  return lines
end

-- A line of prose as pieces, with each of `names` in the colour of a variable.
local function prose(line, names, base, strong)
  local pieces, at = {}, 1
  while at <= #line do
    local from, to = line:find('[%a_][%w_]*', at)
    if not from then break end
    if names[line:sub(from, to)] then
      if from > at then pieces[#pieces + 1] = {line:sub(at, from - 1), base} end
      pieces[#pieces + 1] = {line:sub(from, to), strong}
      at = to + 1
    else
      if to >= at then pieces[#pieces + 1] = {line:sub(at, to), base} end
      at = to + 1
    end
  end
  if at <= #line then pieces[#pieces + 1] = {line:sub(at), base} end
  return pieces
end

-- The paragraph and the predicted values for one line, as rows of pieces
-- `width` cells wide. `line` is the diff's own record of it.
function M.block(note, line, width)
  local rows = {}
  if not (note.detail or note.paused) then return rows end
  local number = tostring(line.new or line.old or '')
  local mark = line.kind == '+' and {'+', 'ScmReviewHeadAdd'} or line.kind == '-' and {'−', 'ScmReviewHeadDelete'}
    or {'·', 'ScmReviewHead'}
  local what = line.kind == '+' and ' added' or line.kind == '-' and ' removed' or ' unchanged'
  local left = {{' ' .. number .. ' ', 'ScmReviewHeadStrong'}, mark, {what, 'ScmReviewHeadStrong'}}
  local keys = {{'K', 'ScmReviewHeadStrong'}, {' more detail  ', 'ScmReviewHead'}, {'\\a', 'ScmReviewHeadStrong'},
    {' ask ', 'ScmReviewHead'}}
  local used = 0
  for _, piece in ipairs(left) do used = used + cells(piece[1]) end
  local keys_width = 0
  for _, piece in ipairs(keys) do keys_width = keys_width + cells(piece[1]) end
  local head = vim.list_extend({}, left)
  head[#head + 1] = {(' '):rep(math.max(1, width - used - keys_width)), 'ScmReviewHead'}
  vim.list_extend(head, keys)
  rows[#rows + 1] = fit(head, width, 'ScmReviewHead')
  local names = {}
  for _, value in ipairs(note.paused and note.paused.values or {}) do names[value.name] = true end
  if note.detail then
    for _, text in ipairs(M.wrap(note.detail, width - 2)) do
      local pieces = prose(text, names, 'ScmReviewProse', 'ScmReviewVar')
      table.insert(pieces, 1, {' ', 'ScmReviewProse'})
      rows[#rows + 1] = fit(pieces, width, 'ScmReviewProse')
    end
  end
  local paused = note.paused
  if paused then
    rows[#rows + 1] = fit({}, width, 'ScmReviewRail')
    rows[#rows + 1] = fit({{'▌', 'ScmReviewPausedBarHead'}, {'IF PAUSED HERE', 'ScmReviewPausedTitle'},
      {'  predicted', 'ScmReviewPredictedHead'}, {' · not a real run', 'ScmReviewPausedHead'}}, width,
      'ScmReviewPausedHead')
    local function body(pieces)
      table.insert(pieces, 1, {'▌', 'ScmReviewPausedBar'})
      table.insert(pieces, 2, {' ', 'ScmReviewPaused'})
      rows[#rows + 1] = fit(pieces, width, 'ScmReviewPaused')
    end
    if paused.when then
      body({{paused.when, 'ScmReviewPaused'}})
      body({})
    end
    local widest = 0
    for _, value in ipairs(paused.values) do widest = math.max(widest, cells(value.name)) end
    widest = math.min(widest, 16)
    for _, value in ipairs(paused.values) do
      body({{value.name .. (' '):rep(math.max(0, widest - cells(value.name)) + 2), 'ScmReviewPausedName'},
        {value.value, 'ScmReviewValue'}})
      if value.note then
        body({{(' '):rep(widest + 2) .. '↳ ' .. value.note, 'ScmReviewPausedNote'}})
      end
    end
    rows[#rows + 1] = fit({{('▔'):rep(width), 'ScmReviewPausedEnd'}}, width, 'ScmReviewPausedEnd')
  end
  return rows
end

-- The note a Review holds for one line of the diff, or nil.
function M.note(review, line)
  if not (review and line) then return nil end
  if line.kind == '-' then return review.lines.old[line.old] end
  return line.new and review.lines.new[line.new] or nil
end

-- What the Rail shows on each row of a diff: {[row] = pieces}. `cursor` is
-- the row the reader is on; in "full" mode the rows under its change hold
-- the block about it. Also returns the rows of the block that the file is
-- too short to hold, to be drawn under its last line.
function M.rows(review, meta, cursor, width, mode)
  local rows = {}
  for row, line in ipairs(meta) do
    local note = M.note(review, line)
    if note then
      local current = row == cursor
      rows[row] = fit({{' ' .. note.gist, current and 'ScmReviewGistCurrent' or 'ScmReviewGist'}}, width,
        current and 'ScmReviewGistCurrent' or 'ScmReviewRail')
    end
  end
  local note = M.note(review, meta[cursor])
  local overflow = {}
  if mode ~= 'full' or not note then return rows, overflow end
  local block = M.block(note, meta[cursor], width)
  if #block == 0 then return rows, overflow end
  -- The block starts under the last line of the change the cursor is in.
  local last = cursor
  while meta[last + 1] and meta[last + 1].kind ~= ' ' do last = last + 1 end
  local start = math.min(last + 2, #meta + 1)
  for i, pieces in ipairs(block) do
    if start + i - 1 > #meta then overflow[#overflow + 1] = pieces else rows[start + i - 1] = pieces end
  end
  return rows, overflow
end

-- How wide the Rail is in a window whose text area is `text_width` cells, or
-- nil when the window is too narrow to hold it beside the code.
function M.width_in(text_width)
  if text_width < M.MIN_CODE + M.WIDTH + 1 then return nil end
  return M.WIDTH
end

-- Where the Rail sits in `win`: its width and the text column it starts at,
-- or nil when it is off or the window is too narrow.
local function place(view, state, win, mode)
  -- The gutter's width is worked out here: while a window is painted
  -- Neovim does not yet say how wide it drew it. The overview strip
  -- covers the last two cells of the window.
  local gutter = view.width + 3 + (#state.data.tour > 0 and 1 or 0)
  local text_width = vim.api.nvim_win_get_width(win) - gutter - 2
  local width = mode ~= 'off' and M.width_in(text_width) or nil
  return width, width and (text_width - width - 1)
end

local tail = vim.api.nvim_create_namespace('scm.review.tail')

-- Draw, under the last line of the diff in `win`, the rows of the block that
-- the file is too short to hold beside its lines.
function M.tail(view, win, mode)
  local state = view.review
  vim.api.nvim_buf_clear_namespace(view.buf, tail, 0, -1)
  if not (state and state.data) or #view.meta == 0 then return end
  local width, col = place(view, state, win, mode)
  if not width then return end
  local _, overflow = M.rows(state.data, view.meta, vim.api.nvim_win_get_cursor(win)[1], width, mode)
  if #overflow == 0 then return end
  local lines = {}
  for i, pieces in ipairs(overflow) do
    lines[i] = vim.list_extend({{(' '):rep(col), 'Normal'}, {'│', 'ScmReviewEdge'}}, pieces)
  end
  vim.api.nvim_buf_set_extmark(view.buf, tail, #view.meta - 1, 0, {virt_lines=lines})
end

-- Draw the Rail as windows are painted. `lookup(buf)` gives a diff's view, or nil.
function M.setup(lookup, mode_of)
  vim.api.nvim_set_decoration_provider(ns, {
    on_win=function(_, win, buf)
      local view = lookup(buf)
      local state = view and view.review
      if not (state and state.data) then return false end
      local mode = mode_of()
      local width, col = place(view, state, win, mode)
      local cursor = vim.api.nvim_win_get_cursor(win)[1]
      state.paint = {width=width, col=col, cursor=cursor, mode=mode}
      if width then
        local key = table.concat({view.revision, cursor, width, mode, state.generation or 0}, ':')
        if state.rail_key ~= key then
          state.rail_key, state.rail = key, M.rows(state.data, view.meta, cursor, width, mode)
        end
      end
      return true
    end,
    on_line=function(_, _, buf, row)
      local view = lookup(buf)
      local state = view and view.review
      local paint = state and state.paint
      if not paint then return end
      local line = view.meta[row + 1]
      if not line then return end
      local current = row + 1 == paint.cursor
      if current then
        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {ephemeral=true, end_row=row + 1, end_col=0, strict=false,
          hl_eol=true, hl_group='ScmReviewCurrentLine', priority=160})
        local note = M.note(state.data, line)
        local after = {}
        if note and note.inline then
          vim.list_extend(after, {{'  ≈ ', 'ScmReviewPredictedInline'}, {note.inline, 'ScmReviewValueInline'},
            {' (predicted)', 'ScmReviewPredictedInline'}})
        end
        -- A window too narrow for the Rail still says what the reader's line does.
        if note and not paint.width and paint.mode ~= 'off' then
          after[#after + 1] = {'   ' .. note.gist, 'ScmReviewGistCurrent'}
        end
        if #after > 0 then
          vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {ephemeral=true, virt_text_pos='eol', priority=170,
            virt_text=after})
        end
      end
      if not paint.width then return end
      local edge = current and {'▌', 'ScmReviewEdgeCurrent'} or line.kind == '+' and {'▌', 'ScmReviewEdgeAdd'}
        or line.kind == '-' and {'▌', 'ScmReviewEdgeDelete'} or {'│', 'ScmReviewEdge'}
      local pieces = {edge}
      vim.list_extend(pieces, state.rail[row + 1] or {{(' '):rep(paint.width), 'ScmReviewRail'}})
      vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {ephemeral=true, virt_text=pieces,
        virt_text_win_col=paint.col, priority=250})
    end,
  })
end

return M
