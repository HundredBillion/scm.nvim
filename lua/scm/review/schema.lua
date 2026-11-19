-- scm.review.schema — turns what an Explainer wrote into a Review. An
-- Explainer is a language model, so nothing it sends is trusted: every field
-- is checked, cut to the room the diff page has for it, and dropped when it
-- is not what was asked for. A Review is plain Lua data:
--   tour   {{title, summary, from, to}...}, by line of the new file
--   lines  {new = {[line] = note}, old = {[line] = note}}, a note being
--          {gist, before, detail, inline, paused = {when, values = {{name, value, note}...}}}
--   flows  {{from, to, note, trigger, later, handoff, outside, steps}...}
local M = {}

-- The longest each kind of text is asked to be, in characters.
M.LIMITS = {title=40, summary=90, gist=44, detail=400, inline=40, when=44, name=28, value=44, note=40,
  step=22, says=30, file=24, keys=14, phrase=36}
-- The Pane and the Tour bar wrap what they show, so their text is cut only when it runs to this
-- many times the length asked for.
M.WRAPPED = 3
-- The most of each list a Review keeps.
local MAX_TOUR, MAX_VALUES, MAX_FLOWS, MAX_LINES = 12, 5, 12, 4000
-- A lane holds this many steps at most, and a Flow Map this many in all.
M.MAX_LANE, M.MAX_STEPS = 4, 8
local WHEN = {now=1, later=2, outside=3}
local STATE = {ran=true, here=true, not_yet=true}

-- One line of text no longer than `limit`: control characters become spaces.
local function text(value, limit)
  if type(value) ~= 'string' then return nil end
  value = vim.trim((value:gsub('%c', ' '):gsub('%s+', ' ')))
  if value == '' then return nil end
  if vim.fn.strchars(value) > limit then value = vim.fn.strcharpart(value, 0, limit - 1) .. '…' end
  return value
end

local function line_number(value)
  if type(value) ~= 'number' or value ~= math.floor(value) or value < 1 or value > 10000000 then return nil end
  return value
end

local function list(value)
  return type(value) == 'table' and vim.islist(value) and value or {}
end

local function range(item)
  local from, to = line_number(item.from), line_number(item.to)
  if not from then return nil end
  to = to or from
  if to < from then from, to = to, from end
  return from, to
end

local function paused(value)
  if type(value) ~= 'table' then return nil end
  local values = {}
  for _, item in ipairs(list(value.values)) do
    if #values == MAX_VALUES then break end
    if type(item) == 'table' then
      local name, shown = text(item.name, M.LIMITS.name), text(item.value, M.LIMITS.value * M.WRAPPED)
      if name and shown then values[#values + 1] = {name=name, value=shown, note=text(item.note, M.LIMITS.note * M.WRAPPED)} end
    end
  end
  if #values == 0 then return nil end
  return {when=text(value.when, M.LIMITS.when * M.WRAPPED), values=values}
end

local function steps(value)
  local out, lanes, here = {}, {0, 0, 0}, false
  local last = 1
  for _, item in ipairs(list(value)) do
    if #out == M.MAX_STEPS then break end
    if type(item) == 'table' then
      local name = text(item.name, M.LIMITS.step)
      -- Time only runs forward: a step cannot be in an earlier lane than the one before it.
      local lane = math.max(WHEN[item.when] or last, last)
      if name and lanes[lane] < M.MAX_LANE then
        local state = STATE[item.state] and item.state or 'ran'
        -- Only one step is where the reader is, and nothing after it has run yet.
        if here then state = 'not_yet' elseif state == 'here' then here = true end
        lanes[lane], last = lanes[lane] + 1, lane
        out[#out + 1] = {name=name, says=text(item.says, M.LIMITS.says), file=text(item.file, M.LIMITS.file),
          lane=lane, state=state, changed=item.changed == true or nil, again=line_number(item.again),
          line=line_number(item.line)}
      end
    end
  end
  return out
end

-- The Review in `raw`, the table an Explainer's JSON decoded to. Returns nil
-- and why when it holds nothing a Review can use.
function M.normalise(raw)
  if type(raw) ~= 'table' then return nil, 'the answer is not a JSON object' end
  local review = {tour={}, lines={new={}, old={}}, flows={}}
  for _, item in ipairs(list(raw.tour)) do
    if #review.tour == MAX_TOUR then break end
    if type(item) == 'table' then
      local from, to = range(item)
      local title = text(item.title, M.LIMITS.title)
      if from and title then
        review.tour[#review.tour + 1] = {title=title, summary=text(item.summary, M.LIMITS.summary * M.WRAPPED), from=from, to=to}
      end
    end
  end
  table.sort(review.tour, function(a, b) return a.from < b.from end)
  local count = 0
  for _, item in ipairs(list(raw.lines)) do
    if count == MAX_LINES then break end
    local number = type(item) == 'table' and line_number(item.line)
    local gist = number and text(item.gist, M.LIMITS.gist * M.WRAPPED)
    if gist then
      count = count + 1
      review.lines[item.side == 'old' and 'old' or 'new'][number] = {gist=gist,
        before=item.side ~= 'old' and text(item.before, M.LIMITS.gist * M.WRAPPED) or nil,
        detail=text(item.detail, M.LIMITS.detail), inline=text(item.inline, M.LIMITS.inline),
        paused=paused(item.paused)}
    end
  end
  for _, item in ipairs(list(raw.flows)) do
    if #review.flows == MAX_FLOWS then break end
    if type(item) == 'table' then
      local from, to = range(item)
      local path = steps(item.steps)
      if from and #path >= 2 then
        local trigger = type(item.trigger) == 'table' and item.trigger or {}
        review.flows[#review.flows + 1] = {from=from, to=to, steps=path,
          note=text(item.note, M.LIMITS.gist),
          trigger={says=text(trigger.says, M.LIMITS.phrase), keys=text(trigger.keys, M.LIMITS.keys)},
          later=text(item.later, M.LIMITS.phrase), handoff=text(item.handoff, M.LIMITS.phrase),
          outside=text(item.outside, M.LIMITS.phrase)}
      end
    end
  end
  if #review.tour == 0 and count == 0 then return nil, 'the answer explains no line of this change' end
  return review
end

-- The JSON object in an Explainer's answer. A model often wraps what it was
-- asked for in a sentence or a code fence, so the outermost braces are read.
function M.decode(answer)
  if type(answer) ~= 'string' then return nil, 'there was no answer' end
  local first, last = answer:find('{', 1, true), nil
  for i = #answer, 1, -1 do
    if answer:sub(i, i) == '}' then last = i; break end
  end
  if not (first and last and last > first) then return nil, 'the answer holds no JSON object' end
  local ok, value = pcall(vim.json.decode, answer:sub(first, last), {luanil={object=true, array=true}})
  if not ok then return nil, 'the answer is not valid JSON' end
  return value
end

-- The index of the tour step that holds new-file line `number`, or nil.
function M.step_at(review, number)
  for i, step in ipairs(review.tour) do
    if number >= step.from and number <= step.to then return i end
  end
end

-- The Flow Map that tells how new-file line `number` gets run, or nil.
function M.flow_at(review, number)
  for _, flow in ipairs(review.flows) do
    if number >= flow.from and number <= flow.to then return flow end
  end
end

return M
