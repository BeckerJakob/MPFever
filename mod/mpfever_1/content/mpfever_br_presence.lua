-- MPFever bridge: presence - seeing the other players on the map (Phase 6).
-- Part of mpfever_bridge.script.lua: called with the bridge's shared environment.
--
-- Every game sends, about ten times a second and only when something moved, where its player's mouse points on the
-- ground and where its camera looks ("presence", relayed like any message, never logged by MPFever.exe). The other
-- games draw, in that player's colour:
--   * a dot where the mouse points (smoothed between updates),
--   * a large faint circle where the camera looks,
--   * a circle where the player just used a construction tool, until the build is there (nat_pending carries the
--     position) - the player's own pending builds use the same colour (Phase 7, instant feedback).
-- Presence never touches the simulation, the actions or the state checks: losing an update changes nothing but a dot.
return function(_ENV)

PRESENCE = {
	every = 6,          -- frames between two looks at mouse and camera (about 10 per second)
	minMove = 1.5,      -- metres a mouse or camera must move to be sent again
	heartbeat = 120,    -- frames: sent at least this often while connected (shows the others we are there)
	timeout = 600,      -- frames without an update: that player's marks go away
	smooth = 0.35,      -- part of the way a drawn dot moves towards the last received position, per frame
	cursorRadius = 6,
	cameraRadius = 60,
	buildRadius = 14,
}

-- the colour of a player (same on every game: from the name)
local COLOURS = {
	{ 1.0, 0.35, 0.3 }, { 0.25, 0.6, 1.0 }, { 0.35, 0.9, 0.35 }, { 1.0, 0.8, 0.15 }, { 0.8, 0.45, 1.0 }, { 0.15, 0.9, 0.9 },
}
function presenceColour(name, alpha)
	local c = COLOURS[(C.hashStr(5, tostring(name)) % #COLOURS) + 1]
	return api.type.Vec4f.new(c[1], c[2], c[3], alpha or 0.6)
end

G.presence = {}          -- name -> { cursor, camera, shown, seen, zones }
G.presenceOut = { frame = -1000, cursor = nil, camera = nil, seq = 0 }
G.presenceStats = { sent = 0, received = 0 }

local function round1(v) return math.floor(v * 10 + 0.5) / 10 end

local function mousePosition()
	local p = nil
	pcall(function()
		local m = api.gui.mouse
		if m and m.hasTerrainPosition and m.hasTerrainPosition() then
			local q = m.getTerrainPosition()
			p = { x = round1(q.x), y = round1(q.y) }
		end
	end)
	return p
end

local function cameraPosition()
	local p = nil
	pcall(function()
		local d = api.gui.camera.getCameraData()
		local x, y = d.x, d.y
		if x == nil then x, y = d[1], d[2] end
		if type(x) == "number" and type(y) == "number" then p = { x = round1(x), y = round1(y) } end
	end)
	return p
end

local function moved(a, b, limit)
	if a == nil or b == nil then return a ~= b end
	local dx, dy = a.x - b.x, a.y - b.y
	return dx * dx + dy * dy >= limit * limit
end

-- called every GUI frame while connected
function presenceTick()
	local o = G.presenceOut
	if G.frames % PRESENCE.every == 0 then
		local cur, cam = mousePosition(), cameraPosition()
		if moved(cur, o.cursor, PRESENCE.minMove) or moved(cam, o.camera, PRESENCE.minMove) or G.frames - o.frame >= PRESENCE.heartbeat then
			o.seq = o.seq + 1
			o.cursor, o.camera, o.frame = cur, cam, G.frames
			send("presence", { s = o.seq, c = cur, k = cam })
			G.presenceStats.sent = G.presenceStats.sent + 1
		end
	end
	presenceDraw()
end

local function zone(id, pos, radius, colour)
	pcall(function()
		api.gui.mission.setZoneCircle(id, api.type.Vec2f.new(pos.x, pos.y), radius, true, colour, false, false)
	end)
end

local function unzone(id)
	pcall(function() api.gui.mission.removeZone(id) end)
end

local function zoneName(name, what) return "mpfever_p_" .. tostring(name) .. "_" .. what end

function presenceForget(name)
	local p = G.presence[name]
	if not p then return end
	for id in pairs(p.zones) do unzone(id) end
	G.presence[name] = nil
end

-- the marks of every other player, moved a little towards their last received positions every frame
function presenceDraw()
	for name, p in pairs(G.presence) do
		if G.frames - p.seen > PRESENCE.timeout then
			presenceForget(name)
		else
			if p.cursor then
				local s = p.shown or { x = p.cursor.x, y = p.cursor.y }
				s.x = s.x + (p.cursor.x - s.x) * PRESENCE.smooth
				s.y = s.y + (p.cursor.y - s.y) * PRESENCE.smooth
				p.shown = s
				if not p.drawn or moved(s, p.drawn, 0.5) then
					p.drawn = { x = s.x, y = s.y }
					local id = zoneName(name, "c")
					zone(id, s, PRESENCE.cursorRadius, presenceColour(name, 0.8))
					p.zones[id] = true
				end
			end
			if p.camera and (not p.cameraDrawn or moved(p.camera, p.cameraDrawn, 5)) then
				p.cameraDrawn = { x = p.camera.x, y = p.camera.y }
				local id = zoneName(name, "k")
				zone(id, p.camera, PRESENCE.cameraRadius, presenceColour(name, 0.12))
				p.zones[id] = true
			end
		end
	end
end

H.presence = function(from, p)
	if from == G.me or type(p) ~= "table" then return end
	local q = G.presence[from]
	if not q then
		q = { zones = {}, seq = -1 }
		G.presence[from] = q
		log("presence of " .. tostring(from) .. " received")
	end
	if type(p.s) == "number" and p.s <= q.seq then return end      -- an older update arriving late
	q.seq = p.s or q.seq
	q.seen = G.frames
	if type(p.c) == "table" then q.cursor = { x = p.c.x, y = p.c.y } end
	if type(p.k) == "table" then q.camera = { x = p.k.x, y = p.k.y } end
	G.presenceStats.received = G.presenceStats.received + 1
end

-- a player left the session: their marks go
do
	local left = H.peerleft
	H.peerleft = function(from, p)
		if p and p.name then presenceForget(p.name) end
		return left(from, p)
	end
end

-- another player's construction tool sent a build: a circle in their colour where they clicked, until it is built
G.presenceBuilds = {}
do
	local pending = H.nat_pending
	H.nat_pending = function(from, p)
		if p and p.origin ~= G.me and type(p.pos) == "table" then
			local id = "mpfever_pb_" .. tostring(p.origin) .. "_" .. tostring(p.id)
			zone(id, p.pos, PRESENCE.buildRadius, presenceColour(p.origin, 0.45))
			G.presenceBuilds[id] = G.frames
		end
		return pending(from, p)
	end
	local cancel = H.nat_cancel
	H.nat_cancel = function(from, p)
		if p then
			local id = "mpfever_pb_" .. tostring(p.origin) .. "_" .. tostring(p.id)
			if G.presenceBuilds[id] then unzone(id); G.presenceBuilds[id] = nil end
		end
		return cancel(from, p)
	end
	local arrived = nativeArrived
	nativeArrived = function(a)
		local id = "mpfever_pb_" .. tostring(a.origin) .. "_" .. tostring(a.natId)
		if G.presenceBuilds[id] then unzone(id); G.presenceBuilds[id] = nil end
		return arrived(a)
	end
end

-- marks of builds that never came (cancelled without notice, lost)
function presenceExpireBuilds()
	for id, since in pairs(G.presenceBuilds) do
		if G.frames - since > 900 then unzone(id); G.presenceBuilds[id] = nil end
	end
end

end
