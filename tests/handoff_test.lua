vim.opt.runtimepath:prepend(vim.uv.cwd())

local function eq(got, want, label)
  assert(vim.deep_equal(got, want), ("%s\nexpected: %s\ngot: %s"):format(label, vim.inspect(want), vim.inspect(got)))
end

local old_schedule = vim.schedule
local queue = {}
vim.schedule = function(fn)
  queue[#queue + 1] = fn
end

local ok, err = xpcall(function()
  package.loaded["scm.transition"] = nil
  local transition = require("scm.transition")
  local ran = {}
  local function flush()
    local fn = table.remove(queue, 1)
    assert(fn, "expected one scheduled transition flush")
    return pcall(fn)
  end

  transition.request(function()
    ran[#ran + 1] = "old"
  end)
  transition.request(function()
    ran[#ran + 1] = "latest"
  end)
  eq(#queue, 1, "many requests schedule one flush")
  assert(flush())
  eq(ran, { "latest" }, "only the latest request runs")

  transition.request(function()
    ran[#ran + 1] = "cancelled"
  end)
  transition.cancel()
  assert(flush())
  eq(ran, { "latest" }, "cancel clears the pending request")

  transition.request(function()
    error("open failed")
  end)
  local error_ok, open_err = flush()
  assert(not error_ok and tostring(open_err):find("open failed", 1, true), "open errors surface")
  transition.request(function()
    ran[#ran + 1] = "after-error"
  end)
  eq(#queue, 1, "an error leaves the coalescer schedulable")
  assert(flush())
  eq(ran, { "latest", "after-error" }, "a later request runs after an error")

  local origin_tab = vim.api.nvim_get_current_tabpage()
  local opened_in_tab
  transition.request(function()
    opened_in_tab = vim.api.nvim_get_current_tabpage()
  end)
  vim.cmd("tabnew")
  local live_tab = vim.api.nvim_get_current_tabpage()
  assert(flush())
  eq(opened_in_tab, origin_tab, "a live request opens in its originating tab")
  eq(vim.api.nvim_get_current_tabpage(), live_tab, "flushing an origin request preserves the current tab")
  vim.cmd("tabclose")

  vim.cmd("tabnew")
  transition.request(function()
    ran[#ran + 1] = "closed-tab"
  end)
  vim.cmd("tabclose")
  assert(flush())
  eq(ran, { "latest", "after-error" }, "a request for a closed tab is discarded")

  local panel = require("scm.panel")
  local scope = require("scm.scope")
  assert(require("scm").open == nil, "scm.open is not part of the public interface")
  local old_current = scope.current
  local old_open = panel.open
  local old_snacks = _G.Snacks
  local old_manager = package.loaded["neo-tree.sources.manager"]
  local old_command = package.loaded["neo-tree.command"]
  local old_svgtree = package.loaded["svgtree"]
  local panel_ok, panel_err = xpcall(function()
    local scm_closed, explorer_closed, neotree_closed, svgtree_closed = 0, 0, 0, 0
    local active_scm = { {
      close = function()
        scm_closed = scm_closed + 1
      end,
    } }
    local active_explorer = {}
    _G.Snacks = {
      picker = {
        get = function(opts)
          if opts.source == "scm" then
            return active_scm
          end
          if opts.source == "explorer" then
            return active_explorer
          end
          return {}
        end,
      },
    }

    transition.request(function()
      ran[#ran + 1] = "stale-before-failed-handoff"
    end)
    active_scm = { {
      close = function()
        error("Snacks close failed")
      end,
    } }
    local close_ok, close_err = pcall(panel.handoff, function()
      ran[#ran + 1] = "blocked-open"
    end)
    assert(not close_ok and tostring(close_err):find("Snacks close failed", 1, true), "Snacks close errors surface")
    assert(flush())
    eq(ran, { "latest", "after-error" }, "failed handoff cancels stale and requested opens")

    active_scm = { {
      close = function()
        scm_closed = scm_closed + 1
      end,
    } }
    local explorer_opened = 0
    panel.handoff(function()
      explorer_opened = explorer_opened + 1
    end)
    eq(scm_closed, 1, "handoff closes SCM synchronously")
    eq(explorer_opened, 0, "handoff defers Explorer open")
    assert(flush())
    eq(explorer_opened, 1, "handoff opens Explorer on the flush")

    active_scm = {}
    active_explorer = {
      {
        close = function()
          explorer_closed = explorer_closed + 1
        end,
        dir = function()
          return "/tmp"
        end,
        items = function()
          return {}
        end,
      },
    }
    package.loaded["svgtree"] = {
      close = function()
        svgtree_closed = svgtree_closed + 1
      end,
    }
    scope.current = function()
      return "/tmp"
    end
    local opened = {}
    panel.open = function(root)
      opened = { root }
    end
    package.loaded["neo-tree.sources.manager"] = {
      get_state = function()
        error("Neo-tree state unavailable")
      end,
    }
    package.loaded["neo-tree.command"] = {
      execute = function()
        error("Neo-tree close must not run after inspection failure")
      end,
    }
    transition.request(function()
      ran[#ran + 1] = "stale-before-inspection-failure"
    end)
    local inspect_ok, inspect_err = pcall(panel.toggle)
    assert(
      not inspect_ok and tostring(inspect_err):find("SCM handoff failed to inspect Neo-tree", 1, true),
      "Neo-tree inspection errors surface clearly"
    )
    assert(flush())
    eq(opened, {}, "failed Neo-tree inspection does not open SCM")
    eq(ran, { "latest", "after-error" }, "failed Neo-tree inspection cancels stale pending work")

    package.loaded["neo-tree.sources.manager"] = {
      get_state = function()
        return { winid = vim.api.nvim_get_current_win() }
      end,
    }
    local neotree_close_args
    package.loaded["neo-tree.command"] = {
      execute = function(args)
        neotree_close_args = args
        neotree_closed = neotree_closed + 1
      end,
    }
    panel.toggle()
    eq(neotree_close_args, { action = "close", source = "filesystem" }, "Neo-tree closes through the filesystem source")
    assert(flush())
    eq(opened, { "/tmp" }, "a later request works after Neo-tree inspection failure")

    opened = {}
    package.loaded["neo-tree.command"] = {
      execute = function()
        error("Neo-tree close failed")
      end,
    }
    transition.request(function()
      ran[#ran + 1] = "stale-before-failed-toggle"
    end)
    local neotree_ok, neotree_err = pcall(panel.toggle)
    assert(not neotree_ok and tostring(neotree_err):find("Neo-tree", 1, true), "Neo-tree close errors surface clearly")
    assert(flush())
    eq(opened, {}, "failed Neo-tree teardown does not open SCM")
    eq(ran, { "latest", "after-error" }, "failed toggle-on cancels its stale request")

    package.loaded["neo-tree.command"] = {
      execute = function()
        neotree_closed = neotree_closed + 1
      end,
    }
    local svgtree_win = vim.api.nvim_get_current_win()
    local previous_buf = vim.api.nvim_win_get_buf(svgtree_win)
    local svgtree_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[svgtree_buf].filetype = "svgtree"
    vim.api.nvim_win_set_buf(svgtree_win, svgtree_buf)
    vim.cmd("tabnew")
    panel.toggle()
    eq(
      { explorer_closed, neotree_closed, svgtree_closed },
      { 4, 2, 0 },
      "SCM in tab B does not close standalone svgtree in tab A"
    )
    eq(opened, {}, "SCM open waits for teardown")
    assert(flush())
    eq(opened, { "/tmp" }, "SCM opens with the captured Explorer scope")
    vim.cmd("tabclose")
    opened = {}
    package.loaded["svgtree"].close = function()
      error("SVGTree close failed")
    end
    local svgtree_ok, svgtree_err = pcall(panel.toggle)
    assert(not svgtree_ok and tostring(svgtree_err):find("SVGTree", 1, true), "SVGTree close errors surface clearly")
    eq(#queue, 0, "failed SVGTree teardown does not schedule SCM")
    eq(opened, {}, "failed SVGTree teardown does not open SCM")

    package.loaded["svgtree"].close = function()
      svgtree_closed = svgtree_closed + 1
    end
    panel.toggle()
    eq(svgtree_closed, 1, "SCM closes standalone svgtree in its current tab")
    assert(flush())
    eq(opened, { "/tmp" }, "a later request works after SVGTree teardown failure")
    vim.api.nvim_win_set_buf(svgtree_win, previous_buf)
    vim.api.nvim_buf_delete(svgtree_buf, { force = true })

    local explorer_root = "/tmp/child"
    scope.current = function()
      return explorer_root
    end
    panel.toggle()
    explorer_root = "/tmp"
    assert(flush())
    eq(opened, { "/tmp/child" }, "entering a directory is captured by the next SCM open")

    panel.toggle()
    assert(flush())
    eq(opened, { "/tmp" }, "going up is captured by the next SCM open")

    transition.request(function()
      opened = { "stale" }
    end)
    active_scm = { {
      close = function()
        scm_closed = scm_closed + 1
      end,
    } }
    panel.toggle()
    assert(flush())
    eq(opened, { "/tmp" }, "toggle-off cancels a pending open")
  end, debug.traceback)

  scope.current = old_current
  panel.open = old_open
  _G.Snacks = old_snacks
  package.loaded["neo-tree.sources.manager"] = old_manager
  package.loaded["neo-tree.command"] = old_command
  package.loaded["svgtree"] = old_svgtree
  assert(panel_ok, panel_err)
end, debug.traceback)

vim.schedule = old_schedule
assert(ok, err)
print("OK sidebar handoff")
