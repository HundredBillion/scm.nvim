-- scm.review.pane — the Pane: the box floating at the right of a diff that
-- explains the line the cursor is on, and no other. It says what the line was
-- before and what it is now, adds a paragraph about it and, when the Explainer
-- could tell, what the values would be if the program were stopped there.
-- This module works out what the Pane says and where it sits; scm.review
-- puts it on screen.
local M = {}

-- The Pane's text area is this many cells wide; its border adds two.
M.WIDTH = 48
-- A window narrower than this shows the Pane's first row alone.
M.NARROW = 100
-- The most rows of the paragraph shown in the Pane.
M.MAX_PROSE = 6
-- The Pane changes sides for more room only when the other side has this many rows more.
local WORTH_MOVING = 3

local function cells(text) return vim.fn.strdisplaywidth(text) end

-- Cut a row of {text, highlight} pieces to `width` cells.
local function fit(pieces, width)
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
  return out
end

-- Break `text` into lines no wider than `width`, at spaces. A word wider
-- than a whole line is broken where the line ends.
function M.wrap(text, width)
  local lines, line = {}, ''
  local words = {}
  for word in text:gmatch('%S+') do
    while cells(word) > width do
      local part = vim.fn.strcharpart(word, 0, width)
      while cells(part) > width do part = vim.fn.strcharpart(part, 0, vim.fn.strchars(part) - 1) end
      if part == '' then break end
      words[#words + 1] = part
      word = vim.fn.strcharpart(word, vim.fn.strchars(part))
    end
    words[#words + 1] = word
  end
  for _, word in ipairs(words) do
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

-- A line of prose as pieces, with each of `names` standing out.
local function prose(line, names, base, strong)
  local pieces, at = {}, 1
  while at <= #line do
    local from, to = line:find('[%a_][%w_]*', at)
    if not from then break end
    if names[line:sub(from, to)] then
      if from > at then pieces[#pieces + 1] = {line:sub(at, from - 1), base} end
      pieces[#pieces + 1] = {line:sub(from, to), strong}
    else
      pieces[#pieces + 1] = {line:sub(at, to), base}
    end
    at = to + 1
  end
  if at <= #line then pieces[#pieces + 1] = {line:sub(at), base} end
  return pieces
end

local function without_before(gist)
  return gist and (gist:gsub('^[Bb]efore:%s*', '')) or nil
end

-- What a Review says about row `row` of a diff, or nil when the row is not a
-- line of it: {line, before, now, detail, paused}. `line` is the diff's own
-- record of the row. An unchanged line has `line` alone.
function M.about(review, meta, row)
  local line = meta[row]
  if not (review and line) then return nil end
  if line.kind ~= '+' and line.kind ~= '-' then return {line=line} end
  -- A change is a run of removed lines and the run of added lines under it.
  local removed_from, added_from
  if line.kind == '+' then
    added_from = row
    while meta[added_from - 1] and meta[added_from - 1].kind == '+' do added_from = added_from - 1 end
    removed_from = added_from
    while meta[removed_from - 1] and meta[removed_from - 1].kind == '-' do removed_from = removed_from - 1 end
  else
    removed_from = row
    while meta[removed_from - 1] and meta[removed_from - 1].kind == '-' do removed_from = removed_from - 1 end
    added_from = row
    while meta[added_from] and meta[added_from].kind == '-' do added_from = added_from + 1 end
  end
  local removed = added_from - removed_from
  local added = 0
  while meta[added_from + added] and meta[added_from + added].kind == '+' do added = added + 1 end
  -- The line across from this one in the other run, or failing that the run's first.
  local nth = row - (line.kind == '+' and added_from or removed_from)
  local function old_note(at)
    local other = at < removed and meta[removed_from + at]
    return other and review.lines.old[other.old] or nil
  end
  local function new_note(at)
    local other = at < added and meta[added_from + at]
    return other and review.lines.new[other.new] or nil
  end
  local old, new = old_note(nth) or old_note(0), nil
  if line.kind == '+' then new = review.lines.new[line.new] else new = new_note(nth) or new_note(0) end
  -- An added line the Review says nothing about is not given the words of another.
  if line.kind == '+' and not new then return {line=line} end
  local own = line.kind == '+' and new or review.lines.old[line.old] or old
  -- What the Explainer said this very line was before, or failing that what the removed lines did.
  local before = line.kind == '+' and new.before or (old and old.gist)
  return {line=line, before=without_before(before), now=new and new.gist,
    detail=own and own.detail, paused=line.kind == '+' and new and new.paused or nil}
end

local function header(about, tail)
  local line = about.line
  local pieces = {{'▶ line ' .. tostring(line.new or line.old or ''), 'ScmReviewPaneLine'}, {'  ', 'ScmReviewPaneLabel'}}
  if line.kind == '+' then
    vim.list_extend(pieces, {{'+', 'ScmReviewPaneAdd'}, {' added', 'ScmReviewPaneLabel'}})
  elseif line.kind == '-' then
    vim.list_extend(pieces, {{'−', 'ScmReviewPaneDelete'}, {' removed', 'ScmReviewPaneLabel'}})
  end
  vim.list_extend(pieces, tail or {})
  pieces.band = true
  return pieces
end

local KEY = {{' · ', 'ScmReviewPaneLabel'}, {'K', 'ScmReviewPaneKey'}, {' full explanation', 'ScmReviewPaneLabel'}}

-- The Pane for `about` as rows of {text, highlight} pieces, in at most `room`
-- rows. A row with `band` is the heading; one with `bar` is part of "if
-- paused here". When everything does not fit, the paragraph gives way and
-- "if paused here" does not; when even that does not fit, or `narrow` is
-- set, the heading stands alone. Also returns true when it stands alone.
function M.rows(about, width, room, narrow)
  local line = about.line
  if line.kind ~= '+' and line.kind ~= '-' then
    return {header(about, {{'no change on this line', 'ScmReviewPaneLabel'}})}, true
  end
  if not (about.before or about.now or about.detail or about.paused) then
    return {header(about, {{' · no note for this line', 'ScmReviewPaneLabel'}})}, true
  end
  local text_width = width - 2
  local values = about.paused and about.paused.values or {}
  -- "before", "now" and the names of the values share one column.
  local label = 6
  for _, value in ipairs(values) do label = math.max(label, math.min(cells(value.name), 16)) end
  label = label + 2
  local function labelled(name, text, highlight, out, bar)
    -- A name too long for its column takes rows of its own, above what it names.
    if cells(name) > label - 2 then
      for _, part in ipairs(M.wrap(name, text_width)) do
        local row = {{part, 'ScmReviewPaneLabel'}}
        row.bar = bar
        out[#out + 1] = row
      end
      name = ''
    end
    for i, part in ipairs(M.wrap(text, math.max(10, text_width - label))) do
      local shown = i == 1 and name or ''
      local row = fit({{shown .. (' '):rep(math.max(1, label - cells(shown))), 'ScmReviewPaneLabel'}, {part, highlight}},
        text_width)
      row.bar = bar
      out[#out + 1] = row
    end
  end
  local head = {header(about)}
  if about.before then labelled('before', about.before, 'ScmReviewPaneText', head) end
  if about.now then labelled('now', about.now, 'ScmReviewPaneGist', head) end
  local tail = {}
  if about.paused then
    local function bar(pieces)
      local row = fit(pieces, text_width)
      row.bar = true
      tail[#tail + 1] = row
    end
    bar({{'IF PAUSED HERE', 'ScmReviewPaneTitle'}, {'  predicted', 'ScmReviewPanePredicted'},
      {' · not a real run', 'ScmReviewPaneLabel'}})
    for _, part in ipairs(about.paused.when and M.wrap(about.paused.when, text_width) or {}) do
      bar({{part, 'ScmReviewPaneLabel'}})
    end
    for _, value in ipairs(values) do
      labelled(value.name, value.value, 'ScmReviewPaneValue', tail, true)
      for i, part in ipairs(value.note and M.wrap(value.note, math.max(10, text_width - label - 2)) or {}) do
        bar({{(' '):rep(label) .. (i == 1 and '↳ ' or '  ') .. part, 'ScmReviewPaneLabel'}})
      end
    end
  end
  if narrow or room < #head + #tail then return {header(about, KEY)}, true end
  local names = {}
  for _, value in ipairs(values) do names[value.name] = true end
  local wrapped = about.detail and M.wrap(about.detail, text_width) or {}
  local gap_prose, gap_tail = #wrapped > 0 and 1 or 0, #tail > 0 and 1 or 0
  local shown = math.min(#wrapped, M.MAX_PROSE)
  local free = room - #head - #tail - gap_prose - gap_tail
  -- Squeezed: the blank row above "if paused here" goes first.
  if shown > free and gap_tail == 1 then gap_tail, free = 0, free + 1 end
  local body = {}
  if shown > free or shown < #wrapped then
    local keep = math.max(0, math.min(shown, free - 1))
    local more = #wrapped - keep
    local kept = vim.list_slice(wrapped, 1, keep)
    -- The paragraph stops at the end of a sentence, not in the middle of one.
    while #kept > 0 and not kept[#kept]:find('[.!?]$') do
      local stop
      for at in kept[#kept]:gmatch('()[.!?] ') do stop = at end
      if stop then kept[#kept] = kept[#kept]:sub(1, stop)
      elseif #kept > 1 then kept[#kept] = nil
      else break end
    end
    for _, text in ipairs(kept) do body[#body + 1] = prose(text, names, 'ScmReviewPaneProse', 'ScmReviewPaneStrong') end
    local says = keep > 0 and ('… %d more row%s · '):format(more, more == 1 and '' or 's')
      or ('paragraph hidden (%d rows) · '):format(more)
    if free < 1 then gap_prose, free = 0, free + 1 end
    if free >= 1 then
      body[#body + 1] = {{says, 'ScmReviewPaneMore'}, {'K', 'ScmReviewPaneKey'}, {' full explanation', 'ScmReviewPaneMore'}}
    end
  else
    for _, text in ipairs(wrapped) do body[#body + 1] = prose(text, names, 'ScmReviewPaneProse', 'ScmReviewPaneStrong') end
  end
  local rows = head
  if #body > 0 then
    if gap_prose == 1 then rows[#rows + 1] = {} end
    for _, pieces in ipairs(body) do rows[#rows + 1] = fit(pieces, text_width) end
  end
  if #tail > 0 then
    if gap_tail == 1 then rows[#rows + 1] = {} end
    vim.list_extend(rows, tail)
  end
  return rows, false
end

-- Everything a Review says about a line, as plain lines of text.
function M.plain(about)
  local lines = {}
  if about.before then lines[#lines + 1] = 'Before: ' .. about.before end
  if about.now then lines[#lines + 1] = 'Now: ' .. about.now end
  if about.detail then vim.list_extend(lines, {'', about.detail}) end
  if about.paused then
    vim.list_extend(lines, {'', 'If paused here (predicted, not a real run):'})
    if about.paused.when then lines[#lines + 1] = about.paused.when end
    for _, value in ipairs(about.paused.values) do
      lines[#lines + 1] = ('%s = %s%s'):format(value.name, value.value, value.note and ('   (' .. value.note .. ')') or '')
    end
  end
  return lines
end

-- Where a Pane of `need` rows (its border counted) sits in a window `height`
-- rows tall whose cursor is on window row `at` (1 is the first). The first
-- `bar` rows (one, when not given) belong to the Tour bar. Home is the top right; when the Pane does not
-- fit above the cursor's row with a clear row between, it rests at the
-- bottom right. `was` is the side it is on now: it stays there while it
-- fits, so it does not jump about as the cursor moves. Returns the side
-- ("home" or "bottom") and the rows it may fill there, border counted.
function M.place(need, at, height, was, bar)
  local room = {home=at - 2 - (bar or 1), bottom=height - at - 1}
  local other = {home='bottom', bottom='home'}
  local first = was or 'home'
  if need <= room[first] then return first, need end
  if need <= room[other[first]] then return other[first], need end
  -- Neither side holds all of it: the larger one, and less is shown.
  local side = room.home >= room.bottom and 'home' or 'bottom'
  if was and room[other[was]] < room[was] + WORTH_MOVING then side = was end
  return side, math.max(0, room[side])
end

return M
