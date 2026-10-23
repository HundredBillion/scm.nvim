# Own the Panel; read no Snacks and no file tree

Supersedes ADR 0001.

ADR 0001 drew the Panel with a Snacks picker because Snacks shipped with LazyVim and gave a sidebar, focus handling, and fuzzy filtering for free. SCM is becoming a full git client that owns every view, including its own filtering and diffs, so a picker's layout and actions would be something to work around rather than build on, and requiring snacks.nvim shut out everyone without it. The standalone Panel (`scm.workspace` and its Renderers) is the only Panel; the Snacks panel and its lazygit actions are removed.

SCM also stops reading file trees. It took its folder from the Snacks Explorer, SVGTree, Neo-tree, or LazyVim's root and remembered it per tab. It now reads the Working Directory: Neovim's current directory for the editor window it opened from. Every explorer that changes folders already changes that directory, so one rule supports all of them, and Neovim's tab- and window-local directories replace SCM's per-tab memory. Keeping an explorer and the Panel from sharing the screen moves to the user's config, through `scm.handoff` and `on_explorer`.

Considered and rejected: keeping the Snacks Explorer lookup as an optional read (it still special-cases one tree, and the current directory already follows it); following every `DirChanged` (an `:lcd` in a terminal would move the Panel).

Consequences: the fuzzy filter, the `d` diff key, the lazygit keys, the "scanning…" title, and the refresh on entering the Panel are gone until SCM provides its own. An explorer that shows a folder without changing Neovim's directory does not steer SCM; `:cd` or `:tcd` there does.
