-- scm.layers — places a file in a Layer of the tech stack, so the Committed
-- group can list a branch from the UI down to its storage. UI-free and pure:
-- it reads only paths, never the files.
local M = {}

-- The Layers from the top of the stack down. A file is placed by, in order:
--   files       Lua patterns on the file name. Checked first, in every Layer,
--               because a name such as schema.sql says more than its folder.
--   dirs        folder names. The deepest folder that names a Layer wins, so
--               api/models/user.py is data and not API.
--   extensions  the fallback when no name or folder decides.
-- Names and extensions are compared in lower case.
M.DEFAULT = {
  {
    name = "UI",
    dirs = {
      "components", "component", "pages", "views", "view", "screens", "layouts", "ui", "frontend",
      "client", "web", "public", "static", "styles", "assets", "templates", "widgets",
    },
    extensions = {
      "tsx", "jsx", "vue", "svelte", "astro", "css", "scss", "sass", "less", "html", "erb", "haml",
    },
  },
  {
    name = "API",
    dirs = {
      "api", "apis", "routes", "router", "routers", "controllers", "controller", "handlers",
      "endpoints", "resolvers", "graphql", "middleware", "rpc",
    },
  },
  {
    name = "Logic",
    dirs = { "services", "service", "domain", "lib", "core", "usecases", "use_cases", "logic", "jobs", "workers" },
  },
  {
    name = "Data",
    dirs = {
      "models", "model", "entities", "repositories", "repository", "dao", "store", "stores",
      "persistence", "data",
    },
  },
  {
    name = "DB",
    dirs = { "migrations", "migration", "migrate", "db", "database", "sql", "prisma", "seeds" },
    files = { "%.sql$", "^schema%.", "%.prisma$" },
    extensions = { "sql", "prisma" },
  },
}

-- Folders that hold tests, and file names that mark one.
local TEST_DIRS = { test = true, tests = true, spec = true, specs = true, __tests__ = true, e2e = true }
local TEST_NAMES = {
  { "[._-]test(%.[^.]+)$", "%1" }, { "[._-]spec(%.[^.]+)$", "%1" }, { "^test_", "" },
}

-- Lookup tables for one list of Layers, built once per list.
local compiled = setmetatable({}, { __mode = "k" })
local function compile(layers)
  local c = compiled[layers]
  if c then
    return c
  end
  c = { dirs = {}, exts = {}, files = {}, ranks = {} }
  for i, layer in ipairs(layers) do
    for _, d in ipairs(layer.dirs or {}) do
      c.dirs[d:lower()] = c.dirs[d:lower()] or i
    end
    for _, x in ipairs(layer.extensions or {}) do
      c.exts[x:lower()] = c.exts[x:lower()] or i
    end
    for _, p in ipairs(layer.files or {}) do
      c.files[#c.files + 1] = { pattern = p, layer = i }
    end
  end
  c.other = #layers + 1
  compiled[layers] = c
  return c
end

-- The Layer index of a path that is not a test, or nil.
local function place(c, dirs, name)
  local lower = name:lower()
  for _, f in ipairs(c.files) do
    if lower:find(f.pattern) then
      return f.layer
    end
  end
  for i = #dirs, 1, -1 do
    local layer = c.dirs[dirs[i]:lower()]
    if layer then
      return layer
    end
  end
  local ext = lower:match("%.([^.]+)$")
  return ext and c.exts[ext]
end

-- Where a path sorts: the index of its Layer and whether it is a test. A test
-- is placed by the file it tests, with its test folders and markers left out,
-- and sorts just after that Layer's own files. A file in no Layer, test or
-- not, gets #layers + 1 and is listed last.
function M.place(path, layers)
  local dirs = {}
  for part in path:gmatch("[^/]+") do
    dirs[#dirs + 1] = part
  end
  local name = table.remove(dirs) or path
  local c = compile(layers or M.DEFAULT)
  local test = false
  local kept = {}
  for _, d in ipairs(dirs) do
    if TEST_DIRS[d:lower()] then
      test = true
    else
      kept[#kept + 1] = d
    end
  end
  local bare = name
  for _, marker in ipairs(TEST_NAMES) do
    local stripped, n = bare:gsub(marker[1], marker[2])
    if n > 0 then
      test, bare = true, stripped
    end
  end
  return place(c, kept, bare) or c.other, test
end

-- A number that orders paths by Layer, each Layer's tests after its files.
-- Remembered per list of Layers: a branch can hold tens of thousands of files.
function M.rank(path, layers)
  local c = compile(layers or M.DEFAULT)
  local rank = c.ranks[path]
  if not rank then
    local layer, test = M.place(path, layers)
    rank = layer * 2 + ((test and layer < c.other) and 1 or 0)
    c.ranks[path] = rank
  end
  return rank
end

-- The Layers for one repository. `option` is the `layers` setup option: nil
-- for the defaults, a list of Layers, or a function given the repository's
-- path that returns a list, or nil for the defaults.
-- A function is asked once per repository, so every redraw sorts by the same
-- list and reuses the order worked out for it.
local asked = setmetatable({}, { __mode = "k" })
function M.resolve(option, repo)
  if type(option) ~= "function" then
    return option or M.DEFAULT
  end
  local answers = asked[option]
  if not answers then
    answers = {}
    asked[option] = answers
  end
  if answers[repo] == nil then
    answers[repo] = option(repo) or M.DEFAULT
  end
  return answers[repo]
end

-- Files sorted top of the stack down; within a Layer, by path. A new list:
-- `files` is not changed.
function M.sort(files, layers)
  layers = layers or M.DEFAULT
  local sorted = {}
  for i = 1, #files do
    sorted[i] = files[i]
  end
  table.sort(sorted, function(a, b)
    local ra, rb = M.rank(a.path, layers), M.rank(b.path, layers)
    if ra ~= rb then
      return ra < rb
    end
    return a.path < b.path
  end)
  return sorted
end

return M
