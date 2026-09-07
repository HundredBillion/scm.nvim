-- scm — public entry module. Lazy derives the plugin's main module ("scm")
-- from the plugin name and requires it on load/reload; this re-exports the
-- panel's public API so that derivation resolves without a `main` override.
local panel = require("scm.panel")

return {
  setup = panel.setup,
  toggle = panel.toggle,
  handoff = panel.handoff,
}
