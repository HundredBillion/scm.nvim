-- scm.review.prompt — what an Explainer is asked, and where its answers are
-- kept. The question holds the change itself, each line with its number, and
-- the exact shape of the Review to send back.
local Schema = require('scm.review.schema')
local M = {}

-- Changing what is asked makes every kept Review out of date.
M.VERSION = 4
-- Unchanged lines shown around each change, and the most lines sent in all.
local CONTEXT, MAX_LINES = 12, 1500

local SHAPE = [[
{
  "tour": [
    {"title": "Scans one at a time", "summary": "Before: every scan at once. Now: one per tick.", "from": 213, "to": 216}
  ],
  "lines": [
    {"side": "old", "line": 213, "gist": "before: start every scan in one go"},
    {"side": "new", "line": 213, "gist": "take the first job off the queue", "before": "looped over every job at once",
     "detail": "Removes the first job from queue and names it job. Everything behind it moves up one place. If the queue is empty, job is nil.",
     "inline": "job = \"status\"",
     "paused": {"when": "After line 213 runs, first time:",
                "values": [{"name": "job", "value": "\"status\""},
                           {"name": "queue", "value": "{ \"show-ref\", \"log\" }", "note": "\"status\" was just taken out"}]}}
  ],
  "flows": [
    {"from": 213, "to": 216, "note": "repeats until the queue is empty",
     "trigger": {"says": "you press", "keys": "Space g s"},
     "later": "when Neovim is free", "handoff": "Neovim runs it later", "outside": "Outside Neovim",
     "steps": [
       {"name": "open()", "says": "opens the Panel", "file": "workspace.lua", "when": "now", "state": "ran"},
       {"name": "refresh()", "says": "plans the scans to run", "when": "now", "state": "ran"},
       {"name": "start_scan()", "says": "adds a scan to the queue", "when": "now", "state": "ran"},
       {"name": "drain_scans()", "says": "one scan at a time", "when": "later", "state": "here", "line": 213, "changed": true, "again": 216},
       {"name": "spawn()", "says": "will start git status", "when": "later", "state": "not_yet"},
       {"name": "git status", "says": "this tool can't see inside", "when": "outside", "state": "not_yet"}
     ]}
  ]
}]]

local RULES = [[
Rules:
- Write for an engineer who wants to learn from this change. Use plain, short words. Say what the code does and why it matters, not what the syntax is.
- "tour": 1 to 8 steps in reading order, one for each change worth understanding. "from" and "to" are line numbers of the NEW file. "title" at most %d characters, "summary" at most %d.
- "lines": one entry for every added line that does something, and one for the first line of each run of removed lines (side "old", its OLD line number, starting "before:"). "gist" is at most %d characters and has no full stop. Give "detail" (two or three sentences, at most %d characters) for added lines. When an added line takes the place of removed code, give "before": what that same piece of code did or held before this change, in words that fit this line alone and not the whole change, at most %d characters, with no full stop and without the word "before". Leave "before" out for a line that is wholly new.
- "inline" and "paused" are a PREDICTION of what the values would be if the program were stopped just after that line ran for the first time. Give them for every added line that sets, changes, passes on or returns a value whenever a realistic example value can be named, and for at least the most important line of each tour step: readers learn most from seeing example values. Use small, concrete values a reader can follow from one line to the next. They are shown to the reader labelled as predicted, so never present a guess as certain: leave them out only when no realistic value can be named.
- "flows": for each tour step that changes how code runs, the path that gets the changed line run, from what starts it (a key press, a command, an event, a request, a test) to the line and one or two calls beyond it. 3 to %d steps, at most %d in one "when". "when" is "now" (runs right away, in order), "later" (the program or its runtime runs it in its own time: a scheduled callback, an event loop, a queue, a timer) or "outside" (another program or service; you cannot see inside it). Steps never go back to an earlier "when". "state" is "ran" for steps before the reader's line, "here" for the one function that holds the changed line (give "line", and "changed": true if this diff changes that function), and "not_yet" for calls after it. "again" is the line where the function asks to be run again, if it does. "file" only when the step is in a different file from this one. "name" at most %d characters, "says" at most %d; "later", "handoff", "outside" and the trigger's "says" at most %d each, and "keys" at most %d. Leave "flows" empty when you cannot tell how the line is reached: an honest gap is better than an invented path.
- Reply with the JSON object alone: no sentence before or after it, no code fence.]]

-- The change as numbered lines: each hunk with the lines around it. Returns
-- the text, or nil when nothing changed.
function M.numbered(lines, meta, hunks)
  if #hunks == 0 then return nil end
  local keep = {}
  for _, hunk in ipairs(hunks) do
    local last = hunk.row + hunk.removed + hunk.added - 1
    for row = math.max(1, hunk.row - CONTEXT), math.min(#lines, last + CONTEXT) do keep[row] = true end
  end
  local out, previous = {}, 0
  for row = 1, #lines do
    if keep[row] then
      if #out >= MAX_LINES then
        out[#out + 1] = '... (the rest of the change is left out: it is too long)'
        break
      end
      if previous ~= row - 1 and #out > 0 then out[#out + 1] = '...' end
      local line = meta[row]
      out[#out + 1] = ('%s %5d | %s'):format(line.kind, line.new or line.old or 0, lines[row])
      previous = row
    end
  end
  return table.concat(out, '\n')
end

-- How the reader asked for things to be explained, as the last part of a question.
local function styled(parts, style)
  if type(style) ~= 'string' or vim.trim(style) == '' then return end
  parts[#parts + 1] = ''
  parts[#parts + 1] = 'The reader asked for every explanation to be written this way. Follow it in each sentence you write, '
    .. 'and still keep to the shape and the limits given: ' .. vim.trim(style)
end

-- The question for one file's change. `reads` is true for an Explainer that
-- can read the repository itself. `style` is how the reader asked for it to
-- be explained, if they said.
function M.build(path, numbered, reads, style)
  local limits = Schema.LIMITS
  local parts = {
    'Explain one file\'s change so that a person reading the diff understands what the code does and what the change does.',
    '',
    'File: ' .. path,
    '',
    'The change. Each line starts with "+" (added; the number is its line in the NEW file), "-" (removed; its line in the OLD file) or a blank (unchanged; its line in the NEW file):',
    '',
    numbered,
    '',
  }
  if reads then
    parts[#parts + 1] = 'You may read other files of this repository to learn what calls this code and what it calls. Only read: change nothing.'
    parts[#parts + 1] = ''
  end
  parts[#parts + 1] = 'Reply with one JSON object of exactly this shape (the values here are an example from another file):'
  parts[#parts + 1] = SHAPE
  parts[#parts + 1] = ''
  parts[#parts + 1] = RULES:format(limits.title, limits.summary, limits.gist, limits.detail, limits.gist, Schema.MAX_STEPS,
    Schema.MAX_LANE, limits.step, limits.says, limits.phrase, limits.keys)
  styled(parts, style)
  return table.concat(parts, '\n')
end

-- The question a reader asks about one line.
function M.question(path, numbered, line, text, question, style)
  local parts = {
    'A person is reading this change and has a question about one line. Answer it in at most five short sentences of plain words. If you are not sure, say so.',
    '', 'File: ' .. path, '', numbered, '',
    ('The line (%d): %s'):format(line, text), '',
    'The question: ' .. question,
  }
  styled(parts, style)
  return table.concat(parts, '\n')
end

-- A longer explanation of one line.
function M.more(path, numbered, line, text, style)
  return M.question(path, numbered, line, text,
    'Explain this line in more depth: what it does, why it is written this way, and what would go wrong without it.', style)
end

local function dir()
  return vim.fs.joinpath(vim.fn.stdpath('cache'), 'scm', 'reviews')
end

-- The name a change's Review is kept under: the same two texts of the same
-- file, explained in the same style, always give the same name.
function M.key(path, old, new, style)
  return vim.fn.sha256(table.concat({M.VERSION, path, #(old or ''), old or '', new or '', style and vim.trim(style) or ''}, '\0'))
end

-- The kept answer for `key`, as the table it decoded to, or nil.
function M.kept(key)
  local file = io.open(vim.fs.joinpath(dir(), key .. '.json'), 'r')
  if not file then return nil end
  local ok, value = pcall(vim.json.decode, file:read('*a'), {luanil={object=true, array=true}})
  file:close()
  return ok and value or nil
end

function M.keep(key, raw)
  vim.fn.mkdir(dir(), 'p')
  local file = io.open(vim.fs.joinpath(dir(), key .. '.json'), 'w')
  if not file then return end
  file:write(vim.json.encode(raw))
  file:close()
end

function M.forget(key)
  vim.uv.fs_unlink(vim.fs.joinpath(dir(), key .. '.json'))
end

return M
