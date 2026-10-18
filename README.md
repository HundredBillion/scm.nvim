# scm.nvim

`scm.nvim` is a multi-repository source-control panel for Neovim. It discovers
every Git repository under the current Explorer root and renders their status
in one sidebar. Choose a built-in terminal sidebar, a native Sprite dock with
terminal fallback, or the original Snacks sidebar.

Originally developed inside the [Sprite](https://github.com/HundredBillion/Sprite)
repository as its Phase 0 track, it now lives here as a standalone plugin.

## Standalone sidebar (no Snacks)

```lua
{
  "HundredBillion/scm.nvim",
  opts = { renderer = "auto" },
  keys = { { "<leader>gs", function() require("scm").toggle() end, desc = "Source Control" } },
}
```

`auto` uses `sprite.nvim` when installed and the host supports native docks;
otherwise it opens a Neovim split. `terminal` always uses the split. `sprite`
also falls back, with a warning. Sprite is optional; no Snacks code is loaded
by these renderers. Omit `renderer` (or use `snacks`) to keep legacy behavior.

Use Enter to open a changed file or toggle a repository, h/l to collapse/expand,
r to refresh, Escape to return to the editor and q to close. Space-e or Ctrl-b
switches to SVGTree when installed. Route your editor's explorer mappings through
`scm.handoff(function() require('svgtree').toggle() end)` to close SCM first.
The sidebar closes when leaving its tab. It refreshes after editor writes,
terminal exit and focus return. `width` sets terminal columns (default 36),
`native_width` sets Sprite pixels (default 300). `native.colors` overrides
native list color roles such as `background` and `foreground`; omitted roles
keep their defaults.

This first standalone renderer lists pending changes and commits relative to
the existing default-branch merge base. It does not yet include prism diffs,
PR-target lookup, CRP, agent following, automatic filesystem watching, staging,
or the legacy Snacks fuzzy picker/lazygit actions. Deleted files are listed;
opening their historical contents awaits prism integration.

## Legacy Snacks install

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

For `auto`, `sprite`, and `terminal` renderers, an optional
`on_explorer = function(root) ... end` setup callback lets a host coordinate the
Explorer action. The callback receives the SCM root and owns closing SCM and
opening Explorer (use `require('scm').handoff(...)` for deferred replacement).
Without it, the action hands off to SVGTree when installed.
