-- scm.model — turns Repo Entries into the rows of the Panel.
-- Rows are presentation-neutral: a Renderer decides how each kind is drawn.
local M = {}

-- Git's `status --porcelain=v2` documents exactly 7 unmerged XY codes; any of
-- them means an active, unresolved conflict on that file.
local UNMERGED_XY = { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }

-- The highlight a letter is drawn in. Renderers map the highlight to a colour.
local LETTER_HL = {
  M = "ScmModified", T = "ScmModified", A = "ScmAdded", D = "ScmDeleted", R = "ScmRenamed", C = "ScmRenamed",
}

-- The Change Groups of a Repository Section, in the order they are listed. A
-- Mixed State file is in both "staged" and "changes", as in VS Code.
M.GROUPS = {
  { key = "merge", label = "Merge Changes" },
  { key = "staged", label = "Staged Changes" },
  { key = "changes", label = "Changes" },
  { key = "committed", label = "Committed" },
}

-- What a row can do, by kind and Change Group. Renderers show these as
-- buttons; the workspace refuses anything not listed.
local FILE_ACTIONS = {
  merge = { "open", "stage" },
  staged = { "open", "unstage" },
  changes = { "open", "discard", "stage" },
  committed = { "open" },
}
local CONTAINER_ACTIONS = { merge = { "stage" }, staged = { "unstage" }, changes = { "stage" } }
-- A file added with `git add -N` has nothing in the index to restore, so
-- discarding it would only empty it.
local INTENT_TO_ADD_ACTIONS = { "open", "stage" }

function M.input_id(repo)
  return "input:" .. repo
end
function M.button_id(repo)
  return "button:" .. repo
end

-- The badge of one File Entry in one Change Group: { text, hl } and whether
-- the file is gone, or nil when the entry is not in that group.
function M.badge(group, entry)
  local function letter(text, hl)
    return { text = text, hl = hl }, text == "D"
  end
  if not entry.xy then
    if group == "committed" then
      return letter(entry.commit_status:sub(1, 1), "ScmCommitted")
    end
    return nil
  end
  local xy = entry.xy
  if UNMERGED_XY[xy] then
    if group == "merge" then
      return { text = "!", hl = "ScmConflict" }, false
    end
    return nil
  end
  if xy == "??" then
    if group == "changes" then
      return { text = "U", hl = "ScmUntracked" }, false
    end
    return nil
  end
  local code = group == "staged" and xy:sub(1, 1) or group == "changes" and xy:sub(2, 2) or "."
  if code == "." then
    return nil
  end
  return letter(code, LETTER_HL[code] or "ScmModified")
end

-- Every path git must be given to stage or unstage a Repo Entry's whole
-- Change Group. A staged rename covers both its new and its original path.
function M.group_paths(entry, group)
  local paths = {}
  for _, f in ipairs(entry.files or {}) do
    if M.badge(group, f) then
      paths[#paths + 1] = f.path
      if group == "staged" and f.orig then
        paths[#paths + 1] = f.orig
      end
    end
  end
  return paths
end

local function split(path)
  local dir, name = path:match("^(.*)/([^/]+)$")
  return dir, name or path
end

-- Nest files into directories by path.
local function tree(files)
  local root = { dirs = {}, order = {}, files = {} }
  for _, file in ipairs(files) do
    local node = root
    local dir = split(file.path)
    if dir then
      for part in dir:gmatch("[^/]+") do
        if not node.dirs[part] then
          node.dirs[part] = { dirs = {}, order = {}, files = {} }
          node.order[#node.order + 1] = part
        end
        node = node.dirs[part]
      end
    end
    node.files[#node.files + 1] = file
  end
  return root
end

local function file_row(add, e, group, f, depth, in_tree)
  local dir, name = split(f.path)
  local untracked = f.fentry.xy == "??"
  local intent_to_add = group == "changes" and f.fentry.xy and f.fentry.xy:sub(2, 2) == "A"
  add({
    id = "file:" .. e.path .. ":" .. group .. ":" .. f.path, kind = "file", depth = depth,
    entry = e, group = group, fentry = f.fentry, path = f.path, file = e.path .. "/" .. f.path,
    -- A staged rename is unstaged under both of its names.
    paths = group == "staged" and f.fentry.orig and { f.path, f.fentry.orig } or { f.path },
    label = name, description = not in_tree and dir or nil, badge = f.badge,
    strikethrough = f.gone or nil, untracked = untracked or nil,
    actions = intent_to_add and INTENT_TO_ADD_ACTIONS or FILE_ACTIONS[group],
  })
end

-- A Change Group's files as directories and files. A directory whose only
-- child is another directory joins it in one row ("a/b/c"), as VS Code's
-- compact folders do.
local function tree_rows(add, e, group, files, depth, collapsed)
  local function walk(node, level, prefix)
    for _, part in ipairs(node.order) do
      local dir, label = node.dirs[part], part
      local path = prefix and (prefix .. "/" .. part) or part
      while #dir.files == 0 and #dir.order == 1 do
        local only = dir.order[1]
        label, path, dir = label .. "/" .. only, path .. "/" .. only, dir.dirs[only]
      end
      local id = "dir:" .. e.path .. ":" .. group .. ":" .. path
      local open = not collapsed[id]
      add({
        id = id, kind = "dir", depth = level, entry = e, group = group, path = path, paths = { path },
        label = label, expanded = open, actions = CONTAINER_ACTIONS[group],
      })
      if open then
        walk(dir, level + 1, path)
      end
    end
    for _, f in ipairs(node.files) do
      file_row(add, e, group, f, level, true)
    end
  end
  walk(tree(files), depth, nil)
end

local function repo_row(add, e, collapsed)
  local id = "repo:" .. e.path
  local files = e.files or {}
  local branch = e.branch or ""
  if (e.ahead or 0) > 0 then
    branch = branch .. " ↑" .. e.ahead
  end
  if (e.behind or 0) > 0 then
    branch = branch .. " ↓" .. e.behind
  end
  local has_children = e.err ~= nil or #files > 0
  local open = has_children and not collapsed[id]
  add({
    id = id, kind = "repo", depth = 0, entry = e, label = e.name, description = branch,
    count = #files > 0 and tostring(#files) or nil,
    expanded = has_children and open or nil, error = e.err,
  })
  return open
end

-- Flatten Repo Entries into the rows of the Panel. `ui` is presentation state:
--   mode       "list" (default) or "tree"
--   collapsed  row id -> true for a collapsed repository, Change Group or directory
--   messages   repository path -> the commit message being typed
--   folded     true hides every row, as collapsing the "Changes" section does
-- Every row has an id that survives a Refresh, a kind, and a depth. One
-- repository is listed without a repository row, as in VS Code.
function M.rows(entries, ui)
  ui = ui or {}
  local rows = {}
  if ui.folded then
    return rows
  end
  local collapsed, mode, messages = ui.collapsed or {}, ui.mode or "list", ui.messages or {}
  local multi = #entries > 1
  local function add(row)
    rows[#rows + 1] = row
  end
  for _, e in ipairs(entries) do
    local base = multi and 1 or 0
    local files = e.files or {}
    local open = not multi or repo_row(add, e, collapsed)
    if open and e.err then
      add({ id = "note:" .. e.path, kind = "note", depth = base, entry = e, label = e.err, error = true })
    elseif open then
      local pending = false
      for _, f in ipairs(files) do
        if f.xy then
          pending = true
          break
        end
      end
      -- With several repositories, only one that has something to commit
      -- spends two rows on a commit box and button.
      if pending or not multi then
        add({ id = M.input_id(e.path), kind = "input", depth = base, entry = e, label = messages[e.path] or "" })
        add({ id = M.button_id(e.path), kind = "button", depth = base, entry = e, label = "Commit" })
      end
      for _, group in ipairs(M.GROUPS) do
        local members = {}
        for _, f in ipairs(files) do
          local badge, gone = M.badge(group.key, f)
          if badge then
            members[#members + 1] = { path = f.path, fentry = f, badge = badge, gone = gone }
          end
        end
        if #members > 0 then
          local id = "group:" .. e.path .. ":" .. group.key
          local group_open = not collapsed[id]
          add({
            id = id, kind = "group", depth = base, entry = e, group = group.key,
            label = group.label, count = tostring(#members), expanded = group_open,
            actions = CONTAINER_ACTIONS[group.key],
          })
          if group_open and mode == "tree" then
            tree_rows(add, e, group.key, members, base + 1, collapsed)
          elseif group_open then
            for _, f in ipairs(members) do
              file_row(add, e, group.key, f, base + 1, false)
            end
          end
        end
      end
    end
  end
  return rows
end

return M
