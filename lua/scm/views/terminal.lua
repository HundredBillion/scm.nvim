-- The terminal Renderer: the Panel as a Neovim split. A cell grid cannot match
-- VS Code's pixels, so this draws the same rows in the same order with text:
-- chevrons, dimmed directories, right-aligned status letters and counts.
local M = {}
local HEADER_LINES = 2

-- One row as a line of text: { text, marks = { {from, to, hl}... }, right =
-- {text, hl} drawn at the right edge, line_hl = a highlight for the whole line }.
local function line(row, ui, width)
  local pad = string.rep('  ', row.depth or 0)
  local kind = row.kind
  local label = (row.label or ''):gsub('[\r\n]', ' ')
  if kind == 'input' then
    local shown = label ~= '' and label
      or ('Message (Ctrl+Enter to commit on "%s")'):format(row.entry and row.entry.branch or '?')
    return {text=' ' .. pad .. shown, marks={{#pad + 1, -1, label ~= '' and 'ScmInput' or 'ScmPlaceholder'}}}
  elseif kind == 'button' then
    local text = '✓ ' .. label
    local left = math.max(0, math.floor((width - vim.fn.strdisplaywidth(text)) / 2))
    return {text=string.rep(' ', left) .. text, marks={}, line_hl='ScmButton'}
  elseif kind == 'note' then
    if not row.error then return {text=' ' .. pad .. label, marks={{0, -1, 'ScmDescription'}}} end
    return {text=' ' .. pad .. '! ' .. label, marks={{0, -1, 'DiagnosticWarn'}}}
  end
  -- A row that cannot expand keeps a chevron's width so labels line up, except
  -- a file in list mode, which VS Code draws flush with its group's label.
  local chevron = '  '
  if row.expanded ~= nil then chevron = row.expanded and '▾ ' or '▸ '
  elseif kind == 'file' and ui.mode ~= 'tree' then chevron = '' end
  local text = ' ' .. pad .. chevron .. label
  local marks = {}
  if kind == 'repo' then marks[#marks + 1] = {0, #text, row.error and 'DiagnosticWarn' or 'Title'}
  elseif kind == 'file' and row.strikethrough then marks[#marks + 1] = {#text - #label, #text, 'ScmStrike'} end
  if row.description and row.description ~= '' then
    local from = #text + 1
    text = text .. ' ' .. row.description
    marks[#marks + 1] = {from, #text, 'ScmDescription'}
  end
  local right
  if row.badge then right = {row.badge.text .. ' ', row.badge.hl or 'Normal'}
  elseif row.count then right = {' ' .. row.count .. ' ', 'ScmCount'} end
  return {text=text, marks=marks, right=right}
end

function M.open(opts, action, closed)
  local view = { closing = false, ui = {} }
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
  local function selected() return math.max(1, vim.api.nvim_win_get_cursor(view.win)[1] - HEADER_LINES) end
  -- The row under the cursor, or 0 on a header line: an index with no row, so
  -- a key pressed there acts on no file.
  local function target() return math.max(0, vim.api.nvim_win_get_cursor(view.win)[1] - HEADER_LINES) end
  local keys = vim.tbl_extend('force', require('scm.keys'), {['<2-LeftMouse>']='open'})
  for key, name in pairs(keys) do
    vim.keymap.set('n', key, function()
      local on_section = vim.api.nvim_win_get_cursor(view.win)[1] == HEADER_LINES
      -- Opening the "Changes" line folds the section, as clicking it does natively.
      action(on_section and name == 'open' and 'fold' or name, target())
    end, {buffer=view.buf, nowait=true})
  end
  local ns = vim.api.nvim_create_namespace('scm.sidebar')
  function view:render(rows, index, ui)
    if not vim.api.nvim_buf_is_valid(self.buf) then return end
    ui = ui or {}
    self.ui = ui
    local width = vim.api.nvim_win_is_valid(self.win) and vim.api.nvim_win_get_width(self.win) or (opts.width or 36)
    local lines = {' Source Control', (ui.folded and ' ▸ ' or ' ▾ ') .. 'Changes  ' .. (ui.mode == 'tree' and '[tree]' or '[list]')}
    local decorations = {}
    for i, row in ipairs(rows) do
      decorations[i] = line(row, ui, width)
      lines[#lines + 1] = decorations[i].text
    end
    if #rows == 0 and not ui.folded then lines[#lines + 1] = ' No repositories found' end
    vim.bo[self.buf].modifiable = true
    vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, lines)
    vim.bo[self.buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(self.buf, ns, 0, -1)
    vim.api.nvim_buf_set_extmark(self.buf, ns, 1, 0, {end_col=#lines[2], hl_group='Title'})
    for i, decoration in ipairs(decorations) do
      local row_index, text = i + HEADER_LINES - 1, decoration.text
      for _, mark in ipairs(decoration.marks) do
        local stop = mark[2] == -1 and #text or math.min(mark[2], #text)
        vim.api.nvim_buf_set_extmark(self.buf, ns, row_index, math.min(mark[1], #text),
          {end_col=stop, hl_group=mark[3]})
      end
      if decoration.line_hl then
        vim.api.nvim_buf_set_extmark(self.buf, ns, row_index, 0, {line_hl_group=decoration.line_hl})
      end
      if decoration.right then
        vim.api.nvim_buf_set_extmark(self.buf, ns, row_index, 0,
          {virt_text={decoration.right}, virt_text_pos='right_align'})
      end
    end
    if vim.api.nvim_win_is_valid(self.win) then
      vim.api.nvim_win_set_cursor(self.win, {math.min(index + HEADER_LINES, #lines), 0})
    end
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
