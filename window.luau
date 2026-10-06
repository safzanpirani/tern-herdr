-- Window half: polls Herdr, mirrors its tabs and panes as Tern tabs and splits, maps Herdr's
-- prefix keys onto Herdr API calls, and adds toasts, a status segment and the sidebar launcher.

local common = require("./common")
local keymap = require("./keymap")

local POLL_MS = 2000
local SIDEBAR_RATIO = 0.17

type Workspace = { id: string, label: string, number: number, status: string, active_tab: string? }
type Tab = { id: string, workspace_id: string, label: string, number: number, status: string }
type Pane = { id: string, terminal_id: string, tab_id: string, workspace_id: string, cwd: string }

-- The latest Herdr snapshot.
local workspaces: { Workspace } = {} -- by number
local tabs: { Tab } = {} -- by workspace number, then tab number
local panes: { [string]: Pane } = {}
local agents: { common.Agent } = {} -- by urgency
local reachable = false

local last: { [string]: string }? = nil -- pane_id -> agent status from the previous poll
local summary = "" -- counts string; a change refreshes the chrome

---------------------------------------------------------------------------------------------------
-- Snapshot

local function workspace_of(id: string): Workspace?
	for _, w in workspaces do
		if w.id == id then
			return w
		end
	end
	return nil
end

local function tabs_of(workspace_id: string): { Tab }
	local out = {}
	for _, t in tabs do
		if t.workspace_id == workspace_id then
			table.insert(out, t)
		end
	end
	return out
end

local function panes_of(tab_id: string): { Pane }
	local out = {}
	for _, p in panes do
		if p.tab_id == tab_id then
			table.insert(out, p)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

local function apply(ws: any, ts: any, ps: any)
	workspaces = {}
	for _, w in ws do
		table.insert(workspaces, {
			id = w.workspace_id,
			label = w.label or w.workspace_id,
			number = w.number or 0,
			status = w.agent_status or "idle",
			active_tab = w.active_tab_id,
		})
	end
	table.sort(workspaces, function(a, b)
		return a.number < b.number
	end)
	local order = {}
	for i, w in workspaces do
		order[w.id] = i
	end
	tabs = {}
	for _, t in ts do
		table.insert(tabs, {
			id = t.tab_id,
			workspace_id = t.workspace_id,
			label = t.label or tostring(t.number),
			number = t.number or 0,
			status = t.agent_status or "idle",
		})
	end
	table.sort(tabs, function(a, b)
		local oa, ob = order[a.workspace_id] or 999, order[b.workspace_id] or 999
		if oa ~= ob then
			return oa < ob
		end
		return a.number < b.number
	end)
	panes = {}
	for _, p in ps do
		panes[p.pane_id] = {
			id = p.pane_id,
			terminal_id = p.terminal_id or "",
			tab_id = p.tab_id or "",
			workspace_id = p.workspace_id or "",
			cwd = p.foreground_cwd or p.cwd or "",
		}
	end
	agents = common.agents_from(ps)
end

-- Reads workspaces, tabs and panes, then calls `done` with a fresh window cx.
local function snapshot(done: (WindowCx?) -> ())
	local results: { [string]: any } = {}
	local got, failed = 0, false
	local function one(argv: { string }, field: string)
		tern.process.run(argv, { timeout_ms = 5000 }, function(res, cx)
			local value = common.decode(res, field)
			if value then
				results[field] = value
			else
				failed = true
			end
			got += 1
			if got < 3 then
				return
			end
			reachable = not failed
			if reachable then
				apply(results.workspaces, results.tabs, results.panes)
			else
				agents = {}
			end
			done(cx)
		end)
	end
	one({ common.herdr, "workspace", "list" }, "workspaces")
	one({ common.herdr, "tab", "list" }, "tabs")
	one({ common.herdr, "pane", "list" }, "panes")
end

---------------------------------------------------------------------------------------------------
-- Toasts and status

local function urgent(): common.Agent?
	for _, a in agents do
		if a.status == "blocked" or a.status == "done" then
			return a
		end
	end
	return nil
end

local function notify(cx: WindowCx, a: common.Agent, before: string?)
	if before == a.status then
		return
	end
	local where = common.basename(a.cwd)
	if a.status == "blocked" then
		cx:toast("error", a.agent .. " needs input · " .. where, common.label(a))
	elseif a.status == "done" and before == "working" then
		cx:toast("success", a.agent .. " finished · " .. where, common.label(a))
	end
end

local function after_poll(cx: WindowCx?)
	local now = {}
	for _, a in agents do
		now[a.pane_id] = a.status
		-- The first poll only records states; toasts start from the second.
		if last and cx then
			notify(cx, a, last[a.pane_id])
		end
	end
	last = now
	local c = common.counts(agents)
	local key = string.format("%d/%d/%d/%d", c.blocked or 0, c.working or 0, c.done or 0, c.idle or 0)
	if key ~= summary then
		summary = key
		tern.chrome.refresh()
	end
end

tern.chrome.status(function(_pane)
	if not reachable or #agents == 0 then
		return nil
	end
	local c = common.counts(agents)
	local parts = {}
	for _, s in common.STATES do
		if c[s] and s ~= "idle" then
			table.insert(parts, c[s] .. " " .. s)
		end
	end
	if #parts == 0 then
		table.insert(parts, #agents .. " idle")
	end
	local tone = (c.blocked and "error") or (c.working and "warn") or "muted"
	return { { text = "herdr " .. table.concat(parts, " · "), icon = "user", tone = tone, command = "plugin.herdr.open" } }
end)

tern.carly.context(function(_cx)
	if not reachable or #agents == 0 then
		return nil
	end
	local lines = {}
	for _, a in agents do
		table.insert(lines, string.format("%s %s %s (%s)", a.pane_id, a.agent, a.status, common.label(a)))
		if #lines >= 8 then
			break
		end
	end
	return "Herdr agents:\n" .. table.concat(lines, "\n")
end)

---------------------------------------------------------------------------------------------------
-- Sidebar tab: the native sidebar beside one terminal that follows the picked agent.

-- The sidebar tab open in this window: its link id, sidebar pane and terminal pane.
local function sidebar_link(cx: WindowCx): (string?, number?, number?)
	for _, p in cx.session:panes() do
		if p.block == "herdr.sidebar" then
			local link = (tern.kv.get("links") or {})[tostring(p.pane)]
			if link then
				local term = tern.kv.get("link:" .. link)
				if type(term) == "number" and cx.session:pane(term) == nil then
					term = nil
				end
				return link, p.pane, term
			end
		end
	end
	return nil, nil, nil
end

local function open_sidebar(cx: WindowCx, terminal_id: string?)
	local link, sidebar, term = sidebar_link(cx)
	if link and sidebar then
		if terminal_id then
			common.retarget(link, term, terminal_id, function(pane, text)
				cx:run(pane, text)
			end)
		end
		cx.layout:focus(term or sidebar)
		return
	end
	link = common.new_link()
	tern.fs.write(common.target_file(link), terminal_id or (agents[1] and agents[1].terminal_id) or "")
	local tab, err = cx.layout:tab({
		name = "herdr",
		split = "right",
		ratio = SIDEBAR_RATIO,
		{ launch = { block = "herdr.sidebar", args = { link } } },
		{ launch = { command = common.follow_command(link) } },
	})
	if not tab then
		cx:toast("error", "Could not open the Herdr tab", err)
		return
	end
	local layout = cx.session:layout(tab)
	local right = layout and layout.root and layout.root[2]
	if right and right.pane then
		tern.kv.set("link:" .. link, right.pane)
		cx.layout:focus(right.pane)
	end
end

---------------------------------------------------------------------------------------------------
-- Mirror: each Herdr tab is a Tern tab and each Herdr pane a Tern split attached to it.
-- kv "mirror" maps a Herdr pane id to the Tern pane attached to it; absent means off.

local TAB_COLOR: { [string]: TabColor } = { blocked = "red", working = "yellow", done = "green" }
local applied: { [number]: string } = {} -- Tern tab -> name this plugin last set
local renamed: { [number]: boolean } = {} -- Tern tabs the user renamed; their names stay
local colors: { [number]: string } = {} -- Tern tab -> color this plugin last set
local dismissed: { [string]: boolean } = {} -- Herdr panes whose Tern pane the user closed
local pending_dir: { [string]: Dir } = {} -- new Herdr pane -> split direction asked for
local pending_focus: string? = nil -- Herdr pane to focus once it is mirrored

local function mirror_on(): boolean
	return tern.kv.get("mirror") ~= nil
end

local function mirror_map(): { [string]: number }
	return tern.kv.get("mirror") or {}
end

local function pane_link(pane_id: string): string
	return "m-" .. string.gsub(pane_id, "[^%w]", "_")
end

local function tab_name(t: Tab): string
	local w = workspace_of(t.workspace_id)
	local space = w and w.label or t.workspace_id
	if #tabs_of(t.workspace_id) > 1 then
		return space .. " · " .. t.label
	end
	return space
end

local function tern_tab_info(cx: WindowCx, tab: number): TabInfo?
	for _, info in cx.session:tabs() do
		if info.id == tab then
			return info
		end
	end
	return nil
end

local function sync_mirror(cx: WindowCx)
	if not mirror_on() then
		return
	end
	local map = mirror_map()
	local prev_tab: number? = nil -- the Tern tab of the previous Herdr tab, for ordering
	local was_focused = cx.session:focused()
	local created = false

	for _, t in tabs do
		local anchor: number? = nil
		for _, p in panes_of(t.id) do
			local term = map[p.id]
			if term and cx.session:pane(term) == nil then
				-- The user closed it in Tern: leave it hidden; Herdr keeps the pane.
				map[p.id] = nil
				dismissed[p.id] = true
				term = nil
			end
			if term then
				anchor = anchor or term
			end
		end
		for _, p in panes_of(t.id) do
			if not map[p.id] and not dismissed[p.id] and p.terminal_id ~= "" then
				local link = pane_link(p.id)
				tern.fs.write(common.target_file(link), p.terminal_id)
				local launch = { cwd = p.cwd, command = common.follow_command(link) }
				local term
				if anchor then
					term = cx.layout:split(anchor, pending_dir[p.id] or "right", launch, { focus = false })
				else
					term = cx.layout:new_tab(launch, { focus = false })
					local tab = term and cx.session:tab_of(term)
					local after = prev_tab and tern_tab_info(cx, prev_tab)
					if tab and after then
						cx.layout:order_tab(tab, after.position + 1)
					end
				end
				pending_dir[p.id] = nil
				if term then
					created = true
					map[p.id] = term
					anchor = anchor or term
				end
			end
		end
		local tab = anchor and cx.session:tab_of(anchor)
		if tab then
			prev_tab = tab
			local info = tern_tab_info(cx, tab)
			-- A name this plugin didn't set means the user renamed the tab; keep theirs.
			if info and applied[tab] and info.name ~= applied[tab] then
				renamed[tab] = true
			end
			local name = tab_name(t)
			if not renamed[tab] and applied[tab] ~= name then
				applied[tab] = name
				cx.layout:name_tab(tab, name)
			end
			local color = TAB_COLOR[t.status]
			if colors[tab] ~= (color or "") then
				colors[tab] = color or ""
				cx.layout:color_tab(tab, color)
			end
		end
	end

	-- Panes that left Herdr take their Tern panes with them.
	for pane_id, term in map do
		if not panes[pane_id] then
			if cx.session:pane(term) then
				cx.layout:close(term)
			end
			map[pane_id] = nil
		end
	end
	for pane_id in dismissed do
		if not panes[pane_id] then
			dismissed[pane_id] = nil
		end
	end
	tern.kv.set("mirror", map)

	if pending_focus and map[pending_focus] then
		cx.layout:focus(map[pending_focus])
		pending_focus = nil
	elseif created and was_focused and cx.session:pane(was_focused) then
		-- New tabs reveal themselves; put the user back where they were.
		cx.layout:focus(was_focused)
	end
end

local function stop_mirror(cx: WindowCx)
	for _, term in mirror_map() do
		if cx.session:pane(term) then
			cx.layout:close(term)
		end
	end
	tern.kv.set("mirror", nil)
	applied, renamed, colors, dismissed = {}, {}, {}, {}
end

---------------------------------------------------------------------------------------------------
-- Polling

local function poll()
	snapshot(function(cx)
		after_poll(cx)
		if reachable and cx then
			sync_mirror(cx)
		end
		tern.timer(POLL_MS, function()
			poll()
		end)
	end)
end

-- Refreshes the snapshot now (after a Herdr change), then syncs.
local function refresh_now()
	snapshot(function(cx)
		if reachable and cx then
			sync_mirror(cx)
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Prefix keys: Herdr's keymap, run against the Herdr pane shown in the focused Tern pane.

-- The Herdr pane behind the focused Tern pane: a mirrored pane, or the sidebar tab's terminal.
local function current(cx: WindowCx): Pane?
	local focused = cx.session:focused()
	if not focused then
		return nil
	end
	for pane_id, term in mirror_map() do
		if term == focused then
			return panes[pane_id]
		end
	end
	local link, sidebar, term = sidebar_link(cx)
	if link and (focused == sidebar or focused == term) then
		local terminal_id = common.link_target(link)
		for _, p in panes do
			if p.terminal_id == terminal_id then
				return p
			end
		end
	end
	return nil
end

-- Shows a Herdr pane: its mirrored Tern pane, else the sidebar terminal.
local function show(cx: WindowCx, p: Pane)
	local term = mirror_on() and mirror_map()[p.id]
	if term and cx.session:pane(term) then
		cx.layout:focus(term)
	elseif mirror_on() then
		pending_focus = p.id
		dismissed[p.id] = nil
		refresh_now()
	else
		open_sidebar(cx, p.terminal_id)
	end
end

local function herdr(cx: WindowCx, argv: { string }, done: ((any) -> ())?)
	local full = { common.herdr }
	for _, a in argv do
		table.insert(full, a)
	end
	tern.process.run(full, { timeout_ms = 10000 }, function(res, cx2)
		local c = cx2 or cx
		local ok, doc = pcall(tern.json.decode, res.stdout)
		if res.status ~= 0 or not ok or type(doc) ~= "table" or doc.error then
			local msg = ok and type(doc) == "table" and doc.error and doc.error.message or (res.stderr .. res.stdout)
			c:toast("error", "herdr " .. argv[1] .. " " .. (argv[2] or "") .. " failed", tostring(msg))
			return
		end
		if done then
			done(doc.result)
		end
		refresh_now()
	end)
end

-- Opens a newly created Herdr pane once it is mirrored (or in the sidebar terminal).
local function reveal_new(cx: WindowCx, pane: any, dir: Dir?)
	if type(pane) ~= "table" or not pane.pane_id then
		return
	end
	if dir then
		pending_dir[pane.pane_id] = dir
	end
	if mirror_on() then
		pending_focus = pane.pane_id
	elseif pane.terminal_id then
		open_sidebar(cx, pane.terminal_id)
	end
end

local function step(list: { any }, index: number, by: number): any
	if #list == 0 then
		return nil
	end
	return list[((index - 1 + by) % #list) + 1]
end

local function index_of(list: { any }, pred: (any) -> boolean): number
	for i, v in list do
		if pred(v) then
			return i
		end
	end
	return 1
end

-- The first pane of a Herdr tab.
local function tab_pane(t: Tab?): Pane?
	return t and panes_of(t.id)[1]
end

local function workspace_pane(w: Workspace?): Pane?
	if not w then
		return nil
	end
	for _, t in tabs_of(w.id) do
		if t.id == w.active_tab then
			return tab_pane(t)
		end
	end
	return tab_pane(tabs_of(w.id)[1])
end

-- Agents in space order, as Herdr's next/previous agent cycles them.
local function agents_by_space(): { common.Agent }
	local order = {}
	for i, w in workspaces do
		order[w.id] = i
	end
	local list = table.clone(agents)
	table.sort(list, function(a, b)
		local oa, ob = order[a.workspace_id] or 999, order[b.workspace_id] or 999
		if oa ~= ob then
			return oa < ob
		end
		return a.pane_id < b.pane_id
	end)
	return list
end

-- Focuses the neighbouring Tern pane in `dir` within the focused pane's tab.
local function focus_dir(cx: WindowCx, dir: Dir)
	local focused = cx.session:focused()
	local tab = focused and cx.session:tab_of(focused)
	local layout = tab and cx.session:layout(tab)
	if not layout or not focused then
		return
	end
	local axis = (dir == "left" or dir == "right") and "right" or "down"
	local forward = dir == "right" or dir == "down"
	-- Path from the root to the focused leaf.
	local path = {}
	local function find(node: TabTree): boolean
		if node.pane == focused then
			return true
		end
		for side = 1, 2 do
			local child = node[side]
			if child then
				table.insert(path, { node = node, side = side })
				if find(child) then
					return true
				end
				table.remove(path)
			end
		end
		return false
	end
	if not find(layout.root) then
		return
	end
	for i = #path, 1, -1 do
		local hop = path[i]
		if hop.node.split == axis and hop.side == (forward and 1 or 2) then
			local node = hop.node[forward and 2 or 1]
			-- Descend to the leaf nearest the edge we came from.
			while node and not node.pane do
				node = node[(node.split == axis and not forward) and 2 or 1]
			end
			if node and node.pane then
				cx.layout:focus(node.pane)
			end
			return
		end
	end
end

local recent_focus: { number } = {} -- the two most recently focused Tern panes

tern.on("focus", function(ev: FocusEvent, _cx)
	if recent_focus[1] ~= ev.pane then
		table.insert(recent_focus, 1, ev.pane)
		recent_focus[3] = nil
	end
end)

local function append(argv: { string }, extra: { string }): { string }
	for _, a in extra do
		table.insert(argv, a)
	end
	return argv
end

-- Handlers by Herdr action name. `n` is the 1-based index of indexed bindings.
local ACTIONS: { [string]: (cx: WindowCx, p: Pane?, n: number?) -> () } = {
	new_tab = function(cx, p)
		local argv = { "tab", "create", "--no-focus" }
		if p then
			append(argv, { "--workspace", p.workspace_id, "--cwd", p.cwd })
		end
		herdr(cx, argv, function(r)
			reveal_new(cx, r.root_pane)
		end)
	end,
	new_workspace = function(cx, p)
		local argv = { "workspace", "create", "--no-focus" }
		if p then
			append(argv, { "--cwd", p.cwd })
		end
		herdr(cx, argv, function(r)
			reveal_new(cx, r.root_pane)
		end)
	end,
	split_vertical = function(cx, p)
		if p then
			herdr(cx, { "pane", "split", p.id, "--direction", "right", "--cwd", p.cwd, "--no-focus" }, function(r)
				reveal_new(cx, r.pane, "right")
			end)
		end
	end,
	split_horizontal = function(cx, p)
		if p then
			herdr(cx, { "pane", "split", p.id, "--direction", "down", "--cwd", p.cwd, "--no-focus" }, function(r)
				reveal_new(cx, r.pane, "down")
			end)
		end
	end,
	close_pane = function(cx, p)
		if p then
			herdr(cx, { "pane", "close", p.id })
		end
	end,
	close_tab = function(cx, p)
		if p then
			herdr(cx, { "tab", "close", p.tab_id })
		end
	end,
	close_workspace = function(cx, p)
		if p then
			herdr(cx, { "workspace", "close", p.workspace_id })
		end
	end,
	next_tab = function(cx, p)
		if p then
			local list = tabs_of(p.workspace_id)
			local target = tab_pane(step(list, index_of(list, function(t)
				return t.id == p.tab_id
			end), 1))
			if target then
				show(cx, target)
			end
		end
	end,
	previous_tab = function(cx, p)
		if p then
			local list = tabs_of(p.workspace_id)
			local target = tab_pane(step(list, index_of(list, function(t)
				return t.id == p.tab_id
			end), -1))
			if target then
				show(cx, target)
			end
		end
	end,
	switch_tab = function(cx, p, n)
		local target = p and n and tab_pane(tabs_of(p.workspace_id)[n])
		if target then
			show(cx, target)
		end
	end,
	next_workspace = function(cx, p)
		local i = index_of(workspaces, function(w)
			return p ~= nil and w.id == p.workspace_id
		end)
		local target = workspace_pane(step(workspaces, i, 1))
		if target then
			show(cx, target)
		end
	end,
	previous_workspace = function(cx, p)
		local i = index_of(workspaces, function(w)
			return p ~= nil and w.id == p.workspace_id
		end)
		local target = workspace_pane(step(workspaces, i, -1))
		if target then
			show(cx, target)
		end
	end,
	switch_workspace = function(cx, _p, n)
		local target = n and workspace_pane(workspaces[n])
		if target then
			show(cx, target)
		end
	end,
	next_agent = function(cx, p)
		local list = agents_by_space()
		local a = step(list, index_of(list, function(a)
			return p ~= nil and a.pane_id == p.id
		end), 1)
		if a and panes[a.pane_id] then
			show(cx, panes[a.pane_id])
		end
	end,
	previous_agent = function(cx, p)
		local list = agents_by_space()
		local a = step(list, index_of(list, function(a)
			return p ~= nil and a.pane_id == p.id
		end), -1)
		if a and panes[a.pane_id] then
			show(cx, panes[a.pane_id])
		end
	end,
	focus_pane_left = function(cx)
		focus_dir(cx, "left")
	end,
	focus_pane_down = function(cx)
		focus_dir(cx, "down")
	end,
	focus_pane_up = function(cx)
		focus_dir(cx, "up")
	end,
	focus_pane_right = function(cx)
		focus_dir(cx, "right")
	end,
	cycle_pane_next = function(cx)
		cx:action("next_pane")
	end,
	cycle_pane_previous = function(cx)
		cx:action("previous_pane")
	end,
	last_pane = function(cx)
		local prev = recent_focus[2]
		if prev and cx.session:pane(prev) then
			cx.layout:focus(prev)
		end
	end,
	zoom = function(cx)
		cx:action("zoom")
	end,
	rename_tab = function(cx)
		cx:action("rename_tab")
	end,
	workspace_picker = function(cx, p)
		open_sidebar(cx, p and p.terminal_id)
	end,
	goto = function(cx, p)
		open_sidebar(cx, p and p.terminal_id)
	end,
	toggle_sidebar = function(cx, p)
		open_sidebar(cx, p and p.terminal_id)
	end,
	detach = function(cx)
		stop_mirror(cx)
	end,
}

local function in_herdr(cx: WindowCx): boolean
	return current(cx) ~= nil
end

local bound = keymap.load(common.herdr_config())
for _, b in bound.bindings do
	local handler = ACTIONS[b.action]
	if handler then
		tern.command({
			id = "key_" .. b.action .. (b.n and ("_" .. b.n) or ""),
			title = "Herdr: " .. keymap.title(b.action) .. (b.n and (" " .. b.n) or ""),
			group = "Herdr keys",
			keys = b.keys,
			available = in_herdr,
			run = function(cx)
				handler(cx, current(cx), b.n)
			end,
		})
	end
end

-- Prefix twice sends the prefix itself to the program, as in tmux.
tern.command({
	id = "key_send_prefix",
	title = "Herdr: Send Prefix",
	group = "Herdr keys",
	keys = { bound.prefix .. ">" .. bound.prefix },
	available = in_herdr,
	run = function(cx)
		local focused = cx.session:focused()
		if focused and bound.prefix_byte then
			cx:run(focused, bound.prefix_byte)
		end
	end,
})

---------------------------------------------------------------------------------------------------
-- Palette commands

tern.command({
	id = "open",
	title = "Herdr: Open Sidebar",
	icon = "user",
	keys = { "cmd+shift+h" },
	run = function(cx)
		open_sidebar(cx, nil)
	end,
})

tern.command({
	id = "mirror",
	title = "Herdr: Toggle Tabs Mirror",
	icon = "user",
	keys = { "cmd+shift+m" },
	run = function(cx)
		if mirror_on() then
			stop_mirror(cx)
			cx:toast("info", "Herdr tabs closed", "Herdr keeps running")
		else
			tern.kv.set("mirror", {})
			sync_mirror(cx)
			cx:toast("success", "Herdr tabs mirrored", #tabs .. " tabs")
		end
	end,
})

tern.command({
	id = "jump",
	title = "Herdr: Jump to Agent Needing Attention",
	icon = "user",
	keys = { "cmd+shift+j" },
	run = function(cx)
		local a = urgent()
		if a and panes[a.pane_id] then
			show(cx, panes[a.pane_id])
		else
			cx:toast("info", "No Herdr agent is blocked or done")
		end
	end,
})

tern.chrome.tab_title(function(tab)
	if tab.name then
		return nil
	end
	local program = tab.program or ""
	if program ~= "herdr" and not string.match(program, "/herdr$") then
		return nil
	end
	local c = common.counts(agents)
	if c.blocked then
		return "herdr · " .. c.blocked .. " blocked"
	end
	return "herdr"
end)

-- window_start does not fire again on a plugin reload, so polling starts at load.
poll()
