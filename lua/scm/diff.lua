-- scm.diff — one file's changes as an inline diff in an editor window: the
-- whole file, removed lines in red above the added lines in green, the parts
-- of a line that changed marked more strongly, the new file's line numbers in
-- the gutter, and a header naming the file and what it is compared against.
local M = {}
local ns = vim.api.nvim_create_namespace('scm.diff')
local text_diff = vim.text and vim.text.diff or vim.diff
local Review = require('scm.review')
local Ui = require('scm.ui')
local Process = require('scm.process')

-- What each Change Group compares, as the header names it.
local SOURCES = {changes='diff', staged='staged diff', committed='branch diff'}
-- A file past this size is not compared: a note is shown in its place.
local MAX_BYTES = 4 * 1024 * 1024
-- What reading a side gives in place of text that is past that size.
local TOO_LARGE = {}
-- A diff past this size is not coloured as code: parsing it would stall.
local MAX_SYNTAX_BYTES = 1024 * 1024
-- Lines longer than this, and files with more changed line pairs than this,
-- get no marks inside their lines.
local MAX_EMPHASIS_LINE, MAX_EMPHASIS_PAIRS = 1000, 2000
-- A pair of lines that share less than this much text is two different lines,
-- and marking nearly all of both says nothing.
local MAX_CHANGED = 0.7

local views = {}    -- buffer -> view
local by_name = {}  -- buffer name -> buffer
local pending = {}  -- window -> the newest request to show a diff in it
local rulers = {}   -- window -> the overview strip at its right edge
-- The overview strip is this many cells wide.
local RULER_WIDTH = 2

local function lines_of(text)
  if not text or text == '' then return {} end
  local lines = vim.split(text, '\n', {plain=true})
  if lines[#lines] == '' then lines[#lines] = nil end
  return lines
end

-- Merge the old and new lines into one list. Returns the lines, what each is
-- ({kind = ' ', '+' or '-', new = its number in the new file, old = its
-- number in the old one}), and the first row of every run of changed lines.
function M.merge(old, new)
  local lines, meta, hunks = {}, {}, {}
  local added, removed = 0, 0
  local function put(text, kind, number, old_number)
    lines[#lines + 1] = text
    meta[#meta + 1] = {kind=kind, new=number, old=old_number}
  end
  local a, b = 1, 1
  local changes = {}
  if #old > 0 and #new > 0 then
    changes = text_diff(table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n',
      {result_type='indices', algorithm='histogram'})
  elseif #old > 0 then changes = {{1, #old, 0, 0}}
  elseif #new > 0 then changes = {{0, 0, 1, #new}} end
  for _, change in ipairs(changes) do
    local start_a, count_a, _, count_b = unpack(change)
    -- A change that removes nothing names the old line it follows.
    local first = count_a > 0 and start_a or start_a + 1
    while a < first do
      put(new[b], ' ', b, a)
      a, b = a + 1, b + 1
    end
    hunks[#hunks + 1] = {row=#lines + 1, removed=count_a, added=count_b}
    for _ = 1, count_a do
      put(old[a], '-', nil, a)
      a = a + 1
    end
    for _ = 1, count_b do
      put(new[b], '+', b)
      b = b + 1
    end
    added, removed = added + count_b, removed + count_a
  end
  while b <= #new do
    put(new[b], ' ', b)
    b = b + 1
  end
  return lines, meta, hunks, {added=added, removed=removed}
end

-- Split a line into words, runs of blanks, and single other characters.
local function tokens(text)
  local list, starts = {}, {}
  local i = 1
  while i <= #text do
    local stop = text:match('^[%w_\128-\255]+()', i) or text:match('^%s+()', i) or i + 1
    list[#list + 1] = text:sub(i, stop - 1)
    starts[#starts + 1] = i - 1
    i = stop
  end
  return list, starts
end

-- The byte ranges that differ between an old line and the line that replaced
-- it: {{from, to}...} for each, or nil when the two are too unlike to compare.
function M.emphasis(old, new)
  if #old > MAX_EMPHASIS_LINE or #new > MAX_EMPHASIS_LINE or old == '' or new == '' then return end
  local old_tokens, old_starts = tokens(old)
  local new_tokens, new_starts = tokens(new)
  local changes = text_diff(table.concat(old_tokens, '\n') .. '\n', table.concat(new_tokens, '\n') .. '\n',
    {result_type='indices'})
  local function ranges(list, starts, at, count)
    local out, bytes = {}, 0
    for _, change in ipairs(changes) do
      local start, n = change[at], change[count]
      if n > 0 then
        local from = starts[start]
        local to = starts[start + n - 1] + #list[start + n - 1]
        local last = out[#out]
        if last and last[2] == from then last[2] = to else out[#out + 1] = {from, to} end
        bytes = bytes + to - from
      end
    end
    return out, bytes
  end
  local old_ranges, old_bytes = ranges(old_tokens, old_starts, 1, 2)
  local new_ranges, new_bytes = ranges(new_tokens, new_starts, 3, 4)
  if old_bytes / #old > MAX_CHANGED and new_bytes / #new > MAX_CHANGED then return end
  return old_ranges, new_ranges
end

-- VS Code's diff colours are translucent layers over the editor background;
-- a terminal cell has one colour, so each is mixed here.
function M.highlights()
  local mix, color = Ui.mix, Ui.color
  local dark = vim.o.background == 'dark'
  local strong = mix(color('Normal', 'fg', dark and 0xacb2be or 0x333333), color('Normal', 'bg', dark and 0x1e1e1e or 0xffffff), 0.97)
  local background = color('Normal', 'bg', dark and 0x1e1e1e or 0xffffff)
  local number = color('LineNr', 'fg', dark and 0x858585 or 0x237893)
  local add_line, delete_line = mix(0x9bb955, background, 0.2), mix(0xff0000, background, 0.2)
  for name, value in pairs({
    ScmDiffAdd={bg=add_line}, ScmDiffDelete={bg=delete_line},
    ScmDiffAddText={bg=mix(0x9ccc2c, add_line, 0.16)}, ScmDiffDeleteText={bg=mix(0xff0000, delete_line, 0.22)},
    ScmDiffAddNr={fg=number, bg=add_line}, ScmDiffDeleteNr={fg=number, bg=delete_line},
    ScmDiffAddSign={fg=dark and 0x81b88b or 0x2f7d32, bg=add_line},
    ScmDiffDeleteSign={fg=dark and 0xc74e39 or 0xb3261e, bg=delete_line},
    -- Bold carries weight, not brightness: nothing in the header is brighter than a shade under the text.
    ScmDiffHeader={fg=strong, bg=background},
    ScmDiffSource={fg=color('Comment', 'fg', number), bg=background},
    ScmDiffButton={fg=strong, bg=background, bold=true},
    ScmDiffRuler={bg=background},
    ScmDiffRulerView={bg=mix(color('Normal', 'fg', dark and 0xcccccc or 0x333333), background, 0.14)},
    ScmDiffRulerAdd={bg=mix(0x9bb955, background, 0.6)}, ScmDiffRulerDelete={bg=mix(0xff0000, background, 0.6)},
  }) do
    value.default = true
    vim.api.nvim_set_hl(0, name, value)
  end
end

-- The gutter of one line: the new file's line number and a + beside an added
-- line; a removed line has no number, only a -.
function M.gutter()
  -- While a window's gutter or header is drawn, that window is the current one.
  local view = views[vim.api.nvim_get_current_buf()]
  if not view then return '' end
  local width = view.width
  local line = view.meta[vim.v.lnum]
  -- A diff with a Tour marks the lines of the step the reader is on.
  local tour = Review.has_gutter(view)
  if not line or vim.v.virtnum ~= 0 then return (' '):rep(width + 3 + (tour and 1 or 0)) end
  local mark = tour and Review.gutter(view, vim.v.lnum, vim.fn.line('.')) or ''
  local number = line.new and ('%' .. width .. 'd'):format(line.new) or (' '):rep(width)
  if line.kind == '+' then return mark .. '%#ScmDiffAddNr# ' .. number .. '%#ScmDiffAddSign#+ ' end
  if line.kind == '-' then return mark .. '%#ScmDiffDeleteNr# ' .. number .. '%#ScmDiffDeleteSign#- ' end
  return mark .. '%#LineNr# ' .. number .. '  '
end

-- The header above the diff: the file, what it is compared against, how many
-- lines were added and removed, and buttons for the previous and next change
-- and for opening the file itself.
function M.header()
  -- While a window's gutter or header is drawn, that window is the current one.
  local view = views[vim.api.nvim_get_current_buf()]
  if not view then return '' end
  local escape = Ui.escape
  local counts = ''
  if view.stats and view.stats.added + view.stats.removed > 0 then
    counts = '%#ScmDiffAddSign# +' .. view.stats.added .. ' %#ScmDiffDeleteSign# -' .. view.stats.removed .. ' '
  end
  -- Which change the cursor is in or has just passed.
  if #view.hunks > 0 then
    local row, at = vim.fn.line('.'), 1
    for i, hunk in ipairs(view.hunks) do
      if hunk.row <= row then at = i end
    end
    counts = counts .. '%#ScmDiffSource# change ' .. at .. '/' .. #view.hunks .. ' '
  end
  local function button(id, label)
    return '%' .. id .. '@v:lua.ScmDiffClick@%#ScmDiffButton# ' .. label .. ' %X'
  end
  return '%#ScmDiffHeader# %<' .. escape(vim.fn.fnamemodify(view.spec.file, ':~'))
    .. '%#ScmDiffSource# (' .. view.source .. ')%=' .. counts
    .. '%#ScmDiffHeader# ' .. button(1, '↑') .. button(2, '↓') .. button(3, 'Open File') .. '%#ScmDiffHeader# '
end

local WINDOW = {
  number=false, relativenumber=false, signcolumn='no', foldcolumn='0', wrap=false, cursorline=false, spell=false,
  statuscolumn="%{%v:lua.require'scm.diff'.gutter()%}", winbar="%{%v:lua.require'scm.diff'.header()%}",
}

-- Give the window showing a diff the diff's options. They are set for that
-- buffer in that window only, so the next buffer shown there has the
-- window's own again.
local function sync(win)
  if not (vim.api.nvim_win_is_valid(win) and views[vim.api.nvim_win_get_buf(win)]) then return end
  for name, value in pairs(WINDOW) do
    vim.api.nvim_set_option_value(name, value, {win=win, scope='local'})
  end
end

-- What each row of an overview strip `height` rows tall shows of a diff:
-- {added, removed, visible} for the lines that row stands for. A diff
-- shorter than the strip is drawn line for line; a longer one is scaled.
-- `cache`, when given, keeps the marks between calls: only what is visible
-- changes as a window scrolls.
function M.overview(meta, height, top, bottom, cache)
  local total = math.max(#meta, height)
  local marks = cache and cache.height == height and cache.marks
  if not marks then
    marks = {}
    for row = 1, height do
      local first = math.floor((row - 1) * total / height) + 1
      local last = math.max(first, math.floor(row * total / height))
      local mark = {first=first, last=last}
      for i = first, math.min(last, #meta) do
        if meta[i].kind == '+' then mark.added = true elseif meta[i].kind == '-' then mark.removed = true end
      end
      marks[row] = mark
    end
    if cache then cache.height, cache.marks = height, marks end
  end
  local rows = {}
  for row, mark in ipairs(marks) do
    rows[row] = {added=mark.added, removed=mark.removed,
      visible=mark.first <= bottom and mark.last >= top and mark.first <= #meta}
  end
  return rows
end

local function close_ruler(win)
  local ruler = rulers[win]
  rulers[win] = nil
  if ruler then Ui.close(ruler.win) end
end

-- Draw the overview strip of the diff in `win`: where in the file lines were
-- added (green) and removed (red), and which part the window shows.
local function draw_ruler(win, view)
  local info = vim.fn.getwininfo(win)[1]
  local height, width = info.height, info.width
  if height < 1 or width <= RULER_WIDTH + view.width + 4 then close_ruler(win); return end
  local ruler = Ui.anchored(rulers[win], {relative='win', win=win, anchor='NE', row=info.winbar, col=width,
    width=RULER_WIDTH, height=height}, 'ScmDiffRuler', {zindex=20})
  rulers[win] = ruler
  local top, bottom
  vim.api.nvim_win_call(win, function() top, bottom = vim.fn.line('w0'), vim.fn.line('w$') end)
  if ruler.changed then
    local blank = (' '):rep(RULER_WIDTH)
    local lines = {}
    for row = 1, height do lines[row] = blank end
    vim.api.nvim_buf_set_lines(ruler.buf, 0, -1, false, lines)
    ruler.drawn = nil
  end
  -- Scrolling within the same rows of the strip changes nothing in it.
  local drawn = table.concat({ruler.shape, top, bottom, view.revision}, ':')
  if ruler.drawn == drawn then return end
  ruler.drawn = drawn
  local cells = M.overview(view.meta, height, top, bottom, view.overview)
  vim.api.nvim_buf_clear_namespace(ruler.buf, ns, 0, -1)
  local function paint(row, from, to, group)
    vim.api.nvim_buf_set_extmark(ruler.buf, ns, row - 1, from, {end_col=to, hl_group=group})
  end
  for row, cell in ipairs(cells) do
    if cell.visible then paint(row, 0, RULER_WIDTH, 'ScmDiffRulerView') end
    -- A row standing for both kinds shows red beside green.
    local half = cell.added and cell.removed and RULER_WIDTH / 2
    if cell.removed then paint(row, 0, half or RULER_WIDTH, 'ScmDiffRulerDelete') end
    if cell.added then paint(row, half or 0, RULER_WIDTH, 'ScmDiffRulerAdd') end
  end
end

-- Give every window showing a diff its overview strip, and take away the
-- strip of a window that no longer shows one.
local function rulers_sync()
  for win in pairs(rulers) do
    if not (vim.api.nvim_win_is_valid(win) and views[vim.api.nvim_win_get_buf(win)]) then close_ruler(win) end
  end
  for buf, view in pairs(views) do
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      if vim.api.nvim_win_get_config(win).relative == '' then draw_ruler(win, view) end
    end
  end
end

-- Read one side of a comparison: {git = "<rev>:<path>"}, {file = <path>}, or
-- {} for a side that does not exist. cb(text): nil when there is none, and
-- TOO_LARGE, without reading the rest, when it is past MAX_BYTES.
local function read(repo, side, cb)
  if side.git then
    local started = Process.run({'git', '-C', repo, 'show', side.git}, {text=false, env=require('scm.core').git_env,
      max_bytes=MAX_BYTES}, function(out)
        if out.too_large then cb(TOO_LARGE)
        else cb(out.code == 0 and out.stdout or nil) end
      end)
    if not started then vim.schedule(function() cb(nil) end) end
    return
  end
  local text
  -- Only a regular file is read: a link is never followed out of the
  -- repository, and a pipe or device would never finish.
  local stat = side.file and vim.uv.fs_lstat(side.file)
  if stat and stat.type == 'link' then
    -- git keeps a link as the path it points to.
    text = vim.uv.fs_readlink(side.file)
  elseif stat and stat.type == 'file' and stat.size > MAX_BYTES then
    text = TOO_LARGE
  elseif stat and stat.type == 'file' then
    local handle = io.open(side.file, 'rb')
    if handle then
      text = handle:read('*a')
      handle:close()
    end
  end
  cb(text)
end

-- The two sides a file's Change Group compares. A rename is compared with
-- the file under its old name. ":0:" names the staged file exactly: a path
-- such as "1:x" after a bare ":" would be read as a conflict stage.
local function sides(spec)
  local before = spec.orig or spec.path
  if spec.group == 'staged' then return {git='HEAD:' .. before}, {git=':0:' .. spec.path} end
  if spec.group == 'committed' then
    return spec.base and {git=spec.base .. ':' .. before} or {}, {git='HEAD:' .. spec.path}
  end
  return spec.untracked and {} or {git=':0:' .. spec.path}, {file=spec.file}
end

-- Read both sides at once, then cb(old, new).
local function load(spec, cb)
  local before, after = sides(spec)
  local old, new, waiting = nil, nil, 2
  local function landed()
    waiting = waiting - 1
    if waiting == 0 then cb(old, new) end
  end
  read(spec.repo, before, function(text) old = text; landed() end)
  read(spec.repo, after, function(text) new = text; landed() end)
end

-- Colour the code as its file type, without running that type's plugins or
-- language servers on a buffer that is not the file.
local function colorize(buf, path)
  local ok, filetype = pcall(vim.filetype.match, {filename=path})
  if not ok or not filetype then return end
  local lang = vim.treesitter.language.get_lang(filetype)
  if not (lang and pcall(vim.treesitter.start, buf, lang)) then vim.bo[buf].syntax = filetype end
end

-- Fill a view's buffer from the two texts. False when nothing changed since
-- it was last filled.
local function fill(view, old, new)
  if view.filled and view.old == old and view.new == new then return false end
  view.filled, view.old, view.new = true, old, new
  view.revision, view.overview = (view.revision or 0) + 1, {}
  local lines, meta, hunks, stats
  local large = old == TOO_LARGE or new == TOO_LARGE
  local size = large and 0 or #(old or '') + #(new or '')
  if large or size > MAX_BYTES then
    lines = {'This file is too large to compare here.'}
  elseif (old or ''):sub(1, 8000):find('\0', 1, true) or (new or ''):sub(1, 8000):find('\0', 1, true) then
    lines = {'This is a binary file, so there is no text to compare.'}
  else
    lines, meta, hunks, stats = M.merge(lines_of(old), lines_of(new))
  end
  view.meta, view.hunks, view.stats = meta or {}, hunks or {}, stats
  local last = 0
  for _, line in ipairs(view.meta) do last = math.max(last, line.new or 0) end
  view.width = math.max(2, #tostring(last))
  local buf = view.buf
  if not view.colored and meta and size <= MAX_SYNTAX_BYTES then
    view.colored = true
    colorize(buf, view.spec.path)
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for row, line in ipairs(view.meta) do
    if line.kind ~= ' ' then
      -- A highlight that runs past the end of the line colours it to the
      -- window's edge, and lets a mark inside the line show over it.
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {end_row=row, end_col=0, strict=false, hl_eol=true,
        hl_group=line.kind == '+' and 'ScmDiffAdd' or 'ScmDiffDelete', priority=150})
    end
  end
  local pairs_left = MAX_EMPHASIS_PAIRS
  local function mark(row, ranges, group)
    for _, range in ipairs(ranges) do
      vim.api.nvim_buf_set_extmark(buf, ns, row - 1, range[1], {end_col=range[2], hl_group=group, priority=200})
    end
  end
  for _, hunk in ipairs(view.hunks) do
    -- The first removed line is compared with the first added line, and so on.
    for i = 0, math.min(hunk.removed, hunk.added) - 1 do
      if pairs_left <= 0 then break end
      pairs_left = pairs_left - 1
      local removed_row, added_row = hunk.row + i, hunk.row + hunk.removed + i
      local old_ranges, new_ranges = M.emphasis(lines[removed_row], lines[added_row])
      if old_ranges then
        mark(removed_row, old_ranges, 'ScmDiffDeleteText')
        mark(added_row, new_ranges, 'ScmDiffAddText')
      end
    end
  end
  return true
end

local function view_in(win)
  return win and vim.api.nvim_win_is_valid(win) and views[vim.api.nvim_win_get_buf(win)]
end

-- Move to the next (direction 1) or previous (-1) change, wrapping around.
function M.jump(direction, win)
  win = win or vim.api.nvim_get_current_win()
  local view = view_in(win)
  if not view or #view.hunks == 0 then return false end
  local row = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if direction > 0 then
    for _, hunk in ipairs(view.hunks) do
      if hunk.row > row then target = hunk.row; break end
    end
    target = target or view.hunks[1].row
  else
    for i = #view.hunks, 1, -1 do
      if view.hunks[i].row < row then target = view.hunks[i].row; break end
    end
    target = target or view.hunks[#view.hunks].row
  end
  vim.api.nvim_win_set_cursor(win, {target, 0})
  vim.api.nvim_win_call(win, function() vim.cmd('normal! zz') end)
  return true
end

-- Open the file itself over its diff, at the line the cursor is on.
function M.open_file(win)
  win = win or vim.api.nvim_get_current_win()
  local view = view_in(win)
  if not view then return false end
  if vim.fn.filereadable(view.spec.file) ~= 1 then
    vim.notify('SCM: this file is deleted, so there is no file to open', vim.log.levels.INFO)
    return false
  end
  local row, target = vim.api.nvim_win_get_cursor(win)[1], 1
  -- A removed line is not in the file: go to the line that follows it.
  for i = row, #view.meta do
    if view.meta[i].new then target = view.meta[i].new; break end
  end
  vim.api.nvim_set_current_win(win)
  vim.cmd.edit(vim.fn.fnameescape(view.spec.file))
  pcall(vim.api.nvim_win_set_cursor, win, {target, 0})
  return true
end

-- A click on a header button: 1 previous change, 2 next change, 3 open file.
function _G.ScmDiffClick(id)
  local win = vim.fn.getmousepos().winid
  if not view_in(win) then win = vim.api.nvim_get_current_win() end
  if id == 1 then M.jump(-1, win) elseif id == 2 then M.jump(1, win) elseif id == 3 then M.open_file(win) end
end

local function create(spec, name)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = 'nofile', 'wipe', false
  -- A buffer left over from an earlier load of this module may hold the name.
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.b[buf].scm_diff = true
  local view = {buf=buf, spec=spec, source=SOURCES[spec.group] or 'diff', meta={}, hunks={}, width=2}
  views[buf], by_name[name] = view, buf
  for key, run in pairs({
    [']c']=function() M.jump(1) end, ['[c']=function() M.jump(-1) end,
    ['<CR>']=function() M.open_file() end, ['gf']=function() M.open_file() end,
  }) do
    vim.keymap.set('n', key, run, {buffer=buf, nowait=true})
  end
  Review.keys(buf)
  vim.api.nvim_create_autocmd('BufWipeout', {buffer=buf, once=true, callback=function()
    views[buf], by_name[name] = nil, nil
    Review.detach(view)
  end})
  return view
end

-- Show the diff of one file in the current window. `spec` names it:
--   repo, path  the repository and the file's path inside it
--   file        the file's full path
--   group       its Change Group: "changes", "staged" or "committed"
--   orig        the name it was renamed from, if it was
--   base        the commit a "committed" file is compared against
--   untracked   true for a file git does not know
-- done(buf), when given, runs once the diff is on screen.
function M.open(spec, done)
  local win = vim.api.nvim_get_current_win()
  local request = {}
  pending[win] = request
  load(spec, function(old, new)
    -- A newer request for this window wins.
    if pending[win] ~= request then return end
    pending[win] = nil
    if not vim.api.nvim_win_is_valid(win) then return end
    local source = SOURCES[spec.group] or 'diff'
    local name = ('scm://%s (%s)'):format(spec.file, source)
    local known = by_name[name] and views[by_name[name]]
    local view = known or create(spec, name)
    view.spec = spec
    -- A result that an older reload is still waiting for is now out of date.
    view.request = nil
    local fresh = fill(view, old, new)
    -- The window may hold unsaved text that cannot be put aside.
    local ok, err = pcall(vim.api.nvim_win_set_buf, win, view.buf)
    if not ok then
      if not known then pcall(vim.api.nvim_buf_delete, view.buf, {force=true}) end
      vim.notify('SCM: ' .. tostring(err):gsub('^.-:%s*', ''), vim.log.levels.WARN)
      return
    end
    sync(win)
    if fresh then
      -- Start at the first change, as a review does.
      local first = view.hunks[1]
      vim.api.nvim_win_set_cursor(win, {first and first.row or 1, 0})
      vim.api.nvim_win_call(win, function() vim.cmd('normal! zz') end)
    end
    rulers_sync()
    Review.attach(view)
    if done then done(view.buf) end
  end)
end

-- Compare every diff on screen again, after something may have changed it.
function M.reload()
  for _, view in pairs(views) do
    -- Only the newest answer is used: an older one may arrive after it.
    local request = {}
    view.request = request
    load(view.spec, function(old, new)
      if view.request ~= request then return end
      view.request = nil
      if views[view.buf] ~= view or not vim.api.nvim_buf_is_valid(view.buf) then return end
      local wins = vim.fn.win_findbuf(view.buf)
      local places = {}
      for _, win in ipairs(wins) do places[win] = vim.api.nvim_win_call(win, vim.fn.winsaveview) end
      if not fill(view, old, new) then return end
      for win, place in pairs(places) do
        vim.api.nvim_win_call(win, function() vim.fn.winrestview(place) end)
      end
      rulers_sync()
      Review.attach(view)
    end)
  end
end

-- The overview strip of the diff in `win`: its window, or nil.
function M.ruler(win)
  return rulers[win] and rulers[win].win
end

-- True when `buf` is a diff.
function M.is_diff(buf)
  return views[buf] ~= nil
end

-- `opts` are SCM's options; `opts.review` sets up the Review of a diff.
function M.setup(opts)
  M.highlights()
  Review.setup((opts or {}).review, function(buf) return views[buf] end)
  local group = vim.api.nvim_create_augroup('ScmDiff', {clear=true})
  vim.api.nvim_create_autocmd('ColorScheme', {group=group, callback=M.highlights})
  vim.api.nvim_create_autocmd({'BufWinEnter', 'BufEnter'}, {group=group, callback=function()
    sync(vim.api.nvim_get_current_win())
    rulers_sync()
  end})
  vim.api.nvim_create_autocmd({'WinScrolled', 'WinResized', 'VimResized'}, {group=group, callback=rulers_sync})
  vim.api.nvim_create_autocmd('WinClosed', {group=group, callback=function(ev)
    pending[tonumber(ev.match)] = nil
    -- A window cannot be closed while another is closing.
    vim.schedule(rulers_sync)
  end})
end

return M
