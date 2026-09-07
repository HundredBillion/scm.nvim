# Snacks picker as the v1 render layer, not a bare nvim_open_win sidebar

The parent brief sketched "bare `nvim_create_buf` + `nvim_open_win`, no
framework dependency" for the panel. We chose a custom snacks picker source
(with the explorer's sidebar layout) instead: snacks ships with LazyVim (an
already-installed dependency), and it provides the persistent left rail,
window/focus management, row formatting, and fuzzy filtering for free —
roughly a third of the code of a hand-rolled sidebar. Framework independence
is preserved where it matters: Core never imports UI, so a bare-Neovim or
Sprite-native Renderer is an alternate ~100-line face over the same Repo
Entry contract, not a rewrite. A second Renderer is already planned work
(Sprite Phase 5.2), which keeps the seam honest.
