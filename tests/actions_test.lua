-- Stage, unstage, discard and commit through the Panel, against real repositories.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local function repo()
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, 'p')
  return vim.uv.fs_realpath(root)
end
local root = repo()
local function git(...)
  -- The test reads status while SCM writes; it must not take the index lock itself.
  local result = vim.system(vim.list_extend({'git', '--no-optional-locks', '-C', root}, {...}), {text=true}):wait()
  assert(result.code == 0, result.stderr)
  return result.stdout
end
local function status() return git('status', '--porcelain', '--untracked-files=all') end
local function write(path, text)
  vim.fn.mkdir(vim.fn.fnamemodify(root .. '/' .. path, ':h'), 'p')
  vim.fn.writefile({text}, root .. '/' .. path)
end
git('init', '-q', '-b', 'main')
git('config', 'user.email', 'test@example.com')
git('config', 'user.name', 'Test')
write('a.txt', 'a'); write('b.txt', 'b'); write('dir/c.txt', 'c'); write('old.txt', 'old')
git('add', '.'); git('commit', '-qm', 'initial')
write('a.txt', 'a changed'); write('b.txt', 'b changed'); write('dir/c.txt', 'c changed')
write('café.txt', 'unicode'); write('*', 'star'); write('other.txt', 'untracked')
vim.cmd.cd(root)

local answers, asked = {}, {}
local scm = require('scm')
scm.setup({renderer='terminal', repo_debounce_ms=0, confirm=function(message)
  asked[#asked + 1] = message
  return table.remove(answers, 1) == true
end})
scm.toggle()
local function panel()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return win end
  end
end
local function lines() return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel()), 0, -1, false) end
local function text() return table.concat(lines(), '\n') end
-- Put the cursor on the first line matching `pattern` after the line matching `after`.
local function go(pattern, after)
  local from = 1
  if after then
    for i, line in ipairs(lines()) do
      if line:find(after, 1, true) then from = i + 1; break end
    end
  end
  for i = from, #lines() do
    if lines()[i]:find(pattern, 1, true) then
      vim.api.nvim_set_current_win(panel())
      vim.api.nvim_win_set_cursor(panel(), {i, 0})
      return
    end
  end
  error('no line with ' .. pattern .. ' in\n' .. text())
end
local function press(key) vim.fn.maparg(key, 'n', false, true).callback() end
local function wait(what, check) assert(vim.wait(5000, check, 20), what .. '\n' .. text() .. '\n' .. status()) end
wait('the Panel lists the changes', function() return text():find('other.txt', 1, true) end)

-- A path is the exact file it names, never a pattern.
go('café.txt')
press('s')
wait('a non-ASCII name is staged under its real name', function() return status():find('A  "?caf') end)
go('*', 'Changes')
answers = {true}
press('x')
wait('discarding a file named * deletes only that file', function() return not status():find('%*') end)
assert(status():find('?? other.txt', 1, true), 'the other untracked file survives a discard of "*"')
assert(asked[#asked]:find('Delete *?', 1, true), 'an untracked file is confirmed as a deletion')

-- Staging and unstaging one file moves it between groups.
go('a.txt', 'Changes')
press('s')
wait('s stages the file', function() return status():find('M  a.txt', 1, true) end)
wait('the Panel shows it staged', function() return text():find('Staged Changes', 1, true) end)
go('a.txt', 'Staged Changes')
press('u')
wait('u unstages the file', function() return status():find(' M a.txt', 1, true) end)

-- A key a row cannot do is ignored: staging the Staged Changes group stages nothing more.
go('Staged Changes')
press('s')
vim.wait(300)
assert(status():find(' M a.txt', 1, true) and status():find(' M b.txt', 1, true),
  'staging on the Staged Changes group leaves Changes alone')
-- Unstaging the group unstages only what is staged.
press('u')
wait('u on Staged Changes unstages it', function() return status():find('%?%? "?caf') end)

-- Discard is confirmed, and declining keeps the change.
go('b.txt')
answers = {false}
press('x')
vim.wait(300)
assert(status():find(' M b.txt', 1, true), 'a declined discard keeps the change')
answers = {true}
press('x')
wait('a confirmed discard restores the file', function() return not status():find('b.txt', 1, true) end)
assert(asked[#asked]:find('Discard changes in b.txt?', 1, true), 'a tracked file is confirmed as a discard')

-- Tree view: a directory row stages everything under it.
press('t')
go('▾ dir')
press('s')
wait('s on a directory stages its files', function() return status():find('M  dir/c.txt', 1, true) end)
press('t')

-- A staged rename is unstaged under both names.
git('reset', '-q')
git('mv', 'old.txt', 'new.txt')
press('r')
wait('the rename is listed', function() return text():find('new.txt', 1, true) end)
go('new.txt', 'Staged Changes')
press('u')
wait('unstaging a rename leaves nothing staged', function() return git('diff', '--cached', '--name-only') == '' end)
assert(vim.uv.fs_rename(root .. '/new.txt', root .. '/old.txt'))
press('r')
wait('the Panel catches up with the restored file', function()
  return not text():find('Staged Changes', 1, true) and not text():find('new.txt', 1, true)
end)

-- Commit: an empty message asks for one instead of committing.
local real_input, prompted = vim.ui.input, 0
vim.ui.input = function(_, on_confirm) prompted = prompted + 1; on_confirm('first commit') end
local before = git('rev-list', '--count', 'HEAD')
go('✓ Commit')
press('<CR>')
wait('an empty message opens the commit box', function() return prompted == 1 end)
assert(git('rev-list', '--count', 'HEAD') == before, 'nothing is committed without a message')
wait('the typed message is shown', function() return text():find('first commit', 1, true) end)
-- With nothing staged, committing asks before staging everything; declining commits nothing.
answers = {false}
go('✓ Commit')
press('<CR>')
vim.wait(300)
assert(git('rev-list', '--count', 'HEAD') == before, 'declining "stage all" commits nothing')
assert(asked[#asked]:find('no staged changes', 1, true), 'committing with nothing staged asks first')
-- A commit that fails keeps the message and shows what the attempt staged.
vim.fn.mkdir(root .. '/.git/hooks', 'p')
vim.fn.writefile({'#!/bin/sh', 'exit 1'}, root .. '/.git/hooks/pre-commit')
vim.fn.setfperm(root .. '/.git/hooks/pre-commit', 'rwxr-xr-x')
local real_notify, errors = vim.notify, {}
vim.notify = function(message, level) if level == vim.log.levels.ERROR then errors[#errors + 1] = message end end
answers = {true}
go('✓ Commit')
press('<CR>')
wait('a failed commit is reported', function() return #errors == 1 end)
wait('a failed commit still shows what it staged', function() return text():find('Staged Changes', 1, true) end)
assert(text():find('first commit', 1, true), 'a failed commit keeps the message')
vim.notify = real_notify
vim.fn.delete(root .. '/.git/hooks/pre-commit')
-- Committing what is staged needs no confirmation and clears the message.
local questions = #asked
go('✓ Commit')
press('<CR>')
wait('the commit lands', function() return git('rev-list', '--count', 'HEAD') ~= before end)
assert(#asked == questions, 'committing staged changes asks nothing')
assert(vim.trim(git('log', '-1', '--format=%s')) == 'first commit', 'the commit carries the typed message')
wait('the message is cleared after the commit', function() return not text():find('first commit', 1, true) end)
assert(status() == '', 'the commit took every change')
vim.ui.input = real_input
scm.toggle()

-- A repository with no commit yet: unstaging removes the file from the index, nothing more.
local unborn = repo()
assert(vim.system({'git', '-C', unborn, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, unborn .. '/first.txt')
assert(vim.system({'git', '-C', unborn, 'add', '.'}):wait().code == 0)
local actions = require('scm.actions')
local done
actions.unstage(unborn, {'first.txt'}, function(err) done = err or true end)
assert(vim.wait(5000, function() return done ~= nil end) and done == true, 'unstage works before the first commit')
assert(vim.system({'git', '-C', unborn, 'status', '--porcelain'}, {text=true}):wait().stdout == '?? first.txt\n',
  'the file is untracked again')
-- In a repository with commits, a failing reset is reported and never falls back to removing the index.
done = nil
vim.fn.writefile({}, root .. '/.git/index.lock')
actions.unstage(root, nil, function(err) done = err or true end)
assert(vim.wait(5000, function() return done ~= nil end) and done ~= true, 'a locked index is an error')
vim.fn.delete(root .. '/.git/index.lock')
assert(status() == '', 'a failed unstage leaves the repository untouched')
vim.fn.delete(root, 'rf')
vim.fn.delete(unborn, 'rf')
print('OK actions')
