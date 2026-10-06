-- Shared helpers for both halves: locating binaries, reading Herdr's state, and the sidebar ↔ terminal link.

local M = {}

local home = tern.getenv("HOME") or ""

local function find(env: string, candidates: { string }, fallback: string): string
	local override = tern.getenv(env)
	if override and override ~= "" then
		return override
	end
	for _, path in candidates do
		local ok, exists = pcall(tern.fs.exists, path)
		if ok and exists then
			return path
		end
	end
	return fallback
end

-- Tern windows and the daemon start from launchd, so PATH rarely holds ~/.local/bin.
M.herdr = find("HERDR_BIN", {
	home .. "/.local/bin/herdr",
	"/opt/homebrew/bin/herdr",
	"/usr/local/bin/herdr",
	home .. "/.cargo/bin/herdr",
}, "herdr")

M.tern = find("TERN_BIN", {
	"/Applications/Tern.app/Contents/MacOS/tern",
	home .. "/.local/bin/tern",
	"/usr/local/bin/tern",
	"/usr/bin/tern",
}, "tern")

-- Herdr's config.toml text, or "" when there is none.
function M.herdr_config(): string
	local base = tern.getenv("XDG_CONFIG_HOME")
	if not base or base == "" then
		base = home .. "/.config"
	end
	local ok, text = pcall(tern.fs.read, base .. "/herdr/config.toml")
	return ok and text or ""
end

-- Order used for sorting and for the status line.
M.STATES = { "blocked", "working", "done", "idle" }
M.RANK = { blocked = 1, working = 2, done = 3, idle = 4 }
M.TONE = { blocked = "error", working = "warn", done = "success", idle = "muted" }

export type Agent = {
	pane_id: string,
	terminal_id: string,
	agent: string,
	status: string,
	title: string,
	cwd: string,
	workspace_id: string,
	tab_id: string,
	focused: boolean,
}

local function failure(res: any): string?
	if res.timed_out then
		return "herdr timed out"
	end
	if res.status ~= 0 then
		local msg = (res.stderr ~= "" and res.stderr) or res.stdout
		return (string.gsub(msg, "%s+$", ""))
	end
	return nil
end

-- Decodes a `herdr ... list` reply and returns `result[field]`, or nil and a reason.
function M.decode(res: any, field: string): (any, string?)
	local err = failure(res)
	if err then
		return nil, err
	end
	local ok, doc = pcall(tern.json.decode, res.stdout)
	if not ok or type(doc) ~= "table" then
		return nil, "unreadable herdr output"
	end
	if doc.error then
		return nil, tostring(doc.error.message or doc.error)
	end
	local value = doc.result and doc.result[field]
	if type(value) ~= "table" then
		return nil, "herdr returned no " .. field
	end
	return value, nil
end

function M.sort(agents: { Agent })
	table.sort(agents, function(x, y)
		local rx, ry = M.RANK[x.status] or 9, M.RANK[y.status] or 9
		if rx ~= ry then
			return rx < ry
		end
		return x.pane_id < y.pane_id
	end)
end

-- Turns `herdr agent list` / `herdr pane list` rows into agents (rows without an agent are skipped).
function M.agents_from(rows: { any }): { Agent }
	local agents = {}
	for _, a in rows do
		if a.agent then
			table.insert(agents, {
				pane_id = a.pane_id,
				terminal_id = a.terminal_id or "",
				agent = a.agent,
				status = a.agent_status or "idle",
				title = a.terminal_title_stripped or a.terminal_title or "",
				cwd = a.foreground_cwd or a.cwd or "",
				workspace_id = a.workspace_id or "",
				tab_id = a.tab_id or "",
				focused = a.focused == true,
			})
		end
	end
	M.sort(agents)
	return agents
end

-- Parses `herdr agent list` output. Returns the agents sorted by urgency, or nil and a reason.
function M.parse_agents(res: any): ({ Agent }?, string?)
	local rows, err = M.decode(res, "agents")
	if not rows then
		return nil, err
	end
	return M.agents_from(rows), nil
end

function M.counts(agents: { Agent }): { [string]: number }
	local c = {}
	for _, a in agents do
		c[a.status] = (c[a.status] or 0) + 1
	end
	return c
end

function M.basename(path: string): string
	return string.match(path, "([^/]+)/*$") or path
end

function M.label(a: Agent): string
	if a.title ~= "" then
		return a.title
	end
	return a.agent .. " in " .. M.basename(a.cwd)
end

function M.quote(s: string): string
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

-- The sidebar and its terminal pane share a link id. The target file names the agent the
-- terminal should show; follow.sh writes `<file>.on` with the agent it is attached to.
function M.target_file(link: string): string
	local dir = tern.plugin.data .. "/links"
	pcall(tern.fs.mkdir, dir)
	return dir .. "/" .. link
end

-- Shell command line for the terminal pane.
function M.follow_command(link: string): string
	return "sh " .. M.quote(tern.plugin.dir .. "/follow.sh") .. " " .. M.quote(M.target_file(link)) .. " " .. M.quote(M.herdr)
end

local function read(path: string): string
	local ok, text = pcall(tern.fs.read, path)
	return ok and text or ""
end

-- Points the link's terminal pane at Herdr terminal `terminal_id`. `write` types into the pane
-- (detaching the current attach with ctrl+b q, which Herdr's direct attach always uses).
function M.retarget(link: string, term: number?, terminal_id: string, write: (number, string) -> ())
	local file = M.target_file(link)
	tern.fs.write(file, terminal_id)
	local on = read(file .. ".on")
	if term and on ~= "" and on ~= terminal_id then
		write(term, "\x02q")
	end
end

-- The terminal a link's pane shows right now (or is about to).
function M.link_target(link: string): string
	return read(M.target_file(link))
end

function M.new_link(): string
	return string.format("%x%04x", math.floor(os.time()), math.random(0, 0xffff))
end

return M
