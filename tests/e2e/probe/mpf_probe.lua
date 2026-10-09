-- MPFever Lua probe (Phase 0, findings F1 / F2): what the game's own Lua does with the two things the offline tests
-- found. Started by tests/e2e/test_game_lua.py as an application script:
--   TransportFever3.exe --script mpfever_1::/mpf_probe.lua   (MPFEVER_DIR set)
-- Writes MPFEVER_DIR/probe.txt (key=value lines, appended step by step: a sandboxed function that is missing ends
-- one step, not the probe) and changes nothing.
local IO = package.loaded.io
local DIR = os.getenv("MPFEVER_DIR")
local BS, NL = string.char(92), string.char(10)

local function put(k, v)
	if not (IO and DIR) then return end
	local f = IO.open(DIR .. BS .. "probe.txt", "ab")
	if f then
		f:write(k .. "=" .. tostring(v) .. NL)
		f:close()
	end
end

local function step(name, fn)
	local ok, err = pcall(fn)
	if not ok then put(name .. "_error", tostring(err):gsub(NL, " ")) end
end

local done = false
local function probe()
	if done then return end
	done = true
	put("started", "true")
	step("version", function() put("lua_version", _VERSION) end)
	-- F1: string.format("%d") with integers beyond 32 bits
	step("fmt", function()
		local ok31, s31 = pcall(string.format, "%d", 2147483648)
		put("fmt_d_2^31_ok", ok31)
		put("fmt_d_2^31", tostring(s31):gsub(NL, " "))
		local ok53 = pcall(string.format, "%d", 9007199254740991)
		put("fmt_d_2^53-1_ok", ok53)
	end)
	-- F2: the bytes %c matches (depends on the process locale), then the locale itself if the sandbox has setlocale
	step("ctl", function()
		local ctl = {}
		for b = 128, 255 do
			if string.char(b):find("%c") then ctl[#ctl + 1] = b end
		end
		put("ctl_bytes_128_255", table.concat(ctl, ","))
	end)
	step("locale", function() put("locale_ctype", os.setlocale(nil, "ctype")) end)
	put("finished", "true")
end

probe()

function data()
	return {
		handleEvent = function() probe() end,
		update = function() probe() end,
	}
end
