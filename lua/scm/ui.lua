-- scm.ui — small pieces several of SCM's windows share: colours mixed as a
-- translucent layer would, floating windows, rows of highlighted pieces,
-- and text wrapped or cut to a number of cells.
local M = {}

local function cells(text) return vim.fn.strdisplaywidth(text) end
M.cells = cells

-- Mix `alpha` of colour `top` over `bottom`, as a translucent layer would.
function M.mix(top, bottom, alpha)
  local out = 0
  for shift = 16, 0, -8 do
    local t, b = bit.band(bit.rshift(top, shift), 255), bit.band(bit.rshift(bottom, shift), 255)
    out = out + bit.lshift(math.floor(t * alpha + b * (1 - alpha) + 0.5), shift)
  end
  return out
end

-- The colour `key` ("fg" or "bg") of highlight group `name`, or `fallback`.
function M.color(name, key, fallback)
  return vim.api.nvim_get_hl(0, {name=name, link=false})[key] or fallback
end

-- Text shown in a statusline or winbar, where % starts an item.
function M.escape(text) return (text:gsub('%%', '%%%%')) end

-- `text` cut to at most `width` cells, ending in "…" when anything was cut.
function M.truncate(text, width)
  if cells(text) <= width then return text end
  if width <= 0 then return '' end
  local out = vim.fn.strcharpart(text, 0, width - 1)
  while out ~= '' and cells(out) > width - 1 do out = vim.fn.strcharpart(out, 0, vim.fn.strchars(out) - 1) end
  return out .. '…'
end

-- Break rows of {text, highlight} pieces into rows no wider than `width`
-- cells, at spaces. The first row may be given less room (`opts.first`);
-- later rows start with `opts.indent` spaces. A word wider than a whole row
-- is broken where the row ends, so nothing is ever cut.
function M.wrap_pieces(pieces, width, opts)
  opts = opts or {}
  width = math.max(1, width)
  local indent = math.min(opts.indent or 0, width - 1)
  local rows, row, used = {}, {}, 0
  local function limit() return math.max(1, #rows == 0 and (opts.first or width) or width) end
  local function next_row(highlight)
    rows[#rows + 1] = row
    row, used = {}, 0
    if indent > 0 then row[1], used = {(' '):rep(indent), highlight}, indent end
  end
  for _, piece in ipairs(pieces) do
    for space, word in piece[1]:gmatch('(%s*)(%S*)') do
      if space ~= '' or word ~= '' then
        local token = space .. word
        -- A later row does not start with the space that stood between two words.
        if #rows > 0 and used == indent then token = word end
        if used > indent and used + cells(token) > limit() then
          next_row(piece[2])
          token = word
        end
        while cells(token) > limit() - used and limit() - used >= 1 do
          local part = vim.fn.strcharpart(token, 0, limit() - used)
          while part ~= '' and cells(part) > limit() - used do
            part = vim.fn.strcharpart(part, 0, vim.fn.strchars(part) - 1)
          end
          -- Not even one character fits what is left of this row.
          if part == '' then
            if used == indent then break end
            next_row(piece[2])
          else
            row[#row + 1] = {part, piece[2]}
            used = used + cells(part)
            token = vim.fn.strcharpart(token, vim.fn.strchars(part))
            next_row(piece[2])
          end
        end
        if token ~= '' then
          row[#row + 1] = {token, piece[2]}
          used = used + cells(token)
        end
      end
    end
  end
  if used > indent then rows[#rows + 1] = row end
  return rows
end

-- Break `text` into lines no wider than `width`, at spaces.
function M.wrap(text, width)
  local lines = {}
  for _, row in ipairs(M.wrap_pieces({{vim.trim((text:gsub('%s+', ' ')))}}, width)) do
    local line = ''
    for _, piece in ipairs(row) do line = line .. piece[1] end
    lines[#lines + 1] = line
  end
  return lines
end

-- Put rows of {text, highlight} pieces in `buf` and highlight them in
-- namespace `ns`. A row's `line_hl` highlights the whole row.
function M.write(buf, ns, rows)
  local lines, marks = {}, {}
  for i, pieces in ipairs(rows) do
    local text = ''
    for _, piece in ipairs(pieces) do
      if piece[1] ~= '' then
        if piece[2] then marks[#marks + 1] = {i - 1, #text, #text + #piece[1], piece[2]} end
        text = text .. piece[1]
      end
    end
    if pieces.line_hl then marks[#marks + 1] = {i - 1, 0, 0, pieces.line_hl, true} end
    lines[i] = text
  end
  local modifiable = vim.bo[buf].modifiable
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = modifiable
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    if mark[5] then
      vim.api.nvim_buf_set_extmark(buf, ns, mark[1], 0, {line_hl_group=mark[4]})
    else
      vim.api.nvim_buf_set_extmark(buf, ns, mark[1], mark[2], {end_col=mark[3], hl_group=mark[4]})
    end
  end
  return lines
end

-- Close floating window `win`. A window cannot always be closed from inside
-- an autocommand, so it is tried again once the editor is free.
function M.close(win)
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  if not pcall(vim.api.nvim_win_close, win, true) then
    vim.schedule(function() pcall(vim.api.nvim_win_close, win, true) end)
  end
end

-- A float that cannot be focused, kept at `place` over another window.
-- `float` is the one from last time, or nil: it is moved only when its
-- place changed, and opened again when it was closed. Returns the float,
-- {win, buf, shape}, with `changed` set when it is new or was moved.
function M.anchored(float, place, highlight, extra)
  local shape = table.concat({place.row, place.col, place.width, place.height, place.anchor or ''}, ':')
  if float and float.win and vim.api.nvim_win_is_valid(float.win) then
    float.changed = float.shape ~= shape
    if float.changed then vim.api.nvim_win_set_config(float.win, place) end
    float.shape = shape
    return float
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local config = vim.tbl_extend('force', place, {focusable=false, style='minimal', noautocmd=true}, extra or {})
  float = vim.tbl_extend('force', float or {}, {win=vim.api.nvim_open_win(buf, false, config), buf=buf, shape=shape,
    changed=true})
  vim.wo[float.win].winhighlight = ('Normal:%s,NormalFloat:%s'):format(highlight, highlight)
    .. ((extra and extra.border) and (',FloatBorder:' .. highlight .. 'Border') or '')
  vim.wo[float.win].wrap = false
  return float
end

-- A window in the middle of the editor, focused, showing `buf`, that q and
-- Esc close. `opts`: title, width, height, row (centred when not given),
-- and `keys`, more keys that close it.
function M.centered(buf, opts)
  local height = math.max(1, math.min(opts.height, vim.o.lines - 6))
  local win = vim.api.nvim_open_win(buf, true, {relative='editor', width=opts.width, height=height,
    row=opts.row or math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col=math.max(0, math.floor((vim.o.columns - opts.width) / 2)),
    style='minimal', border='rounded', title=' ' .. opts.title .. ' ', title_pos='left'})
  vim.wo[win].winhighlight = 'Normal:ScmReviewFloat,FloatBorder:ScmReviewFloat,FloatTitle:ScmReviewFloatTitle'
  for _, key in ipairs(vim.list_extend({'q', '<Esc>'}, opts.keys or {})) do
    vim.keymap.set('n', key, function() pcall(vim.api.nvim_win_close, win, true) end, {buffer=buf, nowait=true})
  end
  return win
end

return M
