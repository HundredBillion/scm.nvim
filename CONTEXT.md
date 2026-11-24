# SCM Panel

The multi-repo source control panel: a persistent Neovim sidebar that shows
every repository's changes under the Working Directory at a glance, laid out
like VS Code's Source Control view, and stages, unstages, discards and commits
them. SCM runs git itself and never hands work to an external git client.

## Language

**Core**:
The UI-free Lua module that discovers repositories under the Working Directory
and produces Repo Entries. The portable half of the plugin; imports nothing from
any UI plugin.
_Avoid_: backend, engine, brain

**Panel**:
The persistent left-rail view listing Repository Sections, opened and closed
with one toggle. It runs git only through Core, which reads, and Actions, which
write.
_Avoid_: sidebar (ambiguous with the file explorer), picker, Workspace (the
module that runs it)

**Actions**:
The UI-free Lua module that changes a repository on the user's behalf: stage,
unstage, discard, commit. Like Core it imports nothing from any UI plugin.
Every path it gives git is the exact file it names, never a pattern.
_Avoid_: commands, operations

**Sidebar Activity**:
One mutually exclusive left-rail mode: either the Panel or a file explorer.
Only one Sidebar Activity may be visible in a tab at a time.
_Avoid_: side panel, drawer

**Handoff**:
The ordered replacement of one Sidebar Activity by another, where the outgoing
activity is fully closed before the incoming activity opens.
_Avoid_: swap, delayed open

**Repository Section**:
One repository's rows in the Panel: its commit box and Commit button, then its
Change Groups. When the Working Directory holds several repositories, each
section starts with a repository row that expands or collapses it, and only a
repository with a Pending File Entry has a commit box; a single repository has
no repository row. Expansion is presentation state and does not change the
Repo Entry.
_Avoid_: directory (the section groups source-control state, not filesystem
children), repo tree

**Change Group**:
One named set of File Entries within a Repository Section, with a count: Merge
Changes, Staged Changes, Changes, or Committed. A group is listed only when it
has entries, and may be collapsed.
_Avoid_: section (a Repository Section), category, status

**Layer**:
One level of a tech stack, such as UI, API, Logic, Data or DB, that a file is
placed in by its path. In the list View Mode the Committed group is sorted by
Layer from the top of the stack down and ends at the lowest Layer present.
_Avoid_: tier, level, category

**View Mode**:
How a Change Group lists its File Entries: as a flat list, each file followed
by its directory, or as a tree in which a directory whose only child is another
directory shares one row with it.
_Avoid_: layout, display mode

**Row**:
One line of the Panel as plain Lua data: a repository, a commit box, a button,
a Change Group, a directory, or a file, with the actions it can take. Rows are
derived from Repo Entries by the model and are the same for every Renderer.
_Avoid_: item, node

**Renderer**:
One way of drawing the Panel: a Neovim terminal buffer, or a Sprite native
panel. Every Renderer receives the same Rows; it decides how each kind is
drawn and holds no git knowledge.
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
`.M`, `M.`, `MM`, `??`. The single source of truth for pending file state; a
file's Change Groups and Badges are derived from it by the model, never stored
in Core.
_Avoid_: status letter (derived), status flag

**Badge**:
The letter a File Entry shows in one Change Group — `M`, `A`, `D`, `R`, `U` for
untracked, `!` for a conflict — and the highlight it is drawn in.
_Avoid_: status, marker

**Mixed State**:
A file whose XY Code has both characters set (staged, then modified again,
e.g. `MM`). It is a row in Staged Changes with its index Badge and a row in
Changes with its working-tree Badge.
_Avoid_: partially staged, dirty-staged

**Review**:
An Explainer's account of one file's change, shown around its diff: a Tour, a
Pane that explains the line under the cursor with its Predicted Values, and
Flow Maps. It is kept by the two texts it compares, so
the same change is explained once.
_Avoid_: explanation (one part of it), annotation, code review (people do that)

**Explainer**:
A language model service that writes Reviews: Claude Code on this machine by
default, or any service the user connects on the admin page. SCM never stores
an Explainer's key.
_Avoid_: provider, backend, AI

**Tour**:
The ordered steps of a Review, each a range of lines with a title and one
sentence, that the reader walks through with `]t` and `[t`.
_Avoid_: walkthrough, guide

**Pane**:
The box floating at the right of a diff that explains the line the cursor is
on, and no other: what it was before, what it is now, a paragraph about it
and its Predicted Values.
_Avoid_: rail, sidebar, panel (the Panel is the source control list)

**Predicted Values**:
What an Explainer expects the variables to hold just after a line runs for
the first time. Always shown labelled "predicted": they are a guess, never a
recording of a run.
_Avoid_: debug values, runtime values, state

**Flow Map**:
The drawing of how a line gets run: the functions on the way to it, in lanes
that are moments in time (right away, later, outside the program).
_Avoid_: call stack, stack trace, call graph

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

## VS Code Source Control layout (2026-11-16)

The Panel is laid out like VS Code's Source Control view and can change a
repository, not only show it. Core still only reads; the new Actions module
writes. Rows replace the old header-and-file items, grouped into Change Groups
with a list or tree View Mode. The native Renderer needs a Sprite host with
decorated list rows (`virtual-list-rows-v2`) and falls back to the terminal
Renderer without it. Core lists every untracked file by name, reports
non-ASCII paths as their real names, and reads without taking git's index
lock, so a refresh never makes a stage or commit fail. Committed File Entries
remain, as a Change Group VS Code does not have. Diffs are still out of scope.
