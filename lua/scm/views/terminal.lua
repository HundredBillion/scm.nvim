local M = {}
function M.open(opts, action, closed)
  local view = { closing = false }
  view.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[view.buf].bufhidden = 'wipe'
  vim.bo[view.buf].buftype = 'nofile'
  vim.bo[view.buf].swapfile = false
  vim.bo[view.buf].filetype = 'scm'
  vim.cmd('topleft vertical ' .. tostring(opts.width or 36) .. 'split')
  view.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view.win, view.buf)
  for key, value in pairs({number=false, relativenumber=false, wrap=false, signcolumn='no',
    foldcolumn='0', cursorline=true, winfixwidth=true, spell=false,
    winhighlight='Normal:ScmBackground,EndOfBuffer:ScmBackground,CursorLine:ScmSelection'}) do
    vim.wo[view.win][key] = value
  end
  local function selected() return math.max(1, vim.api.nvim_win_get_cursor(view.win)[1] - 2) end
  for key, name in pairs({['<CR>']='open', l='expand', h='collapse', r='refresh', q='close',
    ['<Esc>']='editor', ['<Space>gs']='close', ['<C-S-g>']='close', ['<Space>e']='explorer', ['<C-b>']='explorer'}) do
    vim.keymap.set('n', key, function() action(name, selected()) end, {buffer=view.buf, nowait=true})
  end
  local ns = vim.api.nvim_create_namespace('scm.sidebar')
  function view:render(rows, index)
    if not vim.api.nvim_buf_is_valid(self.buf) then return end
    local lines = {' SOURCE CONTROL', ''}
    for _, row in ipairs(rows) do lines[#lines+1] = row.text:gsub('[\r\n]', ' ') end
    if #rows == 0 then lines[#lines+1] = ' No repositories found' end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    for i, row in ipairs(rows) do
      vim.api.nvim_buf_set_extmark(self.buf, ns, i+1, 0, {end_col=#lines[i+2], hl_group=row.hl or 'Normal'})
    end
    vim.api.nvim_win_set_cursor(self.win, {math.min(index+2, #lines), 0})
  end
  function view:selection() return selected() end
  function view:close()
    if self.closing then return end
    self.closing = true
    if vim.api.nvim_win_is_valid(self.win) then
      if #vim.api.nvim_tabpage_list_wins(0) > 1 then vim.api.nvim_win_close(self.win, true)
      else vim.api.nvim_win_set_buf(self.win, vim.api.nvim_create_buf(true, false)) end
    end
    if vim.api.nvim_buf_is_valid(self.buf) then vim.api.nvim_buf_delete(self.buf, {force=true}) end
  end
  vim.api.nvim_create_autocmd('BufWipeout', {buffer=view.buf, once=true, callback=function()
    if not view.closing then view.closing = true; closed() end
  end})
  return view
end
return M
