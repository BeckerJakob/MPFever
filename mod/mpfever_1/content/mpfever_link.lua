-- MPFever link: the channels between this game, MPFever.exe and the native module (Phase 1).
--
-- Every channel is a named append-only stream of lines:
--   out.log            this game -> MPFever.exe        (protocol lines: kind TAB from TAB payload)
--   in.log             MPFever.exe -> this game
--   ui.log             UI hook -> game script bridge   (held commands)
--   results.log        bridge -> UI hook               (results of the commands)
--   bindings.log       bridge -> UI hook               (creation key -> local entity)
--   native_ctl.txt     bridge -> native module         ("enable 1", "release <n>", "tin <id>"...)
--   native_events.log  native module -> bridge         ("deferred <id>", "terrain ..."...)
-- A link has three functions:
--   append(name, text)          adds text (whole lines) to a stream; false when it cannot
--   readNew(name, offs, key)    the complete lines added since the last call; offs[key] keeps the position
--                               (a stream that became shorter is read again from its start)
--   send(kind, payload)         append("out.log", protocol line)
-- files(C): the streams are files in the session folder (MPFEVER_DIR) - what 0.2.x always did.
-- memory(C): the same contract in memory (tests; the in-process link of Phase 3 implements it too).
-- No backslash characters on purpose: special characters are built with string.char.

local M = {}

-- the complete lines of chunk (from its start), the position after the last line break (nil: no complete line)
local function splitLines(chunk, NL, CR)
	local lines, last, pos = {}, nil, 1
	while true do
		local i = chunk:find(NL, pos, true)
		if not i then break end
		last = i
		local line = chunk:sub(pos, i - 1)
		if line:sub(-1) == CR then line = line:sub(1, -2) end
		if #line > 0 then lines[#lines + 1] = line end
		pos = i + 1
	end
	return lines, last
end
M.splitLines = splitLines

local function withSend(L, C)
	function L.send(kind, payload)
		return L.append("out.log", C.line(kind, payload))
	end
	function L.nativeCtl(line)
		return L.append("native_ctl.txt", line .. C.NL)
	end
	return L
end

function M.files(C)
	local L = { kind = "files" }
	local function path(name) return C.DIR .. C.BS .. name end
	function L.append(name, text)
		return C.appendFile(path(name), text)
	end
	function L.readNew(name, offs, key)
		offs[key] = offs[key] or 0
		local f = C.IO and C.IO.open(path(name), "rb")
		if not f then return {} end
		local size = f:seek("end")
		local lines = {}
		if size < offs[key] then offs[key] = 0 end
		if size > offs[key] then
			f:seek("set", offs[key])
			local chunk = f:read(size - offs[key]) or ""
			local last
			lines, last = splitLines(chunk, C.NL, C.CR)
			if last then offs[key] = offs[key] + last end
		end
		f:close()
		return lines
	end
	return withSend(L, C)
end

function M.memory(C)
	local L = { kind = "memory", streams = {} }
	function L.append(name, text)
		L.streams[name] = (L.streams[name] or "") .. text
		return true
	end
	function L.readNew(name, offs, key)
		offs[key] = offs[key] or 0
		local s = L.streams[name]
		if not s then return {} end
		if #s < offs[key] then offs[key] = 0 end
		if #s <= offs[key] then return {} end
		local lines, last = splitLines(s:sub(offs[key] + 1), C.NL, C.CR)
		if last then offs[key] = offs[key] + last end
		return lines
	end
	-- tests: replace a stream (e.g. a file the other side rewrote)
	function L.set(name, text) L.streams[name] = text end
	return withSend(L, C)
end

return M
