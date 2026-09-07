# Perpetual Sidebar Handoff

## Summary

`scm.nvim` and a file explorer share the same left-side activity position. Switching between them must never leave both layouts alive at once, shrink the editor, enlarge `cmdheight`, or allow an older scheduled open to run after a newer request.

The plugin will provide one public handoff interface for opening another sidebar after SCM has closed. SCM's own toggle will use the same internal transition mechanism when moving in the opposite direction. Neovim configuration remains responsible for routing the user's explorer mappings to the handoff interface because it knows which explorer and root mode the user selected.

## User outcome

The user can alternate between SCM and a file explorer indefinitely. After every completed transition:

- exactly one requested sidebar is open;
- the previous sidebar is fully closed before the next one is created;
- the editor retains its full vertical height;
- `cmdheight` retains its configured value;
- an older request cannot open after a newer request;
- no transition history is retained or written to disk.

## Supported explorers

The handoff accepts a caller-supplied open function, so it does not depend on a particular explorer. Neovim mappings can use it with:

- Snacks Explorer, including SVGTree's Snacks icon adapter;
- Neo-tree;
- SVGTree's standalone tree;
- another explorer that can be opened from a Lua function.

SVGTree remains an icon and tree module. It will not gain a dependency on SCM. In the current setup, Snacks owns the Explorer window and SVGTree only formats and decorates it.

## Interface

`scm.nvim` exposes:

```lua
require("scm").handoff(function()
  Snacks.explorer({ cwd = LazyVim.root() })
end)
```

The caller supplies only the action that opens or toggles its desired explorer. The caller does not need to know how SCM closes, how long layout teardown takes, or how competing requests are coalesced.

All configured explorer entry points that require mutual exclusion must use this interface. Direct third-party commands that bypass it are outside this guarantee.

## Transition behavior

The transition implementation keeps one temporary `pending` request and one `scheduled` flag. A request contains the desired open action and the tab page where the user made the request:

1. Close the currently active conflicting sidebar synchronously.
2. Replace `pending` with the newest request.
3. Schedule at most one flush for the next Neovim event-loop tick.
4. During the flush, copy the latest pending request, clear `pending` and `scheduled`, then run the action in its originating tab if that tab still exists.

Replacing `pending` gives the system latest-request-wins behavior without a ticket list or generation history. Multiple requests before the flush do not create multiple scheduled open callbacks. Rapid duplicate requests coalesce into one request for that activity; they are not replayed later as a series of toggles.

SCM's existing toggle will use this same transition implementation when it closes an explorer and opens SCM. It will close Snacks Explorer, Neo-tree, or SVGTree's standalone tree before requesting SCM. Closing an already-open SCM panel remains an immediate toggle-off operation and cancels any pending SCM open.

## Memory and persistence

Transition state is ephemeral:

- no files, database records, globals intended for persistence, or session data are written;
- at most one open function, its originating tab handle, and one boolean are retained while a transition is pending;
- all pending request data and the scheduled marker are cleared before the selected action runs;
- after the event-loop flush, the transition module retains no action or history;
- exiting Neovim releases the module and all remaining process memory.

## Failure handling

Transition state is cleared before invoking the selected action. If an explorer's open function raises an error, SCM does not retain or retry that function, and later handoffs remain usable. The original error is allowed to surface through Neovim's normal error reporting.

If the requested explorer is unavailable, its caller-supplied function determines the error. SCM does not silently select a different explorer.

## Configuration integration

The current delayed SCM close inside Snacks Explorer's `on_show` callback will be removed. `on_show` will return to SVGTree icon attachment only.

The root-directory and current-directory Explorer mappings will call `scm.handoff()` around their existing `Snacks.explorer(...)` actions. Their existing directory semantics and descriptions will remain unchanged.

## Verification

Tests will cover:

1. Only the newest pending action runs.
2. Many requests schedule only one flush.
3. Pending state is cleared before the selected action runs.
4. An opening error leaves transition state empty and future requests usable.
5. Explorer-to-SCM and SCM-to-Explorer both close before opening.
6. Toggling an already-open SCM panel closes it without reopening it.
7. A request executes in its originating tab and is discarded if that tab no longer exists.
8. Snacks Explorer, Neo-tree, and SVGTree's standalone tree are all recognized as conflicting activities when SCM opens.

A real Neovim PTY regression will repeatedly alternate the configured Explorer and SCM at least 100 times. At each stable checkpoint it will assert:

- `cmdheight` is unchanged;
- normal windows use the full available height;
- SCM and Explorer are never simultaneously active;
- no stale open occurs after the final transition.

## Out of scope

- Monkey-patching Snacks, Neo-tree, or SVGTree.
- Making SVGTree depend on SCM.
- Intercepting arbitrary third-party commands that bypass configured mappings.
- Persisting sidebar selection across Neovim restarts.
- Maintaining a transition history, ticket list, or analytics.
