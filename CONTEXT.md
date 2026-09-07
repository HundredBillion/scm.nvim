# SCM Panel (Sprite Phase 0)

The multi-repo source control panel: a persistent Neovim sidebar that shows
all changes across all configured repositories at a glance, delegating write
operations to lazygit.

## Language

**Core**:
The UI-free Lua module that scans Roots and produces Repo Entries. The
portable half of the plugin; imports nothing from any UI plugin.
_Avoid_: backend, engine, brain

**Panel**:
The persistent left-rail view rendering Repo Entries (a snacks picker source
in v1). The disposable half; contains no git knowledge.
_Avoid_: sidebar (ambiguous with the file explorer), picker (an
implementation detail of the v1 face)

**Sidebar Activity**:
One mutually exclusive left-rail mode: either the Panel or a file explorer.
Only one Sidebar Activity may be visible in a tab at a time.
_Avoid_: side panel, drawer

**Handoff**:
The ordered replacement of one Sidebar Activity by another, where the outgoing
activity is fully closed before the incoming activity opens.
_Avoid_: swap, delayed open

**Repository Section**:
One repository header and its zero or more File Entry rows in the Panel. A
Repository Section may be expanded or collapsed; this is presentation state
and does not change its Repo Entry.
_Avoid_: directory (the section groups source-control state, not filesystem
children), repo tree

**Renderer**:
Any consumer of Repo Entries — the snacks Panel today, a bare-Neovim face or
Sprite native panel later. The Repo Entry list is the contract between Core
and every Renderer.
_Avoid_: face (informal), frontend

**Explorer Root**:
The top-level directory represented by the file explorer. It defines SCM's
repository scope even while the explorer is hidden.
_Avoid_: Root, configured root, workspace, project dir

**Repo Entry**:
One repository's aggregated state — name, path, branch, ahead/behind, File
Entries, clean flag, optional error — as plain Lua data emitted by Core.
_Avoid_: repo status, repo record

**File Entry**:
One changed file within a Repo Entry. It is either a Pending File Entry or a
Committed File Entry, and each path appears at most once.
_Avoid_: change, status line

**Pending File Entry**:
A File Entry whose change still exists in Git's index or working tree. Its
pending state takes precedence when the same path is also committed.
_Avoid_: dirty file, uncommitted file

**Committed File Entry**:
A File Entry changed by commits on the current branch since its Comparison
Base, with no pending state for the same path.
_Avoid_: history entry, commit row

**Comparison Base**:
The point where the current branch diverged from the repository's default
branch. Committed File Entries describe changes after this point.
_Avoid_: upstream, parent branch, target branch

**XY Code**:
git porcelain-v2's two-character state pair (X = staged/index state, Y =
working-tree state), carried raw and unmodified in Pending File Entries — e.g.
`.M`, `M.`, `MM`, `??`. The single source of truth for pending file state;
display letters and markers are derived by Renderers, never stored.
_Avoid_: status letter (derived), status flag

**Mixed State**:
A file whose XY Code has both characters set (staged, then modified again,
e.g. `MM`). Rendered as the working-tree letter plus the `✱` marker.
_Avoid_: partially staged, dirty-staged

**Refresh**:
Recalculation of Repo Entries after relevant user activity. A Refresh targets
one repository after lazygit exits, or all configured repositories when the
user requests it, focus returns to Neovim, or the Panel regains focus.
_Avoid_: rescan, reload
