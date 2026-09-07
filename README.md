# scm.nvim

`scm.nvim` is a multi-repository source-control panel for Neovim. It discovers
every Git repository under the current Explorer root and renders their status
in one persistent Snacks sidebar.

Originally developed inside the [Sprite](https://github.com/HundredBillion/Sprite)
repository as its Phase 0 track, it now lives here as a standalone plugin.

## Install

```lua
return {
  {
    "HundredBillion/scm.nvim",
    dependencies = { "folke/snacks.nvim" },
    opts = {},
    keys = {
      {
        "<leader>gC",
        function()
          require("scm").toggle()
        end,
        desc = "Source Control",
      },
    },
    config = function(_, opts)
      require("scm").setup(opts)
    end,
  },
}
```

## Explorer handoff mappings

SCM and Explorer own the same sidebar position. Route every configured
Explorer entry point through `require("scm").handoff()` so SCM closes before
Explorer opens. Preserve the mapping's existing root semantics by passing the
same `cwd` to Snacks:

```lua
local function explorer(cwd)
  require("lazy").load({ plugins = { "scm.nvim" } })
  require("scm").handoff(function()
    Snacks.explorer(cwd and { cwd = cwd } or nil)
  end)
end

return {
  "folke/snacks.nvim",
  keys = {
    { "<leader>fe", function() explorer(LazyVim.root()) end, desc = "Explorer Snacks (root dir)" },
    { "<leader>fE", function() explorer() end, desc = "Explorer Snacks (cwd)" },
    { "<leader>e", function() explorer(LazyVim.root()) end, desc = "Explorer Snacks (root dir)" },
    { "<leader>E", function() explorer() end, desc = "Explorer Snacks (cwd)" },
  },
}
```

The handoff guarantee applies to entry points routed through `scm.handoff()`
and to `scm.toggle()` in the opposite direction. A direct command such as
`Snacks.explorer()`, `:Neotree`, or a standalone SVGTree command bypasses SCM,
so SCM cannot guarantee mutual exclusion for that invocation. SVGTree remains
optional; `scm.nvim` does not depend on it or patch its internals.
