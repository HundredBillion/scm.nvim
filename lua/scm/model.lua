local M = {}

-- Git's `status --porcelain=v2` documents exactly 7 unmerged XY codes; any of
-- them means an active, unresolved conflict on that file, regardless of which
-- letter the usual X/Y derivation below picks.
local UNMERGED_XY = { DD = true, AU = true, UD = true, UA = true, DU = true, AA = true, UU = true }

-- Derive display fields from a raw XY Code. Letter shows the working-tree
-- state (Y) when set, else the index state (X); a Mixed State (both set)
-- additionally gets the mixed marker.
function M.xy_display(xy)
  if xy == "??" then
    return { letter = "??", mixed = false, hl = "ScmUntracked" }
  end
  local x, y = xy:sub(1, 1), xy:sub(2, 2)
  local letter = (y ~= ".") and y or x
  local mixed = x ~= "." and y ~= "."
  local hl
  if UNMERGED_XY[xy] then
    hl = "ScmConflict"
  elseif y == "." then
    hl = "ScmStaged"
  else
    hl = ({ M = "ScmModified", A = "ScmAdded", D = "ScmDeleted", R = "ScmRenamed" })[letter] or "ScmModified"
  end
  return { letter = letter, mixed = mixed, hl = hl }
end

function M.file_display(entry)
  if entry.xy then
    local display = M.xy_display(entry.xy)
    return {
      letter = display.letter,
      marker = display.mixed and "✱" or " ",
      hl = display.hl,
    }
  end
  return {
    letter = entry.commit_status:sub(1, 1),
    marker = "✓",
    hl = "ScmCommitted",
  }
end

-- Flatten Repo Entries into picker items. Every file row is self-identifying
-- (text and ctx carry the repo name) so filtering may orphan headers freely.
function M.build_items(entries, collapsed)
  collapsed = collapsed or {}
  local dup = {}
  for _, e in ipairs(entries) do
    dup[e.name] = (dup[e.name] or 0) + 1
  end
  local items = {}
  local function add(it)
    it.sort = #items + 1
    items[#items + 1] = it
  end
  for _, e in ipairs(entries) do
    local has_children = not e.err and not e.clean and #(e.files or {}) > 0
    local is_collapsed = has_children and collapsed[e.path] == true
    add({
      kind = "header",
      entry = e,
      text = e.name .. " " .. (e.branch or ""),
      dup = dup[e.name] > 1 or nil,
      collapsed = is_collapsed,
    })
    if not is_collapsed then
      for _, f in ipairs(e.files or {}) do
        local dir = f.path:match("^(.*)/[^/]+$")
        add({
          kind = "file",
          entry = e,
          fentry = f,
          file = e.path .. "/" .. f.path,
          text = e.name .. "/" .. f.path,
          ctx = dir and (e.name .. "/" .. dir) or e.name,
        })
      end
    end
  end
  return items
end

return M
