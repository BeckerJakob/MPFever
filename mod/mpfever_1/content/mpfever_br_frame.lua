-- MPFever bridge: the per-frame GUI update (link, pacing, native, hashes) and GUI events.
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

function neutraliseEmissions()
	-- town pollution/noise come from a non-deterministic engine computation: remove their effect on growth
	local n = 0
	api.engine.forEachEntityWithComponent(function(town)
		n = n + 1
		for _, rating in ipairs({ "pollution", "noise" }) do
			O.sendCommand(O.event("", "Towns", "setTownRatingSensitivity", { townEntity = town, rating = rating, sensitivity = 0 }))
		end
	end, api.type.ComponentType.TOWN)
	log("pollution and noise sensitivity set to 0 for " .. n .. " towns")
end

function fileSize(name)
	local f = C.IO.open(C.DIR .. BS .. name, "rb")
	if not f then return 0 end
	local n = f:seek("end")
	f:close()
	return n or 0
end

-- This GUI half starts with the game, and again after a resynchronisation (the host's savegame loaded here): what the
-- files already hold belongs to the previous game state, and the savegame's script state holds the host's records.
function resumeAfterLoad(state)
	-- records of the savegame's script state (an earlier session, or the host's): never shipped or reported again
	local st = state:get() or {}
	for _, o in ipairs(st.out or {}) do if o.n > G.outSent then G.outSent = o.n end end
	-- (keyed by uid and game time: uids start again at 1 in every session, an old record must not hide a new one)
	for _, r in ipairs(st.results or {}) do G.resultsSeen[tostring(r.uid) .. "@" .. tostring(r.at)] = true end
	if type(st.hash) == "table" then G.hashSent = st.hash.n end
	-- first start of this game in the session: everything the launcher wrote so far is for it
	if fileSize("started.txt") == 0 then
		C.appendFile(C.DIR .. BS .. "started.txt", "1")
		return
	end
	G.inOff = fileSize("in.log")
	-- commands the UI hook held before the reload were already shipped and applied: never again
	G.uiOff = fileSize("ui.log")
	G.natOff = fileSize("native_events.log")
	local f = C.IO.open(C.DIR .. BS .. "native_ctl.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		-- the DLL keeps counting releases across loads
		for n in s:gmatch("release (%d+)") do
			n = tonumber(n)
			if n and n > G.natReleased then G.natReleased = n end
		end
	end
	-- entity bindings of a previous game state are void
	LINK.append("bindings.log", "RESET 0" .. NL)
	if G.inOff > 0 then log("started over an existing session (" .. G.inOff .. " bytes of messages skipped): resynchronised game") end
end

function guiUpdate(userParams, state, guiState)
	if not C.ACTIVE then return end
	G.frames = G.frames + 1
	if G.frames % 600 == 0 then
		local ps = G.pstat
		log("gui alive frame " .. G.frames .. " t=" .. tostring(gameTime()) .. " | slowed by other clocks " .. ps.barrier .. "/" .. ps.frames .. " frames, by held actions " .. ps.hold)
		ps.frames, ps.barrier, ps.hold = 0, 0, 0
	end
	if not G.started then
		G.started = true
		-- the game's own functions, even if the UI hook already wrapped this api table (shared after a reload)
		local orig = C.origCmds()
		if not orig.sendCommand then
			orig.sendCommand, orig.setSpeed, orig.event = api.cmd.sendCommand, api.cmd.makeGameSetSpeedCmd, api.cmd.makeScriptingSendEventCmd
		end
		O.sendCommand, O.setSpeed, O.event = orig.sendCommand, orig.setSpeed, orig.event
		O.steps = api.cmd.debug and api.cmd.debug.makeGamePerformSimulationStepsCmd
		pcall(function() guiState:subscribeToAllEvents() end)
		log("bridge v0.17 started: name=" .. C.NAME .. " role=" .. C.ROLE .. " dir=" .. C.DIR)
		local okr, errr = pcall(resumeAfterLoad, state)
		if not okr then log("resume after load failed: " .. tostring(errr)) end
		setSpeed(0)
		local okn, errn = pcall(neutraliseEmissions)
		if not okn then log("emissions: " .. tostring(errn)) end
		send("hello", { name = C.NAME, role = C.ROLE, build = getBuildVersion and getBuildVersion() or "?", time = gameTime() })
	end

	for _, line in ipairs(readLines("in.log", "inOff")) do
		local kind, from, payload = parseLine(line)
		if kind then
			local h = H[kind]
			if h then
				local ok, err = pcall(h, from, C.deser(payload) or {})
				if not ok then log("handler " .. kind .. " failed: " .. tostring(err)) end
			end
		end
	end

	local okh, st = pcall(function() return state:get() end)
	if not (okh and type(st) == "table") then st = {} end
	G.simTerrainSig = st.terrainSig
	if st.late and st.late > (G.lateSeen or 0) then
		G.lateSeen = st.late
		G.aheadLocked = true
		log("an action arrived late: the full stamp distance is kept for the rest of the session")
	end

	-- outgoing actions BEFORE the clock: a peer must receive an action before it may pass its time
	if G.connected then
		local oks, errs = pcall(stampHeld)
		if not oks then log("stamping failed: " .. tostring(errs)) end
		local okb, errb = pcall(shipNativeBuilds, st)
		if not okb then log("shipping native builds failed: " .. tostring(errb)) end
	end

	if G.connected then
		local okv, errv = pcall(function()
			if G.session.started and not G.natEnabled then G.natEnabled = true; nativeCtl("enable 1") end
			pollNativeEvents()
			runNativeRelease()
			expireNativeWaits()
		end)
		if not okv then log("native deferral failed: " .. tostring(errv)) end
	end
	pcall(runPausedActions)
	local okn, errn = pcall(runNativeReplays)
	if not okn then log("native replays failed: " .. tostring(errn)) end

	if G.connected then
		local okp, sp = pcall(pacing)
		if okp then
			if gameSpeed() ~= sp then G.lastSet = -1 end
			setSpeed(sp)
			-- exact steps up to the stop point (once the engine is stopped, one request at a time)
			local now = gameTime()
			if G.stepTarget and (now >= G.stepTarget or G.frames - G.stepSince > 120) then G.stepTarget = nil end
			if sp == 0 and G.wantSteps and G.wantSteps > 0 and not G.stepTarget and gameSpeed() == 0 then
				G.stepTarget, G.stepSince = now + G.wantSteps * STEP, G.frames
				O.sendCommand(O.steps(G.wantSteps))
			end
		end
		-- stamp distance = barrier window + overshoot reserve + 1. The engine runs the simulation on its own thread,
		-- driven by real time: a game passes a stop point by what it simulates before its interface reacts (a frame,
		-- or a hiccup of a few hundred milliseconds). The reserve covers about half a second of simulation.
		local spd = math.max(1, math.min(4, G.session.speed or 1))
		G.window = spd + 2
		if G.lastSpd ~= spd then G.lastSpd = spd; G.consumed = {} end
		G.ahead = adaptAhead(G.window + (2 * spd + 1) + 1)
		local okt, t = pcall(gameTime)
		if okt and (t ~= G.lastClock or G.frames % 30 == 0) then
			G.lastClock = t
			G.stampFloor = math.max(G.stampFloor, t + G.ahead * STEP)
			send("clock", { t = t, sp = gameSpeed(), ah = G.ahead })
		end
	end

	-- bindings, results and hashes produced by the simulation half
	for key, e in pairs(st.bind or {}) do
		if G.bind[key] ~= e then
			G.bind[key] = e
			G.rev[e] = key
			LINK.append("bindings.log", key .. " " .. tostring(e) .. NL)
		end
	end
	if type(st.hash) == "table" and st.hash.n ~= G.hashSent then
		G.hashSent = st.hash.n
		send("sync_hash", { n = st.hash.n, parts = st.hash.parts, cost = st.hash.cost, auth = st.hash.auth })
	end
	for _, r in ipairs(st.results or {}) do
		local key = tostring(r.uid) .. "@" .. tostring(r.at)
		if not G.resultsSeen[key] then
			G.resultsSeen[key] = true
			LINK.append("results.log", C.line("result", r))
			if not r.success then send("act_refused", { uid = r.uid, fn = r.fn, err = r.err }) end
		end
	end

	if #G.waits > 0 then
		local current = G.waits
		G.waits = {}
		for _, w in ipairs(current) do
			if G.frames >= w.at then
				local ok, err = pcall(w.fn)
				if not ok then log("deferred action failed: " .. tostring(err)) end
			else
				G.waits[#G.waits + 1] = w
			end
		end
	end
end

function guiHandleEvent(userParams, state, guiState, src, id, name, param)
	if not C.ACTIVE then return end
	if type(name) == "string" and name:find("^builder%.") then
		G.evSeen = G.evSeen or {}
		local key = tostring(id) .. "/" .. name
		if not G.evSeen[key] then G.evSeen[key] = true; log("tool event: " .. key) end
	end
end

end
