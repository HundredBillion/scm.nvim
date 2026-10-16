# SCM standalone sidebar

Approved scope: VSVim PRD milestone 1b, independent of Snacks, ordinary terminal
and Sprite presentations. Preserve the legacy setup for existing SCM users.

Implementation proceeds inline, with independent final review.

1. Extract existing row derivation unchanged. Add a workspace selected through
   setup({renderer='auto'|'terminal'|'sprite'}); omitted renderer retains Snacks.
   Workspace owns Git refresh, selection, collapse and safe editor targets.
   Terminal renderer owns scratch buffer, split and keys. Verify real Git scans,
   explorer handoff, opening a file, refresh after edits, close/reopen and tabs.
2. Add Sprite renderer behind the same view contract: render(rows,selected),
   close(), focus_editor(). Auto falls back to terminal on missing/refused Sprite.
   Serialize updates and reject stale events; discard late opens after close.
   Verify with a fake public Sprite transport and a live native dock if available.
3. Pin the published SCM commit in VSVim, add Space-g-s and Ctrl-Shift-g,
   and route explorer switching through SCM handoff. Check clean installation,
   no Snacks load, ordinary terminal and native startup. Document controls and
   limitations, push feature branches and draft PRs without merging.

Migration: expand with opt-in renderer; VSVim explicitly opts in. Retain legacy
panel and tests. Rollback VSVim by removing its SCM spec and restoring explorer
mappings. No removal of legacy public APIs in this milestone.

Out of scope: prism diffs, CRP, agent following, Git-host PR target lookup and
filesystem-wide instant refresh. This sidebar refreshes on editor writes,
focus/terminal return and explicit r. The later review engine owns hot reload.
