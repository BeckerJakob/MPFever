-- MPFever bridge: execution of a replicated action (entity references, retries).
-- Part of mpfever_bridge.script.lua (split in Phase 1, tools/dev/split_bridge.py): called with the bridge's shared
-- environment, so the top-level names of every part are visible to every other part.
return function(_ENV)

-- ================================================================== action execution

ENTITY_ARGS = {
	makeVehicleBuyCmd = { 1, 2 }, makeVehicleSellCmd = { 1 }, makeVehicleSetLineCmd = { 1, 2 }, makeVehicleSendToDepotCmd = { 1 },
	makeVehicleReverseCmd = { 1 }, makeVehicleReplaceCmd = { 1 }, makeVehicleSetStoppedByUserCmd = { 1 },
	makeLineUpdateCmd = { 1 }, makeLineDestroyCmd = { 1 }, makeLineCreateCmd = { 3 }, makeEntitySetNameCmd = { 1 }, makeEntitySetColorCmd = { 1 },
}

function missingEntities(fn, margs)
	local missing = {}
	local function check(e, what)
		if type(e) == "number" and e >= 0 then
			local ok, exists = pcall(function() return api.engine.entityExists(e) end)
			if ok and exists == false then missing[#missing + 1] = what .. "=" .. e end
		end
	end
	for _, i in ipairs(ENTITY_ARGS[fn] or {}) do check(margs[i], "arg" .. i) end
	if fn == "makeLineCreateCmd" or fn == "makeLineUpdateCmd" then
		local line = margs[fn == "makeLineCreateCmd" and 4 or 2]
		if type(line) == "table" then
			for k, stop in ipairs(line.stops or {}) do
				if type(stop) == "table" then check(stop.stationGroup, "stop" .. k .. ".stationGroup") end
			end
		end
	end
	return missing
end

-- Ways to rebuild a captured build, tried in this order; a factory failure has no side effect, so the same sequence
-- gives the same outcome on every machine. ie/pi: the ignoreErrors and playerInitiated flags given to the factory
-- (the game's own scripts pass true/false; the native tools true... as captured).
BUILD_TRIES = {
	{ v = "full" }, { v = "minimal" }, { v = "minimalNoOwner" }, { v = "bare" },
	{ v = "full", ie = true, pi = false }, { v = "minimal", ie = true, pi = false },
	{ v = "minimalNoOwner", ie = true, pi = false }, { v = "bare", ie = true, pi = false },
	{ v = "full", raw = true }, { v = "minimal", raw = true, ie = true, pi = false },
}

function shortErr(e)
	local m = tostring(e)
	m = m:match("^[^" .. NL .. "]*") or m
	m = m:gsub("^.*%.lua" .. string.char(34) .. "%]:%d+: ", "")
	return m:sub(1, 90)
end

function tryLabel(t)
	return t.v .. (t.raw and "/raw" or "") .. (t.ie ~= nil and "/ie" or "")
end

-- returns the command (or nil), the label of the combination that worked, the failures
function buildCommand(fn, srcArgs, tries)
	local errs = {}
	for _, t in ipairs(tries) do
		local margs = C.deser(srcArgs)
		if t.ie ~= nil then margs[3] = t.ie; margs[4] = t.pi end
		local okr, args, n = pcall(C.rebuildArgs, fn, margs, { seed = 7919, variant = t.v, raw = t.raw })
		if not okr then
			errs[#errs + 1] = tryLabel(t) .. ": rebuild " .. shortErr(args)
		else
			local okc, c = pcall(function() return api.cmd[fn](table.unpack(args, 1, n)) end)
			if okc and c then return c, tryLabel(t), errs end
			errs[#errs + 1] = tryLabel(t) .. ": " .. shortErr(c)
		end
	end
	return nil, nil, errs
end

-- Executes one replicated action. Returns a result record (for the originator's UI and the bindings).
-- done (optional, with useCallback): called with the result once the engine has answered (or at once on failure)
function executeAction(a, sendCommand, useCallback, bind, done)
	local result = { tok = a.tok, id = a.id, uid = a.uid, fn = a.fn, success = false }
	local okt, unresolved = pcall(R.translateIn, a.args or {}, bind or {})
	if not okt then
		result.err = "references: " .. tostring(unresolved)
		log("action " .. tostring(a.uid) .. " reference resolution failed: " .. tostring(unresolved))
		return result
	end
	if #unresolved > 0 then
		result.err = "DESYNC unresolved: " .. table.concat(unresolved, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	local okm, missing = pcall(missingEntities, a.fn, a.args or {})
	if okm and #missing > 0 then
		result.err = "DESYNC missing entities: " .. table.concat(missing, ",")
		log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " SKIPPED, " .. result.err)
		return result
	end
	local isBuild = a.fn == "makeWorldBuildProposalCmd"
	local cmd, label, errs = buildCommand(a.fn, C.ser(a.args or {}), isBuild and BUILD_TRIES or { { v = "full" } })
	if not cmd then
		result.err = table.concat(errs, " | ")
		log("BUILD NOT REPLAYABLE " .. tostring(a.uid) .. " " .. tostring(a.fn) .. ": " .. result.err)
		return result
	end
	if isBuild then
		pcall(function()
			local src = a.args[1].proposal or {}
			local seg = (src.addedSegments or {})[1]
			local shipped = seg and seg.comp and seg.comp.roadTemplate
			local margs = C.deser(C.ser(a.args))
			local args = C.rebuildArgs(a.fn, margs, { seed = 7919, variant = label:match("^[^/]+"), raw = label:find("/raw") ~= nil })
			local ssp = args[1].streetProposal
			local e = ssp.edgesToAdd[1]
			log("  debug: shipped segments=" .. #(src.addedSegments or {}) .. " removed=" .. #(src.removedSegments or {}) .. " template=" .. tostring(shipped)
				.. " | rebuilt add=" .. #ssp.edgesToAdd .. " remove=" .. #ssp.edgesToRemove .. " nodes=" .. #ssp.nodesToAdd
				.. (e and (" e.id=" .. tostring(e.entity) .. " n0=" .. tostring(e.comp.node0) .. " n1=" .. tostring(e.comp.node1) .. " tmpl=" .. tostring(e.comp.roadTemplate) .. " lanes=" .. tostring(#e.comp.laneConfigs)) or "")
				.. " removeIds=" .. C.ser(ssp.edgesToRemove))
		end)
		log("action " .. tostring(a.uid) .. " rebuilt as '" .. label .. "'" .. (#errs > 0 and (" after " .. #errs .. " refused form(s)") or ""))
		if #C.errors > 0 then log("  notes: " .. table.concat(C.errors, " ; "):sub(1, 300)) end
	end
	local createdKey = (a.fn == "makeLineCreateCmd" and "L" or ((a.fn == "makeVehicleBuyCmd" or a.fn == "makeVehicleReplaceCmd") and "V" or nil))
	local oks, errs
	if useCallback then
		oks, errs = pcall(sendCommand, cmd, function(data, ok, resultEntities)
			result.success = ok
			if isBuild then
				local why = ""
				if not ok then pcall(function() why = " " .. C.ser(C.marshal(data.resultProposalData.errorState.messages)) end) end
				log("action " .. tostring(a.uid) .. " applied by the engine: " .. (ok and "BUILT" or ("REFUSED" .. why)))
			end
			result.data = C.marshal(data)
			result.entities = C.marshal(resultEntities)
			local first = nil
			pcall(function() first = resultEntities[1][1] end)
			if ok and createdKey and type(first) == "number" then result.created = { key = createdKey .. a.uid, e = first } end
			result.answered = true
			if done and result.returned then done(result) end
		end)
	else
		-- simulation state: no callbacks; the command runs at once; created entities are found by difference
		local watch = createdKey == "L" and "LINE" or (createdKey == "V" and "TRANSPORT_VEHICLE" or nil)
		local function list()
			local r = {}
			if watch == "LINE" then
				for _, e in ipairs(api.engine.system.lineSystem.getLines()) do r[e] = true end
			else
				for _, e in ipairs(R.entitiesWith("TRANSPORT_VEHICLE")) do r[e] = true end
			end
			return r
		end
		local beforeSet = nil
		if watch then
			local okl, l = pcall(list)
			if okl then beforeSet = l else log("creation watch failed: " .. tostring(l)) end
		end
		oks, errs = pcall(sendCommand, cmd)
		if oks then
			result.success = true
			local data = {}
			if beforeSet then
				local created = nil
				local okl, after = pcall(list)
				if okl then
					for e, _ in pairs(after) do
						if not beforeSet[e] and (created == nil or e > created) then created = e end
					end
				end
				if created then
					if watch == "TRANSPORT_VEHICLE" then data.resultVehicleEntity = created else data.resultEntity = created end
					result.entities = { { created, 0 } }
					result.created = { key = createdKey .. a.uid, e = created }
				else
					-- the engine may create it during the next step: watch for it
					local seen = {}
					for e, _ in pairs(beforeSet) do seen[#seen + 1] = e end
					result.watch = { kind = watch, key = createdKey .. a.uid, before = seen, steps = 0 }
				end
			end
			result.data = data
		end
	end
	if not oks then
		result.err = "send: " .. tostring(errs)
		log("SEND FAILED " .. tostring(a.uid) .. ": " .. tostring(errs))
		if done then done(result) end
		return result
	end
	if useCallback and done then
		-- the verdict comes in the callback (logged and reported there)
		result.returned = true
		if result.answered then done(result) end
		return result
	end
	log("action " .. tostring(a.uid) .. " " .. tostring(a.fn) .. " at t=" .. tostring(gameTime()) .. " -> " .. (result.success and "OK" or "REFUSED"))
	return result
end

function reverseOf(bind)
	local rev = {}
	for k, e in pairs(bind or {}) do rev[e] = k end
	return rev
end

end
