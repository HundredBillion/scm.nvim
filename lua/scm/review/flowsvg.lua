-- scm.review.flowsvg — the Flow Map drawn as a picture, for a host that can
-- show one. Lanes are moments in time, cards are functions, and each colour
-- says one thing: blue is where the reader is, violet is what the program
-- runs later, slate is what already ran, and a dashed outline is what has
-- not run yet. No text is brighter than the editor's own.
local Flow = require('scm.review.flow')
local M = {}

-- The colours of the map on a dark editor background.
M.COLORS = {
  background='#1e1f22', foreground='#acb2be', dim='#9a9fab', border='#393b40', heading='#2c3744',
  here='#73ade9', here_fill='#274463', here_border='#6398d0', seam='#161b24', here_sub='#a3abb8',
  later='#8f76b8', later_text='#a78bd0', later_border='#5a4a78', later_sub='#9d8fb8',
  predicted='#d9a35c',
  now_lane='#232830', now_border='#363d49', now_label='#95a1b3',
  later_lane='#242229', later_lane_border='#473e5a',
  outside_border='#7f8694', outside_label='#8b93a1',
  ran_fill='#2e333c', ran_border='#444a55', ran_edge='#17181b', ran_bar='#7d8799', sub='#9ca3af',
  chips={'#3a4150', '#3f5073', '#456096'},
  todo_border='#828a98', todo_text='#9aa0ab', todo_chip='#666c78',
  path='#8d95a3', todo_path='#7f8794',
  pill='#232830', pill_border='#5a6070', key='#383c45', changed_border='#3d5a7c',
}

local SANS = "Helvetica Neue, Adwaita Sans, Arial, sans-serif"
local HEADING_H, LENS_TOP, LENS_H, HINT_H, SIDE = 26, 32, 186, 26, 12
local CARD_H, ROWS = 48, {46, 127}
local CALL_GAP, LANE_PAD, LANE_GAP, LOOP_ROOM = 58, 10, 14, 60

local NARROW, WIDE = "iljtfrI.,:;'|!()[] ", 'mwMW@'
-- About how wide `text` is drawn at `size` pixels. A picture is laid out
-- before any font is known, so this errs on the wide side.
local function width(text, size, mono)
  local count = vim.fn.strchars(text)
  if mono then return count * size * 0.61 end
  local total = 0
  for i = 0, count - 1 do
    local char = vim.fn.strcharpart(text, i, 1)
    if NARROW:find(char, 1, true) then total = total + 0.3
    elseif WIDE:find(char, 1, true) then total = total + 0.84
    elseif char:match('%u') then total = total + 0.68
    elseif char:match('%d') then total = total + 0.58
    else total = total + 0.53 end
  end
  return total * size
end

local function escape(text)
  return (text:gsub('&', '&amp;'):gsub('<', '&lt;'):gsub('>', '&gt;'):gsub('"', '&quot;'))
end

local function num(value) return (('%.1f'):format(value):gsub('%.0$', '')) end

-- Build the picture. `opts` holds:
--   width   the room it has, in pixels
--   file    the name of the file the diff is of
--   line    the line the reader is on
--   hints   the row of keys under the map: {{text, strong}...}
--   mono    the editor's font family
--   colors  overrides for M.COLORS
--   density how many pixels of the picture draw one pixel of its room; a
--           host that paints the picture as given needs 2 on a sharp display
-- Returns the SVG and its height in pixels.
function M.svg(flow, opts)
  opts = opts or {}
  local c = vim.tbl_extend('force', M.COLORS, opts.colors or {})
  local mono = (opts.mono and (opts.mono .. ', ') or '') .. 'SF Mono, Menlo, DejaVu Sans Mono, monospace'
  local out = {}
  local function add(...) out[#out + 1] = table.concat({...}) end
  local function text(x, y, value, size, fill, extra)
    add('<text x="', num(x), '" y="', num(y), '" font-size="', num(size), '" fill="', fill, '" ', extra or '',
      '>', escape(value), '</text>')
  end
  local function sans(weight, more)
    return ('font-family="%s" font-weight="%d" %s'):format(SANS, weight or 400, more or '')
  end
  local function code(weight) return ('font-family="%s" font-weight="%d"'):format(mono, weight or 400) end

  local cards, lanes = Flow.place(flow)
  local edges = Flow.edges(flow)
  local _, here_at = Flow.here(flow)
  local leaving = {}
  for _, edge in ipairs(edges) do leaving[edge.from] = edge end

  -- How wide each card is.
  for _, card in ipairs(cards) do
    local step = card.step
    local says = (step.says or '') .. (step.file and ((step.says and ' · ' or '') .. step.file) or '')
    local inner = math.max(width(step.name, 14.6, true), width(says, 12.6))
    card.w = math.max(150, 9 + 7 + 25 + 8 + inner + 14)
    if step.changed then card.w = card.w + width('~ changed', 11.5) + 26 end
    card.says = says
  end
  -- Where each lane and its cards sit.
  local x = SIDE
  for at, lane in ipairs(lanes) do
    local label = Flow.LANES[lane.lane]:upper()
    local sub, keys
    if lane.lane == 1 then
      sub, keys = flow.trigger.says and ('· ' .. flow.trigger.says), flow.trigger.keys
    elseif lane.lane == 2 then
      sub = '· ' .. (flow.later or 'when the program is free')
    else
      label = (flow.outside or 'Outside this program'):upper()
    end
    lane.label, lane.sub, lane.keys = label, sub, keys
    local label_w = width(label, 11.5) * 1.26 + (sub and width(sub, 12.4) + 6 or 0)
      + (keys and width(keys, 12.4, true) + 22 or 0) + 2 * LANE_PAD
    if at > 1 then
      local edge = leaving[lane.cards[1].index - 1]
      lane.handoff = edge and edge.kind == 'later'
      x = x + (lane.handoff and (width(flow.handoff or 'runs it later', 11.8) + 34) or LANE_GAP)
    end
    lane.x = x
    local loop
    for _, card in ipairs(lane.cards) do
      if card.index == here_at and card.step.again then loop = card end
    end
    local again = loop and (width('↻ again · line ' .. loop.step.again, 12.2) + 20)
    if loop and loop.col == 1 then
      -- The loop's label sits past the card's right edge: the card is wide
      -- enough to keep it clear of the lane's own label.
      loop.w = math.max(loop.w, label_w + again / 2 - 24)
    end
    local col_w, gap = {}, {}
    for _, card in ipairs(lane.cards) do
      col_w[card.col] = math.max(col_w[card.col] or 0, card.w)
      -- A call that has not happened yet has a longer label to fit between two cards.
      local edge = leaving[card.index]
      if card.row == 1 and edge then gap[card.col] = edge.kind == 'not_yet' and 88 or CALL_GAP end
    end
    local cx, col_x = x + LANE_PAD, {}
    for col = 1, lane.cols do
      col_x[col] = cx
      cx = cx + col_w[col] + (col < lane.cols and (gap[col] or CALL_GAP) or 0)
    end
    local content = cx - x + LANE_PAD
    for _, card in ipairs(lane.cards) do
      card.x, card.y = col_x[card.col], LENS_TOP + ROWS[card.row]
    end
    -- The path to the next lane leaves room for its label beside the card.
    local last = lane.cards[#lane.cards]
    local out_edge = leaving[last.index]
    if out_edge and out_edge.kind ~= 'later' and lanes[at + 1] then
      content = math.max(content, last.x + last.w + width('not yet', 12.2) + 58 - x)
    end
    if loop then
      content = math.max(content, loop.x + loop.w + LOOP_ROOM + LANE_PAD - x,
        loop.x + loop.w + 24 + again / 2 + LANE_PAD - x)
    end
    lane.w = math.max(content, label_w)
    x = x + lane.w
  end
  local natural = x + SIDE
  local room = math.max(opts.width or natural, 320)
  -- Spare room goes between the lanes, where the paths cross.
  if room > natural and #lanes > 1 then
    local spare = math.min((room - natural) / (#lanes - 1), 90)
    for at, lane in ipairs(lanes) do
      local shift = spare * (at - 1)
      lane.x = lane.x + shift
      for _, card in ipairs(lane.cards) do card.x = card.x + shift end
    end
    natural = natural + spare * (#lanes - 1)
  end
  local canvas = math.max(natural, room)
  local total = LENS_TOP + LENS_H + 8 + (opts.hints and HINT_H or 0)
  -- An empty band under the last row. A host that fits the picture to the
  -- width of its room alone cuts the bottom of a picture a little too tall
  -- for it: this is what it cuts, not the row of keys.
  local spare = opts.spare or 0
  local scale = math.min(1, room / canvas)

  -- No side of the picture may pass what a host will paint.
  local density = math.min(opts.density or 1, 4000 / (canvas * scale))
  add('<svg xmlns="http://www.w3.org/2000/svg" width="', num(canvas * scale * density), '" height="',
    num((total + spare) * scale * density),
    '" viewBox="0 0 ', num(canvas), ' ', num(total + spare), '">')
  add('<defs><pattern id="hatch" width="10" height="10" patternUnits="userSpaceOnUse" patternTransform="rotate(45)">',
    '<rect width="5" height="10" fill="', c.foreground, '" fill-opacity="0.09"/></pattern></defs>')
  add('<rect width="', num(canvas), '" height="', num(total + spare), '" fill="', c.background, '"/>')
  -- The heading.
  add('<rect width="', num(canvas), '" height="', HEADING_H, '" fill="', c.heading, '"/>')
  add('<rect width="', num(canvas), '" height="1" fill="', c.border, '"/>')
  local title = 'HOW THIS LINE GETS RUN'
  text(SIDE, 17.5, title, 13, c.foreground, code(700))
  local tx = SIDE + width(title, 13, true) + 16
  text(tx, 17.5, '≈', 13, c.predicted, code(400))
  text(tx + 16, 17.5, Flow.caption(flow, opts.file), 13, c.dim, code(400))

  -- The lanes.
  for _, lane in ipairs(lanes) do
    local y, h = LENS_TOP, LENS_H
    if lane.lane == 3 then
      add('<rect x="', num(lane.x + 1), '" y="', y + 1, '" width="', num(lane.w - 2), '" height="', h - 2,
        '" rx="8" fill="', c.foreground, '" fill-opacity="0.03" stroke="', c.outside_border,
        '" stroke-width="2" stroke-linecap="round" stroke-dasharray="0.1 4.5"/>')
    else
      local fill = lane.lane == 1 and c.now_lane or c.later_lane
      local stroke = lane.lane == 1 and c.now_border or c.later_lane_border
      add('<rect x="', num(lane.x + 0.5), '" y="', y + 0.5, '" width="', num(lane.w - 1), '" height="', h - 1,
        '" rx="9" fill="', fill, '" stroke="', stroke, '"/>')
    end
    local color = lane.lane == 1 and c.now_label or lane.lane == 2 and c.later_text or c.outside_label
    local lx = lane.x + LANE_PAD
    text(lx, y + 19, lane.label, 11.5, color, sans(700, 'letter-spacing="1.3"'))
    lx = lx + width(lane.label, 11.5) * 1.22 + 6
    if lane.sub then
      text(lx, y + 19, lane.sub, 12.4, lane.lane == 2 and c.later_sub or color, sans(400))
      lx = lx + width(lane.sub, 12.4) + 8
    end
    if lane.keys then
      local kw = width(lane.keys, 12.4, true) + 14
      add('<rect x="', num(lx), '" y="', y + 6, '" width="', num(kw), '" height="19" rx="4" fill="', c.key, '"/>')
      text(lx + 7, y + 19.5, lane.keys, 12.4, c.foreground, code(700))
    end
  end

  -- The paths, under the cards they join.
  local heads, pills = {}, {}
  local function head(hx, hy, turn, color, hollow)
    local size = hollow and 7.5 or 5
    heads[#heads + 1] = ('<path transform="translate(%s %s) rotate(%d)" d="M%s %s L0 0 L%s %s z" fill="%s" '
      .. 'stroke="%s" stroke-width="1.3" stroke-linejoin="round"/>'):format(num(hx), num(hy), turn,
      num(-size * 1.6), num(-size * 0.8), num(-size * 1.6), num(size * 0.8), hollow or color, color)
  end
  local function pill(px, py, label, kind)
    local size = kind == 'calls' and 11.2 or 12.2
    local w = width(label, size) + (kind == 'calls' and 10 or 16)
    local fill, stroke, color, dash = c.pill, c.pill_border, c.foreground, ''
    if kind == 'later' or kind == 'again' then
      fill, stroke, color = c.later_lane, kind == 'again' and c.later or c.later_border, c.later_text
    elseif kind == 'not_yet' then
      fill, stroke, color, dash = c.later_lane, c.todo_border, c.todo_text, ' stroke-width="1.25" stroke-dasharray="5 3"'
    end
    pills[#pills + 1] = table.concat({'<rect x="', num(px - w / 2), '" y="', num(py - 9), '" width="', num(w),
      '" height="18" rx="9" fill="', fill, '" stroke="', stroke, '"', dash, '/>',
      '<text x="', num(px), '" y="', num(py + 4.2), '" text-anchor="middle" font-size="', num(size), '" fill="', color,
      '" ', sans(500), '>', escape(label), '</text>'})
    return w
  end
  local function path(points, color, stroke_width, dash)
    local d = {}
    for i = 1, #points, 2 do d[#d + 1] = (i == 1 and 'M' or 'L') .. num(points[i]) .. ' ' .. num(points[i + 1]) end
    add('<path d="', table.concat(d, ' '), '" fill="none" stroke="', color, '" stroke-width="', num(stroke_width),
      '" stroke-linejoin="round"', dash and (' stroke-dasharray="' .. dash .. '"') or '', '/>')
  end
  for _, edge in ipairs(edges) do
    local a, b = cards[edge.from], cards[edge.to]
    local pending, later = edge.kind == 'not_yet', edge.kind == 'later'
    local color = later and c.later or pending and c.todo_path or c.path
    local stroke_width, dash = later and 1.8 or 1.4, later and '7 4' or pending and '5 3' or nil
    local hollow = pending and c.background or nil
    -- A path stops a little short of the card the reader is on, so its
    -- colour never touches the blue.
    local stop = edge.to == here_at and 3 or 0
    local label = later and (flow.handoff or 'runs it later') or pending and 'not yet called' or 'calls'
    if a.lane == b.lane and a.row == b.row then
      local y = a.y + CARD_H / 2
      path({a.x + a.w, y, b.x - 8 - stop, y}, color, stroke_width, dash)
      head(b.x - stop, y, 0, color, hollow)
      pill((a.x + a.w + b.x) / 2 - 4, y, pending and 'not yet' or label, edge.kind)
    elseif a.lane == b.lane then
      local px = a.x + math.min(67, a.w / 2)
      path({px, a.y + CARD_H, px, b.y - 8 - stop}, color, stroke_width, dash)
      head(px, b.y - stop, 90, color, hollow)
      local w = width(label, pending and 12.2 or 11.2) + 16
      pill(px + 12 + w / 2, (a.y + CARD_H + b.y) / 2, label, edge.kind)
    else
      local ya, yb = a.y + CARD_H / 2, b.y + CARD_H / 2
      local lane_a, lane_b = lanes[1], lanes[1]
      for _, lane in ipairs(lanes) do
        if lane.lane == a.lane then lane_a = lane end
        if lane.lane == b.lane then lane_b = lane end
      end
      local mid = (lane_a.x + lane_a.w + lane_b.x) / 2
      if later then
        path({a.x + a.w, ya, mid, ya, mid, yb, b.x - 8 - stop, yb}, color, stroke_width, dash)
        pill(mid, ya == yb and ya or (ya + yb) / 2 + 12, label, 'later')
      else
        local turn = a.x + a.w + (lane_a.x + lane_a.w - a.x - a.w) / 2
        path({a.x + a.w, ya, turn, ya, turn, yb, b.x - 8 - stop, yb}, color, stroke_width, dash)
        pill(turn, ya, pending and 'not yet' or label, edge.kind)
      end
      head(b.x - stop, yb, 0, color, hollow)
    end
  end
  local here = here_at and cards[here_at]
  if here and here.step.again then
    -- The loop: this function asks to be run again.
    local right, top = here.x + here.w, LENS_TOP + 20
    local turn, back = right + 50, right - 34
    path({right + 3, here.y + CARD_H * 0.72, turn, here.y + CARD_H * 0.72, turn, top, back, top, back, here.y - 11},
      c.later, 1.6, '5 4')
    head(back, here.y - 3, 90, c.later)
    pill(right + 24, top, '↻ again · line ' .. here.step.again, 'again')
  end

  -- The cards.
  local ran = 0
  for _, card in ipairs(cards) do
    local step, cx, cy, w = card.step, card.x, card.y, card.w
    local is_here, pending = card.index == here_at, step.state == 'not_yet'
    local bar = is_here and 7 or 4
    local title_fill, sub_fill, weight = c.foreground, c.sub, 700
    if is_here then
      add('<rect x="', num(cx + 1), '" y="', num(cy + 1), '" width="', num(w - 2), '" height="', CARD_H - 2,
        '" rx="7" fill="', c.here_fill, '" stroke="', c.here_border, '" stroke-width="2"/>')
      add('<path d="M', num(cx + 7), ' ', num(cy), ' h', bar - 7 + 0.01, ' v', CARD_H, ' h', -(bar - 7 + 0.01),
        ' a7 7 0 0 1 -7 -7 v', -(CARD_H - 14), ' a7 7 0 0 1 7 -7 z" fill="', c.here, '"/>')
      add('<rect x="', num(cx + bar), '" y="', num(cy + 2), '" width="2" height="', CARD_H - 4, '" fill="', c.seam,
        '" fill-opacity="0.9"/>')
      sub_fill = c.here_sub
    elseif pending then
      add('<rect x="', num(cx + 0.75), '" y="', num(cy + 0.75), '" width="', num(w - 1.5), '" height="', CARD_H - 1.5,
        '" rx="7" fill="', c.background, '" fill-opacity="0.01" stroke="', c.todo_border,
        '" stroke-width="1.5" stroke-dasharray="5 3"/>')
      if step.lane == 3 then
        add('<path d="M', num(cx + w * 0.82), ' ', num(cy + 1.5), ' H', num(cx + w - 8), ' a6.5 6.5 0 0 1 6.5 6.5 V',
          num(cy + CARD_H / 2), ' H', num(cx + w * 0.82), ' z" fill="url(#hatch)"/>')
      end
      title_fill, sub_fill, weight, bar = c.todo_text, c.todo_text, 400, 0
    else
      ran = ran + 1
      add('<rect x="', num(cx + 0.5), '" y="', num(cy + 0.5), '" width="', num(w - 1), '" height="', CARD_H - 1,
        '" rx="7" fill="', c.ran_fill, '" stroke="', c.ran_border, '"/>')
      add('<path d="M', num(cx + 7), ' ', num(cy + CARD_H - 0.5), ' H', num(cx + w - 7), '" stroke="', c.ran_edge, '"/>')
      add('<path d="M', num(cx + 4), ' ', num(cy), ' v', CARD_H, ' a7 7 0 0 1 -4 -6 v', -(CARD_H - 12),
        ' a7 7 0 0 1 4 -6 z" fill="', c.ran_bar, '"/>')
    end
    -- The number: the order the steps run in.
    local nx, ny = cx + bar + 9, cy + (CARD_H - 25) / 2
    local number = step.lane == 3 and '$' or tostring(card.index)
    if is_here then
      add('<rect x="', num(nx), '" y="', num(ny), '" width="25" height="25" rx="6" fill="', c.here, '"/>')
      text(nx + 12.5, ny + 17, number, 12.8, c.background, code(700) .. ' text-anchor="middle"')
    elseif pending then
      add('<rect x="', num(nx + 0.5), '" y="', num(ny + 0.5), '" width="24" height="24" rx="6" fill="none" stroke="',
        c.todo_chip, '"/>')
      text(nx + 12.5, ny + 17, number, 12.8, c.outside_label, code(400) .. ' text-anchor="middle"')
    else
      add('<rect x="', num(nx), '" y="', num(ny), '" width="25" height="25" rx="6" fill="',
        c.chips[math.min(ran, #c.chips)], '"/>')
      text(nx + 12.5, ny + 17, number, 12.8, c.foreground, code(400) .. ' text-anchor="middle"')
    end
    local tx2 = nx + 25 + 8
    text(tx2, cy + 20.5, step.name, 14.6, title_fill, code(weight))
    if step.says then
      text(tx2, cy + 37.5, step.says .. (step.file and ' · ' or ''), 12.6, sub_fill, sans(400))
    end
    if step.file then
      local fx = tx2 + (step.says and width(step.says .. ' · ', 12.6) or 0)
      text(fx, cy + 37.5, step.file, 11, sub_fill, code(400))
    end
    if step.changed then
      local cw = width('~ changed', 11.5) + 16
      local chx = cx + w - cw - 12
      add('<rect x="', num(chx), '" y="', num(cy + CARD_H / 2 - 9.5), '" width="', num(cw),
        '" height="19" rx="9.5" fill="', c.background, '" fill-opacity="0.4" stroke="', c.changed_border, '"/>')
      text(chx + cw / 2, cy + CARD_H / 2 + 4, '~ changed', 11.5, c.foreground, sans(500) .. ' text-anchor="middle"')
    end
    if is_here then
      local badge = 'YOU ARE HERE · LINE ' .. (step.line or opts.line or '?')
      local bw = width(badge, 10.8) * 1.1 + 22
      add('<rect x="', num(cx + 22), '" y="', num(cy - 13), '" width="', num(bw), '" height="19" rx="9.5" fill="',
        c.here, '" stroke="', c.later_lane, '" stroke-width="3" paint-order="stroke"/>')
      text(cx + 22 + bw / 2, cy + 0.5, badge, 10.8, c.background,
        sans(700, 'letter-spacing="0.75" text-anchor="middle"'))
    end
  end
  for _, item in ipairs(pills) do add(item) end
  for _, item in ipairs(heads) do add(item) end

  -- The keys.
  if opts.hints then
    local hy = LENS_TOP + LENS_H + 8
    add('<rect y="', hy, '" width="', num(canvas), '" height="1" fill="', c.border, '"/>')
    local hx = SIDE
    for _, hint in ipairs(opts.hints) do
      text(hx, hy + 17.5, hint[1], 13, hint[2] and c.foreground or c.dim, code(hint[2] and 700 or 400)
        .. ' xml:space="preserve"')
      hx = hx + width(hint[1], 13, true)
    end
  end
  add('</svg>')
  return table.concat(out), total * scale
end

return M
