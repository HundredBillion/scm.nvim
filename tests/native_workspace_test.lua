vim.opt.runtimepath:prepend(vim.uv.cwd())
local request, dock, fail
local row_callbacks = {}
local renders, closed = 0, 0
local focused, editor_focused = 0, 0
package.loaded.sprite = {
  open=function(opts, cb)
    request=opts
    dock={
      features={['virtual-list-rows-v2']=true},
      assets=function(_, _, done) done() end,
      rows=function(_, revision, rows, selected, done)
        renders=renders+1
        dock.revision, dock.rows_value, dock.selected = revision,rows,selected
        row_callbacks[#row_callbacks+1]=done
      end,
      focus=function(_, done) focused=focused+1; if done then done() end end,
      focus_editor=function(_, done) editor_focused=editor_focused+1; if done then done() end end,
      close=function() closed=closed+1 end,
    }
    if fail then cb({message='refused'}) else cb(nil,dock) end
  end,
}
local fixture=vim.fn.tempname()
vim.fn.mkdir(fixture, 'p')
assert(vim.system({'git','-C',fixture,'init','-b','main'}):wait().code==0)
vim.fn.writefile({'hello'}, fixture .. '/hello.lua')
vim.cmd.cd(fixture)
local scm = require('scm')
scm.setup({renderer='auto',native={colors={background='#2b2d30'}}})
scm.toggle()
assert(request and request.description.root.heading.text=='Source Control', 'native source control dock opens')
assert(request.description.root.colors.background=='#2b2d30', 'native palette override')
assert(renders==1, 'initial native rows sent')
request.on_event({type='input', key='ctrl-l'})
assert(editor_focused==1, 'Ctrl-l focuses editor even while rows are pending')
assert(scm.focus('left') == true, 'SCM exposes native focus entry point')
assert(focused==1, 'focus request reaches native dock')
assert(scm.focus('right') == false, 'left dock cannot handle right focus')
vim.api.nvim_exec_autocmds('FocusGained', {})
assert(vim.wait(5000, function() return #row_callbacks>0 end))
row_callbacks[1]()
assert(focused==1, 'row acknowledgement does not steal focus back')
assert(vim.wait(5000, function() return renders>=2 end), 'Git refresh reaches native dock')
row_callbacks[2]()
-- Rows: commit box, Commit button, the Changes group, then hello.lua.
assert(dock.rows_value[1].kind=='input' and dock.rows_value[2].kind=='button', 'commit box and button lead the rows')
assert(dock.rows_value[4].text=='hello.lua' and dock.rows_value[4].badge.text=='U', 'file row carries its status letter')
for _=1,3 do
  request.on_event({type='input', key='down'})
  row_callbacks[#row_callbacks]()
end
request.on_event({type='input', key='enter', text='\n'})
local hello=vim.uv.fs_realpath(fixture)..'/hello.lua'
assert(vim.wait(5000, function() return vim.api.nvim_buf_get_name(0)=='scm://'..hello..' (diff)' end, 20),
  'real Sprite enter event shows the diff of the file')
request.on_event({type='input', key='o', text='o'})
assert(vim.api.nvim_buf_get_name(0)==hello, 'o opens the file itself')
-- Typing a commit message in the dock: `c` opens the commit box, keys become its text.
local acked=#row_callbacks
local function ack()
  while acked<#row_callbacks do acked=acked+1; row_callbacks[acked]() end
end
ack()
request.on_event({type='input', key='c', text='c'})
ack()
assert(dock.rows_value[1].cursor==0 and dock.selected==dock.rows_value[1].id, 'c selects the commit box and starts typing')
assert(focused>=2, 'starting to type gives the dock the keyboard')
for _, char in ipairs({'h','j','k'}) do request.on_event({type='input', key=char, text=char}) end
ack()
assert(dock.rows_value[1].text=='hjk' and dock.rows_value[1].cursor==3, 'j and k are typed, not navigation, while editing')
request.on_event({type='input', key='backspace'})
request.on_event({type='input', key='left'})
request.on_event({type='input', key='shift-x', text='X'})
ack()
assert(dock.rows_value[1].text=='hXj' and dock.rows_value[1].cursor==2, 'editing keys move the cursor and delete')
-- Clicking another row ends typing: later keys navigate again and the message is kept.
request.on_event({type='list_click', revision=dock.revision, button='left', id=dock.rows_value[3].id})
ack()
assert(dock.rows_value[1].cursor==nil and dock.rows_value[1].text=='hXj', 'a click elsewhere ends typing and keeps the message')
local typed=dock.rows_value[1].text
request.on_event({type='input', key='j', text='j'})
ack()
assert(dock.rows_value[1].text==typed, 'j navigates again once typing has ended')
-- Enter on the commit box resumes typing; Escape leaves it.
request.on_event({type='input', key='escape'})
local before_close=renders
scm.toggle()
assert(closed==1, 'close releases native dock')
row_callbacks[1]()
assert(renders==before_close, 'late row ack does not resurrect closed dock')
scm.toggle()
scm.toggle()
assert(closed==2, 'opening again closes the previous dock')
fail=true
scm.toggle()
local found=false
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='scm' then found=true end
end
assert(found, 'refused native dock falls back to terminal')
scm.toggle()
vim.fn.delete(fixture,'rf')
print('OK native workspace lifecycle')
