-- scm.review.admin — the admin page: which services explain changes, which
-- one is in use, and connecting another. Opened with :ScmExplainers, or \s
-- in a diff.
local Explainers = require('scm.review.explainers')
local M = {}
local ns = vim.api.nvim_create_namespace('scm.review.admin')

local page  -- {win, buf, rows = {[line] = service name}, note}

local function summary(service)
  local kind = Explainers.KINDS[service.kind]
  local parts = {kind.label}
  for _, field in ipairs({'command', 'url', 'model'}) do
    if service[field] then parts[#parts + 1] = service[field] end
  end
  if service.key_env then parts[#parts + 1] = 'key in $' .. service.key_env
  elseif service.key_cmd then parts[#parts + 1] = 'key from a command' end
  if service.fixed then parts[#parts + 1] = 'set in your configuration' end
  return table.concat(parts, ' · ')
end

local function draw()
  if not (page and vim.api.nvim_buf_is_valid(page.buf)) then return end
  local active = Explainers.active()
  local lines, marks, rows = {'', '  Changes are explained by:', ''}, {{1, 'ScmReviewFloatTitle'}}, {}
  local widest = 0
  for _, service in ipairs(Explainers.list()) do widest = math.max(widest, vim.fn.strdisplaywidth(service.name)) end
  for _, service in ipairs(Explainers.list()) do
    local chosen = active and service.name == active.name
    lines[#lines + 1] = ('  %s %s%s   %s'):format(chosen and '●' or '○', service.name,
      (' '):rep(widest - vim.fn.strdisplaywidth(service.name)), summary(service))
    rows[#lines] = service.name
    if chosen then marks[#marks + 1] = {#lines - 1, 'ScmReviewHere'} end
  end
  vim.list_extend(lines, {'', '  Enter use   a add   e edit   d remove   t test   q close', ''})
  marks[#marks + 1] = {#lines - 2, 'ScmReviewHintKey'}
  -- The page may be narrower than this sentence.
  local room = vim.api.nvim_win_is_valid(page.win) and vim.api.nvim_win_get_width(page.win) - 4 or 72
  for _, text in ipairs(require('scm.review.rail').wrap('A key is never kept here. A service names the environment '
    .. 'variable that holds its key, or a command that prints it. The change you are reading is sent to the '
    .. 'service in use when you ask for it to be explained.', room)) do
    lines[#lines + 1] = '  ' .. text
  end
  if page.note then
    vim.list_extend(lines, {'', '  ' .. page.note})
    marks[#marks + 1] = {#lines - 1, page.failed and 'ScmReviewBarError' or 'ScmReviewLater'}
  end
  lines[#lines + 1] = ''
  page.rows = rows
  vim.bo[page.buf].modifiable = true
  vim.api.nvim_buf_set_lines(page.buf, 0, -1, false, lines)
  vim.bo[page.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(page.buf, ns, 0, -1)
  for _, mark in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(page.buf, ns, mark[1], 0, {end_row=mark[1] + 1, hl_group=mark[2], hl_eol=false,
      strict=false})
  end
  if vim.api.nvim_win_is_valid(page.win) then
    pcall(vim.api.nvim_win_set_height, page.win, math.min(#lines, vim.o.lines - 6))
  end
end

local function say(text, failed)
  if not page then return end
  page.note, page.failed = text, failed
  draw()
end

local function selected()
  if not (page and vim.api.nvim_win_is_valid(page.win)) then return nil end
  local name = page.rows[vim.api.nvim_win_get_cursor(page.win)[1]]
  return name and Explainers.get(name)
end

-- Ask for each field of `service` in turn, then done(service), or nothing
-- when the reader gives up.
local function fill(service, done)
  local kind = Explainers.KINDS[service.kind]
  local function ask(at)
    local field = kind.fields[at]
    if not field then done(service); return end
    vim.ui.input({prompt=('%s (%s): '):format(field, Explainers.FIELD_HELP[field]),
      default=service[field] or kind.defaults[field] or ''}, function(value)
      if value == nil then return end
      service[field] = vim.trim(value) ~= '' and vim.trim(value) or nil
      ask(at + 1)
    end)
  end
  ask(1)
end

local function saved(service)
  local kept, why = Explainers.put(service)
  if kept then say(('Saved "%s".'):format(kept.name)) else say(why, true) end
end

function M.add()
  local labels = {}
  for _, kind in ipairs(Explainers.KIND_ORDER) do labels[#labels + 1] = Explainers.KINDS[kind].label end
  vim.ui.select(labels, {prompt='What kind of service?'}, function(_, index)
    if not index then return end
    local kind = Explainers.KIND_ORDER[index]
    vim.ui.input({prompt='A name for it: '}, function(name)
      name = name and vim.trim(name) or ''
      if name == '' then return end
      if Explainers.get(name) then say(('There is already a service named "%s".'):format(name), true); return end
      fill({name=name, kind=kind}, saved)
    end)
  end)
end

function M.edit()
  local service = selected()
  if not service then return end
  if service.fixed then say('This service is set in your Neovim configuration.', true); return end
  fill(vim.deepcopy(service), saved)
end

function M.remove()
  local service = selected()
  if not service then return end
  local ok, why = Explainers.remove(service.name)
  if ok then say(('Removed "%s".'):format(service.name)) else say(why or 'There is no such service.', true) end
end

function M.use()
  local service = selected()
  if not service then return end
  Explainers.use(service.name)
  say(('Changes are now explained by "%s".'):format(service.name))
  require('scm.review').sync()
end

function M.test()
  local service = selected()
  if not service then return end
  say(('Asking "%s" to answer…'):format(service.name))
  Explainers.test(service, function(err)
    if err then say(('"%s" did not answer: %s'):format(service.name, err), true)
    else say(('"%s" answered.'):format(service.name)) end
  end)
end

-- Open the page. closed(), when given, runs once it is closed.
function M.open(closed)
  if page and vim.api.nvim_win_is_valid(page.win) then
    vim.api.nvim_set_current_win(page.win)
    if closed then closed() end
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  local width = math.min(92, vim.o.columns - 6)
  local win = vim.api.nvim_open_win(buf, true, {relative='editor', width=width, height=12,
    row=math.max(1, math.floor(vim.o.lines / 2) - 9), col=math.floor((vim.o.columns - width) / 2),
    style='minimal', border='rounded', title=' SCM · Explainers ', title_pos='left'})
  vim.wo[win].winhighlight = 'Normal:ScmReviewFloat,FloatBorder:ScmReviewFloat,FloatTitle:ScmReviewFloatTitle'
  vim.wo[win].cursorline = true
  page = {win=win, buf=buf, rows={}}
  local function close() pcall(vim.api.nvim_win_close, win, true) end
  for key, run in pairs({['<CR>']=M.use, a=M.add, e=M.edit, d=M.remove, t=M.test, q=close, ['<Esc>']=close}) do
    vim.keymap.set('n', key, run, {buffer=buf, nowait=true})
  end
  vim.api.nvim_create_autocmd('BufWipeout', {buffer=buf, once=true, callback=function()
    page = nil
    if closed then vim.schedule(closed) end
  end})
  draw()
  -- Start on the service in use.
  local active = Explainers.active()
  for line, name in pairs(page.rows) do
    if active and name == active.name then vim.api.nvim_win_set_cursor(win, {line, 0}) end
  end
end

return M
