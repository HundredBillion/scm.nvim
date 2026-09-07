local baseline_cmdheight
local cycles = 0
local limit = 100
local expected_repo = vim.fs.normalize(assert(vim.uv.fs_realpath(vim.uv.cwd()), "resolve PTY repository root"))
local explorer_mapping
local mapping_used = false
local last_scm_generation = -1

local function fail(message)
  vim.api.nvim_err_writeln(message)
  vim.cmd("cquit 1")
end

local function source_count(source)
  return #Snacks.picker.get({ source = source })
end

local function expected_entry()
  local state = require("scm.panel").tab_state()
  for _, entry in ipairs(state.entries) do
    if entry.path == expected_repo then
      return entry, state
    end
  end
  return nil, state
end

local function scm_ready()
  if source_count("scm") ~= 1 or source_count("explorer") ~= 0 then
    return false
  end
  local entry, state = expected_entry()
  return not state.refreshing and state.generation > last_scm_generation and entry ~= nil
end

local function assert_layout(expected)
  assert(vim.o.cmdheight == baseline_cmdheight, ("cmdheight changed to %d"):format(vim.o.cmdheight))
  assert(source_count(expected) == 1, expected .. " is not the sole requested picker")
  local other = expected == "scm" and "explorer" or "scm"
  assert(source_count(other) == 0, other .. " overlaps " .. expected)
  local top = (vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)) and 1 or 0
  local bottom = vim.o.cmdheight + (vim.o.laststatus == 3 and 1 or 0)
  local expected_height = vim.o.lines - top - bottom
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      assert(vim.api.nvim_win_get_height(win) == expected_height, "normal window lost full vertical height")
    end
  end
  if expected == "scm" then
    local entry, state = expected_entry()
    assert(not state.refreshing, "SCM refresh is still running")
    assert(entry and entry.name == "svgtree.nvim", "SCM is missing the svgtree.nvim repository entry")
    local picker = Snacks.picker.get({ source = "scm" })[1]
    local rendered = false
    for _, item in ipairs(picker:items()) do
      if item.kind == "header" and item.entry.path == expected_repo then
        rendered = true
        break
      end
    end
    assert(rendered, "SCM picker did not render the svgtree.nvim repository header")
  end
end

local function wait_for(predicate, done, started)
  started = started or vim.uv.now()
  if predicate() then
    return done()
  end
  if vim.uv.now() - started >= 2000 then
    return fail("sidebar transition timed out")
  end
  vim.defer_fn(function()
    wait_for(predicate, done, started)
  end, 10)
end

local function open_explorer()
  if not mapping_used then
    mapping_used = true
    explorer_mapping()
    return
  end
  require("scm").handoff(function()
    Snacks.explorer({ cwd = vim.uv.cwd() })
  end)
end

local run_cycle
run_cycle = function()
  if cycles == limit then
    return vim.defer_fn(function()
      local ok, err = pcall(assert_layout, "scm")
      if not ok then
        return fail(err)
      end
      assert(mapping_used, "configured <leader>e mapping was not exercised")
      print(("OK sidebar handoff %d cycles"):format(limit))
      vim.cmd("qa!")
    end, 100)
  end
  open_explorer()
  wait_for(function()
    return source_count("explorer") == 1 and source_count("scm") == 0
  end, function()
    local ok, err = pcall(assert_layout, "explorer")
    if not ok then
      return fail(err)
    end
    require("scm").toggle()
    wait_for(scm_ready, function()
      local scm_ok, scm_err = pcall(assert_layout, "scm")
      if not scm_ok then
        return fail(scm_err)
      end
      last_scm_generation = require("scm.panel").tab_state().generation
      cycles = cycles + 1
      run_cycle()
    end)
  end)
end

vim.defer_fn(function()
  baseline_cmdheight = vim.o.cmdheight
  local mapping = vim.fn.maparg(vim.g.mapleader .. "e", "n", false, true)
  if type(mapping.callback) ~= "function" then
    return fail("configured <leader>e Lua callback is unavailable")
  end
  explorer_mapping = mapping.callback
  for _, source in ipairs({ "scm", "explorer" }) do
    for _, picker in ipairs(Snacks.picker.get({ source = source })) do
      picker:close()
    end
  end
  vim.schedule(run_cycle)
end, 500)
