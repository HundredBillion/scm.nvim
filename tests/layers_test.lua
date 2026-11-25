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
  local list = stack or layers.DEFAULT
  local layer = list[index]
  local name = layer and layer.name or (index == #list + 1 and "code" or "outside")
  return name .. (test and " test" or "")
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
eq(layer_of("README.md"), "outside", "documentation is outside the stack")
eq(layer_of("package.json"), "outside", "configuration is outside the stack")
eq(layer_of(".gitattributes"), "outside", "a dotfile is outside the stack")
eq(layer_of("Cargo.lock"), "outside", "a lockfile is outside the stack")
eq(layer_of(".github/workflows/ci.yml"), "outside", "CI is outside the stack")
eq(layer_of("docs/api/routes.md"), "outside", "a document is outside the stack whatever its folders say")
eq(layer_of("scripts/release.py"), "outside", "a build script is outside the stack")
eq(layer_of("packaging/windows/shim.rs"), "outside", "packaging is outside the stack")
eq(layer_of("crates/app/build.rs"), "outside", "a Cargo build script is outside the stack")
eq(layer_of("vite.config.ts"), "outside", "tool configuration is outside the stack")
eq(layer_of("lua/scm/core.lua"), "Logic", "code no Layer places joins Logic")
eq(layer_of("crates/term/src/session.rs"), "Logic", "Rust code no folder places joins Logic")
eq(layer_of("crates/app/src/terminal_view/input.rs"), "UI", "a folder is matched by its last word")
eq(layer_of("crates/term/src/pty/unix.rs"), "System", "a pty is System")
eq(layer_of("vendor/gpui/src/platform/windows/window.rs"), "System", "platform code is System")
eq(layer_of("Lib/Models/User.cs"), "Data", "folder names are compared in lower case")

-- Placing a test by the file it tests
eq(layer_of("spec/models/user_spec.rb"), "Data test", "a model spec follows the models")
eq(layer_of("src/components/Button.test.tsx"), "UI test", "a component test follows the UI")
eq(layer_of("src/components/__tests__/Button.tsx"), "UI test", "a __tests__ folder marks a test")
eq(layer_of("tests/api/test_users.py"), "API test", "a test_ prefix marks a test")
eq(layer_of("tests/core_test.lua"), "Logic test", "a test of code no Layer places follows Logic")
eq(layer_of("src/worker/cadence_tests.rs"), "Logic test", "a _tests suffix marks a test")
eq(layer_of("src/terminal_view/tests.rs"), "UI test", "a file named tests marks a test")
eq(layer_of("src/workspace/control_tests/reading.rs"), "Logic test", "a folder ending in tests marks a test")
eq(layer_of("scripts/test_policy.py"), "outside test", "a test of a script stays outside the stack")

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

-- A branch none of whose folders name a Layer still lists its code first and
-- its configuration last.
eq(vim.tbl_map(function(f) return f.path end, layers.sort({
  { path = ".gitattributes" }, { path = "Cargo.toml" }, { path = "crates/term/src/pty/unix.rs" },
  { path = "crates/term/src/session.rs" }, { path = "crates/term/tests/session.rs" },
  { path = "crates/app/src/terminal_view/input.rs" },
})), {
  "crates/app/src/terminal_view/input.rs",
  "crates/term/src/session.rs",
  "crates/term/tests/session.rs",
  "crates/term/src/pty/unix.rs",
  ".gitattributes",
  "Cargo.toml",
}, "a Rust branch: UI, Logic and its tests, System, then what is outside the stack")

-- The order stops at the deepest Layer the branch touches
eq(vim.tbl_map(function(f) return f.path end, layers.sort({
  { path = "app/models/user.rb" }, { path = "app/views/home.erb" },
})), { "app/views/home.erb", "app/models/user.rb" }, "a branch that stops at Data ends with Data")

-- Your own Layers, for every repository or for one
local mine = { { name = "Screens", dirs = { "screens" } }, { name = "Store", dirs = { "store" } } }
eq(layer_of("src/store/cart.ts", mine), "Store", "a list of Layers replaces the defaults")
eq(layer_of("src/components/x.tsx", mine), "code", "the defaults are not mixed into your own")
eq(layer_of("src/app.ts", mine), "code", "without a code Layer, unplaced code follows the last Layer")
eq(layer_of("README.md", mine), "outside", "and files outside the stack still come last")
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
  "file app/models/user.rb",
  "file app/views/home.erb",
  "file db/migrate/1.rb",
  "file README.md",
}, "the layers option reaches the Panel, and what is outside the stack stays last")

print("OK")
