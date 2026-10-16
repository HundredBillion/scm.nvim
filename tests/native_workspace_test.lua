vim.opt.runtimepath:prepend(vim.uv.cwd())
local pending, request, dock, fail
local row_callbacks = {}
local renders, closed = 0, 0
package.loaded.sprite = {
  available=function(cb) pending=cb end,
  open=function(opts, cb)
    request=opts
    dock={
      assets=function(_, _, done) done() end,
      rows=function(_, revision, rows, selected, done)
        renders=renders+1
        dock.revision, dock.rows_value, dock.selected = revision,rows,selected
        row_callbacks[#row_callbacks+1]=done
      end,
      focus=function(_, done) if done then done() end end,
      focus_editor=function(_, done) if done then done() end end,
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
scm.setup({renderer='auto'})
scm.toggle()
assert(pending, 'auto checks Sprite capabilities')
pending(nil, {features={'owned-dock-v1','virtual-list-v1'}})
assert(request and request.description.root.heading.text=='SOURCE CONTROL', 'native source control dock opens')
assert(renders==1, 'initial native rows sent')
vim.api.nvim_exec_autocmds('FocusGained', {})
assert(vim.wait(5000, function() return #row_callbacks>0 end))
row_callbacks[1]()
assert(vim.wait(5000, function() return renders>=2 end), 'Git refresh reaches native dock')
row_callbacks[2]()
request.on_event({type='input', key='down'})
row_callbacks[3]()
request.on_event({type='input', key='enter', text='\n'})
assert(vim.api.nvim_buf_get_name(0)==vim.uv.fs_realpath(fixture)..'/hello.lua', 'real Sprite enter event opens file')
local before_close=renders
scm.toggle()
assert(closed==1, 'close releases native dock')
row_callbacks[1]()
assert(renders==before_close, 'late row ack does not resurrect closed dock')
scm.toggle()
local late=pending
scm.toggle()
late(nil, {features={'owned-dock-v1','virtual-list-v1'}})
assert(closed==1, 'late discovery does not open a dock')
fail=true
scm.toggle()
pending(nil, {features={'owned-dock-v1','virtual-list-v1'}})
local found=false
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.bo[vim.api.nvim_win_get_buf(win)].filetype=='scm' then found=true end
end
assert(found, 'refused native dock falls back to terminal')
scm.toggle()
vim.fn.delete(fixture,'rf')
print('OK native workspace lifecycle')
