-- Shared event batching for the Panel.
-- Save bursts retain every affected path; focus and explicit refresh requests cover the whole scope.
local M = {}

function M.merge(previous, request)
  if not previous then return request end
  if not previous.cached or not request.cached then return {cached=false} end
  if not previous.paths or not request.paths then return {cached=true} end
  local paths = vim.tbl_extend("force", previous.paths, request.paths)
  return {cached=true, paths=paths}
end

-- Refresh ordering for every Renderer. Each owner (a view or tab state) runs at
-- most one Core refresh at a time. Requests made meanwhile merge into one re-run
-- when the run lands, and only the newest request's result is delivered, so a
-- slow older run can never overwrite newer Repo Entries. State lives on the
-- owner: generation, refreshing and queued_request.
--   hooks.start(request, done, progress)  begin one run and call done(entries, err) once,
--                               and progress(entries) for partial results before it
--   hooks.deliver(entries, err) publish the newest result; entries is nil on error
--   hooks.progress(entries)     optional; render a partial result of the newest run
--   hooks.alive()               optional; false drops the result and any re-run
local function run(owner)
  local hooks, request, generation = owner.refresh_hooks, owner.queued_request, owner.generation
  owner.queued_request, owner.refreshing = nil, true
  local function current()
    return generation == owner.generation and not (hooks.alive and not hooks.alive())
  end
  hooks.start(request, function(entries, err)
    owner.refreshing = false
    if hooks.alive and not hooks.alive() then return end
    if generation == owner.generation then hooks.deliver(entries, err) end
    if owner.queued_request then run(owner) end
  end, function(entries)
    if hooks.progress and current() then hooks.progress(entries) end
  end)
end

-- Returns true when the run starts now, false when it waits for the one in flight.
-- An omitted request means full discovery.
function M.request(owner, request, hooks)
  owner.refresh_hooks = hooks
  owner.queued_request = M.merge(owner.queued_request, request or {cached=false})
  owner.generation = (owner.generation or 0) + 1
  if owner.refreshing then return false end
  run(owner)
  return true
end

-- Forget queued requests and reject the result of the run in flight, for when
-- what the owner shows changes (a different Working Directory).
function M.reset(owner)
  owner.generation = (owner.generation or 0) + 1
  owner.queued_request = nil
end

function M.event(owner, options, request, callback)
  owner.pending_event = M.merge(owner.pending_event, request)
  if owner.event_scheduled then return end
  owner.event_scheduled = true
  vim.defer_fn(function()
    local pending = owner.pending_event
    owner.pending_event, owner.event_scheduled = nil, false
    callback(pending)
  end, options.repo_debounce_ms or 150)
end

-- Warm-up for every renderer: once startup is over, scan the root SCM would open on.
-- Deferred so a Panel opened in the same tick (a lazy load on the key) starts first and the
-- warm-up then skips its root.
function M.warm(options)
  if options.warm == false then return end
  local function run()
    local root = require("scm.scope").candidate()
    if root then require("scm.core").warm(root, options) end
  end
  if vim.v.vim_did_enter == 1 then
    vim.defer_fn(run, 0)
  else
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = function() vim.defer_fn(run, 0) end })
  end
end

return M
