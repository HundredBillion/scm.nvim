-- Selecting a file shows its changes as one inline diff: the whole file, the
-- removed lines above the added ones, the new file's line numbers.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local diff = require('scm.diff')
local ns = vim.api.nvim_get_namespaces()['scm.diff']
-- The windows that hold text: a diff's overview strip floats over its window.
local function windows()
  return #vim.tbl_filter(function(win) return vim.api.nvim_win_get_config(win).relative == '' end,
    vim.api.nvim_tabpage_list_wins(0))
end

-- Merging two versions of a file.
local lines, meta, hunks, stats = diff.merge({'a', 'b', 'c', 'd'}, {'a', 'B', 'c', 'd', 'e'})
assert(vim.deep_equal(lines, {'a', 'b', 'B', 'c', 'd', 'e'}), 'a removed line comes before the line that replaced it')
local kinds, numbers = {}, {}
for i, line in ipairs(meta) do kinds[i], numbers[i] = line.kind, line.new or 0 end
assert(table.concat(kinds) == ' -+  +', 'each line says what it is, got ' .. table.concat(kinds))
assert(vim.deep_equal(numbers, {1, 0, 2, 3, 4, 5}), 'lines carry the new file\'s numbers; a removed line has none')
assert(#hunks == 2 and hunks[1].row == 2 and hunks[2].row == 6, 'each run of changes is found')
assert(stats.added == 2 and stats.removed == 1, 'added and removed lines are counted')
lines, meta, hunks = diff.merge({}, {'x', 'y'})
assert(#lines == 2 and meta[1].kind == '+' and meta[2].new == 2 and #hunks == 1, 'a new file is all added')
lines, meta = diff.merge({'x', 'y'}, {})
assert(#lines == 2 and meta[1].kind == '-' and not meta[2].new, 'a deleted file is all removed')
lines, meta, hunks = diff.merge({'x'}, {'x'})
assert(#lines == 1 and #hunks == 0, 'an unchanged file has no changes')
lines, meta = diff.merge({'x', 'y', 'z'}, {'y', 'z'})
assert(vim.deep_equal(lines, {'x', 'y', 'z'}) and meta[1].kind == '-' and meta[2].new == 1, 'a line removed from the top')
lines, meta = diff.merge({'x', 'z'}, {'x', 'y', 'z'})
assert(vim.deep_equal(lines, {'x', 'y', 'z'}) and meta[2].kind == '+' and meta[3].new == 3, 'a line added in the middle')

-- The changed part of a line.
local old_ranges, new_ranges = diff.emphasis('# worth a copy.', '# worth a copy. A stacked PR.')
assert(#old_ranges == 0, 'nothing is marked in a line that was only added to')
assert(#new_ranges == 1 and new_ranges[1][1] == 15 and new_ranges[1][2] == 29, 'the added words are marked')
old_ranges, new_ranges = diff.emphasis('local count = 1', 'local total = 1')
assert(vim.deep_equal(old_ranges, {{6, 11}}) and vim.deep_equal(new_ranges, {{6, 11}}), 'a changed word is marked on both lines')
assert(diff.emphasis('alpha beta', 'gamma delta') == nil, 'two unlike lines are not marked word by word')

-- A repository with one file in every state.
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
root = vim.uv.fs_realpath(root)
local function git(...)
  local out = vim.system({'git', '-C', root, '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', ...}):wait()
  assert(out.code == 0, out.stderr)
end
local function write(name, text) vim.fn.writefile(text, root .. '/' .. name) end
git('init', '-q', '-b', 'main')
write('edit.lua', {'local a = 1', 'local b = 2', 'local c = 3', 'return a'})
write('gone.lua', {'gone 1', 'gone 2'})
write('moved.lua', {'one', 'two', 'three', 'four', 'five'})
write('blob.bin', {'x'})
git('add', '-A')
git('commit', '-q', '-m', 'base')
git('checkout', '-q', '-b', 'work')
write('branch.lua', {'on the branch'})
git('mv', 'moved.lua', 'renamed.lua')
write('renamed.lua', {'one', 'two', 'THREE', 'four', 'five'})
git('add', '-A')
git('commit', '-q', '-m', 'work')
local base = vim.trim(vim.system({'git', '-C', root, 'rev-parse', 'main'}):wait().stdout)
write('edit.lua', {'local a = 1', 'local b = 20', 'local c = 3', 'return a'})
git('add', 'edit.lua')
write('edit.lua', {'local a = 1', 'local b = 20', 'local c = 3', 'local d = 4', 'return a'})
vim.fn.delete(root .. '/gone.lua')
write('new.lua', {'brand new'})
local handle = io.open(root .. '/blob.bin', 'wb')
handle:write('a\0b')
handle:close()

diff.setup()
vim.o.number, vim.o.signcolumn = true, 'yes'
local window = vim.api.nvim_get_current_win()
local function show(spec)
  spec.repo, spec.file = root, root .. '/' .. spec.path
  local shown
  diff.open(spec, function(buf) shown = buf end)
  assert(vim.wait(5000, function() return shown end, 10), 'the diff of ' .. spec.path .. ' appears')
  return shown, vim.api.nvim_buf_get_lines(shown, 0, -1, false)
end
-- The gutter of line `row`, as the window draws it.
local function gutter(row)
  return vim.api.nvim_eval_statusline(vim.wo[window].statuscolumn, {winid=window, use_statuscol_lnum=row}).str
end
local function line_marks(buf)
  local found = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})) do
    if mark[4].hl_eol then found[mark[2] + 1] = mark[4].hl_group end
  end
  return found
end

-- Changes: what is staged against the file on disk.
local buf, text = show({path='edit.lua', group='changes'})
assert(vim.deep_equal(text, {'local a = 1', 'local b = 20', 'local c = 3', 'local d = 4', 'return a'}), 'the whole file is shown')
assert(vim.api.nvim_buf_get_name(buf) == 'scm://' .. root .. '/edit.lua (diff)', 'the buffer is named for the file and what it compares')
assert(vim.deep_equal(line_marks(buf), {[4]='ScmDiffAdd'}), 'only the unstaged line is marked')
assert(gutter(1) == '  1  ' and gutter(4) == '  4+ ', 'the gutter numbers lines and marks an added one, got "' .. gutter(4) .. '"')
assert(vim.api.nvim_win_get_cursor(window)[1] == 4, 'the diff opens at its first change')
assert(vim.bo[buf].buftype == 'nofile' and not vim.bo[buf].modifiable, 'a diff cannot be edited')
assert(vim.wo[window].number == false and vim.wo[window].signcolumn == 'no', 'the diff draws its own gutter')
local header = vim.api.nvim_eval_statusline(vim.wo[window].winbar, {winid=window, use_winbar=true}).str
assert(header:find('edit.lua (diff)', 1, true) and header:find('+1', 1, true) and header:find('Open File', 1, true),
  'the header names the file and counts its changes, got ' .. header)

-- The overview strip: where the changes are in the file, and what is on screen.
local cells = diff.overview({{kind=' '}, {kind='-'}, {kind='+'}, {kind=' '}}, 4, 1, 2)
assert(cells[2].removed and cells[3].added and not cells[1].added and not cells[4].removed, 'a short diff is drawn line for line')
assert(cells[1].visible and cells[2].visible and not cells[3].visible, 'the lines on screen are marked')
local long = {}
for i = 1, 100 do long[i] = {kind=i == 1 and '-' or i == 2 and '+' or i == 100 and '+' or ' '} end
cells = diff.overview(long, 10, 1, 100)
assert(cells[1].added and cells[1].removed and cells[10].added and not cells[10].removed and not cells[5].added,
  'a long diff is scaled to the strip')
cells = diff.overview({{kind='+'}}, 3, 1, 1)
assert(cells[1].visible and not cells[2].visible and not cells[2].added, 'rows past the end of the file are empty')
local strip = diff.ruler(window)
assert(strip and vim.api.nvim_win_get_config(strip).relative == 'win' and not vim.api.nvim_win_get_config(strip).focusable,
  'the diff has an overview strip that cannot take the cursor')
assert(vim.api.nvim_win_get_height(strip) == vim.fn.getwininfo(window)[1].height, 'as tall as the text')
local painted = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(vim.api.nvim_win_get_buf(strip), ns, 0, -1, {details=true})) do
  painted[#painted + 1] = (mark[2] + 1) .. ':' .. mark[4].hl_group
end
assert(vim.tbl_contains(painted, '4:ScmDiffRulerAdd') and vim.tbl_contains(painted, '1:ScmDiffRulerView')
  and not vim.tbl_contains(painted, '6:ScmDiffRulerView'), 'the added line is green in the strip, got ' .. vim.inspect(painted))

-- Staged: the last commit against what is staged.
buf, text = show({path='edit.lua', group='staged'})
assert(vim.deep_equal(text, {'local a = 1', 'local b = 2', 'local b = 20', 'local c = 3', 'return a'}), 'staged: the old line sits above the new one')
assert(vim.deep_equal(line_marks(buf), {[2]='ScmDiffDelete', [3]='ScmDiffAdd'}), 'staged: removed and added are marked')
assert(gutter(2) == '   - ' and gutter(3) == '  2+ ', 'a removed line has no number, got "' .. gutter(2) .. '"')
local words = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details=true})) do
  if not mark[4].hl_eol then words[#words + 1] = {mark[2] + 1, mark[3], mark[4].end_col, mark[4].hl_group} end
end
assert(vim.deep_equal(words, {{2, 10, 11, 'ScmDiffDeleteText'}, {3, 10, 12, 'ScmDiffAddText'}}),
  'the changed number is marked inside both lines, got ' .. vim.inspect(words))
assert(vim.api.nvim_buf_get_name(buf):find('(staged diff)', 1, true), 'staged: named so')

-- Moving between changes, and opening the file from its diff.
show({path='edit.lua', group='changes'})
vim.api.nvim_win_set_cursor(window, {1, 0})
assert(diff.jump(1) and vim.api.nvim_win_get_cursor(window)[1] == 4, 'the next change is found')
assert(diff.jump(1) and vim.api.nvim_win_get_cursor(window)[1] == 4, 'the last change wraps to the first')
assert(type(vim.fn.maparg(']c', 'n', false, true).callback) == 'function', ']c is bound in a diff')
assert(diff.open_file() and vim.api.nvim_buf_get_name(0) == root .. '/edit.lua', 'the file opens over its diff')
assert(vim.api.nvim_win_get_cursor(window)[1] == 4, 'at the line the cursor was on')
assert(vim.wo[window].number == true and vim.wo[window].signcolumn == 'yes' and vim.wo[window].statuscolumn == ''
  and vim.wo[window].winbar == '', 'the window gets its own options back')
assert(not vim.api.nvim_buf_is_valid(buf) or not diff.is_diff(buf), 'the diff is gone once it is hidden')
assert(not diff.ruler(window) and windows() == #vim.api.nvim_tabpage_list_wins(0), 'and so is its overview strip')

-- A deleted file shows what was removed; an untracked file is all new.
buf, text = show({path='gone.lua', group='changes'})
assert(vim.deep_equal(text, {'gone 1', 'gone 2'}) and vim.deep_equal(line_marks(buf), {'ScmDiffDelete', 'ScmDiffDelete'}),
  'a deleted file shows its last contents as removed')
assert(diff.open_file() == false and diff.is_diff(vim.api.nvim_get_current_buf()), 'a deleted file has no file to open')
buf, text = show({path='new.lua', group='changes', untracked=true})
assert(vim.deep_equal(text, {'brand new'}) and line_marks(buf)[1] == 'ScmDiffAdd', 'an untracked file is all added')
_, text = show({path='blob.bin', group='changes'})
assert(#text == 1 and text[1]:find('binary', 1, true), 'a binary file is not compared')

-- Only a regular file of a sane size is read from disk.
vim.uv.fs_symlink('/etc/hosts', root .. '/link')
buf, text = show({path='link', group='changes', untracked=true})
assert(vim.deep_equal(text, {'/etc/hosts'}), 'a link shows where it points, as git keeps it, and is not followed')
assert(vim.system({'mkfifo', root .. '/pipe'}):wait().code == 0)
_, text = show({path='pipe', group='changes', untracked=true})
assert(vim.deep_equal(text, {''}), 'a pipe is not read: reading one would never finish')
handle = io.open(root .. '/huge.txt', 'wb')
handle:write(('0123456789abcde\n'):rep(300000))
handle:close()
_, text = show({path='huge.txt', group='changes', untracked=true})
assert(#text == 1 and text[1]:find('too large', 1, true), 'a file past the size limit is not read')
git('add', 'huge.txt')
_, text = show({path='huge.txt', group='staged'})
assert(#text == 1 and text[1]:find('too large', 1, true), 'nor is one that git holds')
git('rm', '-q', '--cached', 'huge.txt')
vim.fn.delete(root .. '/huge.txt')
vim.fn.delete(root .. '/pipe')
vim.fn.delete(root .. '/link')
-- A file whose name looks like a conflict stage is still the staged file.
write('1:edit.lua', {'odd name'})
git('add', '1:edit.lua')
_, text = show({path='1:edit.lua', group='staged'})
assert(vim.deep_equal(text, {'odd name'}), 'a path beginning "1:" is read as itself, got ' .. vim.inspect(text))
git('rm', '-q', '-f', '1:edit.lua')

-- Committed: the branch's base against its last commit, following a rename.
buf, text = show({path='branch.lua', group='committed', base=base})
assert(vim.deep_equal(text, {'on the branch'}) and line_marks(buf)[1] == 'ScmDiffAdd', 'a file added on the branch is all added')
assert(vim.api.nvim_buf_get_name(buf):find('(branch diff)', 1, true), 'committed: named a branch diff')
buf, text = show({path='renamed.lua', orig='moved.lua', group='committed', base=base})
assert(vim.deep_equal(text, {'one', 'two', 'three', 'THREE', 'four', 'five'}), 'a renamed file is compared with its old name')
local committed
require('scm.core').refresh(root, require('scm.core').defaults, function(entries) committed = entries end)
assert(vim.wait(5000, function() return committed end, 10))
local renamed
for _, file in ipairs(committed[1].files) do
  if file.path == 'renamed.lua' then renamed = file end
end
assert(renamed and renamed.orig == 'moved.lua' and committed[1].comparison_base == base,
  'Core reports the old name of a file renamed on the branch')

-- A diff on screen follows the repository.
buf = show({path='edit.lua', group='changes'})
git('add', 'edit.lua')
diff.reload()
assert(vim.wait(5000, function() return next(line_marks(buf)) == nil end, 10), 'staging the file empties its diff')
assert(vim.api.nvim_get_current_buf() == buf, 'the diff stays where it is')

-- Selecting a file in the Panel shows its diff; the row's button opens it.
git('reset', '-q')
vim.cmd('silent! only')
vim.cmd.enew()
vim.cmd.cd(root)
local scm = require('scm')
scm.setup({renderer='terminal'})
scm.toggle()
local function panel()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return win end
  end
end
local function line_of(label)
  for number, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel()), 0, -1, false)) do
    if line:find(label, 1, true) then return number end
  end
end
local function press(label, key)
  vim.api.nvim_set_current_win(panel())
  vim.api.nvim_win_set_cursor(panel(), {line_of(label), 0})
  vim.fn.maparg(key, 'n', false, true).callback()
end
local function named(name)
  return vim.wait(5000, function() return vim.api.nvim_buf_get_name(0) == name end, 10)
end
assert(vim.wait(5000, function() return panel() and line_of('renamed.lua') end), 'the Panel lists the branch\'s files')
press('gone.lua', '<CR>')
assert(named('scm://' .. root .. '/gone.lua (diff)'), 'Enter on a deleted file shows what was removed')
press('renamed.lua', '<CR>')
assert(named('scm://' .. root .. '/renamed.lua (branch diff)'), 'Enter on a committed file shows its branch diff')
assert(#vim.api.nvim_buf_get_lines(0, 0, -1, false) == 6, 'compared with its old name')
assert(windows() == 2, 'one diff replaces another in the same window')
press('edit.lua', 'o')
assert(named(root .. '/edit.lua'), 'o opens the file itself')
assert(windows() == 2, 'the file replaces the diff')
scm.toggle()
print('OK diff: a selected file shows its changes inline')
