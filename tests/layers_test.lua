-- Headless test: run with `nvim -l tests/layers_test.lua` from the plugin root.
-- The Committed group in a list reads down the stack, from the UI to storage.
vim.opt.runtimepath:prepend(vim.uv.cwd())

local function eq(got, want, label)
  assert(
    vim.deep_equal(got, want),
    ("%s\nexpected: %s\ngot:      %s"):format(label or "mismatch", vim.inspect(want), vim.inspect(got))
  )
end

local layers = require("scm.layers")
local model = require("scm.model")

local function layer_of(path, stack)
  local index, test = layers.place(path, stack)
  local layer = (stack or layers.DEFAULT)[index]
  return (layer and layer.name or "other") .. (test and " test" or "")
end

-- Placing one file
eq(layer_of("src/components/Button.tsx"), "UI", "a component folder is UI")
eq(layer_of("src/App.tsx"), "UI", "a .tsx file in no Layer folder is UI by its extension")
eq(layer_of("app/views/users/index.html.erb"), "UI", "a Rails view is UI")
eq(layer_of("app/controllers/users_controller.rb"), "API", "a controller is API")
eq(layer_of("server/routes/users.ts"), "API", "a route is API")
eq(layer_of("app/services/billing.rb"), "Logic", "a service is Logic")
eq(layer_of("app/models/user.rb"), "Data", "a model is Data")
eq(layer_of("api/models/user.py"), "Data", "the deepest folder that names a Layer wins")
eq(layer_of("models/api/user.py"), "API", "the deepest folder wins either way round")
eq(layer_of("db/migrate/20240101_add_users.rb"), "DB", "a migration is DB")
eq(layer_of("api/queries/users.sql"), "DB", "a .sql file is DB wherever it is")
eq(layer_of("prisma/schema.prisma"), "DB", "a Prisma schema is DB")
eq(layer_of("src/components/schema.ts"), "DB", "a file named schema is DB")
eq(layer_of("README.md"), "other", "documentation is in no Layer")
eq(layer_of("package.json"), "other", "configuration is in no Layer")
eq(layer_of("Lib/Models/User.cs"), "Data", "folder names are compared in lower case")

-- Placing a test by the file it tests
eq(layer_of("spec/models/user_spec.rb"), "Data test", "a model spec follows the models")
eq(layer_of("src/components/Button.test.tsx"), "UI test", "a component test follows the UI")
eq(layer_of("src/components/__tests__/Button.tsx"), "UI test", "a __tests__ folder marks a test")
eq(layer_of("tests/api/test_users.py"), "API test", "a test_ prefix marks a test")
eq(layer_of("tests/core_test.lua"), "other test", "a test of nothing in a Layer is in no Layer")

-- Sorting: down the stack, each Layer's tests after its files, the rest last
local files = {
  { path = "README.md" },
  { path = "db/migrate/1_users.rb" },
  { path = "app/models/user.rb" },
  { path = "spec/models/user_spec.rb" },
  { path = "app/controllers/users_controller.rb" },
  { path = "app/views/users/show.html.erb" },
  { path = "app/views/users/index.html.erb" },
  { path = "app/services/signup.rb" },
}
local before = vim.deepcopy(files)
eq(vim.tbl_map(function(f) return f.path end, layers.sort(files)), {
  "app/views/users/index.html.erb",
  "app/views/users/show.html.erb",
  "app/controllers/users_controller.rb",
  "app/services/signup.rb",
  "app/models/user.rb",
  "spec/models/user_spec.rb",
  "db/migrate/1_users.rb",
  "README.md",
}, "UI to storage, by path within a Layer")
eq(files, before, "sorting leaves the list it was given as it was")

-- The order stops at the deepest Layer the branch touches
eq(vim.tbl_map(function(f) return f.path end, layers.sort({
  { path = "app/models/user.rb" }, { path = "app/views/home.erb" },
})), { "app/views/home.erb", "app/models/user.rb" }, "a branch that stops at Data ends with Data")

-- Your own Layers, for every repository or for one
local mine = { { name = "Screens", dirs = { "screens" } }, { name = "Store", dirs = { "store" } } }
eq(layer_of("src/store/cart.ts", mine), "Store", "a list of Layers replaces the defaults")
eq(layer_of("src/components/x.tsx", mine), "other", "the defaults are not mixed into your own")
local calls = 0
local pick = function(repo)
  calls = calls + 1
  return repo == "/r/mobile" and mine or nil
end
eq(layers.resolve(pick, "/r/mobile"), mine, "a function chooses the Layers of one repository")
eq(layers.resolve(pick, "/r/web"), layers.DEFAULT, "a function that returns nil keeps the defaults")
layers.resolve(pick, "/r/mobile")
eq(calls, 2, "a function is asked once per repository")

-- The Panel
local function shape(rows)
  local out = {}
  for _, r in ipairs(rows) do
    if r.kind == "file" or r.kind == "group" or r.kind == "note" then
      out[#out + 1] = r.kind .. " " .. (r.kind == "file" and r.path or r.label)
    end
  end
  return out
end
local entry = {
  name = "app", path = "/r/app", branch = "feat", files = {
    { path = "app/models/user.rb", commit_status = "M" },
    { path = "app/services/signup.rb", xy = ".M" },
    { path = "app/views/home.erb", commit_status = "A" },
    { path = "db/migrate/1.rb", commit_status = "A" },
    { path = "README.md", commit_status = "M" },
  },
}
eq(shape(model.rows({ entry }, {})), {
  "group Changes",
  "file app/services/signup.rb",
  "group Committed",
  "file app/views/home.erb",
  "file app/models/user.rb",
  "file db/migrate/1.rb",
  "file README.md",
}, "a list sorts Committed by Layer and leaves Changes by path")
eq(shape(model.rows({ entry }, { mode = "tree" })), {
  "group Changes",
  "file app/services/signup.rb",
  "group Committed",
  "file app/models/user.rb",
  "file app/views/home.erb",
  "file db/migrate/1.rb",
  "file README.md",
}, "a tree keeps its folders in path order")
eq(shape(model.rows({ entry }, { limit = 2 })), {
  "group Changes",
  "file app/services/signup.rb",
  "group Committed",
  "file app/views/home.erb",
  "file app/models/user.rb",
  "note 2 more not shown",
}, "the limit keeps the top of the stack")
eq(shape(model.rows({ entry }, { layers = function() return mine end })), {
  "group Changes",
  "file app/services/signup.rb",
  "group Committed",
  "file README.md",
  "file app/models/user.rb",
  "file app/views/home.erb",
  "file db/migrate/1.rb",
}, "the layers option reaches the Panel")

print("OK")
