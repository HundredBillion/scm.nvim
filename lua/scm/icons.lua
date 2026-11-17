-- scm.icons — the SVG pictures the native Panel draws: Codicons for controls,
-- and an optional VS Code file-icon theme for files and folders.
local M = {}

local function assets_dir()
  local source = debug.getinfo(1, "S").source:sub(2)
  return vim.fn.fnamemodify(source, ":h:h:h") .. "/assets"
end

local function read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and table.concat(lines, "\n") or nil
end

local codicons = {}
-- A Codicon drawn in `color`, optionally moved `dx` pixels inside its slot.
-- nil when the icon is missing, so a row simply draws without it.
function M.codicon(name, color, dx)
  local key = name .. color .. (dx or 0)
  if codicons[key] == nil then
    local svg = read(assets_dir() .. "/codicons/" .. name .. ".svg")
    if svg then
      svg = svg:gsub("currentColor", color)
      if dx and dx ~= 0 then
        svg = svg:gsub("(<svg[^>]*>)", "%1<g transform=\"translate(" .. dx .. " 0)\">", 1):gsub("</svg>", "</g></svg>")
      end
    end
    codicons[key] = svg or false
  end
  return codicons[key] or nil
end

-- An unpacked VS Code file-icon theme: its JSON and the directory its icon
-- paths are relative to. nil when dir holds no theme.
local function load_theme(dir)
  local ok, package = pcall(vim.json.decode, read(dir .. "/package.json") or "", { luanil = { object = true, array = true } })
  local themes = ok and type(package) == "table" and type(package.contributes) == "table" and package.contributes.iconThemes
  local first = type(themes) == "table" and themes[1]
  local path = type(first) == "table" and first.path
  if type(path) ~= "string" then
    return nil
  end
  local file = vim.fs.normalize(dir .. "/" .. path)
  local parsed, theme = pcall(vim.json.decode, read(file) or "", { luanil = { object = true, array = true } })
  if not parsed or type(theme) ~= "table" or type(theme.iconDefinitions) ~= "table" then
    return nil
  end
  local function lower(map)
    local index = {}
    for name, id in pairs(type(map) == "table" and map or {}) do
      if type(name) == "string" and type(id) == "string" then
        index[name:lower()] = id
      end
    end
    return index
  end
  local function id(value)
    return type(value) == "string" and value or nil
  end
  return {
    -- Icons are only ever read from inside the theme's own directory.
    root = vim.fs.normalize(dir) .. "/",
    dir = vim.fn.fnamemodify(file, ":h"),
    definitions = theme.iconDefinitions,
    file = id(theme.file), folder = id(theme.folder), folder_open = id(theme.folderExpanded),
    file_names = lower(theme.fileNames), extensions = lower(theme.fileExtensions),
    folder_names = lower(theme.folderNames), folder_names_open = lower(theme.folderNamesExpanded),
    svgs = {}, resolved = {},
  }
end

-- Where a theme may already be on disk when the user names none: the Material
-- theme svgtree.nvim bundles. Only its files are read; svgtree is never loaded.
local function find_theme()
  local found = vim.api.nvim_get_runtime_file("assets/material/package.json", false)[1]
  if found then
    return vim.fn.fnamemodify(found, ":h")
  end
  local lazy = vim.fn.stdpath("data") .. "/lazy/svgtree.nvim/assets/material"
  if vim.uv.fs_stat(lazy .. "/package.json") then
    return lazy
  end
end

-- Themes by the option that asked for them, `false` when there is none, so
-- the search and the JSON decode happen once and not once per row.
local themes = {}
-- Forget every theme, for when the Panel opens: a plugin that bundles one may
-- have been installed or loaded since.
function M.reset()
  themes = {}
end

-- option: nil finds a theme, a string names a theme directory, false uses none.
function M.theme(option)
  if option == false then
    return nil
  end
  local key = type(option) == "string" and option or true
  if themes[key] == nil then
    local dir = type(option) == "string" and vim.fn.expand(option) or find_theme()
    themes[key] = dir and load_theme(dir) or false
  end
  return themes[key] or nil
end

local function icon_id(t, name, kind, open)
  local lower = name:lower()
  if kind == "dir" then
    -- A compacted "a/b/c" row is drawn with the icon of its last directory.
    lower = lower:match("[^/]+$") or lower
    return open and t.folder_names_open[lower] or t.folder_names[lower] or (open and t.folder_open) or t.folder
  end
  local id = t.file_names[lower]
  local from = 1
  -- "a.test.ts" tries "test.ts" before "ts": the longest extension wins.
  while not id do
    local dot = lower:find(".", from, true)
    if not dot then
      break
    end
    id, from = t.extensions[lower:sub(dot + 1)], dot + 1
  end
  return id or t.file
end

local function themed_svg(t, id)
  if t.svgs[id] == nil then
    local definition = t.definitions[id]
    local relative = type(definition) == "table" and definition.iconPath
    local path = type(relative) == "string" and vim.fs.normalize(t.dir .. "/" .. relative)
    local svg = path and path:sub(1, #t.root) == t.root and read(path)
    svg = svg and svg:gsub("^%s*<%?xml.-%?>%s*", ""):gsub("^%s*<!%-%-.-%-%->%s*", "")
    t.svgs[id] = svg and svg:match("^%s*<svg[%s>]") and svg or false
  end
  return t.svgs[id] or nil
end

-- The icon for a file or directory row: an asset id and its SVG text.
-- `t` is a theme from M.theme, or nil. `fallback` is the colour of the plain
-- Codicon drawn when the theme has no icon for the name.
function M.file(t, name, kind, open, fallback)
  if t then
    local key = kind .. (open and "+" or "-") .. name:lower()
    local id = t.resolved[key]
    if id == nil then
      id = icon_id(t, name, kind, open) or false
      t.resolved[key] = id
    end
    local svg = id and themed_svg(t, id)
    if svg then
      return "scm-theme-" .. id, svg
    end
  end
  local codicon = kind == "dir" and (open and "folder-opened" or "folder") or "file"
  return "scm-" .. codicon, M.codicon(codicon, fallback)
end

return M
