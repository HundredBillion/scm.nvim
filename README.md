# scm.nvim

`scm.nvim` is a multi-repository source-control panel for Neovim. It finds every
Git repository under Neovim's current directory and shows their changes in one
sidebar, drawn in a Neovim split or, with Sprite, a native dock. It needs no
other plugin and works with any file explorer.

Originally developed inside the [Sprite](https://github.com/HundredBillion/Sprite)
repository as its Phase 0 track, it now lives here as a standalone plugin.

## Install

```lua
{
  "HundredBillion/scm.nvim",
  event = "VeryLazy",
  opts = { renderer = "auto" },
  keys = { { "<leader>gs", function() require("scm").toggle() end, desc = "Source Control" } },
}
```

`auto`, the default, uses `sprite.nvim` when installed and the host supports
native docks; otherwise it opens a Neovim split. `terminal` always uses the
split. `sprite` also falls back, with a warning.

Use Enter to open a changed file or toggle a repository, h/l to collapse/expand,
r to refresh, Escape to return to the editor and q to close. Space-e or Ctrl-b
opens your file explorer once one is connected (see below). The sidebar closes
when leaving its tab. It refreshes after editor writes and when Neovim regains
focus. `width` sets terminal columns (default 36), `native_width` sets Sprite
pixels (default 300). `native.colors` overrides native list color roles such as
`background` and `foreground`; omitted roles keep their defaults.

The sidebar lists pending changes and commits relative to the existing
default-branch merge base. It does not yet include diffs, staging, filtering,
PR-target lookup, CRP, agent following, or automatic filesystem watching.
Deleted files are listed; opening their historical contents is not yet
supported.

## Which folder is scanned

SCM scans Neovim's current directory (`:pwd`) for the window you open it from,
so `:cd`, `:tcd` and `:lcd` all steer it. File explorers such as SVGTree,
Neo-tree and the Snacks explorer change that directory when they move to a
folder, so SCM follows them without knowing which one you use. While SCM is
open, changing that window's directory moves SCM to the new folder; an `:lcd`
in another window, such as a terminal, does not.

## Repository discovery

SCM finds repositories by walking the current directory and stopping at each
one, so it takes milliseconds even on large trees. Worktrees inside a repository
(such as `.worktrees/x`) are listed; clones nested inside a repository, like
vendored code, are not. The walk skips build output and dependency directories
by name and must finish within `discovery_timeout_ms` (default 15000); each
per-repository git command keeps `timeout_ms` (default 5000).

The default `discovery_exclude` list is `node_modules`, `target`, `.venv`, `venv`,
`__pycache__`, `.tox`, `.mypy_cache`, `.pytest_cache`, `.gradle`, `.next`,
`.terraform`, `.zig-cache`, `zig-cache` and `DerivedData`. A directory with one
of these names is skipped entirely, so repositories inside it, or a repository
that itself has one of these names, are not listed. The current directory itself
is always searched, even when its own name is in the list.

A list you pass replaces the default; `{}` searches everything:

```lua
opts = {
  discovery_exclude = { "node_modules", "target", "vendor" },
}
```

If discovery still exceeds `discovery_timeout_ms`, SCM shows an error rather
than a partial list. Add the heavy directory names to `discovery_exclude` or
raise `discovery_timeout_ms`.

Opening SCM shows the last known changes at once and updates them as each
repository is rescanned. After startup SCM scans the current directory once so
even the first open is instant; set `warm = false` to turn that off. With
lazy.nvim, load the plugin at startup (for example `event = "VeryLazy"`) for the
warm-up to run before the first open.

## Connecting a file explorer

SCM and a file explorer share the left side of the screen. SCM never opens or
closes an explorer itself; connect yours in your config:

```lua
local function open_explorer()
  require("scm").handoff(function()
    require("svgtree").toggle() -- or vim.cmd("Neotree"), Snacks.explorer(), ...
  end)
end

return {
  "HundredBillion/scm.nvim",
  event = "VeryLazy",
  opts = {
    renderer = "auto",
    -- Space-e or Ctrl-b inside SCM opens your explorer.
    on_explorer = open_explorer,
  },
  keys = {
    {
      "<leader>gs",
      function()
        require("svgtree").close() -- close your explorer before SCM opens
        require("scm").toggle()
      end,
      desc = "Source Control",
    },
    { "<leader>e", open_explorer, desc = "Explorer" },
  },
}
```

`scm.handoff(fn)` closes SCM, then runs `fn` on the next tick, so the two never
share the screen. `on_explorer` receives SCM's folder if your explorer needs it.
Without `on_explorer`, Space-e and Ctrl-b show a message instead. A command that
opens an explorer directly, without `scm.handoff`, can leave both open.
