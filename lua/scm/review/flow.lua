-- scm.review.flow — the Flow Map, "how this line gets run", as a shape both
-- drawings share and as the one made of characters. The map reads as time:
-- what runs right away, what the program runs later, and what happens
-- outside it. Each step is a function, numbered in the order it runs.
local M = {}

M.LANES = {'Right away', 'Later', 'Outside'}

-- Where each step sits. A lane lays its steps along the top row and drops
-- the last one under the step before it, so the path through a lane turns
-- once; a lane's only step stays on the row of the step that leads to it.
-- Returns the steps as cards {step, index, lane, col, row} and the lanes in
-- use as {lane, cards, cols}.
function M.place(flow)
  local lanes, by_lane = {}, {}
  for index, step in ipairs(flow.steps) do
    local lane = by_lane[step.lane]
    if not lane then
      lane = {lane=step.lane, cards={}}
      by_lane[step.lane] = lane
      lanes[#lanes + 1] = lane
    end
    lane.cards[#lane.cards + 1] = {step=step, index=index, lane=step.lane}
  end
  local cards, last_row = {}, 1
  for _, lane in ipairs(lanes) do
    local count = #lane.cards
    for i, card in ipairs(lane.cards) do
      if count == 1 then card.col, card.row = 1, last_row
      elseif i < count then card.col, card.row = i, 1
      else card.col, card.row = count - 1, 2 end
      cards[#cards + 1] = card
    end
    lane.cols = math.max(1, count - 1)
    last_row = lane.cards[count].row
  end
  return cards, lanes
end

-- What joins each step to the next: "calls" for a call that has happened,
-- "later" where the program takes over and runs the next step in its own
-- time, and "not_yet" for a call the reader's line has not reached.
function M.edges(flow)
  local out = {}
  for i = 1, #flow.steps - 1 do
    local a, b = flow.steps[i], flow.steps[i + 1]
    local kind = b.state == 'not_yet' and 'not_yet' or (a.lane == 1 and b.lane == 2) and 'later' or 'calls'
    out[#out + 1] = {from=i, to=i + 1, kind=kind}
  end
  return out
end

-- The step the reader is on, and its place in the list.
function M.here(flow)
  for i, step in ipairs(flow.steps) do
    if step.state == 'here' then return step, i end
  end
end

-- What the heading says after the title: that the map is a guess, what the
-- Explainer noted about it, and which file an untagged step is in.
function M.caption(flow, file)
  local parts = {'guess', 'first run shown'}
  if flow.note then parts[#parts + 1] = flow.note end
  if file then parts[#parts + 1] = 'in ' .. file .. ' unless tagged' end
  return table.concat(parts, ' · ')
end

local function lane_title(flow, lane)
  if lane == 3 then return (flow.outside or 'Outside this program'):upper() end
  return M.LANES[lane]:upper()
end

-- The map drawn with characters, for a terminal that cannot show a picture:
-- a staircase, one step a row, each a list of {text, highlight} pieces.
function M.text(flow, line)
  local rows = {}
  local function row(...) rows[#rows + 1] = {...} end
  local trigger = flow.trigger or {}
  if trigger.says or trigger.keys then
    row({' ● ', 'ScmReviewDim'}, {(trigger.says or 'starts with') .. ' ', 'ScmReviewDim'},
      {trigger.keys and (' ' .. trigger.keys .. ' ') or '', 'ScmReviewKey'})
  end
  local lane, depth = 0, 0
  local _, here_at = M.here(flow)
  for i, step in ipairs(flow.steps) do
    local pending = step.state == 'not_yet'
    if step.lane ~= lane then
      if step.lane == 2 and lane == 1 then
        -- The program takes over: the path leaves the staircase and starts again.
        row({'╭' .. ('╌'):rep(math.max(2, depth * 2 + 3)) .. '╯  ', 'ScmReviewLater'},
          {'later · ' .. (flow.later or 'when the program is free'), 'ScmReviewLater'})
        depth = 0
      else
        local rule = step.lane == 3 and '┯━ ' or '┬─ '
        local fill = step.lane == 3 and '━' or '─'
        local title = lane_title(flow, step.lane)
        row({rule, 'ScmReviewRule'}, {title .. ' ', 'ScmReviewLane'},
          {fill:rep(math.max(3, 40 - vim.fn.strchars(title))), 'ScmReviewRule'})
        depth = 0
      end
      lane = step.lane
    end
    local arrow
    if step.lane == 2 and depth == 0 and i > 1 and flow.steps[i - 1].lane == 1 then
      arrow = {'╰╌▶ ', 'ScmReviewLater'}
      -- That arrow is a column wider than a stair, so the next stair starts further in.
      depth = 1
    else
      arrow = {('  '):rep(depth) .. (pending and '└▷ ' or '└▶ '), pending and 'ScmReviewDim' or 'ScmReviewRule'}
    end
    local number = step.lane == 3 and '$' or tostring(i)
    local name_hl = step.state == 'here' and 'ScmReviewHere' or pending and 'ScmReviewDim' or 'ScmReviewName'
    local pieces = {arrow, {number .. ' ', step.state == 'here' and 'ScmReviewHere' or 'ScmReviewDim'},
      {step.name, name_hl}}
    if step.says then pieces[#pieces + 1] = {'  ' .. step.says, 'ScmReviewDim'} end
    if step.file then pieces[#pieces + 1] = {' · ' .. step.file, 'ScmReviewDim'} end
    if step.changed then pieces[#pieces + 1] = {'  ~ changed', 'ScmReviewDim'} end
    rows[#rows + 1] = pieces
    if i == here_at then
      local where = {{('  '):rep(depth + 1) .. '┃ ', 'ScmReviewHere'},
        {'you are here · line ' .. (step.line or line or '?'), 'ScmReviewHere'}}
      if step.again then where[#where + 1] = {'   ↻ again at line ' .. step.again, 'ScmReviewLater'} end
      rows[#rows + 1] = where
    end
    depth = depth + 1
  end
  return rows
end

-- The map on one row, for a window too short to give it more: the step
-- before the reader's, the reader's, and the one after.
function M.brief(flow, line)
  local step, at = M.here(flow)
  if not step then step, at = flow.steps[#flow.steps], #flow.steps end
  local pieces = {}
  local before, after = flow.steps[at - 1], flow.steps[at + 1]
  if before then
    pieces[#pieces + 1] = {(at > 2 and '… ' or '') .. before.name .. ' ', 'ScmReviewName'}
    if before.lane == 1 and step.lane == 2 then
      pieces[#pieces + 1] = {'┄later┄▶ ', 'ScmReviewLater'}
    else
      pieces[#pieces + 1] = {'─▶ ', 'ScmReviewRule'}
    end
  end
  pieces[#pieces + 1] = {step.name, 'ScmReviewHere'}
  pieces[#pieces + 1] = {' line ' .. (step.line or line or '?'), 'ScmReviewHere'}
  if step.again then pieces[#pieces + 1] = {'  ↻ again at ' .. step.again, 'ScmReviewLater'} end
  if after then
    pieces[#pieces + 1] = {after.state == 'not_yet' and '  ┄not yet┄▷ ' or '  ─▶ ', 'ScmReviewDim'}
    pieces[#pieces + 1] = {after.name .. (at + 1 < #flow.steps and ' …' or ''),
      after.state == 'not_yet' and 'ScmReviewDim' or 'ScmReviewName'}
  end
  return pieces
end

return M
