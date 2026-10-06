-- Host half: the Herdr sidebar block. Spaces and agents drawn natively; picking an agent attaches
-- the linked terminal pane to it.

local common = require("./common")
local ui = tern.ui

local POLL_MS = 1500
local BRANCH_EVERY = 10 -- polls between git branch refreshes

type Space = { id: string, label: string, number: number, status: string, focused: boolean, cwd: string? }

type State = {
	link: string,
	pane: number,
	spaces: { Space },
	agents: { common.Agent },
	branches: { [string]: string },
	err: string?,
	sel: number,
	target: string?,
	ticks: number,
	closed: boolean,
}

local DOT = { blocked = "●", working = "●", done = "●", idle = "○" }

local function alive(pane: number): boolean
	for _, p in tern.pane.list() do
		if p.pane == pane then
			return true
		end
	end
	return false
end

local function clamp(state: State)
	state.sel = math.clamp(state.sel, 1, math.max(1, #state.agents))
end

local function linked_term(state: State): number?
	local term = tern.kv.get("link:" .. state.link)
	if type(term) == "number" and alive(term) then
		return term
	end
	return nil
end

local function toast_failure(cx: BlockCx, what: string, res: any)
	cx:toast("error", "herdr: " .. what .. " failed", (string.gsub(res.stderr .. res.stdout, "%s+$", "")))
end

-- Shows agent `a` in the linked terminal, splitting one off the sidebar when there is none.
local function attach(state: State, cx: BlockCx, a: common.Agent)
	state.target = a.terminal_id
	local term = linked_term(state)
	common.retarget(state.link, term, a.terminal_id, tern.pane.write)
	if term then
		return
	end
	local argv = { common.tern, "split", tostring(state.pane), "right", "--json", "--", "sh",
		tern.plugin.dir .. "/follow.sh", common.target_file(state.link), common.herdr }
	tern.process.run(argv, { timeout_ms = 10000 }, function(res)
		if res.status ~= 0 then
			toast_failure(cx, "opening a terminal", res)
			return
		end
		local ok, doc = pcall(tern.json.decode, res.stdout)
		local pane = ok and type(doc) == "table" and (doc.block or doc.pane)
		if type(pane) == "number" then
			tern.kv.set("link:" .. state.link, pane)
		else
			tern.log.warn("herdr: split gave no pane id", res.stdout)
		end
	end)
end

local function select_by_id(state: State, pane_id: string): common.Agent?
	for i, a in state.agents do
		if a.pane_id == pane_id or a.terminal_id == pane_id then
			state.sel = i
			return a
		end
	end
	return nil
end

local function refresh_branches(state: State, cx: BlockCx)
	for _, s in state.spaces do
		if s.cwd then
			local id = s.id
			tern.process.run({ "git", "-C", s.cwd, "branch", "--show-current" }, { timeout_ms = 3000 }, function(res)
				local branch = res.status == 0 and string.gsub(res.stdout, "%s+$", "") or ""
				if state.branches[id] ~= branch then
					state.branches[id] = branch
					pcall(function()
						cx:render()
					end)
				end
			end)
		end
	end
end

local function poll(state: State, cx: BlockCx)
	if state.closed then
		return
	end
	if not alive(state.pane) then
		state.closed = true
		return
	end
	tern.process.run({ common.herdr, "workspace", "list" }, { timeout_ms = 5000 }, function(wres)
		tern.process.run({ common.herdr, "pane", "list" }, { timeout_ms = 5000 }, function(pres)
			local workspaces, err = common.decode(wres, "workspaces")
			local panes, perr = common.decode(pres, "panes")
			state.err = err or perr
			local first_cwd = {}
			for _, p in panes or {} do
				if p.workspace_id and not first_cwd[p.workspace_id] then
					first_cwd[p.workspace_id] = p.foreground_cwd or p.cwd
				end
			end
			state.spaces = {}
			for _, w in workspaces or {} do
				table.insert(state.spaces, {
					id = w.workspace_id,
					label = w.label or w.workspace_id,
					number = w.number or 0,
					status = w.agent_status or "idle",
					focused = w.focused == true,
					cwd = first_cwd[w.workspace_id],
				})
			end
			table.sort(state.spaces, function(a, b)
				return a.number < b.number
			end)

			local current = state.agents[state.sel]
			state.agents = common.agents_from(panes or {})
			if current then
				select_by_id(state, current.pane_id)
			end
			clamp(state)

			-- Learn what the terminal shows when it was set up by the window command.
			local ok, on = pcall(tern.fs.read, common.target_file(state.link))
			if ok and on ~= "" and on ~= state.target then
				state.target = on
				select_by_id(state, on)
			end

			if state.ticks % BRANCH_EVERY == 0 then
				refresh_branches(state, cx)
			end
			state.ticks += 1

			if pcall(function()
				cx:render()
			end) then
				tern.timer(POLL_MS, function()
					poll(state, cx)
				end)
			else
				state.closed = true
			end
		end)
	end)
end

local function el(tag: string, class: string, text: string?, children: { Node }?, click: string?): Node
	local props: { [string]: any } = { class = class }
	if text then
		props.text = text
	end
	if click then
		props.actions = { click = click }
	end
	return ui.el(tag, props, children)
end

local function dot(status: string): Node
	local node = el("span", "hs-dot", DOT[status] or "○")
	local p = node.p :: { [string]: any }
	p.attrs = { ["data-state"] = status }
	return node
end

local function space_row(state: State, s: Space): Node
	local shows = false
	for _, a in state.agents do
		if a.workspace_id == s.id and a.terminal_id == state.target then
			shows = true
		end
	end
	local children = {
		el("div", "hs-line", nil, { dot(s.status), el("span", "hs-name", s.label) }),
	}
	local branch = state.branches[s.id]
	if branch and branch ~= "" then
		table.insert(children, el("div", "hs-sub", branch))
	end
	return el("div", "hs-row" .. (shows and " hs-on" or ""), nil, children, "space=" .. s.id)
end

local function agent_rows(state: State): { Node }
	local labels, seen, totals = {}, {}, {}
	for _, s in state.spaces do
		labels[s.id] = s.label
	end
	for _, a in state.agents do
		totals[a.workspace_id] = (totals[a.workspace_id] or 0) + 1
	end
	local rows = {}
	for i, a in state.agents do
		seen[a.workspace_id] = (seen[a.workspace_id] or 0) + 1
		local name = labels[a.workspace_id] or common.basename(a.cwd)
		local line = { dot(a.status), el("span", "hs-name", name) }
		if totals[a.workspace_id] > 1 then
			table.insert(line, el("span", "hs-n", "· " .. seen[a.workspace_id]))
		end
		local class = "hs-row hs-agent"
		if a.terminal_id == state.target then
			class ..= " hs-on"
		end
		if i == state.sel then
			class ..= " hs-sel"
		end
		local row = el("div", class, nil, {
			el("div", "hs-line", nil, line),
			el("div", "hs-sub", a.agent .. (a.title ~= "" and (" · " .. a.title) or "")),
		}, "pick=" .. a.pane_id)
		local p = row.p :: { [string]: any }
		p.title = common.label(a) .. " (" .. a.status .. ")"
		table.insert(rows, row)
	end
	return rows
end

local def: BlockDef<State> = {
	init = function(cx, args, saved)
		local link = args[1] or (saved and saved.link) or common.new_link()
		local state: State = {
			link = link,
			pane = cx.pane,
			spaces = {},
			agents = {},
			branches = {},
			err = nil,
			sel = 1,
			target = nil,
			ticks = 0,
			closed = false,
		}
		-- The window finds the sidebar's link (and through it, its terminal) by pane id.
		local links = tern.kv.get("links") or {}
		links[tostring(cx.pane)] = link
		tern.kv.set("links", links)
		poll(state, cx)
		return state
	end,

	save = function(state)
		return { link = state.link }
	end,

	title = function(state)
		local c = common.counts(state.agents)
		if c.blocked then
			return "herdr · " .. c.blocked .. " blocked"
		end
		return "herdr"
	end,

	view = function(state, _cx)
		local body: { Node } = {}
		if state.err then
			table.insert(body, el("div", "hs-err", "Herdr is not reachable"))
			table.insert(body, el("div", "hs-sub", state.err))
		else
			table.insert(body, el("div", "hs-head", "spaces"))
			for _, s in state.spaces do
				table.insert(body, space_row(state, s))
			end
			table.insert(body, el("div", "hs-head hs-gap", nil, {
				el("span", "", "agents"),
				el("span", "hs-right", "priority"),
			}))
			if #state.agents == 0 then
				table.insert(body, el("div", "hs-sub", "no agents"))
			end
			for _, row in agent_rows(state) do
				table.insert(body, row)
			end
		end
		return {
			main = ui.col({ el("div", "hs", nil, body) }),
			dock = ui.col({ el("div", "hs-keys", "↑↓ select · ⏎ show · r refresh") }),
		}
	end,

	key = function(state, key, cx)
		local name = key.name
		if name == "down" or name == "j" then
			state.sel += 1
		elseif name == "up" or name == "k" then
			state.sel -= 1
		elseif name == "r" then
			state.ticks = 0
			poll(state, cx)
			return false
		elseif name == "enter" or name == "space" then
			local a = state.agents[state.sel]
			if a then
				attach(state, cx, a)
			end
		else
			return false
		end
		clamp(state)
		return true
	end,

	event = function(state, ev, cx)
		if ev.ev ~= "action" or not ev.value then
			return
		end
		if ev.act == "pick" then
			local a = select_by_id(state, ev.value)
			if a then
				attach(state, cx, a)
			end
		elseif ev.act == "space" then
			-- A space shows its most urgent agent (agents are sorted by urgency).
			for _, a in state.agents do
				if a.workspace_id == ev.value then
					select_by_id(state, a.pane_id)
					attach(state, cx, a)
					return
				end
			end
			cx:toast("info", "No agent in that space")
		end
	end,
}

tern.block.define("sidebar", def)
