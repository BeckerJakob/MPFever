-- MPFever common code, shared by the game-script state (link + execution) and the UI state (interception).
-- No backslash characters on purpose: special characters are built with string.char.

local C = {}

C.BS = string.char(92)
C.NL = string.char(10)
C.CR = string.char(13)
C.TAB = string.char(9)
local BS, NL, CR, TAB, QUOTE = C.BS, C.NL, C.CR, C.TAB, string.char(34)

do
	local ok, v = pcall(function() return package.loaded["io"] end)
	C.IO = ok and v or nil
end

C.DIR = os.getenv("MPFEVER_DIR")
C.NAME = os.getenv("MPFEVER_NAME") or "player"
C.ROLE = os.getenv("MPFEVER_ROLE") or "solo"
C.ACTIVE = C.DIR ~= nil and C.DIR ~= "" and C.IO ~= nil

-- name and role chosen in the main menu's MPFever window (written by MPFever.exe before the savegame is loaded)
if C.ACTIVE then
	local f = C.IO.open(C.DIR .. BS .. "identity.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		local n = s:match("name=([^" .. NL .. CR .. "]+)")
		local r = s:match("role=([^" .. NL .. CR .. "]+)")
		if n then C.NAME = n end
		if r then C.ROLE = r end
	end
end

function C.appendFile(path, text)
	local f = C.IO and C.IO.open(path, "ab")
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

function C.logger(prefix, fileName)
	return function(msg)
		pcall(debugPrint, "[MPFEVER" .. prefix .. "] " .. msg)
		if C.ACTIVE then
			pcall(C.appendFile, C.DIR .. BS .. fileName, os.date("%H:%M:%S") .. " " .. msg .. NL)
		end
	end
end

local function escapeChar(c)
	if c == NL then return BS .. "n" end
	if c == CR then return BS .. "r" end
	if c == QUOTE then return BS .. QUOTE end
	if c == BS then return BS .. BS end
	return BS .. string.format("%03d", string.byte(c))
end

-- An integral number as decimal text. string.format("%d") of the game's Lua 5.2 is 32 bits (LUA_INTFRM_T long on
-- Windows): beyond +-2^31 it raises "not a number in proper range" (finding F1: a balance above 2.1 billion broke
-- sync_hash). "%.0f" is exact for every integer a double holds exactly (below 2^53).
function C.int(v)
	if v == 0 then return "0" end
	return string.format("%.0f", v)
end

-- The bytes a string must escape: control bytes 0-31 and 127, quote and backslash - explicitly, not with %c, whose
-- meaning follows the process locale (finding F2: under a code page locale %c also matches bytes inside UTF-8
-- characters, e.g. the second byte of "í", which then left an invalid UTF-8 line).
local ESCAPED = "[" .. string.char(0) .. "-" .. string.char(31) .. string.char(127) .. QUOTE .. BS .. "]"

function C.ser(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "0" end
		if math.floor(v) == v and math.abs(v) < 9007199254740992 then return C.int(v) end
		return string.format("%.17g", v)
	elseif t == "string" then
		return QUOTE .. v:gsub(ESCAPED, escapeChar) .. QUOTE
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" and depth < 40 then
		local parts = {}
		for k, val in pairs(v) do
			parts[#parts + 1] = "[" .. C.ser(k, depth + 1) .. "]=" .. C.ser(val, depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

function C.deser(s)
	local chunk = load("return " .. s, "msg", "t", {})
	if not chunk then return nil end
	local ok, v = pcall(chunk)
	if ok then return v end
	return nil
end

function C.dump(v)
	local ok, s = pcall(function() return toString(v) end)
	if ok then return tostring(s) end
	return tostring(v)
end

-- the clock the timeouts of the mod use (seconds, os.clock of the game: wall time since the process started on
-- Windows). One place to replace it (tests run on a virtual clock; finding F4).
function C.clock()
	return os.clock()
end

function C.hashStr(h, s)
	for i = 1, #s do
		h = (h * 31 + s:byte(i)) % 4294967296
	end
	return h
end

-- the game's own command functions, saved before the UI hook wraps them; kept in package.loaded so that every
-- script of the Lua state (UI hook, game script bridge) sees the same table, also after a savegame reload
function C.origCmds()
	local ok, t = pcall(function()
		local t = package.loaded["mpfever_orig_cmds"]
		if type(t) ~= "table" then t = {}; package.loaded["mpfever_orig_cmds"] = t end
		return t
	end)
	if ok then return t end
	C._orig = C._orig or {}
	return C._orig
end

-- one protocol line: kind TAB from TAB payload
function C.line(kind, payload)
	return kind .. TAB .. C.NAME .. TAB .. C.ser(payload or {}) .. NL
end

-- ------------------------------------------------------------------ marshalling of native objects

local function members(o)
	local ok, m = pcall(function() return o.__members end)
	if ok and m ~= nil then return m end
	local mt = getmetatable(o)
	if type(mt) == "table" then
		ok, m = pcall(function() return mt.__members end)
		if ok and m ~= nil then return m end
	end
	return nil
end
C.members = members

local function marshal(v, depth)
	depth = depth or 0
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" then return v end
	if depth > 30 then return nil end
	if t == "table" then
		local r = {}
		for k, x in pairs(v) do
			if type(k) == "number" or type(k) == "string" then r[k] = marshal(x, depth + 1) end
		end
		return r
	end
	if t == "userdata" then
		-- matrix first: Mat4f exposes no members but is indexable by 1..16
		local okm, m16 = pcall(function() return v[16] end)
		if okm and type(m16) == "number" then
			local r = { __mat = true }
			for i = 1, 16 do r[i] = v[i] end
			return r
		end
		local m = members(v)
		if m ~= nil and #m > 0 then
			local r = { __ud = true }
			local ok = pcall(function()
				for i = 1, #m do
					local k = m[i]
					local okk, x = pcall(function() return v[k] end)
					if okk and type(x) ~= "function" then r[k] = marshal(x, depth + 1) end
				end
			end)
			if ok then return r end
		end
		local okx, x = pcall(function() return v.x end)
		if okx and type(x) == "number" then
			local r = { __vec = true, x = x }
			pcall(function() r.y = v.y end)
			pcall(function() r.z = v.z end)
			pcall(function() r.w = v.w end)
			return r
		end
		local okl, n = pcall(function() return #v end)
		if okl and type(n) == "number" then
			local r = {}
			local ok0, v0 = pcall(function() return v[0] end)
			if ok0 and v0 ~= nil then r[0] = marshal(v0, depth + 1) end
			for i = 1, n do
				local oki, e = pcall(function() return v[i] end)
				if oki then r[i] = marshal(e, depth + 1) end
			end
			return r
		end
		local r = {}
		local okp = pcall(function()
			for k, x in pairs(v) do
				if type(k) == "number" or type(k) == "string" then r[k] = marshal(x, depth + 1) end
			end
		end)
		if okp then return r end
		return { __unknown = tostring(v) }
	end
	return nil
end
C.marshal = marshal

local function isVec(m)
	return type(m) == "table" and (m.__vec or (m.__ud and type(m.x) == "number" and type(m.y) == "number" and m.n == nil))
end

local function plain(m)
	if type(m) ~= "table" then return m end
	if isVec(m) then
		if m.w ~= nil then return api.type.Vec4f.new(m.x, m.y, m.z, m.w) end
		if m.z ~= nil then return api.type.Vec3f.new(m.x, m.y, m.z) end
		return api.type.Vec2f.new(m.x, m.y)
	end
	if m.__mat then
		local V = api.type.Vec4f.new
		return api.type.Mat4f.new(V(m[1], m[2], m[3], m[4]), V(m[5], m[6], m[7], m[8]), V(m[9], m[10], m[11], m[12]), V(m[13], m[14], m[15], m[16]))
	end
	local r = {}
	for k, x in pairs(m) do
		if k ~= "__ud" then r[k] = plain(x) end
	end
	return r
end
C.plain = plain

local function path(root, dotted)
	local cur = root
	for part in dotted:gmatch("[^.]+") do
		if cur == nil then return nil end
		local ok, nxt = pcall(function() return cur[part] end)
		if not ok then return nil end
		cur = nxt
	end
	return cur
end

C.CTOR = {
	SimpleProposal = { "api.type.SimpleProposal" },
	ConstructionEntity = { "api.type.SimpleProposal.ConstructionEntity" },
	NodeAndEntity = { "api.type.NodeAndEntity", "api.type.Proposal.NodeAndEntity" },
	SegmentAndEntity = { "api.type.SegmentAndEntity", "api.type.Proposal.SegmentAndEntity" },
	BaseNode = { "api.type.BaseNode", "api.engine.Component.BaseNode" },
	BaseEdge = { "api.type.BaseEdge", "api.engine.Component.BaseEdge" },
	BaseEdgeStreet = { "api.type.BaseEdgeStreet", "api.engine.Component.BaseEdgeStreet" },
	PlayerOwned = { "api.type.PlayerOwned", "api.engine.Component.PlayerOwned" },
	TransportVehicleConfig = { "api.type.TransportVehicleConfig" },
	TransportVehiclePart = { "api.type.TransportVehiclePart" },
	VehiclePart = { "api.type.VehiclePart" },
	LoadConfig = { "api.type.LoadConfig" },
	Line = { "api.type.Line", "api.engine.Component.Line" },
	LineStop = { "api.type.Line.Stop", "api.engine.Component.Line.Stop" },
	StopConfig = { "api.type.Line.StopConfig", "api.engine.Component.Line.StopConfig" },
	StationTerminal = { "api.type.StationTerminal" },
	Context = { "api.type.Context" },
	StreetEdgeObject = { "api.type.SimpleStreetProposal.EdgeObject" },
}

-- fields needing a specific type; false = derived by the engine, never copied; absent = copied generically
local SCHEMA = {
	NodeAndEntity = { comp = "BaseNode" },
	BaseNode = { position = "Vec3f" },
	SegmentAndEntity = { comp = "BaseEdge", streetEdge = "BaseEdgeStreet", playerOwned = "PlayerOwned", emissionEmitter = false },
	BaseEdge = { position0 = "Vec3f", position1 = "Vec3f", tangent0 = "Vec3f", tangent1 = "Vec3f", laneConfigs = false, laneConfigs_native = false, laneConfig = false, distance = false },
	TransportVehicleConfig = { vehicles = { list = "TransportVehiclePart" } },
	TransportVehiclePart = { part = "VehiclePart" },
	VehiclePart = { compartment2loadConfig = { list = "LoadConfig" }, color = "Vec3f" },
	Line = { stops = { list = "LineStop" } },
	LineStop = { alternativeTerminals = { list = "StationTerminal" }, stopConfig = "StopConfig", waypoints = false },
}

C.errors = {}

function C.newOf(tname)
	for _, p in ipairs(C.CTOR[tname] or {}) do
		local c = path(_G, p)
		if c ~= nil then
			local ok, obj = pcall(function() return c.new() end)
			if ok and obj ~= nil then return obj end
			ok, obj = pcall(function() return c:new() end)
			if ok and obj ~= nil then return obj end
		end
	end
	error("no constructor for " .. tname)
end

local rebuild

local function fill(obj, m, tname, where)
	local schema = SCHEMA[tname] or {}
	for k, mv in pairs(m) do
		if k ~= "__ud" and k ~= "__mat" and k ~= "__vec" then
			local ft = schema[k]
			if ft ~= false then
				local val
				local okv, errv = pcall(function()
					if type(ft) == "string" then
						val = rebuild(ft, mv, where .. "." .. k)
					elseif type(ft) == "table" and ft.list then
						val = {}
						for i, e in ipairs(mv) do val[i] = rebuild(ft.list, e, where .. "." .. k .. "[" .. i .. "]") end
					elseif type(mv) == "table" and mv.__ud and not isVec(mv) then
						local cur = obj[k]
						if type(cur) == "userdata" then
							fill(cur, mv, "?", where .. "." .. k)
							val = cur
						else
							val = plain(mv)
						end
					else
						val = plain(mv)
					end
				end)
				if okv then
					local oka, erra = pcall(function() obj[k] = val end)
					if not oka then
						-- a sub-object that cannot be replaced is filled in place; read-only members are derived by
						-- the engine and are skipped
						local cur = nil
						pcall(function() cur = obj[k] end)
						local msg = tostring(erra)
						if type(cur) == "userdata" and type(mv) == "table" then
							pcall(fill, cur, mv, "?", where .. "." .. k)
						elseif not msg:find("read only", 1, true) then
							C.errors[#C.errors + 1] = where .. "." .. k .. ": " .. msg:sub(1, 120)
						end
					end
				else
					C.errors[#C.errors + 1] = where .. "." .. k .. ": " .. tostring(errv):sub(1, 120)
				end
			end
		end
	end
	return obj
end

rebuild = function(tname, m, where)
	where = where or tname
	if type(m) ~= "table" then return m end
	if tname == "Vec3f" or tname == "Mat4f" or isVec(m) or m.__mat then return plain(m) end
	local obj = C.newOf(tname)
	return fill(obj, m, tname, where)
end
C.rebuild = rebuild
C.isVec, C.fill = isVec, fill

-- part 2 (proposal and argument rebuilding): mpfever_proposal.lua
do
	local ok, part = pcall(ug_require, "mpfever_proposal.lua")
	if not ok then part = ug_require("mpfever_1::/mpfever_proposal.lua") end
	part(C)
end

return C
