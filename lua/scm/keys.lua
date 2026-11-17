-- The keys both Renderers bind, in Vim notation, and the Panel action each runs.
return {
  ["<CR>"] = "open", l = "expand", h = "collapse", i = "open", o = "file",
  s = "stage", u = "unstage", x = "discard",
  c = "compose", ["<C-CR>"] = "commit",
  t = "view", m = "menu", r = "refresh",
  q = "close", ["<Space>gs"] = "close", ["<C-S-g>"] = "close",
  ["<Esc>"] = "editor", ["<Space>e"] = "explorer", ["<C-b>"] = "explorer",
}
