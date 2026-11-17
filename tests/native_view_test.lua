-- The native Renderer: what it sends Sprite, and how keys and clicks come back.
vim.opt.runtimepath:prepend(vim.uv.cwd())
local sent = {rows={}, state={}, assets={}, updates={}}
local request, focused = nil, 0
local dock = {
  features={['virtual-list-rows-v2']=true},
  assets=function(_, entries, done) sent.assets[#sent.assets + 1] = entries; done() end,
  update=function(_, description, done) sent.updates[#sent.updates + 1] = description; done() end,
  rows=function(_, revision, rows, selected, done)
    sent.rows[#sent.rows + 1] = {revision=revision, rows=rows, selected=selected}
    done()
  end,
  state=function(_, revision, patch, done) sent.state[#sent.state + 1] = {revision=revision, patch=patch}; done() end,
  focus=function(_, done) focused = focused + 1; if done then done() end end,
  focus_editor=function(_, done) if done then done() end end,
  close=function() end,
}
package.loaded.sprite = {open=function(opts, done) request = opts; done(nil, dock) end}

local model = require('scm.model')
local view_module = require('scm.views.sprite')
local entries = {{name='api', path='/r/api', branch='main', files={
  {path='.gitignore', xy='.M'}, {path='src/app/main.lua', xy='A.'}, {path='src/app/old.lua', xy='.D'},
}}}
local actions = {}
local view = view_module.open({native={icon_theme=false}}, function(name, index, arg)
  actions[#actions + 1] = {name=name, index=index, arg=arg}
end, function() end, function(err) error(vim.inspect(err)) end)
local function last() return sent.rows[#sent.rows] end
local function by_text(text)
  for _, row in ipairs(last().rows) do
    if row.text == text then return row end
  end
  error('no row ' .. text)
end
local function key(name, text) request.on_event({type='input', key=name, text=text}) end

-- The description is VS Code's layout: title, a "Changes" section with its buttons, 22-pixel rows.
local root = request.description.root
assert(root.heading.text == 'Source Control' and root.section.text == 'Changes' and root.row_height == 22)
local header_actions = vim.tbl_map(function(a) return a.id end, root.section.actions)
assert(vim.deep_equal(header_actions, {'view', 'commit', 'refresh', 'menu'}), vim.inspect(header_actions))
assert(root.section.action == 'fold', 'clicking the section folds it')

-- List view: commit box, button, groups with counts, files with directory, letter and actions.
local rows = model.rows(entries, {})
view:render(rows, 1, {mode='list'})
local input, button = last().rows[1], last().rows[2]
assert(input.kind == 'input' and input.height == 36 and input.text == '' and input.indent == 11)
assert(input.placeholder:find('to commit on "main"', 1, true) and input.cursor == nil, 'an idle commit box has no cursor')
assert(button.kind == 'button' and button.text == 'Commit' and button.height == 36 and button.actions[1].id == 'menu')
local staged = by_text('Staged Changes')
assert(staged.count == '1' and staged.indent == 0 and staged.leading and not staged.icon, 'a group has a chevron and a count')
assert(staged.actions[1].id == 'unstage', 'the Staged Changes group can be unstaged')
local main = by_text('main.lua')
assert(main.indent == 8 and main.description == 'src/app' and main.badge.text == 'A' and main.badge.color == '#81b88b')
assert(main.icon and not main.leading, 'a file in the list has an icon and no chevron slot')
assert(main.guides[1].offset == 8 and main.guides[1].id == staged.id, 'a file is guided by its group')
local old = by_text('old.lua')
assert(old.strikethrough == true and old.badge.text == 'D', 'a deleted file is struck through')
assert(vim.deep_equal(vim.tbl_map(function(a) return a.id end, old.actions), {'open', 'discard', 'stage'}))
for _, row in ipairs(last().rows) do
  for _, name in ipairs({'icon', 'leading', 'trailing'}) do
    if row[name] then
      local registered = false
      for _, batch in ipairs(sent.assets) do registered = registered or batch[row[name]] ~= nil end
      assert(registered, name .. ' ' .. row[name] .. ' was registered before its row')
    end
  end
end

-- Moving the selection sends only the selection, never the rows again.
local frames = #sent.rows
key('j'); key('down')
assert(#sent.rows == frames, 'j and down do not resend rows')
assert(#sent.state == 2 and sent.state[2].patch.selected == last().rows[3].id and sent.state[2].patch.reveal == last().rows[3].id)
assert(view:selection() == 3)

-- Keys run the shared actions on the selected row.
for name, expected in pairs({s='stage', u='unstage', x='discard', t='view', c='compose', m='menu', r='refresh'}) do
  actions = {}
  key(name, name)
  assert(#actions == 1 and actions[1].name == expected and actions[1].index == 3, name .. ' runs ' .. expected)
end
actions = {}
key('cmd-enter')
assert(actions[1].name == 'commit', 'Cmd+Enter commits')

-- A button on a row acts on that row; a header button acts on the Panel.
actions = {}
request.on_event({type='list_action', revision=last().revision, action='stage', row=old.id})
assert(actions[1].name == 'stage' and last().rows[actions[1].index].id == old.id, 'a row button targets its own row')
actions = {}
request.on_event({type='list_action', revision=last().revision, action='view'})
assert(actions[1].name == 'view', 'a header button runs its action')
actions = {}
request.on_event({type='list_action', revision=last().revision - 1, action='stage', row=old.id})
assert(#actions == 0, 'a button press from stale rows is ignored')

-- Tree view: the description changes its toggle icon, folders are compacted, files keep a chevron slot.
local updates = #sent.updates
view:render(model.rows(entries, {mode='tree'}), 1, {mode='tree'})
assert(#sent.updates == updates + 1, 'switching the view sends a new description')
local dir = by_text('src/app')
assert(dir.leading and dir.icon and dir.indent == 8, 'a folder has a chevron and an icon')
assert(by_text('main.lua').indent == 16 and by_text('main.lua').leading == 'scm-blank' and not by_text('main.lua').description)
view:render(model.rows(entries, {mode='tree'}), 1, {mode='tree'})
assert(#sent.updates == updates + 1, 'the same view sends no new description')

-- Typing: while the commit box is edited, keys become text and never navigate or act.
view:render(model.rows(entries, {messages={['/r/api']='fix'}}), 1, {mode='list', editing=model.input_id('/r/api'), cursor=3})
assert(last().rows[1].text == 'fix' and last().rows[1].cursor == 3, 'the edited commit box carries its cursor')
actions = {}
key('j', 'j'); key('s', 's'); key('shift-a', 'A'); key('space', ' ')
assert(#actions == 4, 'every typed key is delivered')
for i, typed in ipairs({'j', 's', 'A', ' '}) do
  assert(actions[i].name == 'edit' and actions[i].index == nil and actions[i].arg.op == 'insert' and actions[i].arg.text == typed)
end
actions = {}
key('backspace'); key('left'); key('ctrl-w'); key('escape'); key('enter', '\n'); key('ctrl-enter')
local got = vim.tbl_map(function(a) return a.name .. (a.arg and (':' .. a.arg.op) or '') end, actions)
assert(vim.deep_equal(got, {'edit:backspace', 'edit:left', 'edit:word', 'edit_end', 'edit_next', 'commit'}), vim.inspect(got))
-- A paste keeps its first line and drops control bytes.
actions = {}
request.on_event({type='paste', text='one\27[31m line\0\nsecond line'})
assert(actions[1].arg.text == 'one[31m line', vim.inspect(actions[1].arg.text))

-- A string longer than the host accepts is cut, not sent whole.
local long = {{id='note:x', kind='note', depth=0, label=string.rep('é', 5000)}}
view:render(long, 1, {mode='list'})
assert(#last().rows[1].text <= 4096 and vim.fn.strchars(last().rows[1].text) > 0, 'a long row is clipped on a character boundary')
assert(vim.str_utfindex(last().rows[1].text, 'utf-32', #last().rows[1].text, true), 'the clipped text is valid UTF-8')

-- A host without decorated rows is refused, so the caller falls back to the terminal Panel.
dock.features = {}
local refused
view_module.open({}, function() end, function() error('opened') end, function(err) refused = err end)
assert(refused and refused.message:find('update Sprite', 1, true), 'an old host is refused with a reason')
print('OK native view')
