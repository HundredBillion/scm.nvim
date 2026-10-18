vim.opt.runtimepath:prepend(vim.uv.cwd())

local request
local row_callbacks = {}
local actions = {}
local dock = {
	assets = function(_, _, done)
		done()
	end,
	rows = function(_, revision, rows, selected, done)
		row_callbacks[#row_callbacks + 1] = {
			revision = revision,
			rows = rows,
			selected = selected,
			done = done,
		}
	end,
	focus = function(_, done)
		if done then
			done()
		end
	end,
	close = function() end,
}
package.loaded.sprite = {
	open = function(opts, done)
		request = opts
		done(nil, dock)
	end,
}

local sprite_view = require("scm.views.sprite")
local opened
local failed
local view = sprite_view.open({}, function(name, index)
	actions[#actions + 1] = { name = name, index = index }
end, function(value)
	opened = value
end, function(err)
	failed = err
end)
assert(opened == view and not failed, "native dock opens")

local rows = { { id = "first", text = "First" }, { id = "second", text = "Second" } }
view:render(rows, 1)
assert(#row_callbacks == 1 and row_callbacks[1].revision == 1)
request.on_event({ type = "input", key = "down" })
request.on_event({ type = "input", key = "enter", text = "\n" })
row_callbacks[1].done()
assert(#row_callbacks == 2, "queued navigation renders the intended selection after its ack")
assert(row_callbacks[2].revision == 2 and row_callbacks[2].selected == "second")
row_callbacks[2].done()
assert(
	#actions == 1 and actions[1].name == "open" and actions[1].index == 2,
	"queued activation opens the row selected by navigation"
)
request.on_event({ type = "list_click", revision = 1, button = "left", id = "first" })
assert(#actions == 1, "stale list revisions remain ignored")

local newest_rows = { { id = "newest", text = "Newest" } }
view:render(rows, 1)
request.on_event({ type = "input", key = "enter", text = "\n" })
view:render(newest_rows, 1)
row_callbacks[3].done()
assert(#actions == 1, "activation waits for rows already pending behind the acknowledged revision")
assert(row_callbacks[4].revision == 4 and row_callbacks[4].selected == "newest")
row_callbacks[4].done()
assert(
	#actions == 2 and actions[2].name == "open" and actions[2].index == 1,
	"activation runs after the newer pending row revision is acknowledged"
)

view:render(rows, 1)
local late_ack = row_callbacks[5]
view:close()
late_ack.done()
request.on_event({ type = "input", key = "enter", text = "\n" })
assert(#actions == 2, "closed views ignore later input")
print("OK sprite busy input")
