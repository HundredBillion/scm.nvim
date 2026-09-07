# scm.nvim

`scm.nvim` is Sprite's Phase 0 multi-repository source-control panel for
Neovim. It discovers every Git repository under the current Explorer root and
renders their status in one persistent Snacks sidebar.

## Install from the Sprite repository

The current setup uses a sparse local clone of Sprite. The clone lives where
Lazy normally stores plugins, while the plugin itself is the nested
`phase_0/scm.nvim` directory:

```bash
SCM_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/lazy/scm.nvim"
git clone --filter=blob:none --sparse \
  https://github.com/HundredBillion/Sprite.git \
  "$SCM_DIR"
git -C "$SCM_DIR" sparse-checkout set phase_0/scm.nvim
```

Point Lazy at that nested local directory:

```lua
return {
  {
    name = "scm.nvim",
    dir = vim.fn.stdpath("data") .. "/lazy/scm.nvim/phase_0/scm.nvim",
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

This local-clone bootstrap is the current development installation path. It is
not a standalone Lazy package URL because the plugin remains inside Sprite.

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
