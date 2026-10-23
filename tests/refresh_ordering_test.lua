-- Refresh ordering rules shared by every Renderer, exercised through scm.refresh.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local refresh = require("scm.refresh")

local function eq(got, want, label)
  assert(
    vim.deep_equal(got, want),
    ("%s\nexpected: %s\ngot:      %s"):format(label or "mismatch", vim.inspect(want), vim.inspect(got))
  )
end

-- A fake Core: runs stay pending until the test finishes them.
local function harness()
  local h = { runs = {}, delivered = {}, alive = true, owner = {} }
  h.hooks = {
    start = function(request, done)
      h.runs[#h.runs + 1] = { request = request, done = done }
    end,
    deliver = function(entries, err)
      h.delivered[#h.delivered + 1] = { entries = entries, err = err }
    end,
    alive = function()
      return h.alive
    end,
  }
  h.request = function(request)
    return refresh.request(h.owner, request, h.hooks)
  end
  return h
end

local function save(path)
  return { cached = true, paths = { [path] = true } }
end

-- Burst coalescing: one run at a time; requests made meanwhile merge into one re-run.
local h = harness()
assert(h.request(save("/a")), "first request starts a run")
assert(not h.request(save("/b")), "request during a run is queued")
assert(not h.request(save("/c")), "second request during a run is queued")
eq(#h.runs, 1, "a burst never stacks Core runs")
eq(h.runs[1].request, save("/a"), "first run carries its own request")

-- Stale rejection plus re-run: the superseded result is dropped and one merged re-run starts.
h.runs[1].done({ { path = "/stale" } }, nil)
eq(h.delivered, {}, "a result superseded by a newer request is not delivered")
eq(#h.runs, 2, "queued requests re-run once after the in-flight run lands")
eq(h.runs[2].request, { cached = true, paths = { ["/b"] = true, ["/c"] = true } }, "re-run merges queued requests")
h.runs[2].done({ { path = "/fresh" } }, nil)
eq(h.delivered, { { entries = { { path = "/fresh" } } } }, "the newest result is delivered")
eq(#h.runs, 2, "nothing queued means no further run")

-- A full request absorbs targeted ones; an omitted request means full discovery.
assert(h.request(nil), "idle request starts immediately")
eq(h.runs[3].request, { cached = false }, "omitted request is a full refresh")
assert(not h.request(save("/d")), "targeted request queues behind the full run")
assert(not h.request(nil), "full request queues too")
h.runs[3].done({}, nil)
eq(h.runs[4].request, { cached = false }, "full request absorbs queued targeted requests")
h.runs[4].done({}, nil)

-- Error delivery: errors reach the renderer and leave the coordinator usable.
h = harness()
h.request(nil)
h.runs[1].done(nil, "repository discovery failed")
eq(h.delivered, { { entries = nil, err = "repository discovery failed" } }, "errors are delivered")
assert(h.request(nil), "a failed run does not leave the coordinator busy")
h.runs[2].done({ { path = "/ok" } }, nil)
eq(h.delivered[2], { entries = { { path = "/ok" } } }, "a run after an error delivers normally")

-- A stale error is rejected like a stale success.
h = harness()
h.request(nil)
h.request(save("/x"))
h.runs[1].done(nil, "old failure")
eq(h.delivered, {}, "a superseded error is not delivered")
h.runs[2].done({}, nil)
eq(h.delivered, { { entries = {} } }, "the replacement result is delivered")

-- Reset: the in-flight result is rejected and queued requests are dropped.
h = harness()
h.request(nil)
h.request(save("/old-root"))
refresh.reset(h.owner)
h.runs[1].done({ { path = "/old" } }, nil)
eq(h.delivered, {}, "reset rejects the in-flight result")
eq(#h.runs, 1, "reset drops queued requests")
assert(h.request(nil), "a request after reset starts")

-- A dead owner (closed view or tab) neither receives results nor re-runs.
h = harness()
h.request(nil)
h.request(save("/late"))
h.alive = false
h.runs[1].done({ { path = "/gone" } }, nil)
eq(h.delivered, {}, "a closed owner receives nothing")
eq(#h.runs, 1, "a closed owner does not re-run")

-- Progress: partial results of the newest run reach the renderer; older runs' never do.
h = harness()
h.progressed = {}
h.hooks.progress = function(entries)
  h.progressed[#h.progressed + 1] = entries
end
h.hooks.start = function(request, done, progress)
  h.runs[#h.runs + 1] = { request = request, done = done, progress = progress }
end
h.request(nil)
h.runs[1].progress({ { path = "/first" } })
eq(h.progressed, { { { path = "/first" } } }, "the current run's progress is rendered")
h.request(save("/newer"))
h.runs[1].progress({ { path = "/superseded" } })
eq(#h.progressed, 1, "a superseded run's progress is not rendered")
h.runs[1].done({}, nil)
h.runs[2].progress({ { path = "/rerun" } })
eq(h.progressed[2], { { path = "/rerun" } }, "the re-run's progress is rendered")
refresh.reset(h.owner)
h.runs[2].progress({ { path = "/old-root" } })
eq(#h.progressed, 2, "progress after a reset is not rendered")
h.runs[2].done({}, nil)
h.request(nil)
h.alive = false
h.runs[3].progress({ { path = "/gone" } })
eq(#h.progressed, 2, "a closed owner receives no progress")

-- A renderer without a progress hook is unaffected by Core's progress calls.
h = harness()
h.hooks.start = function(request, done, progress)
  progress({ { path = "/partial" } })
  done({ { path = "/all" } }, nil)
end
h.request(nil)
eq(h.delivered, { { entries = { { path = "/all" } } } }, "progress without a hook is ignored")

print("OK refresh ordering")
