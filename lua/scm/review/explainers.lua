-- scm.review.explainers — the Explainers: the language model services that
-- write Reviews, which one is in use, and how each is asked. Claude Code,
-- run on this machine, is the one SCM starts with; any other service can be
-- added. A key is never kept here: a service names the environment variable
-- that holds it, or a command that prints it.
local M = {}

-- The kinds of service, and what each needs to be told.
M.KINDS = {
  claude_code={label='Claude Code on this machine', fields={'command', 'model'},
    defaults={command='claude'}},
  anthropic={label='Claude API', fields={'model', 'key_env', 'key_cmd', 'url'},
    defaults={model='claude-opus-5-5', key_env='ANTHROPIC_API_KEY', url='https://api.anthropic.com'}},
  openai={label='OpenAI-compatible API', fields={'url', 'model', 'key_env', 'key_cmd'},
    defaults={url='https://api.openai.com/v1', key_env='OPENAI_API_KEY'}},
  command={label='A command of your own', fields={'command'}, defaults={}},
}
M.KIND_ORDER = {'claude_code', 'anthropic', 'openai', 'command'}
M.FIELD_HELP = {
  command='the command to run; the question is sent to its standard input',
  model='the model to ask (blank for the service\'s own default)',
  url='where the service answers',
  key_env='the environment variable that holds the key',
  key_cmd='a command that prints the key, used when the variable is not set',
}
local DEFAULT = {name='Claude Code', kind='claude_code', command='claude'}
-- How long an Explainer may take to answer, in milliseconds.
M.TIMEOUT = 300000

local state  -- {active = name, services = {...}}, read once
local configured  -- what setup() was given

local function path()
  return vim.fs.joinpath(vim.fn.stdpath('data'), 'scm', 'explainers.json')
end

local function valid(service)
  return type(service) == 'table' and type(service.name) == 'string' and service.name ~= ''
    and M.KINDS[service.kind] ~= nil
end

local function load()
  if state then return state end
  state = {services={}}
  local file = io.open(path(), 'r')
  if file then
    local ok, saved = pcall(vim.json.decode, file:read('*a'))
    file:close()
    if ok and type(saved) == 'table' then
      for _, service in ipairs(type(saved.services) == 'table' and saved.services or {}) do
        if valid(service) then state.services[#state.services + 1] = service end
      end
      state.active = type(saved.active) == 'string' and saved.active or nil
    end
  end
  -- Services named in setup() come first and cannot be changed from the admin page.
  local seen = {}
  local merged = {}
  for _, service in ipairs(configured and configured.services or {}) do
    if valid(service) and not seen[service.name] then
      seen[service.name] = true
      merged[#merged + 1] = vim.tbl_extend('force', service, {fixed=true})
    end
  end
  for _, service in ipairs(state.services) do
    if not seen[service.name] then
      seen[service.name] = true
      merged[#merged + 1] = service
    end
  end
  if not seen[DEFAULT.name] then table.insert(merged, 1, vim.deepcopy(DEFAULT)) end
  state.services = merged
  state.active = state.active or (configured and configured.use) or DEFAULT.name
  if not M.get(state.active) then state.active = merged[1].name end
  return state
end

local function save()
  local keep = {}
  for _, service in ipairs(state.services) do
    if not service.fixed then keep[#keep + 1] = service end
  end
  vim.fn.mkdir(vim.fs.dirname(path()), 'p')
  local file = assert(io.open(path(), 'w'))
  file:write(vim.json.encode({active=state.active, services=keep}))
  file:close()
end

-- Take the Explainers named in setup(): {use = name, services = {...}}.
function M.setup(opts)
  configured, state = opts or {}, nil
end

function M.list() return load().services end

function M.get(name)
  for _, service in ipairs(load().services) do
    if service.name == name then return service end
  end
end

-- The Explainer in use.
function M.active() return M.get(load().active) end

function M.use(name)
  if not M.get(name) then return false end
  state.active = name
  save()
  return true
end

-- Add a service, or change the one of that name. Returns nil and why when it cannot be.
function M.put(service)
  if not valid(service) then return nil, 'a service needs a name and a kind' end
  local known = M.get(service.name)
  if known and known.fixed then return nil, 'this service is set in your Neovim configuration' end
  local kept = {name=service.name, kind=service.kind}
  for _, field in ipairs(M.KINDS[service.kind].fields) do
    local value = service[field]
    if type(value) == 'string' and vim.trim(value) ~= '' then kept[field] = vim.trim(value) end
  end
  if known then
    for i, other in ipairs(state.services) do
      if other.name == kept.name then state.services[i] = kept end
    end
  else
    state.services[#state.services + 1] = kept
  end
  save()
  return kept
end

function M.remove(name)
  local known = M.get(name)
  if not known then return false end
  if known.fixed then return nil, 'this service is set in your Neovim configuration' end
  if #state.services == 1 then return nil, 'at least one service is kept' end
  for i, other in ipairs(state.services) do
    if other.name == name then table.remove(state.services, i); break end
  end
  if state.active == name then state.active = state.services[1].name end
  save()
  return true
end

-- The key a service uses, or nil and why there is none.
local function key_of(service, cb)
  local from_env = service.key_env and vim.env[service.key_env]
  if from_env and from_env ~= '' then cb((vim.trim(from_env):match('^[^\r\n]*'))); return end
  if not service.key_cmd then
    cb(nil, service.key_env and ('the environment variable ' .. service.key_env .. ' is not set') or nil)
    return
  end
  vim.system({vim.o.shell, vim.o.shellcmdflag, service.key_cmd}, {text=true, timeout=15000}, function(out)
    vim.schedule(function()
      -- A key is one line: a password manager may print notes after it.
      local key = out.code == 0 and vim.trim((vim.trim(out.stdout or ''):match('^[^\r\n]*') or '')) or ''
      if key == '' then cb(nil, 'the key command printed no key') else cb(key) end
    end)
  end)
end

local function shorten(text)
  text = vim.trim((text or ''):gsub('%s+', ' '))
  return #text > 300 and (text:sub(1, 300) .. '…') or text
end

-- Run `argv` with `input` on its standard input; cb(err, stdout).
local function run(argv, input, cwd, cb)
  local ok, process = pcall(vim.system, argv, {text=true, stdin=input, cwd=cwd, timeout=M.TIMEOUT}, function(out)
    vim.schedule(function()
      if out.code == 124 or out.signal == 15 and out.code ~= 0 then cb('it took too long to answer')
      elseif out.code ~= 0 then cb(shorten(out.stderr ~= '' and out.stderr or out.stdout) or ('exit ' .. out.code))
      else cb(nil, out.stdout or '') end
    end)
  end)
  if not ok then
    vim.schedule(function() cb('could not start ' .. argv[1] .. ': is it installed?') end)
    return nil
  end
  return process
end

-- Send a JSON body to `url` with curl. The headers, which hold the key, go
-- through curl's standard input and the body through a file only this user
-- can read, so neither shows in the list of running programs.
local function post(url, headers, body, cb)
  local file = vim.fn.tempname()
  local handle = assert(io.open(file, 'w'))
  handle:write(vim.json.encode(body))
  handle:close()
  vim.uv.fs_chmod(file, 384)
  -- One value of curl's configuration: a line break in it would start another option.
  local function quoted(value)
    return '"' .. value:gsub('%c', ''):gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
  end
  local config = {'url = ' .. quoted(url), 'silent', 'show-error', 'data-binary = ' .. quoted('@' .. file),
    'header = "content-type: application/json"'}
  for _, header in ipairs(headers) do config[#config + 1] = 'header = ' .. quoted(header) end
  return run({'curl', '--config', '-'}, table.concat(config, '\n') .. '\n', nil, function(err, out)
    vim.uv.fs_unlink(file)
    if err then cb(err); return end
    local ok, reply = pcall(vim.json.decode, out, {luanil={object=true, array=true}})
    if not ok or type(reply) ~= 'table' then cb('the service did not answer in JSON: ' .. shorten(out)); return end
    if reply.error then
      local message = type(reply.error) == 'table' and reply.error.message or reply.error
      cb(shorten(tostring(message)))
      return
    end
    cb(nil, reply)
  end)
end

local ASK = {}
-- Each way of asking is given `job`, and puts the process it starts in
-- job.process so the question can be taken back.

-- Claude Code reads the repository itself, with tools that only read.
function ASK.claude_code(service, prompt, opts, cb, job)
  local argv = vim.split(service.command or 'claude', '%s+', {trimempty=true})
  -- The repository being read may not be the reader's own, so nothing in it
  -- configures Claude Code: its settings, with any hooks, and its MCP
  -- servers are left out, and the only tools are ones that read.
  vim.list_extend(argv, {'-p', '--output-format', 'json', '--tools', 'Read,Grep,Glob', '--no-session-persistence',
    '--setting-sources', 'user', '--strict-mcp-config'})
  if service.model then vim.list_extend(argv, {'--model', service.model}) end
  job.process = run(argv, prompt, opts.cwd, function(err, out)
    if err then cb(err); return end
    local ok, reply = pcall(vim.json.decode, out, {luanil={object=true, array=true}})
    if not ok or type(reply) ~= 'table' then cb(nil, out); return end
    if reply.is_error then cb(shorten(tostring(reply.result or 'Claude Code reported an error'))); return end
    cb(nil, type(reply.result) == 'string' and reply.result or out)
  end)
end

function ASK.anthropic(service, prompt, _, cb, job)
  key_of(service, function(key, why)
    if job.cancelled then return end
    if not key then cb(why or 'this service has no key'); return end
    local body = {model=service.model or M.KINDS.anthropic.defaults.model, max_tokens=16000,
      -- A request the model declines is tried once more on another model.
      fallbacks='default', messages={{role='user', content=prompt}}}
    job.process = post((service.url or M.KINDS.anthropic.defaults.url):gsub('/+$', '') .. '/v1/messages',
      {'x-api-key: ' .. key, 'anthropic-version: 2026-10-21', 'anthropic-beta: server-side-fallback-2026-07-01'},
      body, function(err, reply)
        if err then cb(err); return end
        if reply.stop_reason == 'refusal' then cb('the model declined to explain this change'); return end
        local parts = {}
        for _, block in ipairs(type(reply.content) == 'table' and reply.content or {}) do
          if type(block) == 'table' and block.type == 'text' then parts[#parts + 1] = block.text end
        end
        if #parts == 0 then cb('the service sent no text') else cb(nil, table.concat(parts)) end
      end)
  end)
end

function ASK.openai(service, prompt, _, cb, job)
  if not service.model then cb('this service needs a model'); return end
  key_of(service, function(key, why)
    if job.cancelled then return end
    -- A service on this machine may need no key at all.
    if not key and why and service.key_cmd then cb(why); return end
    local headers = key and {'authorization: Bearer ' .. key} or {}
    job.process = post((service.url or M.KINDS.openai.defaults.url):gsub('/+$', '') .. '/chat/completions', headers,
      {model=service.model, messages={{role='user', content=prompt}}}, function(err, reply)
        if err then cb(err); return end
        local choice = type(reply.choices) == 'table' and reply.choices[1]
        local text = type(choice) == 'table' and type(choice.message) == 'table' and choice.message.content
        if type(text) ~= 'string' or text == '' then cb('the service sent no text') else cb(nil, text) end
      end)
  end)
end

function ASK.command(service, prompt, opts, cb, job)
  if not service.command then cb('this service needs a command'); return end
  job.process = run({vim.o.shell, vim.o.shellcmdflag, service.command}, prompt, opts.cwd, cb)
end

-- Ask `service` the question in `prompt`. `opts.cwd` is the repository the
-- question is about. cb(err, answer), once, on the main loop. Returns a
-- function that takes the question back: the service is stopped and cb is
-- never called.
function M.ask(service, prompt, opts, cb)
  local ask = service and ASK[service.kind]
  if not ask then vim.schedule(function() cb('no such service') end); return function() end end
  local job = {}
  ask(service, prompt, opts or {}, function(err, answer)
    if not job.cancelled then cb(err, answer) end
  end, job)
  return function()
    job.cancelled = true
    if job.process then pcall(job.process.kill, job.process, 15) end
  end
end

-- Check that `service` answers at all. cb(err).
function M.test(service, cb)
  M.ask(service, 'Reply with the single word: ready', {cwd=vim.uv.cwd()}, function(err, answer)
    if err then cb(err)
    elseif not answer or vim.trim(answer) == '' then cb('it answered with nothing')
    else cb(nil) end
  end)
end

return M
