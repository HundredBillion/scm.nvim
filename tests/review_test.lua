-- A Review explains a diff: a Tour through its changes, a Pane about the line
-- the cursor is on with its predicted values, and a Flow Map of how it gets run.
vim.env.XDG_CACHE_HOME, vim.env.XDG_DATA_HOME = vim.fn.tempname(), vim.fn.tempname()
vim.opt.runtimepath:prepend(vim.uv.cwd())
local Schema = require('scm.review.schema')
local Flow = require('scm.review.flow')
local Pane = require('scm.review.pane')
local Prompt = require('scm.review.prompt')
local Explainers = require('scm.review.explainers')

local function answer()
  return {
    tour={
      {title='Start the queue once', summary='Only the first scan wakes the queue.', from=9, to=9},
      {title='Scans one at a time', summary='Before: every scan at once. Now: one per tick.', from=3, to=6},
    },
    lines={
      {side='old', line=3, gist='before: start every scan in one go'},
      {side='new', line=3, gist='take the first job off the queue',
        detail='Removes the first job from queue and names it job. If the queue is empty, job is nil.',
        inline='job = "status"',
        paused={when='After line 3 runs, first time:', values={
          {name='job', value='"status"'}, {name='queue', value='{ "log" }', note='"status" was just taken out'}}}},
      {side='new', line=4, gist='nothing left? stop here'},
      {side='new', line=6, gist='come back on the next tick'},
    },
    flows={{from=3, to=6, note='repeats until the queue is empty', trigger={says='you press', keys='Space g s'},
      later='when Neovim is free', handoff='Neovim runs it later', outside='Outside Neovim',
      steps={
        {name='open()', says='opens the Panel', file='workspace.lua', when='now', state='ran'},
        {name='refresh()', says='plans the scans to run', when='now', state='ran'},
        {name='start_scan()', says='adds a scan to the queue', when='now', state='ran'},
        {name='drain_scans()', says='one scan at a time', when='later', state='here', changed=true, again=6, line=3},
        {name='spawn()', says='will start git status', when='later', state='not_yet'},
        {name='git status', says="this tool can't see inside", when='outside', state='not_yet'},
      }}},
  }
end

-- What an Explainer sends is checked, cut to size and put in order.
local review = assert(Schema.normalise(answer()))
assert(#review.tour == 2 and review.tour[1].from == 3, 'the tour is put in the order of the file')
assert(review.lines.old[3].gist:find('^before') and review.lines.new[3].paused.values[2].note, 'notes are kept by side and line')
assert(Schema.step_at(review, 5) == 1 and Schema.step_at(review, 9) == 2 and not Schema.step_at(review, 7), 'a line finds its step')
assert(Schema.flow_at(review, 4) == review.flows[1] and not Schema.flow_at(review, 9), 'a line finds its flow map')
local long = answer()
long.lines[2].gist = ('word '):rep(40)
long.lines[3].gist = 'two\nlines\tof it'
long.lines[4] = {side='new', line='six', gist='no number'}
long.tour[1].from = -4
long.flows[1].steps[2].when = 'never'
long.flows[1].steps[5].state = 'here'
local cut = assert(Schema.normalise(long))
assert(vim.fn.strchars(cut.lines.new[3].gist) == Schema.LIMITS.gist * Schema.WRAPPED, 'a long gist is cut to size')
assert(cut.lines.new[4].gist == 'two lines of it', 'a gist is one line')
assert(not cut.lines.new[6] and #cut.tour == 1, 'what does not name a line is dropped')
assert(cut.flows[1].steps[2].lane == 1, 'a step with no time keeps the time of the step before it')
assert(cut.flows[1].steps[5].state == 'not_yet', 'only one step is where the reader is')
assert(not Schema.normalise({tour={}, lines={}}) and not Schema.normalise('text'), 'an answer that explains nothing is refused')
local raw = Schema.decode('Here you are:\n```json\n{"tour": [], "lines": [{"line": 1, "gist": "x"}]}\n```')
assert(raw and raw.lines[1].gist == 'x', 'the JSON is found inside what a model wraps it in')
assert(not Schema.decode('no braces here') and not Schema.decode('{broken'), 'an answer with no JSON is refused')
local backwards = answer()
backwards.flows[1].steps[5].when = 'now'
assert(Schema.normalise(backwards).flows[1].steps[5].lane == 2, 'time never runs backwards in a flow map')

-- The flow map: where each step sits and what joins them.
local flow = review.flows[1]
local cards, lanes = Flow.place(flow)
assert(#lanes == 3 and lanes[1].cols == 2, 'steps are grouped into lanes of time')
assert(cards[1].row == 1 and cards[2].row == 1 and cards[3].row == 2 and cards[3].col == 2, 'the last step of a lane drops under the one before')
assert(cards[6].row == 2, 'a lane\'s only step stays on the row of the step that leads to it')
local kinds = vim.tbl_map(function(edge) return edge.kind end, Flow.edges(flow))
assert(vim.deep_equal(kinds, {'calls', 'calls', 'later', 'not_yet', 'not_yet'}), 'each join says what it is: ' .. table.concat(kinds, ','))
local staircase = table.concat(vim.tbl_map(function(row)
  return table.concat(vim.tbl_map(function(piece) return piece[1] end, row))
end, Flow.text(flow, 3)), '\n')
assert(staircase:find('1 open()', 1, true) and staircase:find('you are here · line 3', 1, true)
  and staircase:find('later · when Neovim is free', 1, true) and staircase:find('OUTSIDE NEOVIM', 1, true)
  and staircase:find('again at line 6', 1, true), 'the map drawn with characters:\n' .. staircase)
local brief = table.concat(vim.tbl_map(function(piece) return piece[1] end, Flow.brief(flow, 3)))
assert(brief:find('start_scan()', 1, true) and brief:find('drain_scans() line 3', 1, true) and brief:find('spawn()', 1, true), 'the map on one row: ' .. brief)
assert(Flow.caption(flow, 'core.lua') == 'guess · first run shown · repeats until the queue is empty · in core.lua unless tagged', 'the heading says the map is a guess')

-- The map as a picture.
local svg, height = require('scm.review.flowsvg').svg(flow, {width=1400, file='core.lua', line=3, hints={{']t', true}, {' next'}}})
assert(svg:find('^<svg ') and svg:find('</svg>$') and height > 200, 'the picture is one SVG')
for _, text in ipairs({'drain_scans()', 'YOU ARE HERE · LINE 3', 'Neovim runs it later', 'not yet called', '↻ again · line 6', 'OUTSIDE NEOVIM', 'HOW THIS LINE GETS RUN'}) do
  assert(svg:find(text, 1, true), 'the picture says "' .. text .. '"')
end
assert(not svg:lower():find('#fff') and not svg:lower():find('white'), 'no text in the picture is white')
local narrow = require('scm.review.flowsvg').svg(flow, {width=600})
assert(narrow:match('width="(%d+)') == '600', 'a narrow strip scales the picture down to fit')
local tricky = vim.deepcopy(flow)
tricky.steps[1].name = 'a<b>&"c"'
assert(require('scm.review.flowsvg').svg(tricky, {}):find('a&lt;b&gt;&amp;&quot;c&quot;', 1, true), 'names are escaped')

-- The pane: what the Review says about the reader's line, and no other.
local meta = {
  {kind=' ', new=1, old=1}, {kind=' ', new=2, old=2}, {kind='-', old=3}, {kind='-', old=4},
  {kind='+', new=3}, {kind='+', new=4}, {kind='+', new=5}, {kind='+', new=6},
  {kind=' ', new=7, old=5}, {kind=' ', new=8, old=6},
}
for i = 9, 30 do meta[#meta + 1] = {kind=' ', new=i, old=i - 2} end
local function text_of(pieces)
  local text = ''
  for _, piece in ipairs(pieces) do text = text .. piece[1] end
  return text
end
local function pane_text(rows) return table.concat(vim.tbl_map(text_of, rows), '\n') end
local about = Pane.about(review, meta, 5)
assert(about.before == 'start every scan in one go' and about.now == 'take the first job off the queue', 'an added line knows what it replaced')
local whole = Pane.rows(about, 48, math.huge)
local text = pane_text(whole)
assert(vim.deep_equal(vim.tbl_map(function(p) return p[1] end, Pane.title(about)), {' Line 3 ', ' added ', ' '}), 'the title names the line and that it was added')
assert(#whole[1] == 0 and #whole[#whole] == 0, 'an empty row above the first line and below the last')
assert(text_of(whole[2]) == 'was  start every scan in one go' and text_of(whole[3]) == 'now  take the first job off the queue', '"was" comes first, then "now":\n' .. text)
assert(text:find('▏ If paused here   predicted · not a real run ', 1, true), 'predicted values are labelled as predicted:\n' .. text)
assert(text:find('▏ queue   { "log" }', 1, true) and text:find('▏         "status" was just taken out', 1, true), 'the values line up under their names:\n' .. text)
local tinted = 0
for _, pieces in ipairs(whole) do
  if pieces.tint then
    tinted = tinted + 1
    assert(text_of(pieces):sub(1, #'▏ ') == '▏ ', 'every row of "if paused here" has the amber edge: ' .. text_of(pieces))
  end
end
assert(tinted >= 4 and not whole[#whole].tint, 'the warm block holds "if paused here" and ends with it')
assert(not text:find('nothing left', 1, true), 'nothing about another line is shown')
for _, pieces in ipairs(whole) do
  assert(vim.fn.strdisplaywidth(text_of(pieces)) <= 48, 'a row fits the pane: ' .. text_of(pieces))
end
-- Short of room, the paragraph gives way and "if paused here" does not.
local squeezed, alone = Pane.rows(about, 48, #whole - 2)
text = pane_text(squeezed)
assert(not alone and #squeezed <= #whole - 2 and text:find('queue   { "log" }', 1, true), 'the values stay:\n' .. text)
assert(text:find('paragraph hidden (2 rows) · K full explanation\n▏ If paused here', 1, true), 'the paragraph says how much of it is left:\n' .. text)
local least = Pane.rows(about, 48, 10)
assert(#least == 10 and not pane_text(least):find('Removes', 1, true) and pane_text(least):find('If paused here', 1, true), 'with no room the paragraph goes entirely:\n' .. pane_text(least))
local floor
floor, alone = Pane.rows(about, 48, 8)
assert(alone and text_of(floor[1]) == 'K full explanation', 'less room than that leaves one row: ' .. text_of(floor[1]))
floor, alone = Pane.rows(about, 48, math.huge, true)
assert(alone and #floor == 1, 'and so does a narrow window')
-- Nothing in the Pane is cut short: what does not fit on a row goes on to the next.
local wordy = vim.deepcopy(about)
wordy.paused = {when='When put() is first called, old = {a, b, c} and new = {a, x, c}',
  values={{name='kind', value='" "', note='a space means the line did not change at all'},
    {name='a_name_far_too_long_for_its_column', value='"' .. ('x'):rep(60) .. '"'}}}
local wrapped_rows = Pane.rows(wordy, 48, math.huge)
text = pane_text(wrapped_rows)
assert(not text:find('…', 1, true), 'no row ends in a cut:\n' .. text)
assert(text:find('and new = {a, x, c}', 1, true) and text:find('change at all', 1, true)
  and text:find('a_name_far_too_long_for_its_column', 1, true), 'all of it is there:\n' .. text)
assert(select(2, text:gsub('x', '')) >= 60, 'a word wider than a row is broken, not cut:\n' .. text)
for _, pieces in ipairs(wrapped_rows) do
  assert(vim.fn.strdisplaywidth(text_of(pieces)) <= 48, 'a wrapped row fits the pane: ' .. text_of(pieces))
end
local long = vim.deepcopy(about)
long.detail = ('One more sentence here. '):rep(20)
text = pane_text(Pane.rows(long, 48, math.huge))
assert(text:find('sentence here.\n… 4 more rows · K full explanation', 1, true), 'a long paragraph shows six rows at most and stops at the end of a sentence:\n' .. text)
-- Other lines.
assert(text_of(Pane.rows(Pane.about(review, meta, 1), 48, math.huge)[1]) == 'no change on this line'
  and #Pane.title(Pane.about(review, meta, 1)) == 2, 'an unchanged line says so, under a title with no tag')
local own = vim.deepcopy(review)
own.lines.new[4].before = 'ran every job without looking'
assert(Pane.about(own, meta, 6).before == 'ran every job without looking' and Pane.about(own, meta, 5).before == 'start every scan in one go', 'a line with a "before" of its own shows that one')
local with_before = answer()
with_before.lines[2].before = 'before: looped over every job'
assert(Pane.about(assert(Schema.normalise(with_before)), meta, 5).before == 'looped over every job', 'and it is kept from what the Explainer sends')
local removed = Pane.about(review, meta, 4)
assert(removed.before == 'start every scan in one go' and removed.now == 'nothing left? stop here' and not removed.paused, 'a removed line says what replaced it')
assert(Pane.title(removed)[1][1] == ' Line 4 ' and Pane.title(removed)[2][1] == ' removed ', 'and is named by its old number')
assert(text_of(Pane.rows(Pane.about(review, meta, 7), 48, math.huge)[1]):find('no note for this line', 1, true), 'a changed line with no note says so')
assert(not Pane.about(review, meta, 99), 'a row past the end has no pane')
assert(table.concat(Pane.plain(about), '\n'):find('queue = { "log" }   ("status" was just taken out)', 1, true), 'the same as plain text')
-- Where it sits: home is the top right; it moves only when it stops fitting.
local function place(...) return {Pane.place(...)} end
assert(vim.deep_equal(place(12, 20, 30), {'home', 12}), 'it starts at home')
assert(vim.deep_equal(place(12, 6, 30), {'bottom', 12}), 'and rests at the bottom when the cursor is high')
assert(vim.deep_equal(place(12, 16, 40, 'bottom'), {'bottom', 12}), 'it stays where it is while it fits')
assert(vim.deep_equal(place(12, 30, 40, 'bottom'), {'home', 12}), 'and moves when it does not')
assert(vim.deep_equal(place(12, 10, 20), {'bottom', 9}), 'when neither side holds it, the larger one does')
assert(vim.deep_equal(place(12, 10, 20, 'home'), {'home', 7}), 'but it does not change sides for a row or two')
assert(vim.deep_equal(Pane.wrap('one two three four', 9), {'one two', 'three', 'four'}), 'prose wraps at spaces')

-- What is asked, and where answers are kept.
local numbered = Prompt.numbered({'a', 'old', 'new', 'z'}, {{kind=' ', new=1, old=1}, {kind='-', old=2}, {kind='+', new=2}, {kind=' ', new=3, old=3}},
  {{row=2, removed=1, added=1}})
assert(numbered == '      1 | a\n-     2 | old\n+     2 | new\n      3 | z', 'each line carries its kind and number:\n' .. numbered)
assert(not Prompt.numbered({'a'}, {{kind=' ', new=1}}, {}), 'nothing changed, nothing to ask')
local question = Prompt.build('lua/core.lua', numbered, true)
assert(question:find('File: lua/core.lua', 1, true) and question:find('"flows"', 1, true) and question:find('PREDICTION', 1, true)
  and question:find('You may read other files', 1, true), 'the question names the file, the shape and the rules')
assert(not Prompt.build('x', numbered, false):find('You may read other files', 1, true), 'a service that cannot read files is not told to')
assert(Prompt.build('x', numbered, false, 'like I am ten'):find('written this way.-like I am ten') and not Prompt.build('x', numbered, false, ' '):find('written this way', 1, true), 'the reader\'s style is part of the question')
assert(Prompt.key('a.lua', 'old', 'new', 'like I am ten') ~= Prompt.key('a.lua', 'old', 'new'), 'and another style is another Review')
local refused, why = Explainers.put({name='Wrong', kind='claude_code', command='explain things simply'})
assert(not refused and why:find('no program named "explain"', 1, true), 'a sentence is not taken as the program to run: ' .. tostring(why))
assert(Explainers.put({name='Styled', kind='command', command='cat', style='like I am ten'}).style == 'like I am ten' and Explainers.remove('Styled'), 'a service keeps its style')
local key = Prompt.key('a.lua', 'old', 'new')
assert(key == Prompt.key('a.lua', 'old', 'new') and key ~= Prompt.key('a.lua', 'old', 'newer') and key ~= Prompt.key('b.lua', 'old', 'new'), 'a change has one name')
assert(Prompt.kept(key) == nil, 'nothing is kept at first')
Prompt.keep(key, answer())
assert(Prompt.kept(key).tour[1].title == 'Start the queue once', 'an answer is kept')
Prompt.forget(key)
assert(Prompt.kept(key) == nil, 'and forgotten')

-- The Explainers: Claude Code first, any service added, no key kept.
Explainers.setup({})
assert(Explainers.active().kind == 'claude_code' and #Explainers.list() == 1, 'Claude Code is the Explainer SCM starts with')
local kept, why = Explainers.put({name='Local', kind='openai', url='http://localhost:11434/v1', model='llama', key='SECRET', key_env='LOCAL_KEY'})
assert(kept and kept.key == nil and kept.key_env == 'LOCAL_KEY', 'a key is never kept, only where to find it')
assert(not Explainers.put({name='Bad', kind='telepathy'}) and not Explainers.put({kind='openai'}), 'a service needs a name and a known kind')
assert(Explainers.use('Local') and Explainers.active().name == 'Local' and not Explainers.use('Nobody'), 'a service is chosen by name')
local saved = io.open(vim.fn.stdpath('data') .. '/scm/explainers.json'):read('*a')
assert(saved:find('Local', 1, true) and not saved:find('SECRET', 1, true), 'what is saved holds no key')
Explainers.setup({})
assert(Explainers.active().name == 'Local' and #Explainers.list() == 2, 'services and the choice are remembered')
assert(Explainers.remove('Local') and Explainers.active().name == 'Claude Code', 'removing the service in use falls back')
kept, why = Explainers.remove('Claude Code')
assert(not kept and why:find('at least one'), 'the last service is kept')
Explainers.setup({use='Mine', services={{name='Mine', kind='command', command='cat'}}})
assert(Explainers.get('Mine').fixed and Explainers.active().name == 'Mine', 'services can be set in the configuration, and the one named is used')
assert(Explainers.put({name='Other', kind='command', command='cat'}))
Explainers.setup({use='Mine', services={{name='Mine', kind='command', command='cat'}}})
assert(Explainers.active().name == 'Mine', 'adding a service on the admin page does not override the configuration')
assert(Explainers.use('Claude Code'))
Explainers.setup({use='Mine', services={{name='Mine', kind='command', command='cat'}}})
assert(Explainers.active().name == 'Claude Code', 'a service chosen on the admin page holds until another is chosen')
assert(Explainers.remove('Other'))
assert(Explainers.use('Mine') and Explainers.active().name == 'Mine', 'and are chosen like any other')
assert(not Explainers.put({name='Typed', kind='claude_code', command={'claude'}}), 'a field that is not text is refused')
kept, why = Explainers.put({name='Plain', kind='anthropic', url='http://example.com'})
assert(not kept and why:find('https', 1, true), 'a key is never sent over plain http to another machine')
assert(Explainers.safe_url('http://127.0.0.1:8080/v1') and Explainers.safe_url('http://[::1]:1/')
  and Explainers.safe_url('https://example.com') and not Explainers.safe_url('ftp://example.com')
  and not Explainers.safe_url('http://localhost.example.com/'), 'only this machine may be reached over plain http')
kept, why = Explainers.put({name='Mine', kind='command', command='rm'})
assert(not kept and why:find('configuration'), 'and those are not changed from the admin page')
local function ask(service, prompt)
  local err, out, done
  Explainers.ask(service, prompt, {cwd=vim.uv.cwd()}, function(e, o) err, out, done = e, o, true end)
  assert(vim.wait(10000, function() return done end, 10), 'the service answers')
  return err, out
end
local err, out = ask(Explainers.get('Mine'), 'hello there')
assert(not err and vim.trim(out) == 'hello there', 'a command is sent the question on its standard input')
err = ask({name='Broken', kind='command', command='echo nope >&2; exit 3'}, 'x')
assert(err == 'nope', 'a failing command says why: ' .. tostring(err))
err = ask({name='Silent', kind='command', command='exit 3'}, 'x')
assert(err == 'it stopped with exit code 3', 'a command that fails without a word still says how: ' .. tostring(err))
err, out = ask({name='Where', kind='command', command='printf "%s|%s" "$SCM_REPO" "$PWD"'}, 'x')
assert(not err and out == vim.uv.cwd() .. '|' .. vim.uv.fs_realpath(vim.fn.stdpath('cache')),
  'a command runs outside the repository and is told where it is: ' .. tostring(out))
err = ask({name='Endless', kind='command', command='yes'}, 'x')
assert(err == 'its answer was too long', 'a command that never stops printing is stopped: ' .. tostring(err))
err = ask({name='Clear', kind='anthropic', url='http://example.com', key_env='HOME'}, 'x')
assert(err and err:find('https', 1, true), 'a key is not sent to a plain http address: ' .. tostring(err))
err = ask({name='Default key', kind='anthropic', url='https://127.0.0.1:1'}, 'x')
assert(err and not err:find('no key', 1, true), 'an API service with no key variable named uses the usual one: ' .. tostring(err))
err = ask({name='Keyless', kind='anthropic', key_env='SCM_TEST_NO_SUCH_KEY'}, 'x')
assert(err:find('SCM_TEST_NO_SUCH_KEY', 1, true), 'a service with no key says which variable is missing')
err = ask({name='Gone', kind='claude_code', command='scm-no-such-program'}, 'x')
assert(err and err:find('scm%-no%-such%-program'), 'a missing program is named: ' .. tostring(err))
-- A stand-in for Claude Code: it prints the JSON the real one prints.
local fake = vim.fn.tempname()
local handle = io.open(fake, 'w')
handle:write('#!/bin/sh\ncat > "$0.asked"\necho "$@" > "$0.args"\nprintf \'%s\' \'{"is_error": false, "result": "the answer"}\'\n')
handle:close()
vim.uv.fs_chmod(fake, 493)
err, out = ask({name='Fake', kind='claude_code', command=fake, model='some-model'}, 'the question')
assert(not err and out == 'the answer', 'Claude Code\'s answer is read from its result')
assert(io.open(fake .. '.asked'):read('*a') == 'the question', 'and it is asked on its standard input')
local limited = vim.fn.tempname()
vim.fn.writefile({'#!/bin/sh', 'cat > /dev/null', [[printf '%s' '{"is_error": true, "result": "You have hit your spend limit"}']], 'exit 1'}, limited)
vim.uv.fs_chmod(limited, 493)
err = ask({name='Limited', kind='claude_code', command=limited}, 'x')
assert(err == 'You have hit your spend limit', 'a failure Claude Code reports is said in its own words: ' .. tostring(err))
local args = io.open(fake .. '.args'):read('*a')
assert(args:find('--tools Read,Grep,Glob', 1, true) and args:find('--model some-model', 1, true) and args:find('-p', 1, true), 'it may only read: ' .. args)
assert(args:find('--setting-sources user', 1, true) and args:find('--strict-mcp-config', 1, true), 'and the repository it reads cannot configure it: ' .. args)
assert(args:find('--restricted', 1, true) and args:find('--safe-mode', 1, true), 'and it cannot read past the repository: ' .. args)
-- A stand-in for curl: it keeps what it was told and answers as the service would.
local bin = vim.fn.tempname()
vim.fn.mkdir(bin, 'p')
handle = io.open(bin .. '/curl', 'w')
handle:write('#!/bin/sh\necho "$@" > "' .. bin .. '/args"\ncat > "' .. bin .. '/config"\nprintf \'%s\' \'{"content":[{"type":"text","text":"from the API"}],"stop_reason":"end_turn"}\'\n')
handle:close()
vim.uv.fs_chmod(bin .. '/curl', 493)
local path = vim.env.PATH
vim.env.PATH = bin .. ':' .. path
err, out = ask({name='API', kind='anthropic', key_cmd='printf "sk-first-line\\nurl = https://elsewhere.invalid\\n"'}, 'the question')
vim.env.PATH = path
assert(not err and out == 'from the API', 'the Claude API\'s answer is read from its text: ' .. tostring(err))
local config = io.open(bin .. '/config'):read('*a')
assert(config:find('header = "x-api-key: sk-first-line"', 1, true) and not config:find('elsewhere', 1, true), 'a key is its first line, and nothing after it reaches curl:\n' .. config)
assert(config:find('url = "https://api.anthropic.com/v1/messages"', 1, true) and config:find('anthropic-version: 2026-10-21', 1, true), 'the request goes where the service is')
assert(not io.open(bin .. '/args'):read('*a'):find('sk-first-line', 1, true), 'the key is not among the arguments other programs can see')
-- A question can be taken back.
local answered = false
local cancel = Explainers.ask({name='Slow', kind='command', command='sleep 30; echo late'}, 'x', {}, function() answered = true end)
vim.wait(200)
cancel()
vim.wait(300)
assert(not answered, 'a question taken back is never answered')
-- "3[0]" matches "30" but not itself, so pgrep does not find the shell that runs it.
local left = vim.trim(vim.fn.system('pgrep -f "sleep 3[0]; echo late" || true'))
assert(left == '', 'a question taken back stops the service: ' .. left)

-- A diff with a Review kept for it.
local root = vim.fn.tempname()
vim.fn.mkdir(root, 'p')
local function git(...) assert(vim.system({'git', '-C', root, ...}):wait().code == 0, 'git ' .. table.concat({...}, ' ')) end
local function write(lines)
  local file = assert(io.open(root .. '/core.lua', 'w'))
  file:write(table.concat(lines, '\n') .. '\n')
  file:close()
end
local tail = {'end', 'local function start_scan(job)', '  queue[#queue + 1] = job', '  if #queue == 1 then vim.schedule(drain_scans) end', 'end'}
for i = 1, 30 do tail[#tail + 1] = '-- ' .. i end
local old = vim.list_extend({'local queue = {}', 'local function drain_scans()', '  for _, job in ipairs(queue) do spawn(job) end', '  queue = {}'}, tail)
local new = vim.list_extend({'local queue = {}', 'local function drain_scans()', '  local job = table.remove(queue, 1)', '  if not job then return end', '  spawn(job)', '  vim.schedule(drain_scans)'}, tail)
git('init', '-q', '-b', 'main')
git('config', 'user.email', 'scm@example.invalid')
git('config', 'user.name', 'SCM Test')
write(old)
git('add', '-A')
git('commit', '-q', '-m', 'one')
write(new)
local fake_review = vim.fn.tempname()
handle = io.open(fake_review, 'w')
handle:write('#!/bin/sh\ncat > /dev/null\ncat "$0.json"\n')
handle:close()
vim.uv.fs_chmod(fake_review, 493)
handle = io.open(fake_review .. '.json', 'w')
handle:write('Here is the review.\n' .. vim.json.encode(answer()))
handle:close()
-- A script's screen is 80 cells wide and 24 tall: the pane is let into less than it asks for.
Pane.NARROW = 60
local diff = require('scm.diff')
require('scm').setup({renderer='terminal', review={explainer='Stand-in', explainers={{name='Stand-in', kind='command', command=fake_review}}}})
Explainers.use('Stand-in')
local Review = require('scm.review')
local window = vim.api.nvim_get_current_win()
local function show()
  local shown
  diff.open({repo=root, path='core.lua', file=root .. '/core.lua', group='changes'}, function(buf) shown = buf end)
  assert(vim.wait(5000, function() return shown end, 10), 'the diff appears')
  return shown
end
local function floats()
  return vim.tbl_filter(function(win) return vim.api.nvim_win_get_config(win).relative ~= '' end, vim.api.nvim_tabpage_list_wins(0))
end
local function bar_text()
  for _, win in ipairs(floats()) do
    -- Each row starts with the bar's blue edge; the rows are read as one line.
    local rows = vim.tbl_map(function(row) return (row:gsub('^▍ ', '')) end,
      vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false))
    local line = table.concat(rows, ' ')
    if vim.api.nvim_win_get_config(win).zindex == 21 then return line end
  end
end
local function bar_window()
  for _, win in ipairs(floats()) do
    if vim.api.nvim_win_get_config(win).zindex == 21 then return win end
  end
end
local buf = show()
assert(bar_text():find('\\e explain this change with Stand-in', 1, true), 'a diff with no Review says how to get one: ' .. tostring(bar_text()))
assert(not require('scm.review.strip').window(), 'and has no strip under it')
assert(vim.fn.maparg('\\e', 'n', false, true).buffer == 1 and vim.fn.maparg(']t', 'n', false, true).buffer == 1, 'the keys are bound in the diff')
-- Asking: nothing is sent until the reader asks.
Review.pane()
assert(bar_text():find('Stand-in is reading this change', 1, true), 'the bar says who is reading: ' .. bar_text())
assert(vim.wait(10000, function() return bar_text():find('Tour', 1, true) ~= nil end, 10), 'the Review arrives: ' .. bar_text())
assert(bar_text():find('Tour  1 of 2', 1, true) and bar_text():find('Scans one at a time', 1, true)
  and bar_text():find('lines 3–6', 1, true), 'the bar shows the step the cursor is in: ' .. bar_text())
-- A bar with more to say than one row holds takes more rows, and cuts nothing.
assert(vim.api.nvim_win_get_height(bar_window()) > 1 and not bar_text():find('…', 1, true)
  and bar_text():find('Now: one per tick.', 1, true), 'the bar wraps what does not fit: ' .. bar_text())
assert(vim.fn.winline() > vim.api.nvim_win_get_height(bar_window()), 'the line the reader is on is not under the bar')
local bar_rows_now = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bar_window()), 0, -1, false)
local function column(row, text) return vim.fn.strdisplaywidth(row:sub(1, row:find(text, 1, true) - 1)) end
assert(bar_rows_now[2]:find('^▍ +Before: every scan at once') and column(bar_rows_now[2], 'Before') == column(bar_rows_now[1], 'Scans'),
  'a summary that does not fit beside the title goes, whole, under it:\n' .. table.concat(bar_rows_now, '\n'))
for _, row in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(bar_window()), 0, -1, false)) do
  assert(vim.fn.strdisplaywidth(row) <= vim.api.nvim_win_get_width(bar_window()), 'a row of the bar fits it: ' .. row)
end
local strip = require('scm.review.strip').window()
assert(strip and vim.api.nvim_win_get_height(strip) == 1, 'a short editor shows one row of the flow map under the diff')
Review.map()
strip = require('scm.review.strip').window()
assert(strip and vim.api.nvim_win_get_height(strip) > 5, 'and \\m opens the whole map')
local strip_text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(strip), 0, -1, false), '\n')
assert(strip_text:find('drain_scans()', 1, true) and strip_text:find(']t next step (2 of 2)', 1, true) and strip_text:find('K full explanation', 1, true)
  and strip_text:find('g? all keys', 1, true) and not strip_text:find('[t previous', 1, true), 'with the keys under it, whole, the least needed left out of a narrow window:\n' .. strip_text)
assert(vim.wo[strip].winbar:find('HOW THIS LINE GETS RUN', 1, true) and vim.wo[strip].winfixwidth, 'and its heading above')
assert(Review.step(1) and vim.api.nvim_win_get_cursor(window)[1] == 11, ']t goes to the next step, at row ' .. vim.api.nvim_win_get_cursor(window)[1])
local function marked(group)
  local bar_buf = vim.api.nvim_win_get_buf(bar_window())
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bar_buf, -1, 0, -1, {details=true})) do
    if mark[4].hl_group == group then return true end
  end
end
assert(bar_text():find('Tour  2 of 2', 1, true) and marked('ScmReviewTourDone') and marked('ScmReviewTourNow'),
  'the step left behind is marked done, beside the one you are on: ' .. bar_text())
assert(Review.step(1) and vim.api.nvim_win_get_cursor(window)[1] == 5, 'and wraps to the first')
assert(Review.step(-1) and vim.api.nvim_win_get_cursor(window)[1] == 11, '[t goes back')
Review.step(1)
-- The map folds to one row, which leaves the diff the room.
Review.map()
strip = require('scm.review.strip').window()
assert(vim.api.nvim_win_get_height(strip) == 1 and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(strip), 0, 1, false)[1]:find('\\m map', 1, true), 'the map folds to one row')
-- The screen: the pane over the right of the code, the marks in the gutter.
vim.o.lines = 40
vim.cmd('doautocmd CursorMoved')
vim.cmd('redraw')
local function screen_row(row)
  local text = ''
  for col = 1, vim.o.columns do text = text .. vim.fn.screenstring(row, col) end
  return text
end
local function screen_text()
  local rows = {}
  for row = 1, vim.o.lines do rows[row] = screen_row(row) end
  return table.concat(rows, '\n')
end
local all = screen_text()
assert(all:find('╭ Line 3  added  ─', 1, true) and all:find('now  take the first job off the queue', 1, true), 'the pane explains the reader\'s line:\n' .. all)
assert(all:find('▏ If paused here   predicted · not a real run', 1, true), 'the predicted values are drawn')
assert(not all:find('nothing left? stop here', 1, true), 'and no other line is explained')
assert(all:find('▶  3+', 1, true) and all:find('▏  4+', 1, true), 'the gutter marks the step')
assert(vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == 'local queue = {}', 'none of it is text in the buffer')
local pane = assert(Review.pane_window(window), 'the pane is a window floating over the diff')
local pane_place = vim.api.nvim_win_get_config(pane)
assert(not pane_place.focusable, 'that the cursor never enters')
local cursor_row = vim.fn.screenpos(window, 5, 1).row
local top = vim.fn.win_screenpos(pane)[1]
assert(top > cursor_row + 1 or top + vim.api.nvim_win_get_height(pane) + 1 < cursor_row - 1, 'it leaves the reader\'s line and a row beside it clear:\n' .. all)
assert(vim.fn.win_screenpos(pane)[1] + vim.api.nvim_win_get_height(pane) < vim.fn.win_screenpos(window)[1] + vim.api.nvim_win_get_height(window) + 1, 'and ends above the map')
vim.api.nvim_win_set_cursor(window, {1, 0})
vim.cmd('doautocmd CursorMoved')
vim.cmd('redraw')
assert(screen_text():find('1  local queue = {}', 1, true), 'line 1 is not hidden under the bar:\n' .. screen_text())
assert(screen_text():find('╭ Line 1  ─', 1, true) and screen_text():find('no change on this line', 1, true), 'an unchanged line keeps its title:\n' .. screen_text())
-- The pane is put away, and brought back.
vim.api.nvim_win_set_cursor(window, {5, 0})
Review.pane()
vim.cmd('redraw')
assert(not Review.shown() and not Review.pane_window(window) and not screen_text():find('If paused here', 1, true), '\\e hides the pane')
Review.pane()
vim.cmd('redraw')
assert(Review.shown() and screen_text():find('If paused here', 1, true), 'and shows it again')
-- The Review is kept: the next time nothing is asked.
os.remove(fake_review .. '.json')
vim.cmd('enew')
assert(#floats() == 0 and not require('scm.review.strip').window(), 'leaving the diff takes the bar and the strip away')
show()
assert(bar_text():find('Tour', 1, true), 'a kept Review is shown at once: ' .. bar_text())
-- A change to the file is a different change.
table.insert(new, 5, '  -- one more line')
write(new)
diff.reload()
assert(vim.wait(5000, function() return bar_text() and bar_text():find('explain this change', 1, true) ~= nil end, 10), 'an edited file has no Review yet: ' .. tostring(bar_text()))
Review.pane()
assert(vim.wait(10000, function() return bar_text():find('Could not explain', 1, true) ~= nil end, 10), 'a failure is said in the bar: ' .. bar_text())
-- The admin page.
require('scm').explainers()
local page = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
assert(page:find('● Stand-in', 1, true) and page:find('○ Claude Code', 1, true) and page:find('A key is never kept here', 1, true), 'the admin page lists the services:\n' .. page)
vim.cmd('normal! gg')
vim.fn.search('Claude Code')
require('scm.review.admin').use()
assert(Explainers.active().name == 'Claude Code', 'Enter chooses the service under the cursor')
assert(vim.fn.exists(':ScmExplainers') == 2, 'and there is a command for the page')
vim.api.nvim_win_close(0, true)
-- In a Sprite Terminal with a dock under the editor, the map is a picture.
local opened, updates, closed = {}, {}, 0
package.loaded['sprite'] = {open=function(opts, done)
  opened[#opened + 1] = opts
  if opts.refuse then return end
  vim.schedule(function()
    if DOCK_ERROR then done(DOCK_ERROR); return end
    done(nil, {update=function(_, description, cb) updates[#updates + 1] = description; cb() end,
      close=function() closed = closed + 1 end, focus_editor=function() end})
  end)
end}
require('scm').setup({renderer='terminal', review={explainer='Stand-in', explainers={{name='Stand-in', kind='command', command=fake_review}}}})
Prompt.keep(Prompt.key('core.lua', table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n'), answer())
vim.cmd('enew')
show()
vim.api.nvim_win_set_cursor(window, {5, 0})
-- The map was left folded to one row above.
Review.map()
assert(vim.wait(2000, function() return #updates > 0 end, 10), 'the picture is sent to the dock')
assert(opened[1].side == 'bottom' and opened[1].height > 100, 'the dock is asked for under the editor')
local image = updates[#updates].root.children[1]
assert(image.kind == 'image' and image.svg:find('drain_scans()', 1, true) and image.svg:find('YOU ARE HERE · LINE 3', 1, true), 'the picture is the flow map')
assert(not require('scm.review.strip').window() and require('scm.review.strip').docked(), 'and no window of characters is shown with it')
-- The dock takes rows from the editor; that must not make the editor "short" and fold the map away again.
local lines_before = vim.o.lines
vim.o.lines = 20
assert(not require('scm.review.strip').short(), 'an editor made shorter by the dock keeps the dock')
vim.o.lines = lines_before
local sent = #updates
opened[1].on_event({type='resize', width=900, height=252})
assert(vim.wait(2000, function() return #opened == 2 and #updates > sent end, 10), 'a dock of another width is opened again to fit its picture')
assert(closed == 1 and opened[2].height < opened[1].height, 'at the height the narrower picture needs: ' .. opened[2].height)
sent = #updates
opened[2].on_event({type='resize', width=900, height=opened[2].height})
Review.sync()
vim.wait(100)
assert(#updates == sent and #opened == 2, 'the same picture is not sent twice, and the dock is not opened a third time')
Review.map()
assert(closed == 2 and require('scm.review.strip').window(), 'one row of the map is characters, and the dock is given back')
Review.map()
-- A host with no such dock gets characters.
DOCK_ERROR = {code='unsupported'}
require('scm').setup({renderer='terminal', review={explainer='Stand-in', explainers={{name='Stand-in', kind='command', command=fake_review}}}})
vim.cmd('enew')
show()
assert(vim.wait(2000, function() return require('scm.review.strip').window() ~= nil end, 10), 'a host without the dock gets the map in characters')
package.loaded['sprite'] = nil
-- A step that names a line the file does not have is left out of the tour.
local far = answer()
far.tour[#far.tour + 1] = {title='Nowhere', from=5000, to=5001}
Prompt.keep(Prompt.key('core.lua', table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n'), far)
vim.cmd('enew')
show()
assert(bar_text():find('of 2', 1, true) and not bar_text():find('of 3', 1, true), 'the tour holds only steps that can be walked to: ' .. bar_text())
-- Steps that overlap: ]t still reaches each of them.
local nested = answer()
nested.tour = {{title='All of it', from=1, to=9}, {title='The middle', from=3, to=4}, {title='The end', from=7, to=8}}
Prompt.keep(Prompt.key('core.lua', table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n'), nested)
vim.cmd('enew')
show()
local reached = {}
for _ = 1, 3 do
  Review.step(1)
  reached[#reached + 1] = bar_text():match('Tour  (%d) of 3') or '?'
end
table.sort(reached)
assert(table.concat(reached, ',') == '1,2,3', 'steps that overlap are each reached: ' .. table.concat(reached, ','))
-- The rows kept above line 1 follow the bar as it grows and shrinks.
local static = vim.api.nvim_create_namespace('scm.review.static')
local function filler(win)
  local mark = vim.api.nvim_buf_get_extmark_by_id(vim.api.nvim_win_get_buf(win), static, 1, {details=true})
  return mark[3] and #mark[3].virt_lines or 0
end
Prompt.keep(Prompt.key('core.lua', table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n'), answer())
-- A window too narrow for a bar, where the reader sets their own scrolloff, then made wide enough for one.
vim.fn.writefile(old, root .. '/other.lua')
git('add', 'other.lua')
git('commit', '-q', '-m', 'other')
vim.fn.writefile(new, root .. '/other.lua')
Prompt.keep(Prompt.key('other.lua', table.concat(old, '\n') .. '\n', table.concat(new, '\n') .. '\n'), answer())
vim.cmd('enew')
vim.cmd('vsplit')
local split = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(split, 25)
local other_shown
diff.open({repo=root, path='other.lua', file=root .. '/other.lua', group='changes'}, function(b) other_shown = b end)
assert(vim.wait(5000, function() return other_shown end, 10), 'the other diff appears')
assert(not bar_window(), 'a window 25 cells wide has no bar')
vim.wo[split].scrolloff = 7
vim.api.nvim_win_set_width(split, 40)
Review.sync()
Review.step(1)
local tall = vim.api.nvim_win_get_height(bar_window())
assert(tall > 2 and filler(split) == tall, 'a bar of several rows keeps as many above line 1: ' .. filler(split) .. ' for ' .. tall)
assert(vim.wo[split].scrolloff == 7, 'the reader\'s own scrolloff is kept while the bar is up: ' .. vim.wo[split].scrolloff)
vim.api.nvim_win_set_width(split, 75)
Review.sync()
local shorter = vim.api.nvim_win_get_height(bar_window())
assert(shorter < tall and filler(split) == shorter, 'and fewer when it shrinks: ' .. filler(split) .. ' for ' .. shorter)
vim.api.nvim_win_set_width(split, 25)
Review.sync()
assert(not bar_window() and vim.wo[split].scrolloff == 7, 'when the bar goes, the reader\'s scrolloff is as it was: ' .. vim.wo[split].scrolloff)
vim.cmd('close')
vim.api.nvim_set_current_win(window)
-- A service that fails as it is asked: the bar says so and \e can ask again.
local real_ask = Explainers.ask
local calls = 0
Explainers.ask = function() calls = calls + 1; error('the service is set up wrongly') end
table.insert(new, 6, '  -- yet another line')
write(new)
show()
assert(vim.wait(5000, function() return bar_text() and bar_text():find('explain this change', 1, true) ~= nil end, 10))
Review.pane()
assert(bar_text():find('Could not explain this change: the service is set up wrongly', 1, true), 'a service that fails at once is said in the bar: ' .. bar_text())
Review.pane()
assert(calls == 2, 'and is not left waiting: \\e asks again')
-- A diff closed while it is explained stops the Explainer and its clock.
local function timers()
  local count = 0
  vim.uv.walk(function(handle) if handle:get_type() == 'timer' and handle:is_active() then count = count + 1 end end)
  return count
end
local taken_back = 0
Explainers.ask = function() calls = calls + 1; return function() taken_back = taken_back + 1 end end
local timers_before = timers()
Review.pane()
assert(bar_text():find('is reading this change', 1, true) and timers() == timers_before + 1, 'the bar counts the seconds')
vim.cmd('bwipeout! ' .. vim.api.nvim_win_get_buf(window))
vim.wait(50)
assert(taken_back == 1 and timers() == timers_before, 'closing the diff stops the Explainer and the clock')
-- K asked again while it is being answered goes back to the window waiting, and closing it takes the question back.
table.remove(new, 6)
write(new)
show()
vim.api.nvim_win_set_cursor(window, {5, 0})
local asked_before, taken_before = calls, taken_back
Review.ask()
local waiting_win = vim.api.nvim_get_current_win()
assert(waiting_win ~= window, 'K opens a window that waits for the answer')
vim.api.nvim_set_current_win(window)
Review.ask()
assert(calls == asked_before + 1 and vim.api.nvim_get_current_win() == waiting_win, 'K again asks nothing new')
vim.api.nvim_win_close(waiting_win, true)
assert(taken_back == taken_before + 1, 'closing the window takes the question back')
Explainers.ask = real_ask
assert(pcall(require('scm').setup, {renderer='terminal', review=true}), 'review = true means on')
-- Turned off.
require('scm').setup({renderer='terminal', review=false})
show()
assert(#floats() <= 1 and not require('scm.review.strip').window(), 'with review off a diff is as it was')
assert(vim.fn.maparg('\\e', 'n', false, true).buffer ~= 1 and vim.fn.exists(':ScmExplainers') == 0, 'its keys and its command are gone')
print('OK review: a diff explains itself')
