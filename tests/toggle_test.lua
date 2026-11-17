-- Every row that can expand must close and open again, by Enter, by h and l,
-- and by a click, in both Renderers. A collapsed repository once reported
-- itself as a row that cannot expand, so Enter closed it and never reopened it.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local model = require('scm.model')

-- The model: a row with children says whether it is open, true or false.
local files = {
  {path='src/a/one.lua', xy='.M'}, {path='src/two.lua', xy='.M'}, {path='top.lua', xy='M.'},
}
local entries = {
  {path='/r/alpha', name='alpha', branch='main', files=files},
  {path='/r/beta', name='beta', branch='main', files=files},
  {path='/r/empty', name='empty', branch='main', files={}},
}
for _, mode in ipairs({'list', 'tree'}) do
  local open = model.rows(entries, {mode=mode})
  local expandable = {}
  for _, row in ipairs(open) do
    if row.kind == 'repo' and row.label == 'empty' then
      assert(row.expanded == nil, 'a repository with nothing in it cannot expand')
    elseif row.kind == 'repo' or row.kind == 'group' or row.kind == 'dir' then
      assert(row.expanded == true, mode .. ': ' .. row.id .. ' starts open')
      expandable[#expandable + 1] = row.id
    end
  end
  assert(#expandable >= (mode == 'tree' and 8 or 6), mode .. ': found ' .. #expandable .. ' expandable rows')
  for _, id in ipairs(expandable) do
    local closed
    for _, row in ipairs(model.rows(entries, {mode=mode, collapsed={[id]=true}})) do
      if row.id == id then closed = row end
    end
    assert(closed, mode .. ': ' .. id .. ' is still listed when collapsed')
    assert(closed.expanded == false, mode .. ': collapsed ' .. id .. ' says false, not ' .. tostring(closed.expanded))
  end
end

-- Two real repositories, so the Panel lists repository rows.
local root = vim.fn.tempname()
for _, name in ipairs({'alpha', 'beta'}) do
  local repo = root .. '/' .. name
  vim.fn.mkdir(repo .. '/src/a', 'p')
  assert(vim.system({'git', '-C', repo, 'init', '-b', 'main'}):wait().code == 0)
  vim.fn.writefile({'x'}, repo .. '/src/a/one.lua')
  vim.fn.writefile({'x'}, repo .. '/src/two.lua')
  vim.fn.writefile({'x'}, repo .. '/top.lua')
end
vim.cmd.cd(root)

-- The native Renderer, against a dock that records what it is sent.
local request, dock
local waiting = {}
package.loaded.sprite = {open=function(opts, cb)
  request = opts
  dock = {
    features={['virtual-list-rows-v2']=true},
    assets=function(_, _, done) done() end,
    rows=function(_, revision, rows, selected, done)
      dock.revision, dock.rows_value, dock.selected = revision, rows, selected
      waiting[#waiting + 1] = done
    end,
    state=function(_, _, state, done) dock.selected = state.selected; waiting[#waiting + 1] = done end,
    focus=function(_, done) if done then done() end end,
    focus_editor=function(_, done) if done then done() end end,
    close=function() end,
  }
  cb(nil, dock)
end}
local function ack() while #waiting > 0 do table.remove(waiting, 1)() end end
local function ids()
  return vim.tbl_map(function(row) return row.id end, dock.rows_value)
end
local function index_of(id)
  for i, row in ipairs(dock.rows_value) do
    if row.id == id then return i end
  end
end
local function settle(done)
  assert(vim.wait(5000, function() ack(); return done() end, 20), 'the dock settles')
end
local function press(key) request.on_event({type='input', key=key}); ack() end
local function go(id)
  local from, to = index_of(dock.selected), index_of(id)
  assert(from and to, 'no row ' .. id)
  for _ = 1, math.abs(to - from) do press(to > from and 'down' or 'up') end
  assert(dock.selected == id, 'selection reaches ' .. id)
end

local scm = require('scm')
for _, mode in ipairs({'list', 'tree'}) do
  scm.setup({renderer='auto', view=mode})
  scm.toggle()
  -- Both repositories, each with its group and files.
  settle(function() return dock and dock.rows_value and #dock.rows_value >= 12 end)
  local all = ids()
  local expandable = vim.tbl_filter(function(id) return id:find('^repo:') or id:find('^group:') or id:find('^dir:') end, all)
  assert(#expandable >= (mode == 'tree' and 8 or 4), mode .. ': ' .. #expandable .. ' expandable rows in the dock')
  local ways = {
    Enter={function() press('enter') end, function() press('enter') end},
    ['h and l']={function() press('h') end, function() press('l') end},
    click={
      function(id) request.on_event({type='list_click', revision=dock.revision, id=id, count=1, button='left', modifiers=''}); ack() end,
      function(id) request.on_event({type='list_click', revision=dock.revision, id=id, count=1, button='left', modifiers=''}); ack() end,
    },
  }
  for way, steps in pairs(ways) do
    for _, id in ipairs(expandable) do
      local what = ('native %s, %s on %s'):format(mode, way, id:match('^%a+') .. ' ' .. id:match('[^/:]*$'))
      go(id)
      steps[1](id)
      settle(function() return #dock.rows_value < #all end)
      assert(index_of(id), what .. ': the row stays listed')
      assert(dock.selected == id, what .. ': the row stays selected')
      steps[2](id)
      settle(function() return #dock.rows_value == #all end)
      assert(vim.deep_equal(ids(), all), what .. ': opening again restores every row')
    end
  end
  scm.toggle()
  dock, request = nil, nil
end

-- The terminal Renderer: Enter on the line of each expandable row.
scm.setup({renderer='terminal', view='tree'})
scm.toggle()
local function panel()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.bo[vim.api.nvim_win_get_buf(win)].filetype == 'scm' then return win end
  end
end
local function lines() return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(panel()), 0, -1, false) end
assert(vim.wait(5000, function() return panel() and #lines() >= 14 end), 'the terminal Panel lists both repositories')
local function enter() vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<CR>', true, false, true), 'x', false) end
local full = lines()
local toggled = 0
for number, text in ipairs(full) do
  -- Line 2 is the "Changes" section; rows that can expand show an open chevron.
  if number > 2 and text:find('▾', 1, true) then
    vim.api.nvim_set_current_win(panel())
    vim.api.nvim_win_set_cursor(panel(), {number, 0})
    enter()
    assert(vim.wait(5000, function() return #lines() < #full end), 'terminal: Enter closes "' .. text .. '"')
    assert(vim.api.nvim_win_get_cursor(panel())[1] == number, 'terminal: the cursor stays on "' .. text .. '"')
    assert(lines()[number]:find('▸', 1, true), 'terminal: "' .. text .. '" shows a closed chevron')
    enter()
    assert(vim.wait(5000, function() return vim.deep_equal(lines(), full) end), 'terminal: Enter reopens "' .. text .. '"')
    toggled = toggled + 1
  end
end
assert(toggled >= 8, 'terminal: toggled ' .. toggled .. ' rows')
print('OK toggle: every expandable row closes and reopens')
