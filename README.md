# scm.nvim

`scm.nvim` is a multi-repository source-control panel for Neovim. It finds every
Git repository under Neovim's current directory and shows their changes in one
sidebar laid out like VS Code's Source Control view: a commit box, a Commit
button, and Staged Changes and Changes groups you can stage, unstage, discard
and commit from. With Sprite it is a native dock that matches VS Code's
metrics; otherwise it is a Neovim split with the same rows. It needs no other
plugin and works with any file explorer.

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

Native docks require a Sprite Terminal and `sprite.nvim` that support decorated
list rows (the `virtual-list-rows-v2` feature). After upgrading Sprite, run
`:Lazy update scm.nvim sprite.nvim` and restart Neovim. An older host falls
back to the terminal panel.

## What the panel shows

One repository is listed as VS Code lists it: the commit box, the Commit
button, then its groups. Several repositories each get a collapsible row with
their branch and change count, and only a repository with something to commit
shows a commit box.

| Group | Holds |
| --- | --- |
| Merge Changes | Files with unresolved conflicts, marked `!`. |
| Staged Changes | What the next commit will contain. |
| Changes | Modified, deleted and untracked (`U`) files not yet staged. |
| Committed | Files changed by commits on this branch since it left the default branch. |

A file that is staged and then edited again appears in both Staged Changes and
Changes. A deleted file is struck through. The Committed group has no
counterpart in VS Code; it is SCM's own.

The view is a flat list, each file followed by its directory, or a tree with
single-child folders joined into one row. Switch with `t`, the list/tree
button in the "Changes" header, or `view = "tree"` in `opts` to start in the
tree.

## Keys and mouse

| Key | Action |
| --- | --- |
| `j` / `k`, arrows | Move the selection. |
| Enter | Open a file, toggle a group or folder, type in the commit box, or press Commit. |
| `h` / `l` | Collapse / expand; `h` on a file selects its group or folder. |
| `s` | Stage the file, folder, or group under the cursor. |
| `u` | Unstage the file, folder, or group under the cursor. |
| `x` | Discard the changes to a file under Changes, after confirming. |
| `c` | Type a commit message. |
| Ctrl-Enter (⌘Enter in the dock) | Commit. |
| `t` | Switch between list and tree. |
| `m` | Open the menu: view, refresh, commit, stage all, unstage all. |
| `r` | Refresh. |
| Escape | Return to the editor. |
| `q`, Space-g-s | Close. |
| Space-e, Ctrl-b | Open your file explorer once one is connected (see below). |

A key acts only on what its row shows: `s` on the Staged Changes group does
nothing, and a key pressed on the title line acts on no file.

In the native dock, the same actions are buttons. Hover a file for open,
discard and stage; hover a group or folder to stage or unstage all of it; the
"Changes" header has list/tree, commit, refresh and the menu. Click the commit
box to type in it: Enter moves to the Commit button, Escape stops typing, and
⌘Enter commits. In the terminal panel the commit box opens a prompt instead.

Committing with nothing staged asks whether to stage every change and commit
it, as VS Code does. A commit that fails keeps your message.

To bind an action to your own key, call `require("scm").act(name)` with
`stage`, `unstage`, `stage_all`, `unstage_all`, `discard`, `compose`, `commit`,
`view`, `fold`, `menu`, `refresh`, `open`, `expand` or `collapse`.

The sidebar closes when leaving its tab. It refreshes after editor writes,
when Neovim regains focus, and after every action it runs.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `renderer` | `"auto"` | `auto`, `terminal`, or `sprite`. |
| `view` | `"list"` | `list` or `tree`. |
| `group_limit` | `1000` | Most files one group lists. The group's count stays the true total and a last row says how many are left out. |
| `width` | `36` | Terminal panel width in columns. |
| `native_width` | `300` | Native dock width in pixels. |
| `native.colors` | VS Code dark | Overrides for native colour roles such as `background`, `foreground`, `button_background` and `count_background`. |
| `native.icon_theme` | found automatically | A directory holding an unpacked VS Code file-icon theme, or `false` for plain icons. |
| `confirm` | Neovim's prompt | `function(message, choices)` returning true to proceed; replaces the discard and stage-all prompts. |

File icons come from a VS Code file-icon theme. With none named, SCM uses the
Material theme that `svgtree.nvim` bundles when that plugin is installed, by
reading its icon files only; it never loads svgtree. Without a theme, files
and folders get plain outline icons.

The panel does not yet show diffs, filter, look up PR targets, or watch the
filesystem. Deleted files are listed; opening their historical contents is not
yet supported. A commit message is one line.

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
