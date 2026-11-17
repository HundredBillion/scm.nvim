-- A refresh that finds nothing new does not send the Panel's rows to the host
-- again: for a long list that is a megabyte, many times on every open.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
assert(vim.system({'git', '-C', root, 'init', '-q', '-b', 'main'}):wait().code == 0)
vim.fn.writefile({'x'}, root .. '/hello.lua')
vim.cmd.cd(root)

local frames, states, waiting, request = {}, {}, {}, nil
local refuse_state = false
package.loaded.sprite = {open=function(opts, cb)
  request = opts
  cb(nil, {
    features={['virtual-list-rows-v2']=true},
    assets=function(_, _, done) done() end,
    rows=function(_, revision, rows, selected, done)
      frames[#frames + 1] = {revision=revision, rows=rows, selected=selected}
      waiting[#waiting + 1] = done
    end,
    state=function(_, _, state, done)
      states[#states + 1] = state.selected
      done(refuse_state and {message='stale'} or nil)
    end,
    focus=function(_, done) if done then done() end end,
    focus_editor=function(_, done) if done then done() end end,
    close=function() end,
  })
end}
local function ack() while #waiting > 0 do table.remove(waiting, 1)() end end
local function settle()
  vim.wait(400, function() ack(); return false end, 10)
end
local function listed()
  local last = frames[#frames]
  for _, row in ipairs(last and last.rows or {}) do
    if row.text == 'hello.lua' then return true end
  end
end

local scm = require('scm')
scm.setup({renderer='auto', warm=false})
scm.toggle()
assert(vim.wait(5000, function() ack(); return listed() end, 10), 'the dock lists the file')
settle()
local sent = #frames

-- Refreshing an unchanged repository sends nothing.
vim.api.nvim_exec_autocmds('FocusGained', {})
settle()
assert(#frames == sent, 'an unchanged refresh sends no rows, sent ' .. (#frames - sent))

-- A change is sent.
vim.fn.writefile({'y'}, root .. '/second.lua')
vim.api.nvim_exec_autocmds('FocusGained', {})
assert(vim.wait(5000, function() ack(); return #frames > sent end, 10), 'a new file is sent to the dock')
settle()
sent = #frames

-- Moving the selection sends only the selection, and later frames know it.
request.on_event({type='input', key='down'})
settle()
assert(#states == 1 and #frames == sent, 'moving the selection sends no rows')
vim.api.nvim_exec_autocmds('FocusGained', {})
settle()
assert(#frames == sent, 'a refresh after moving the selection still sends nothing')

-- A selection the host refused leaves its frame unknown: the next is sent whole.
refuse_state = true
request.on_event({type='input', key='down'})
assert(vim.wait(5000, function() ack(); return #frames > sent end, 10), 'a refused selection is followed by the whole frame')
assert(frames[#frames].selected == states[#states], 'carrying the selection that was asked for')
scm.toggle()
print('OK frame reuse: unchanged rows are not sent again')
