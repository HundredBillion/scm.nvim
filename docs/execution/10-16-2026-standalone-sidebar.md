# Standalone sidebar execution

Source: approved VSVim PRD milestone 1b; plan ../TSPs/10-16-2026-standalone-sidebar.md.
Base: 00ad444. Inline implementation in feat/standalone-sidebar.

- Terminal/controller: complete. Real Git fixture test initially failed on legacy
  Snacks access; now opens changed files, preserves sidebar/selection, refreshes
  new files, collapses/expands and closes without Snacks.
- Native renderer: complete. Lifecycle test initially failed on missing native
  discovery. Now covers actual-shaped down/enter events, close during work,
  late callbacks and capability refusal fallback.
- Existing core, handoff and scope suites: pass unchanged on macOS nightly
  0.13.0-dev-761+g0639f6e41a. New workspace and native workspace tests pass.
- Independent review: identified raw Sprite key translation; fixed and reviewed
  again. No remaining Important findings.
- Live Sprite native adapter: dock opened with SOURCE CONTROL heading; server
  acknowledged revision 2 containing nine repository/file rows with no error.
  Screenshot capture unavailable; pixel appearance is not asserted.
- Linux runtime remains untested locally; both new tests added to Linux CI.
- VSVim integration is tracked in VSVim's branch after publishing this commit.

Legacy Snacks backend remains the default for existing consumers. New renderer
is opt-in; no core Git baseline semantics changed. Full review engine, prism,
instant filesystem refresh and CRP remain later milestones.
