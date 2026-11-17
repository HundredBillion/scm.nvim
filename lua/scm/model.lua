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
-- buttons; the workspace refuses anything not listed. "file" opens the file
-- itself, where activating the row shows its diff.
local FILE_ACTIONS = {
  merge = { "file", "stage" },
  staged = { "file", "unstage" },
  changes = { "file", "discard", "stage" },
  committed = { "file" },
}
local CONTAINER_ACTIONS = { merge = { "stage" }, staged = { "unstage" }, changes = { "stage" } }
-- A file added with `git add -N` has nothing in the index to restore, so
-- discarding it would only empty it.
local INTENT_TO_ADD_ACTIONS = { "file", "stage" }

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

-- The Change Groups one File Entry is listed in: up to two keys, in the order
-- of M.GROUPS. It says where M.badge would give a badge, without building
-- one, so tens of thousands of files can be sorted into groups cheaply.
local function groups_of(entry)
  local xy = entry.xy
  if not xy then
    return "committed"
  end
  if UNMERGED_XY[xy] then
    return "merge"
  end
  if xy == "??" then
    return "changes"
  end
  local staged, changed = xy:byte(1) ~= 46, xy:byte(2) ~= 46 -- 46 is "."
  if staged and changed then
    return "staged", "changes"
  end
  return staged and "staged" or changed and "changes" or nil
end

-- The most files one Change Group lists. A branch far from its baseline can
-- differ in tens of thousands of files, more than a Renderer can be sent.
M.GROUP_LIMIT = 1000

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
  -- `expanded` is nil only for a row that cannot expand. A collapsed row says
  -- false, which `has_children and open or nil` would turn into nil.
  local expanded = nil
  if has_children then
    expanded = open
  end
  add({
    id = id, kind = "repo", depth = 0, entry = e, label = e.name, description = branch,
    count = #files > 0 and tostring(#files) or nil,
    expanded = expanded, error = e.err,
  })
  return open
end

-- Flatten Repo Entries into the rows of the Panel. `ui` is presentation state:
--   mode       "list" (default) or "tree"
--   collapsed  row id -> true for a collapsed repository, Change Group or directory
--   messages   repository path -> the commit message being typed
--   folded     true hides every row, as collapsing the "Changes" section does
--   limit      the most files one Change Group lists (default GROUP_LIMIT)
-- Every row has an id that survives a Refresh, a kind, and a depth. One
-- repository is listed without a repository row, as in VS Code.
function M.rows(entries, ui)
  ui = ui or {}
  local rows = {}
  if ui.folded then
    return rows
  end
  local collapsed, mode, messages = ui.collapsed or {}, ui.mode or "list", ui.messages or {}
  local limit = ui.limit or M.GROUP_LIMIT
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
      -- One pass sorts every file into its groups. Only the files a group
      -- will list are kept; the rest are counted.
      local pending = false
      local listed, counts = {}, {}
      for _, group in ipairs(M.GROUPS) do
        listed[group.key], counts[group.key] = {}, 0
      end
      for i = 1, #files do
        local f = files[i]
        if f.xy then
          pending = true
        end
        local first, second = groups_of(f)
        while first do
          local count = counts[first] + 1
          counts[first] = count
          if count <= limit then
            listed[first][count] = f
          end
          first, second = second, nil
        end
      end
      -- With several repositories, only one that has something to commit
      -- spends two rows on a commit box and button.
      if pending or not multi then
        add({ id = M.input_id(e.path), kind = "input", depth = base, entry = e, label = messages[e.path] or "" })
        add({ id = M.button_id(e.path), kind = "button", depth = base, entry = e, label = "Commit" })
      end
      for _, group in ipairs(M.GROUPS) do
        local total = counts[group.key]
        if total > 0 then
          local id = "group:" .. e.path .. ":" .. group.key
          local group_open = not collapsed[id]
          add({
            id = id, kind = "group", depth = base, entry = e, group = group.key,
            label = group.label, count = tostring(total), expanded = group_open,
            actions = CONTAINER_ACTIONS[group.key],
          })
          -- A Change Group lists at most `limit` files. The count beside it
          -- stays the true total, and a note says how many are left out.
          local hidden = math.max(0, total - limit)
          local members = {}
          -- A closed group lists nothing, so its badges are not worked out.
          if group_open then
            for i, f in ipairs(listed[group.key]) do
              local badge, gone = M.badge(group.key, f)
              members[i] = { path = f.path, fentry = f, badge = badge, gone = gone }
            end
          end
          if group_open and mode == "tree" then
            tree_rows(add, e, group.key, members, base + 1, collapsed)
          elseif group_open then
            for _, f in ipairs(members) do
              file_row(add, e, group.key, f, base + 1, false)
            end
          end
          if group_open and hidden > 0 then
            add({
              id = "more:" .. e.path .. ":" .. group.key, kind = "note", depth = base + 1, entry = e,
              label = ("%d more not shown"):format(hidden),
            })
          end
        end
      end
    end
  end
  return rows
end

return M
