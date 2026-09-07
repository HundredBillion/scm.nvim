# Local Plugin Checkout Consolidation Technical Spec

> **For agentic workers:** REQUIRED SUB-SKILL: Use dmi-superpowers:subagent-driven-development (recommended) or dmi-superpowers:executing-plans to implement this TSP task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the project clones the only editable SCM and SVGTree plugin sources used by Neovim while preserving all existing work.

**Architecture:** Transfer Git history and working-tree changes before changing configuration. Lazy.nvim will load each plugin through an explicit local `dir`, so its install cache is no longer a source checkout; the old cache directories can then be moved to trash and Neovim rechecked without them.

**Tech Stack:** Git, Lua, Neovim, lazy.nvim

## Global Constraints

- Preserve all eight commits on `feat/perpetual-sidebar-handoff`.
- Preserve both SVGTree `root()` accessors.
- Keep the migration local; do not push, merge, or add dependencies.
- Remove redundant Lazy copies only after tests and resolved-path checks pass.

---

### Task 1: Promote the SCM checkout

**Files:**
- Modify: `/home/hundredbillion/Projects/Sprite/.git/refs/heads/feat/perpetual-sidebar-handoff`
- Modify: `/home/hundredbillion/.config/nvim/lua/plugins/scm.lua`

**Interfaces:**
- Consumes: the committed branch in `/home/hundredbillion/.local/share/nvim/lazy/scm.nvim`
- Produces: `require("scm")` loaded from `/home/hundredbillion/Projects/Sprite/the repository root`

- [x] **Step 1: Transfer the exact branch tip**

```bash
git -C /home/hundredbillion/Projects/Sprite fetch /home/hundredbillion/.local/share/nvim/lazy/scm.nvim feat/perpetual-sidebar-handoff:feat/perpetual-sidebar-handoff
git -C /home/hundredbillion/Projects/Sprite switch feat/perpetual-sidebar-handoff
```

Expected: both checkouts report the same `git rev-parse feat/perpetual-sidebar-handoff` value.

- [x] **Step 2: Point Lazy at the project checkout**

```lua
dir = vim.fn.expand("~/Projects/Sprite/the repository root"),
```

- [x] **Step 3: Run SCM regression tests**

```bash
cd /home/hundredbillion/Projects/Sprite/the repository root
nvim -l tests/core_test.lua
nvim -l tests/explorer_scope_test.lua
nvim -l tests/handoff_test.lua
```

Expected: every script exits zero.

### Task 2: Promote the SVGTree checkout

**Files:**
- Create: `/home/hundredbillion/Projects/svgtree.nvim/scripts/test-root.lua`
- Modify: `/home/hundredbillion/Projects/svgtree.nvim/scripts/test.sh`
- Modify: `/home/hundredbillion/Projects/svgtree.nvim/lua/svgtree/init.lua`
- Modify: `/home/hundredbillion/Projects/svgtree.nvim/lua/svgtree/render.lua`
- Modify: `/home/hundredbillion/.config/nvim/lua/plugins/svgtree.lua`
- Modify: `/home/hundredbillion/.config/nvim/lua/plugins/snacks-animated-scrolling-off.lua`

**Interfaces:**
- Consumes: SVGTree's active `view.tree.root`
- Produces: `require("svgtree").root() -> string|nil` and a local Lazy plugin spec named `svgtree.nvim`

- [x] **Step 1: Add a failing public-root API check**

```lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local svgtree = require('svgtree')
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
assert(svgtree.root() == nil, 'closed tree must have no root')
svgtree.open(root)
assert(svgtree.root() == root, 'open tree must expose its root')
svgtree.close()
assert(svgtree.root() == nil, 'closed tree must clear its root')
vim.fn.delete(root, 'rf')
```

Add `scripts/test-root.lua` to the `scripts=(...)` list in `scripts/test.sh`, then run `SVGTREE_NVIM=nvim bash scripts/test.sh`.

Expected before implementation: `attempt to call field 'root' (a nil value)`.

- [x] **Step 2: Expose the minimal root accessors**

```lua
-- lua/svgtree/init.lua
function M.root()
  return render.root()
end

-- lua/svgtree/render.lua
function M.root()
  return view and view.tree.root or nil
end
```

- [x] **Step 3: Run SVGTree tests and commit**

```bash
SVGTREE_NVIM=nvim bash scripts/test.sh
git add scripts/test.sh scripts/test-root.lua lua/svgtree/init.lua lua/svgtree/render.lua
git commit -m "feat: expose active tree root"
```

Expected: `SUITE PASSED` and a clean working tree.

- [x] **Step 4: Point Lazy at the project checkout**

Use this plugin identity in both Neovim plugin specifications:

```lua
{
  name = "svgtree.nvim",
  dir = vim.fn.expand("~/Projects/svgtree.nvim"),
}
```

### Task 3: Prove cache independence and retire duplicates

**Files:**
- Remove recoverably: `/home/hundredbillion/.local/share/nvim/lazy/scm.nvim`
- Remove recoverably: `/home/hundredbillion/.local/share/nvim/lazy/svgtree.nvim`

**Interfaces:**
- Consumes: local Lazy plugin specs from Tasks 1 and 2
- Produces: one canonical editable checkout per plugin

- [x] **Step 1: Verify Lazy's resolved directories**

```bash
nvim --headless "+lua local p=require('lazy.core.config').plugins; assert(p['scm.nvim'].dir == vim.fn.expand('~/Projects/Sprite/the repository root')); assert(p['svgtree.nvim'].dir == vim.fn.expand('~/Projects/svgtree.nvim'))" +qa
```

Expected: exit zero.

- [x] **Step 2: Move both cache directories to desktop trash**

```bash
gio trash /home/hundredbillion/.local/share/nvim/lazy/scm.nvim
gio trash /home/hundredbillion/.local/share/nvim/lazy/svgtree.nvim
```

- [x] **Step 3: Repeat the resolved-directory check**

Run the Step 1 command again.

Expected: exit zero and neither removed path is recreated.
