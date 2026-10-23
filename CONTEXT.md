# SCM Panel

The multi-repo source control panel: a persistent Neovim sidebar that shows
every repository's changes under the Working Directory at a glance. SCM runs git
itself and never hands work to an external git client.

## Language

**Core**:
The UI-free Lua module that discovers repositories under the Working Directory
and produces Repo Entries. The portable half of the plugin; imports nothing from
any UI plugin.
_Avoid_: backend, engine, brain

**Panel**:
The persistent left-rail view listing Repo Entries, opened and closed with one
toggle. It contains no git knowledge.
_Avoid_: sidebar (ambiguous with the file explorer), picker, Workspace (the
module that runs it)

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
One way of drawing the Panel: a Neovim terminal buffer, or a Sprite native
panel. Every Renderer receives the same Repo Entry list from Core.
_Avoid_: face (informal), frontend

**Working Directory**:
Neovim's current directory for the editor window SCM was opened from. It
defines which repositories SCM discovers and refreshes, whichever file tree (if
any) set it. It may contain many repositories, or be inside one.
_Avoid_: Explorer Root, Root, workspace, project dir, working tree (git's
checked-out files of one repository)

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
the containing repository after a save, or all discovered repositories when the
user requests it or focus returns to Neovim. Ordinary events reuse discovery for
the Working Directory. An explicit Refresh, opening the Panel, a change of
Working Directory, or a save under an unknown repository rediscovers repository
membership. Opening the Panel or changing the Working Directory shows the last
Repo Entries Core holds for that directory at once, and replaces them as each
repository's Refresh lands.
_Avoid_: rescan, reload

## Standalone renderer migration (2026-10-16)

The optional `auto`, `terminal`, and `sprite` renderers use `scm.workspace` with
`scm.views` presentations and shared `scm.model` row derivation. The default
remains the legacy Snacks panel. No core Git behavior changes. Native capability
refusal falls back to terminal, and leaving a tab closes the standalone view.

## Scoped refresh scheduling (2026-10-16)

Core caches discovery by normalized Working Directory and limits repository scans
across callers to four at once. Refresh events share burst coalescing and request
merging in `scm.refresh`, which also owns refresh ordering for every renderer:
one Core run per view at a time, one merged re-run for requests made meanwhile,
and delivery of only the newest result. Renderers are adapters that render the
delivered Repo Entries or error. Cache membership and entries carry request versions so older
callbacks cannot replace newer cached results. Comparison Base calculations
still run for each selected repository; they are not cached independently.
A new nested repository inside an already known repository is discovered by
explicit Refresh or reopening the Panel.

## Bounded discovery (2026-10-22)

Discovery walks the Working Directory in-process and stops at every repository: a
directory holding a `.git` entry is a Repo Entry and is not searched further, and
neither is a Working Directory that is itself a repository. Worktrees inside a
repository (such as `.worktrees/x`) come from `git worktree list` instead; clones
nested inside a repository (vendored code, test dependencies) are not Repo
Entries. The walk skips `discovery_exclude` names below the Working Directory and
must finish within `discovery_timeout_ms`. A walk that fails or times out is an
error, never a partial repository list.

## Instant open (2026-10-22)

Opening the Panel never waits on git. Renderers draw Core's cached Repo Entries
for the Working Directory immediately, then each repository as its Refresh
lands. After startup Core scans the Working Directory once (`warm`, on by
default) so the first open has rows; it skips a root whose Refresh already
started. Refreshes that overlap share repository scans still waiting in the
queue, never ones already running.

## No Snacks, no file tree (2026-10-22)

The standalone Panel is the only Panel; the Snacks panel and every lazygit
action are gone. SCM reads no file tree, LazyVim, or Snacks state. The Working
Directory decides what is scanned, so any explorer that changes Neovim's
directory steers SCM without SCM knowing it exists. Keeping one Sidebar Activity
on screen is the user's config's job, through Handoff and `on_explorer`. Moving
the cursor into the Panel does not refresh it, and the Panel shows no
in-progress indicator.
