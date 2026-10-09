-- MPFever bridge: GUI half - link, session, barrier (pacing), stamps, received actions.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- ================================================================== GUI half (persistent, every frame)

O = {}
G = {
	inOff = 0, uiOff = 0, frames = 0, started = false, me = C.NAME, connected = false,
	session = { speed = 0, pauseAt = nil, started = false },
	peers = {},                -- other players' clocks (barrier)
	oseq = 0, outSent = 0, lastClock = -1,
	hashSent = -1, resultsSeen = {}, lastSet = -1,
	waits = {}, pendingPaused = {}, holdAt = nil, bind = {}, rev = {},
	ahead = 3, stampFloor = 0,    -- steps ahead of this game's stamps; no stamp below what others were allowed
}

function send(kind, payload)
	if not LINK.send(kind, payload) then log("cannot write out.log") end
end

-- the complete lines added to a channel since the last call (the position is kept in G[offKey])
function readLines(fileName, offKey)
	return LINK.readNew(fileName, G, offKey)
end

function parseLine(line)
	local kind, from, payload = line:match("^([^" .. TAB .. "]*)" .. TAB .. "([^" .. TAB .. "]*)" .. TAB .. "(.*)$")
	return kind, from, payload
end

function toSim(name, param)
	O.sendCommand(O.event("mpfever", "mpfever", name, param))
end

function setSpeed(sp)
	if sp ~= G.lastSet then
		G.lastSet = sp
		O.sendCommand(O.setSpeed(sp))
	end
end

-- queue an action on this game: simulation queue, or applied between steps while the session is paused
-- the game time at which an action issued now is applied everywhere
function stampFor(t)
	return math.max(t + G.ahead * STEP, G.stampFloor)
end

-- stamp of an action issued while the session is paused: the games may have stopped a batch apart (a speed change
-- takes a frame), so the stamp is the latest of their times; the others catch up to it (pacing) before applying it
function pausedStamp(now)
	local t = now
	for _, pc in pairs(G.peers) do if type(pc.t) == "number" and pc.t > t then t = pc.t end end
	return t
end

function queueLocal(a)
	if a.paused then
		G.pendingPaused[#G.pendingPaused + 1] = a
	else
		toSim("queue", a)
	end
end

-- the speed this game may run at: session speed, never past the slowest other player (barrier), stop points
G.pstat = { frames = 0, barrier = 0, hold = 0 }
function pacing()
	local now = gameTime()
	local s = G.session
	if not s.started then return 0 end
	local stopAt = s.pauseAt
	-- paused, but an action stamped later (another game stopped further): catch up to it, one step at a time
	local catchUp = s.pauseAt ~= nil and G.holdAt ~= nil and G.holdAt > s.pauseAt and now < G.holdAt
	if catchUp then stopAt = G.holdAt
	elseif G.holdAt and (stopAt == nil or G.holdAt < stopAt) then stopAt = G.holdAt end
	local barrier = nil
	for _, pc in pairs(G.peers) do
		-- window (see G.ahead): a game that overshoots this limit by its reserve is still before the time stamped on
		-- the peer's next action
		local limit = pc.t + (G.window or 3) * STEP
		if barrier == nil or limit < barrier then barrier = limit end
	end
	if barrier and (stopAt == nil or barrier < stopAt) then stopAt = barrier end
	local want = s.speed
	if s.pauseAt == nil and G.holdAt then want = math.max(1, want) end
	if catchUp then want = 1 end
	-- statistics (logged with "gui alive"): frames slowed down by the other players' clocks, or by held actions
	local ps = G.pstat
	ps.frames = ps.frames + 1
	local function slowed(r)
		if r < want and s.pauseAt == nil then
			if stopAt == barrier then ps.barrier = ps.barrier + 1 else ps.hold = ps.hold + 1 end
		end
		return r
	end
	G.wantSteps = nil
	if stopAt then
		if now >= stopAt then return slowed(0) end
		-- near a stop point, running at a speed would overshoot it (N steps per frame, a speed change takes a frame):
		-- the game pauses and the engine performs exactly the steps left
		-- (only for real stop points: the barrier keeps a reserve for the overshoot and moves all the time)
		if O.steps and stopAt ~= barrier and stopAt - now <= 2 * math.max(1, want) * STEP then
			G.wantSteps = math.floor((stopAt - now) / STEP)
			return slowed(0)
		end
		if want > 1 and stopAt - now < want * STEP then return slowed(1) end   -- do not overshoot a stop point inside a batch
	end
	return want
end

H = {}

H.welcome = function(from, p)
	if p.you then G.me = p.you end
	G.connected = true
	log("connected to session as " .. tostring(G.me) .. " (" .. tostring(p.role) .. ")")
end

H.chat = function(from, p) log("chat " .. tostring(from) .. ": " .. tostring(p.text)) end

H.session = function(from, p)
	G.session.started = p.started == true
	G.session.speed = p.speed or 0
	if p.pauseAt ~= G.session.pauseAt then
		G.session.pauseAt = p.pauseAt
		if p.pauseAt then toSim("pause_at", { at = p.pauseAt }) else toSim("resume", {}) end
	end
end

H.peerclock = function(from, p)
	if p.name and p.name ~= G.me then G.peers[p.name] = { t = p.t, ah = p.ah } end
end

H.peerleft = function(from, p)
	if p.name then G.peers[p.name] = nil end
end

-- native builds of other players: replayed here (callbacks give the engine's verdict), as soon as this game has
-- reached their time
G.nativeQueue = {}
nativeReceived = nil
-- how far ahead of this game an announced action still is when it arrives (steps): the margin the stamp distance leaves
-- The stamp distance (G.ahead) is the safe worst case. It is shortened (never below 60%) when the margins really left on
-- the announcements this game receives show that the games stay well within it, and given back for good the first time an
-- action arrives late.
G.consumed = {}
function adaptAhead(base)
	-- (opt-in, MPFEVER_ADAPTAHEAD=1: on a loaded PC builds already arrive up to 3 steps late with the full distance, so it is
	-- not shortened by default)
	if not os.getenv("MPFEVER_ADAPTAHEAD") or G.aheadLocked or #G.consumed < 8 then return base end
	local mx = 0
	for _, c in ipairs(G.consumed) do mx = math.max(mx, c) end
	return math.max(math.ceil(base * 0.6), math.min(base, math.ceil(mx * 1.5) + 4))
end

function logMargin(kind, at, origin)
	local ok, now = pcall(gameTime)
	if ok and type(at) == "number" then
		local m = (at - now) / STEP
		-- what the stamp's distance lost on the way: the other game's lead and the network
		local pa = origin and G.peers[origin] and G.peers[origin].ah
		if pa and (kind == "nat_pending" or kind == "act") then
			table.insert(G.consumed, pa + (kind == "nat_pending" and 1 or 0) - m)
			if #G.consumed > 12 then table.remove(G.consumed, 1) end
		end
		G.minMargin = math.min(G.minMargin or 99, m)
		log("MARGIN " .. kind .. " " .. m .. " steps (smallest so far " .. G.minMargin .. ", stamp distance " .. tostring(G.ahead) .. ", speed " .. tostring(G.session.speed) .. ") [frame " .. G.frames .. "]")
	end
end

H.act = function(from, p)
	logMargin(p.native and "act(native)" or "act", p.at, p.origin)
	if p.native then
		G.nativeQueue[#G.nativeQueue + 1] = p
		if nativeReceived then pcall(nativeReceived, p) end
	else
		queueLocal(p)
	end
end

end
