-- MPFever page of the game's main menu.
-- The main menu's UI runs in its own Lua state, where mods are not loaded: the native module (winhttp.dll) puts
-- require("mpfever_1::/mpfever_menu.lua") in front of gui/menu/main_menu.tl. This file then wraps the main page through
-- the UI's recipe replacement table: the page is drawn as usual, with a « Multiplayer » card on top of it, which opens
-- the MPFever page in its place (host one of the player's savegames, or join a host by its address).
-- Link with MPFever.exe: two small files in the session folder (MPFEVER_DIR).
--   menu_req.txt   written here: seq TAB command TAB argument TAB player name TAB option   (host / join / cancel; the option
--                  is the company mode of a host, the password of a dedicated server for a join)
--   menu_state.txt written by MPFever.exe: key=value lines (phase, text, progress, load, name, addr, players)
-- No backslash characters on purpose.

local IO = package.loaded.io
local DIR = os.getenv("MPFEVER_DIR")
if not (IO and DIR and DIR ~= "") then return {} end

local BS, NL, TAB = string.char(92), string.char(10), string.char(9)
-- Texts: French and English are written in the code as T("français", "English"); the other languages come from
-- lang.txt in the session folder, written by MPFever.exe: "@lang TAB code", then "English TAB translation" lines.
-- Read again when MPFever.exe announces another language (lang= in menu_state.txt).
local LANG, LANGCODE = {}, os.getenv("MPFEVER_LANG") or "en"
local function loadLang()
	local t = {}
	local f = IO.open(DIR .. BS .. "lang.txt", "rb")
	if f then
		local s = f:read("*a") or ""
		f:close()
		for line in s:gmatch("[^" .. NL .. "]+") do
			local k, v = line:match("^(.-)" .. TAB .. "(.*)$")
			if k and k ~= "" then
				v = v:gsub(string.char(13), "")
				if k == "@lang" then LANGCODE = v else t[k] = v end
			end
		end
	end
	LANG = t
end
loadLang()
local function T(fr, en)
	if LANGCODE == "fr" then return fr end
	return LANG[en] or en
end

local function log(msg)
	pcall(print, "[MPFEVER-MENU] " .. tostring(msg))
	local f = IO.open(DIR .. BS .. "menu.log", "ab")
	if f then f:write(os.date("%H:%M:%S") .. " " .. tostring(msg) .. NL) f:close() end
end

local function readFile(name)
	local f = IO.open(DIR .. BS .. name, "rb")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	return s
end

local function writeFile(name, text)
	local f = IO.open(DIR .. BS .. name, "wb")
	if not f then return false end
	f:write(text)
	f:close()
	return true
end

-- what MPFever.exe tells the menu
-- (a state read while MPFever.exe writes it lacks its last line "end=1": the last whole one is kept, else the page showed the
-- tabs for a moment, then the session again, over and over while the host's game came in)
local lastState, endSeen = nil, false
local function readState()
	local st = {}
	for line in (readFile("menu_state.txt") or ""):gmatch("[^" .. NL .. "]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then st[k] = v:gsub(string.char(13), "") end
	end
	if st["end"] then endSeen = true end
	if st["end"] or not lastState or not endSeen then
		lastState = st
		return st
	end
	local copy = {}
	for k, v in pairs(lastState) do copy[k] = v end
	return copy
end

local reqSeq = 0
local function request(cmd, arg, name, option)
	reqSeq = reqSeq + 1
	local seq = tostring(os.time()) .. "." .. reqSeq
	writeFile("menu_req.txt", seq .. TAB .. cmd .. TAB .. (arg or "") .. TAB .. (name or "") .. TAB .. (option or "") .. NL)
	log("request " .. cmd .. " " .. tostring(arg))
end

-- the folders of the player's savegames, as the game gives them (save_dirs.txt, one per line): the launcher looks there
-- too. A game not installed through Steam keeps them elsewhere than Steam's userdata, and the launcher found none of
-- them (« savegame not found » when hosting, issue #76)
local savedDirs = nil
local function noteSaveDirs(list)
	local seen, dirs = {}, {}
	for _, s in ipairs(list) do
		local d = type(s.path) == "string" and s.path:gsub(BS, "/"):match("^(.+)/[^/]*%.sav$") or nil
		if d and d ~= "" and not seen[d] then seen[d] = true dirs[#dirs + 1] = d end
	end
	-- (the engine leaves SaveGameInfo.path empty: issue #80, and #76 again. The game's own folder of the player's data, its
	-- "save" folder inside, is where it writes them, wherever the game is installed)
	pcall(function()
		local u = app.getUserDataFolder()
		if type(u) == "string" and u ~= "" then
			u = u:gsub(BS, "/"):gsub("/+$", "")
			for _, d in ipairs({ u .. "/save" }) do
				if not seen[d] then seen[d] = true dirs[#dirs + 1] = d end
			end
		end
	end)
	table.sort(dirs)
	local text = table.concat(dirs, NL)
	if text ~= savedDirs then
		savedDirs = text
		writeFile("save_dirs.txt", text .. NL)
		log("savegame folders: " .. (text ~= "" and text:gsub(NL, " ; ") or ("none (first path: " .. tostring(list[1] and list[1].path) .. ")")))
	end
end

local function listSaves()
	local out = {}
	local ok, err = pcall(function()
		local ns = app.SaveGameNamespace.getSavegame()
		local byName = {}
		local all = app.findAllSavegames(ns) or {}
		pcall(noteSaveDirs, all)
		for _, s in ipairs(all) do
			-- one entry per savegame name, the most recent file
			local name = s.saveName
			if name and not name:find("^MPFever resync") and not name:find("^autosave_") and not name:find("^crash_") then
				local cur = byName[name]
				if not cur or (s.timestamp or 0) > (cur.timestamp or 0) then byName[name] = s end
			end
		end
		for _, s in pairs(byName) do out[#out + 1] = s end
		table.sort(out, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
	end)
	if not ok then log("savegames: " .. tostring(err)) end
	return out
end

-- The mods of a savegame (MPFever left out), as the host sends them to the players of its lobby: "id|name|source|hub"
-- entries separated by ";;" (one line of menu_state.txt). The mod's display name and origin (Steam Workshop, mod.io...)
-- come from the savegame's mod descriptions; hub is its number on its Mod Hub (mod.io, Steam Workshop), from which a player
-- who lacks it installs it (empty for a local mod).
local MOD_ID = "mpfever_1"
local function modsOf(info)
	local out, descs = {}, {}
	pcall(function()
		for _, d in ipairs(info.metadata.gameModDescs or {}) do
			if d.modId and d.modId.name then descs[d.modId.name] = d end
		end
	end)
	pcall(function()
		for _, m in ipairs(info.mods or {}) do
			local id = m.name
			if id and id ~= "" and id ~= MOD_ID then
				local d = descs[id]
				local hub = ""
				pcall(function()
					local h = api.modhub.getModHubModIdForModId(m)
					if h and h:isValid() and tostring(h.value):match("^[%w_-]+$") then hub = tostring(h.value) end
				end)
				out[#out + 1] = { id = id, name = d and d.name ~= "" and d.name or id, source = d and d.modSource or "", hub = hub }
			end
		end
	end)
	return out
end

local function encodeMods(mods)
	local parts = {}
	local function clean(s) return (tostring(s or ""):gsub("[|;%c]", " ")) end
	for _, m in ipairs(mods or {}) do parts[#parts + 1] = clean(m.id) .. "|" .. clean(m.name) .. "|" .. clean(m.source) .. "|" .. clean(m.hub) end
	return table.concat(parts, ";;")
end

-- MPFever.exe adds what it knows of each mod (see Mods.cs): "id|name|source|kind|level|here|note|personal", kind = assets,
-- load, ui or sim (a script acting on the game), level = ok, fixed, caution or bad, here = ok, differs or notfound (a player's
-- PC), personal = host (the host's personal mod, not needed by the others), mine (taken for personal by this player) or empty
local function decodeMods(s)
	local out = {}
	for e in (s or ""):gmatch("[^;]+") do
		local f = {}
		for x in (e .. "|"):gmatch("([^|]*)|") do f[#f + 1] = x end
		local id = f[1]
		if id and id ~= "" then
			out[#out + 1] = { id = id, name = (f[2] or "") ~= "" and f[2] or id, source = f[3] or "", kind = f[4] or "",
				level = f[5] or "", here = f[6] or "", note = f[7] or "", personal = f[8] or "", hub = f[9] or "", size = f[10] or "" }
		end
	end
	return out
end

-- whether a mod is installed on this PC (nil: unknown)
local function modInstalled(id)
	local ok, r = pcall(function()
		local m = api.type.ModId.new()
		m.name = id
		return app.getUserProfile():getModRep():exists(m)
	end)
	if ok then return r and true or false end
	return nil
end

-- Installing a host's mod from its Mod Hub (0.5.0): the game's own Mod Hub subscribes this player to it and downloads it
-- (api.modhub, as its Mod Manager does; the way of TPF3-MP's roommods.lua). Each mod is asked once per menu; MPFEVER_AUTOMODS=0
-- (the launcher's setting): not by itself, a button per mod instead.
local hub = { installs = {}, requests = {} }
function hub.backend(source)
	local ok, id = pcall(function() return api.modhub.getBackendIdForSource((source and source ~= "") and source or "mod.io") end)
	if ok and type(id) == "number" and id >= 0 then return id end
	ok, id = pcall(function() return api.modhub.getBackendIdForSource("mod.io") end)
	if ok and type(id) == "number" and id >= 0 then return id end
	return nil
end
function hub.modId(number)
	local id = api.type.modhub.ModId.new()
	id.value = tostring(number)
	return id
end
-- "ok", or why not: "offline" (no Mod Hub), "signed_out" (not signed in to it)
function hub.ready(source)
	local b = hub.backend(source)
	if not b then return "offline" end
	local ok, st = pcall(function()
		if not api.modhub.isInitialized(b) then return "offline" end
		if api.modhub.getCapabilities(b).isInfoOnly then return "offline" end
		if api.modhub.getUserInfo(b) == nil then return "signed_out" end
		return "ok"
	end)
	return ok and st or "offline"
end
-- "none", "subscribed", "downloading", "installed" or "failed"
function hub.state(source, number)
	local b = hub.backend(source)
	if not b then return "none" end
	local ok, st = pcall(function()
		local id = hub.modId(number)
		local states = api.type.modhub.InstallState
		local s = api.modhub.getModInstallState(b, id)
		if s == states.Installed then return "installed" end
		if s == states.InsufficientSpace or s == states.MiscError then return "failed" end
		if s == states.Downloading or s == states.Extracting or s == states.InstallationPending or s == states.UpdatePending then return "downloading" end
		if api.modhub.getModSubscriptionState(b, id) then return "subscribed" end
		return "none"
	end)
	return ok and st or "none"
end
function hub.install(m)
	if hub.installs[m.hub] then return end
	local b = hub.backend(m.source)
	if not b then hub.installs[m.hub] = { state = "failed", err = "Mod Hub" }; return end
	hub.installs[m.hub] = { state = "asked" }
	log("Mod Hub: subscribing to " .. tostring(m.id) .. " (" .. tostring(m.source) .. " " .. tostring(m.hub) .. ")")
	local ok, err = pcall(function()
		local key, over = {}, false
		local handle = api.modhub.subscribeModAsync(b, api.type.modhub.SubscribeModRequest.new(hub.modId(m.hub)), function(result)
			over = true
			hub.requests[key] = nil
			local okr, failed = pcall(function()
				if result:isSuccess() then return nil end
				local e = result:getError()
				return e and e.message or "?"
			end)
			if okr and failed == nil then
				hub.installs[m.hub] = { state = "subscribed" }
				log("Mod Hub: subscribed to " .. tostring(m.id))
			else
				hub.installs[m.hub] = { state = "failed", err = tostring(failed) }
				log("Mod Hub: " .. tostring(m.id) .. " not subscribed: " .. tostring(failed))
			end
		end)
		if not over then hub.requests[key] = handle end
	end)
	if not ok then hub.installs[m.hub] = { state = "failed", err = tostring(err) }; log("Mod Hub: " .. tostring(err)) end
end

-- loads a savegame of this player; the application script (mpfever_auto.lua) starts it once loaded
local function loadSave(name)
	local ns = app.SaveGameNamespace.getSavegame()
	local found
	for _, s in ipairs(app.findAllSavegames(ns) or {}) do
		if s.saveName == name and (not found or (s.timestamp or 0) > (found.timestamp or 0)) then found = s end
	end
	if not found then log("savegame not found: " .. tostring(name)) return false end
	local id = api.type.SavegameId.new()
	id.path = found.path
	id.saveGameName = found.saveName
	id.saveGameNamespace = ns
	writeFile("resync_pending.txt", "1")
	log("loading savegame '" .. name .. "'")
	app.loadGame(id, false)
	return true
end

-- The release notes window (with the thank-you note for the game's buyers), which the main menu opens over the main
-- page at start until "Do Not Show Again": its close button calls back into the main page, whose states are gone once a
-- game has been loaded from it as MPFever does (the game's own menus leave the main page first). Left open, the window
-- stayed over the loaded game and its close buttons no longer removed it. Its onClose is caught here (recipe
-- replacement, as for the main page) so that MPPage closes it before a game loads.
local NOTICE_WINDOWS = { ReleaseNotesWindow = true }
local noticeClose = {}   -- recipe id -> onClose of that window while it is shown
local function catchNotice(id, name)
	_react.recipeReplace[id] = function(p, ...)
		local okq, q = pcall(function()
			if type(p) ~= "table" or type(p.onClose) ~= "function" then return nil end
			local orig = p.onClose
			local c = {}
			for k, v in pairs(p) do c[k] = v end
			-- (closed by its own button: nothing left to close)
			c.onClose = function(...)
				noticeClose[id] = nil
				return orig(...)
			end
			noticeClose[id] = c.onClose
			return c
		end)
		if okq and q then return _react.originalRecipeFn[id](q, ...) end
		return _react.originalRecipeFn[id](p, ...)
	end
	log("notice window caught: " .. tostring(name))
end

-- the main page's recipe id, caught when main_page.tl registers it (this file is loaded before it)
local mainId
local MPPage
local installReplacement
do
	local detail = api.gui.react.detail
	local orig = detail.makeRecipeId
	local ok, err = pcall(function()
		detail.makeRecipeId = function(name, ...)
			local id = orig(name, ...)
			if name == "MainPage" and not mainId then mainId = id; installReplacement() end
			if NOTICE_WINDOWS[name] then
				local okn, errn = pcall(catchNotice, id, name)
				if not okn then log("notice window " .. tostring(name) .. " not caught: " .. tostring(errn)) end
			end
			return id
		end
	end)
	if not ok then log("makeRecipeId not wrapped: " .. tostring(err)) end
end

-- The MPFever page: a page of the main menu like the game's « Load Game » (same frame, title bar, back button and
-- savegame tiles), opened by a « Multiplayer » card on the main page. Two tabs: host one of the player's savegames (its
-- tile's button opens the lobby), or join a host by its address. While something runs (lobby, connection, download,
-- loading) the page shows the session instead: the savegame's picture, what happens, the players, and its buttons.
local function setup()
	-- (the savegame folders, at once: MPFever.exe needs them to find the savegame the player hosts)
	pcall(noteSaveDirs, {})
	local react = ug_require("::/gui/main/react.lua")
	local builtin = ug_require("::/gui/main/builtin.lua")
	local menuUi = ug_require("::/gui/menu/menu_icon_react_util.tl")
	local tiles = ug_require("::/gui/main/tile_list_react_util.tl")   -- (rows of tiles)
	local guiUtil = ug_require("::/gui/main/gui_react_util.tl")
	local V = builtin.type.Orientation.Vertical
	local H = builtin.type.Orientation.Horizontal

	local PAGE_W, PAGE_H = 1630, 680   -- content of the page's card (the « Load Game » card is 1646 x 774)
	local SIDE_W = 960                 -- picture of the session view (16:9)
	local CHOICE_W = (PAGE_W - 60) / 2

	-- inline style: only what the game's style sheets do not give (sizes, paddings, colours)
	local function style(t)
		local s = api.gui.StyleSheet.new()
		local function v4(x) return api.type.Vec4f.new(x[1], x[2], x[3], x[4]) end
		-- (one property at a time: a value the UI refuses only loses that property, not the page)
		local function set(k, f) local ok, err = pcall(f); if not ok then log("style " .. k .. ": " .. tostring(err)) end end
		if t.size then set("size", function() s.size = api.type.Vec2f.new(t.size[1], t.size[2]) end) end
		if t.padding then set("padding", function() s.padding = v4(t.padding) end) end
		if t.color then set("color", function() s.color = v4(t.color) end) end
		if t.background then set("background", function() s.backgroundColor = v4(t.background) end) end
		if t.border then set("border", function() s.borderColor = v4(t.border) end) end
		if t.borderWidth then set("borderWidth", function() s.borderWidth = v4(t.borderWidth) end) end
		if t.background1 then set("background1", function() s.backgroundColor1 = v4(t.background1) end) end
		if t.image1 then
			set("image1", function()
				local n = api.gui.NinePatch.new()
				n.fileName = t.image1.fileName
				n.horizontal = t.image1.horizontal
				n.vertical = t.image1.vertical
				s.backgroundImage1 = n
			end)
		end
		return s
	end
	local function text(s, class, width)
		return builtin.TextView{ meta = { class = class or "font-scale-body" }, text = s, width = width and math.floor(width) or nil }
	end
	-- (some of the game's icons are large pictures: always a fixed size)
	local function icon(path, size)
		size = size or 24
		return builtin.ImageView{ meta = { styleSheet = style{ size = { size, size } } }, path = path, scaling = builtin.type.ImageViewScaling.AutoFit }
	end
	local function box(orientation, children, class, st)
		return builtin.Component{
			meta = { class = class, styleSheet = st and style(st) or nil },
			layout = builtin.BoxLayout{ orientation = orientation, children = children },
		}
	end
	local function gap(w, h) return builtin.Component{ meta = { styleSheet = style{ size = { w or 1, h or 1 } } } } end
	local function hfill() return guiUtil.makeHorizontalSpacer() end
	local function vfill() return guiUtil.makeVerticalSpacer() end
	-- game buttons: "primary" (filled, the main action) or "secondary" (outlined); an icon in front of the label
	local function button(label, onClick, opts)
		opts = opts or {}
		local content = {}
		if opts.icon then content[#content + 1] = icon(opts.icon); content[#content + 1] = gap(8, 1) end
		content[#content + 1] = text(label, opts.font or "font-scale-title-4")
		return builtin.Button{
			meta = {
				class = opts.primary and "primary" or "secondary",
				enabled = opts.enabled ~= false,
				tooltip = opts.tooltip,
				styleSheet = opts.size and style{ size = opts.size } or nil,
			},
			content = box(H, content),
			onClick = onClick,
		}
	end
	local function input(value, placeholder, onTyping, width)
		return builtin.TextInputField{
			meta = { class = "font-scale-title-4", styleSheet = style{ size = { width or 420, 34 } } },
			placeholderText = placeholder,
			value = value,
			onTyping = onTyping,
		}
	end
	local function sanitizeName(s)
		return (tostring(s or ""):gsub("[^%w_%-]", ""))
	end

	-- picture of a savegame (its screenshot), as the game's savegame cards read it
	local function saveId(s)
		local id = api.type.SavegameId.new()
		id.path = s.path
		id.saveGameName = s.saveName
		id.saveGameNamespace = app.SaveGameNamespace.getSavegame()
		return id
	end
	local SavePicture = react.RegisterRecipe("MPFeverSavePicture", function(sp)
		local imageRef = react.useRef(nil)
		local keyRef = react.useRef(nil)
		local key = sp.save and sp.save.saveName or ""
		if keyRef:get() ~= key then
			keyRef:set(key)
			local img
			if sp.save then
				local ok, i = pcall(app.getSavegameImage, saveId(sp.save))
				img = ok and i or nil
			end
			imageRef:set(img)
		end
		local img = imageRef:get()
		local view
		if img and img.image_native then
			view = builtin.ImageView{
				data_native = img.image_native,
				size = api.type.Vec2i.new(img.width, img.height),
				scaling = builtin.type.ImageViewScaling.AutoZoom,
			}
		else
			view = builtin.ImageView{ path = sp.fallback or "::/gui/menu/images/main.tga", scaling = builtin.type.ImageViewScaling.AutoZoom }
		end
		return builtin.BoxLayout{ children = { builtin.Component{ meta = { styleSheet = style{ size = sp.size } }, layout = builtin.BoxLayout{ children = { view } } } } }
	end)

	-- one savegame of the « Host » tab: a card like the game's savegame tiles (screenshot, name, date) with a « Host » button
	local TILE_W = math.floor((PAGE_W - 16 - 4 * 8) / 5) - 2   -- five per row, as on the « Load Game » page
	local CARD_SURFACE = { fileName = "::/gui/entity_window/design/card_surface.tga", horizontal = { 0, 6, 26, 32 }, vertical = { 0, 6, 26, 32 } }
	local SaveTile = react.RegisterRecipe("MPFeverSaveTile", function(tp)
		local asyncState = react.useState(nil)
		local dataState = react.useState(nil)
		if asyncState:old() == nil then
			local ok, a = pcall(app.getSavegameInfo, saveId(tp.save))
			asyncState:set(ok and a or false)
		end
		react.onStep(function()
			local a = asyncState:old()
			if a and dataState:old() == nil and a:isCompleted() then
				local d = a:get()
				local image, mods
				if d and d.info then
					pcall(function()
						local sh = d.info.metadata.screenshot
						image = { native = sh.image_native:clone(), w = sh.width, h = sh.height }
					end)
					mods = modsOf(d.info)
				end
				dataState:set({ image = image or false, mods = mods })
			end
		end)
		react.onUnmount(function()
			local a = asyncState:old()
			if a then pcall(function() a:abort() end) end
		end)
		local d = dataState:old()
		local picture
		if d and d.image then
			picture = builtin.ImageView{
				meta = { styleSheet = style{ size = { TILE_W - 8, 180 } } },
				data_native = d.image.native,
				size = api.type.Vec2i.new(d.image.w, d.image.h),
				scaling = builtin.type.ImageViewScaling.AutoZoom,
			}
		else
			picture = box(H, { hfill(), icon(d and "::/gui/menu/icons/alert.tga" or "::/gui/menu/icons/symbol_arrows_refresh.tga", 48), hfill() }, nil,
				{ size = { TILE_W - 8, 180 }, padding = { 66, 0, 66, 0 }, background = { 0, 0, 0, 0.35 } })
		end
		return builtin.BoxLayout{
			children = {
				box(V, {
					picture,
					gap(1, 6),
					box(H, { text(tp.save.saveName, "font-scale-title-4", TILE_W - 24) }, nil, { padding = { 0, 6, 0, 6 } }),
					box(H, {
						icon("::/gui/menu/icons/calendar.tga", 16),
						gap(6, 1),
						text(tp.save.timestamp and api.util.formatPosixTimestamp(tp.save.timestamp, api.type["enum"].DateFormat.MEDIUM) or "", "font-scale-body"),
					}, nil, { padding = { 2, 6, 0, 6 } }),
					gap(1, 8),
					button(T("Héberger", "Host"), function() tp.onHost(d and d.mods) end, { primary = true, enabled = tp.enabled, icon = "::/gui/menu/icons/menu_play.tga", size = { TILE_W - 8, 40 } }),
				}, nil, { size = { TILE_W, -1 }, padding = { 4, 4, 4, 4 }, image1 = CARD_SURFACE, background1 = { 0.16, 0.24, 0.32, 1 } }),
			},
		}
	end)

	-- a choice of the « Host » tab (company mode): a large button, filled when chosen
	local function choice(selected, title, description, onClick, enabled, warn)
		return builtin.Button{
			meta = {
				class = selected and "primary" or "secondary",
				enabled = enabled,
				styleSheet = style{ size = { CHOICE_W, -1 }, padding = { 10, 14, 10, 14 } },
			},
			content = box(V, {
				box(H, {
					icon(selected and "::/gui/menu/icons/symbol_check.tga" or "::/gui/menu/icons/symbol_star_outline.tga"),
					gap(10, 1),
					text(title, "font-scale-title-4"),
				}),
				gap(1, 4),
				text(description, warn and "font-scale-body, warning" or "font-scale-body", CHOICE_W - 40),
			}),
			onClick = onClick,
		}
	end

	-- the colour of the player's company (one company per player): a palette index, kept between sessions in the folder of every
	-- session (company_color.txt there) and given to this session (company_color.txt in the session folder, read by the
	-- bridge when the player announces itself; a colour another company already has gives the first free one)
	local PALETTE = nil
	pcall(function()
		local CO = require("mpfever_1::/mpfever_co.lua")
		if type(CO) == "table" and type(CO.PALETTE) == "table" then PALETTE = CO.PALETTE end
	end)
	PALETTE = PALETTE or {
		{ 0.86, 0.20, 0.20 }, { 0.20, 0.45, 0.90 }, { 0.20, 0.72, 0.30 }, { 0.98, 0.62, 0.10 },
		{ 0.62, 0.30, 0.82 }, { 0.10, 0.75, 0.80 }, { 0.95, 0.88, 0.15 }, { 0.95, 0.45, 0.70 },
		{ 0.55, 0.35, 0.18 }, { 0.55, 0.85, 0.15 }, { 0.15, 0.30, 0.55 }, { 0.62, 0.62, 0.62 },
	}
	local COLOR_KEPT = ".." .. BS .. "company_color.txt"
	local function readColor()
		local n = tonumber((readFile(COLOR_KEPT) or ""):match("%d+"))
		return (n and n >= 1 and n <= #PALETTE) and n or nil
	end
	local function writeColor(n)
		writeFile(COLOR_KEPT, tostring(n) .. NL)
		writeFile("company_color.txt", tostring(n) .. NL)
	end
	local function colorRow(current, onPick, note, compact, taken)
		local label = text(T("Couleur de votre entreprise", "Your company's colour") .. (compact and note and ("  " .. note) or ""), "font-scale-title-4")
		local items = compact and {} or { label, gap(12, 1) }
		local bw, bh = compact and 32 or 38, compact and 28 or 34
		for i, c in ipairs(PALETTE) do
			local sel = current == i
			local busyC = taken and taken[i]
			items[#items + 1] = builtin.Button{
				meta = { class = sel and "primary" or "secondary", enabled = not busyC,
					tooltip = busyC and T("Déjà prise par un autre joueur", "Already taken by another player") or nil,
					styleSheet = style{ size = { bw, bh }, padding = { 4, 4, 4, 4 } } },
				content = builtin.Component{ meta = { styleSheet = style{ size = { bw - (sel and 10 or 16), bh - (sel and 10 or 16) }, background = { c[1], c[2], c[3], busyC and 0.25 or 1 } } } },
				onClick = function() onPick(i) end,
			}
			items[#items + 1] = gap(4, 1)
		end
		if compact then return box(V, { label, gap(1, 4), box(H, items) }) end
		if note then items[#items + 1] = gap(12, 1); items[#items + 1] = text(note, "font-scale-body") end
		return box(H, items)
	end

	local busyPhase = function(phase) return phase ~= nil and phase ~= "" and phase ~= "idle" and phase ~= "error" end

	local MPFeverPage = react.RegisterRecipe("MPFeverPage", function(pp)
		local st0 = readState()
		-- The page opens from the main menu only: a session still "in game" (or hosting) is the one the player left by going back
		-- to the main menu. MPFever.exe ends it, and the page offers to host or join again.
		-- (only when the page opens: once open, "hosting" is the session the player just started from it)
		local opened = react.useState(false)
		local left = react.useState(false)
		if not opened:old() then
			opened:set(true)
			if st0.phase == "ingame" or st0.phase == "hosting" then
				left:set(true)
				request("leave", "", st0.name or "")
				st0.phase = "idle"
				st0.text = ""
			end
		end
		local tab = react.useState("host")
		local saves = react.useStateLazy(listSaves)
		local filter = react.useState("")
		local defaultName = st0.name
		if not defaultName or defaultName == "" then
			local ok, n = pcall(function() return app.getUserProfile():getUserName() end)
			defaultName = ok and sanitizeName(n) or ""
		end
		local name = react.useState(defaultName)
		local companies = react.useState("shared")     -- hosting: everybody plays one company, or each player has its own
		local coColor = react.useStateLazy(function()
			local n = readColor()
			if n then writeFile("company_color.txt", tostring(n) .. NL) end
			return n
		end)
		-- (in the lobby: MPFever.exe keeps it when no other player has it; the lobby's list then says it, see below)
		local function pickColor(i)
			coColor:set(i)
			request("color", tostring(i))
			log("company colour " .. i .. " asked")
		end
		local colorAsked = react.useRef(false)
		local addr = react.useState(st0.addr or "")
		local password = react.useState("")            -- joining: the password of a dedicated server (none: empty)
		local state = react.useState(st0)
		local leaving = react.useRef(false)
		-- (the host's savegame, once received, is loaded by the application script mpfever_auto.lua)
		react.onStepTimer(function()
			local s = readState()
			if s.lang and s.lang ~= "" and s.lang ~= LANGCODE then loadLang() end
			-- (the end of the left session is on its way: not a reason to leave the page)
			if left:old() then
				if s.phase == "ingame" or s.phase == "hosting" then s.phase = "idle"; s.text = ""
				else left:set(false) end
			end
			state:set(s)
			-- the game is about to load (the host's own, or the host's game received by a player who joins) or is loaded: the
			-- page has done its job, the main menu shows its main page again while the game loads
			if s.phase == "hosting" or s.phase == "loading" or s.phase == "ingame" then
				if not leaving:get() then
					leaving:set(true)
					log("phase " .. tostring(s.phase) .. ": back to the main page")
					local ok, err = pcall(pp.back)
					if not ok then log("leaving the page failed: " .. tostring(err)) end
				end
			else
				leaving:set(false)
			end
		end, 0.5)

		local st = state:old()
		local busy = busyPhase(st.phase)
		local playerName = function() return sanitizeName(name:old()) end

		-- header: the two tabs, then the player's name ------------------------------------------------------------
		local function tabButton(id, label, iconPath)
			-- (the public servers' tab asks MPFever.exe to read the list again at once)
			return button(label, function() tab:set(id); if id == "servers" then request("servers") end end, { primary = tab:old() == id, enabled = not busy, icon = iconPath, font = "font-scale-title-3" })
		end
		local header = {
			tabButton("host", T("Héberger une partie", "Host a game"), "::/gui/menu/icons/list.tga"),
			gap(8, 1),
			tabButton("join", T("Rejoindre une partie", "Join a game"), "::/gui/menu/icons/start_mission.tga"),
		}
		-- (a third tab when MPFever.exe knows a public server list, see its ServerList.cs)
		if st.serversOn == "1" then
			header[#header + 1] = gap(8, 1)
			header[#header + 1] = tabButton("servers", T("Serveurs publics", "Public servers"), "::/gui/menu/icons/list.tga")
		end
		for _, c in ipairs({
			hfill(),
			icon("::/gui/menu/icons/profile.tga"),
			gap(8, 1),
			text(T("Pseudo", "Player name"), "font-scale-title-4"),
			gap(12, 1),
			input(name:old(), T("Votre pseudo", "Your name"), function(v) name:set(v) end, 320),
		}) do header[#header + 1] = c end

		local body = {}
		local hasError = st.phase == "error" and st.text and st.text ~= ""
		-- the last error (cannot host, cannot connect, lobby closed...), above the tab
		if hasError then
			body[#body + 1] = box(H, {
				icon("::/gui/menu/icons/alert.tga"),
				gap(10, 1),
				text(st.text, "font-scale-title-4", PAGE_W - 80),
			}, "error-tape", { padding = { 8, 12, 8, 12 } })
			body[#body + 1] = gap(1, 8)
		end

		if busy then
			-- the session view ----------------------------------------------------------------------------------------
			local isHost = st.lobby == "host"
			local titles = {
				lobby = isHost and T("Salon ouvert", "Lobby open") or T("Dans le salon", "In the lobby"),
				connecting = T("Connexion à l'hôte...", "Connecting to the host..."),
				connected = T("Connecté à l'hôte", "Connected to the host"),
				downloading = T("Réception de la partie", "Receiving the game"),
				loading = T("Chargement de la partie", "Loading the game"),
				hosting = T("En partie", "In game"),
				ingame = T("En partie", "In game"),
			}
			local lobbySave
			if isHost and st.lobbySave then
				for _, s in ipairs(saves:old()) do if s.saveName == st.lobbySave then lobbySave = s end end
			end
			local right = {}
			right[#right + 1] = text(titles[st.phase] or T("Multijoueur", "Multiplayer"), "font-scale-title-1")
			if isHost and st.lobbySave and st.lobbySave ~= "" then
				right[#right + 1] = text(st.lobbySave, "font-scale-title-3")
			end
			right[#right + 1] = gap(1, 12)
			if st.text and st.text ~= "" then right[#right + 1] = text(st.text, "font-scale-title-4", PAGE_W - SIDE_W - 60) end
			-- the host's lobby: the addresses to give to the other players (public: looked up by MPFever.exe, "..." meanwhile,
			-- "?" when unknown)
			if isHost and st.publicAddr and st.publicAddr ~= "" then
				local w = PAGE_W - SIDE_W - 60
				local pub = st.publicAddr
				local addrRows = {
					text(T("Adresse à donner aux autres joueurs (Internet)", "Address to give to the other players (Internet)"), "font-scale-body"),
					gap(1, 4),
				}
				if pub == "..." then
					addrRows[#addrRows + 1] = text(T("Recherche de votre adresse publique...", "Looking up your public address..."), "font-scale-title-3")
				elseif pub == "?" then
					addrRows[#addrRows + 1] = text(T("Adresse publique introuvable : cherchez « mon adresse IP » sur Internet.", "Public address unknown: search « what is my IP » on the Internet."), "font-scale-title-4, warning", w - 24)
				else
					addrRows[#addrRows + 1] = text(pub, "font-scale-title-2", w - 24)
				end
				if st.port and st.port ~= "" then
					addrRows[#addrRows + 1] = gap(1, 4)
					addrRows[#addrRows + 1] = text((T("Le port TCP %s doit être redirigé vers ce PC sur votre box.", "TCP port %s must be forwarded to this PC on your router."):gsub("%%s", function() return st.port end)), "font-scale-body, warning", w - 24)
				end
				if st.localAddr and st.localAddr ~= "" then
					addrRows[#addrRows + 1] = gap(1, 8)
					addrRows[#addrRows + 1] = text(T("Même réseau local : ", "Same local network: ") .. st.localAddr, "font-scale-body", w - 24)
				end
				right[#right + 1] = gap(1, 10)
				right[#right + 1] = box(V, addrRows, nil, { padding = { 10, 12, 10, 12 }, background = { 1, 1, 1, 0.07 }, size = { w, -1 } })
			end
			-- the download of the host's game: its percentage, from the text MPFever.exe writes
			if st.phase == "downloading" then
				local pct = tonumber((st.text or ""):match("(%d+)%s*%%"))
				if pct then
					right[#right + 1] = gap(1, 8)
					right[#right + 1] = builtin.ProgressBar{ meta = { class = "font-scale-annotation", styleSheet = style{ size = { PAGE_W - SIDE_W - 60, 24 } } }, value = pct / 100 }
				end
			end
			-- the players
			local players = {}
			for p in (st.players or ""):gmatch("[^,]+") do
				p = p:gsub("^%s+", ""):gsub("%s+$", "")
				if p ~= "" then players[#players + 1] = p end
			end
			-- one company per player: each player's colour (picked here, before the game starts)
			local separate = st.cmode == "separate" and (st.lobby == "host" or st.lobby == "client")
			local colorOf, taken, mine = {}, {}, nil
			for nm, ix in (st.colors or ""):gmatch("([^,:]+):(%d+)") do colorOf[nm] = tonumber(ix) end
			local me = st.name or playerName()
			for nm, ix in pairs(colorOf) do if nm == me then mine = ix else taken[ix] = true end end
			if separate then
				if mine and mine ~= readColor() then writeColor(mine) elseif mine then writeFile("company_color.txt", tostring(mine) .. NL) end
				-- (the colour kept from last time, asked once when the player enters a lobby without one)
				if not mine and not colorAsked:get() then
					colorAsked:set(true)
					local pref = readColor()
					if pref and not taken[pref] then request("color", tostring(pref)) end
				end
			end
			if #players > 0 then
				right[#right + 1] = gap(1, 16)
				right[#right + 1] = text(T("Joueurs", "Players") .. " (" .. #players .. ")", "font-scale-title-3")
				right[#right + 1] = gap(1, 6)
				for i, p in ipairs(players) do
					local base = p:gsub("%s*%(.*$", "")
					local ix = separate and colorOf[base] or nil
					local pc = ix and PALETTE[ix] or nil
					-- (the colour square is the icon's place when the player has one: no hole in the list of children)
					right[#right + 1] = box(H, {
						pc and builtin.Component{ meta = { styleSheet = style{ size = { 22, 22 }, background = { pc[1], pc[2], pc[3], 1 } } } }
							or icon("::/gui/menu/icons/profile.tga"),
						gap(10, 1),
						text(p, "font-scale-title-4"),
						hfill(),
						i == 1 and (st.lobby == "host" or st.lobby == "client") and text(T("hôte", "host"), "font-scale-body") or nil,
					}, nil, { padding = { 4, 10, 4, 10 }, background = { 1, 1, 1, i % 2 == 1 and 0.06 or 0.02 }, size = { PAGE_W - SIDE_W - 60, -1 } })
				end
			end
			if separate then
				right[#right + 1] = gap(1, 14)
				right[#right + 1] = colorRow(mine, pickColor, nil, true, taken)
			end
			-- (the host) months in debt before a company goes bankrupt (its assets auctioned to the others, its players start
			-- again with a new company): the game's rule, sent with the session (see MPFever.exe's BankruptMonths)
			if separate and isHost then
				local cur = tonumber(st.bankrupt) or 12
				local opts = { box(H, { text(T("Faillite d'une entreprise endettée après :", "A company in debt goes bankrupt after:"), "font-scale-title-4") }), gap(1, 6) }
				local row = {}
				for _, mo in ipairs({ 0, 3, 6, 12, 24 }) do
					local m = mo
					row[#row + 1] = button(m == 0 and T("Jamais", "Never") or (T("%s mois", "%s months"):gsub("%%s", tostring(m))),
						function() request("bankrupt", tostring(m), playerName()) end, { font = "font-scale-body", primary = cur == m })
					row[#row + 1] = gap(6, 1)
				end
				opts[#opts + 1] = box(H, row)
				right[#right + 1] = gap(1, 14)
				right[#right + 1] = box(V, opts)
			end
			-- (the host) players who lack mods no Mod Hub has: send them from this PC? (with their size)
			if isHost then
				for e in (st.modAsk or ""):gmatch("[^;]+") do
					local who, ids, mb = e:match("^([^|]*)|([^|]*)|([^|]*)$")
					if who and who ~= "" then
						local n = 0
						for _ in ids:gmatch("[^,]+") do n = n + 1 end
						local w = who
						right[#right + 1] = gap(1, 10)
						right[#right + 1] = box(V, {
							text((T("%s n'a pas %s mod(s) qu'aucun Mod Hub ne propose (%s Mo) : ", "%s lacks %s mod(s) no Mod Hub has (%s MB): "):gsub("%%s", (who:gsub("%%", "%%%%")), 1):gsub("%%s", tostring(n), 1):gsub("%%s", mb, 1))
								.. ids:gsub(",", ", "), "font-scale-title-4, warning", PAGE_W - SIDE_W - 80),
							text(T("Les lui envoyer depuis votre PC ? Il devra accepter.", "Send them from your PC? They will have to accept."), "font-scale-body", PAGE_W - SIDE_W - 80),
							box(H, {
								button(T("Envoyer", "Send"), function() request("sendmods", w, playerName(), "1") end, { font = "font-scale-body", primary = true }),
								gap(8, 1),
								button(T("Non", "No"), function() request("sendmods", w, playerName(), "0") end, { font = "font-scale-body" }),
							}),
						}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.45, 0.1, 0.25 } })
					end
				end
				if (st.modSend or "") ~= "" then right[#right + 1] = text(st.modSend, "font-scale-body", PAGE_W - SIDE_W - 80) end
			else
				-- (a player) the host's offer: its mods hold code this game will run, so the player decides
				local ids, mb = (st.modOffer or ""):match("^([^|]*)|([^|]*)$")
				if ids and ids ~= "" then
					right[#right + 1] = gap(1, 10)
					right[#right + 1] = box(V, {
						text((T("L'hôte propose de vous envoyer ces mods (%s Mo) : ", "The host offers to send you these mods (%s MB): "):gsub("%%s", mb, 1)) .. ids:gsub(",", ", "), "font-scale-title-4", PAGE_W - SIDE_W - 80),
						text(T("Un mod contient du code qui s'exécutera dans votre jeu : n'acceptez que d'un hôte de confiance.", "A mod holds code that will run in your game: only accept from a host you trust."), "font-scale-body, warning", PAGE_W - SIDE_W - 80),
						box(H, {
							button(T("Accepter", "Accept"), function() request("takemods", "", playerName(), "1") end, { font = "font-scale-body", primary = true }),
							gap(8, 1),
							button(T("Refuser", "Refuse"), function() request("takemods", "", playerName(), "0") end, { font = "font-scale-body" }),
						}),
					}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.45, 0.1, 0.25 } })
				elseif st.modAskState == "waiting" then
					right[#right + 1] = text(T("Des mods de l'hôte ne s'installent pas automatiquement : l'hôte a été prévenu et peut vous les envoyer. Sinon, installez-les vous-même.",
						"Some of the host's mods cannot be installed by themselves: the host was told and can send them to you. Otherwise, install them yourself."), "font-scale-body, warning", PAGE_W - SIDE_W - 80)
				elseif st.modAskState == "refused" then
					right[#right + 1] = text(T("Les mods locaux de l'hôte ne vous seront pas envoyés : installez-les vous-même.", "The host's local mods will not be sent to you: install them yourself."), "font-scale-body, warning", PAGE_W - SIDE_W - 80)
				end
				if (st.modRecv or "") ~= "" then right[#right + 1] = text(st.modRecv, "font-scale-body", PAGE_W - SIDE_W - 80) end
				-- the host's savegame: on this PC already (copied by hand before joining: nothing to download), or sent at the start
				local hs, hn, hmb = (st.hostSave or ""):match("^([^|]*)|([^|]*)|([^|]*)$")
				if hs and hs ~= "" then
					local w = PAGE_W - SIDE_W - 80
					right[#right + 1] = gap(1, 10)
					if hs == "have" then
						right[#right + 1] = text((T("La sauvegarde de l'hôte (« %s ») est déjà sur ce PC : rien à télécharger au lancement.", "The host's savegame (« %s ») is already on this PC: nothing to download at the start."):gsub("%%s", (hn:gsub("%%", "%%%%")))), "font-scale-body, success", w)
					elseif hs == "checking" then
						right[#right + 1] = text(T("Recherche de la sauvegarde de l'hôte sur ce PC...", "Looking for the host's savegame on this PC..."), "font-scale-body", w)
					else
						right[#right + 1] = box(V, {
							text((T("La sauvegarde de l'hôte (« %s », %s Mo) vous sera envoyée au lancement.", "The host's savegame (« %s », %s MB) will be sent to you at the start."):gsub("%%s", (hn:gsub("%%", "%%%%")), 1):gsub("%%s", hmb, 1)), "font-scale-body", w),
							text(T("Pour éviter ce téléchargement (connexion lente), copiez ce fichier .sav depuis le PC de l'hôte dans votre dossier de sauvegardes, puis cliquez sur « Vérifier ».",
								"To avoid this download (slow connection), copy this .sav file from the host's PC into your savegame folder, then click « Check »."), "font-scale-body", w),
							box(H, {
								button(T("Ouvrir le dossier des sauvegardes", "Open the savegame folder"), function() request("opensaves", "", playerName()) end, { font = "font-scale-body" }),
								gap(8, 1),
								button(T("Vérifier", "Check"), function() request("recheck", "", playerName()) end, { font = "font-scale-body", primary = true }),
							}),
						}, nil, { padding = { 8, 8, 8, 8 }, background = { 1, 1, 1, 0.05 } })
					end
				end
			end
			-- the buttons
			local actions = {}
			if isHost then
				actions[#actions + 1] = button(T("Lancer la partie", "Start the game"), function() request("start", "", playerName()) end,
					{ primary = true, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" })
				actions[#actions + 1] = gap(8, 1)
			end
			if st.invite == "1" then
				actions[#actions + 1] = button(T("Inviter des amis Steam", "Invite Steam friends"), function() request("invite") end,
					{ icon = "::/gui/menu/icons/mod_management/platform_steam.tga" })
				actions[#actions + 1] = gap(8, 1)
			end
			if st.phase ~= "hosting" and st.phase ~= "ingame" then
				local cancelLabel = isHost and T("Fermer le salon", "Close the lobby")
					or (st.lobby == "client" and T("Quitter le salon", "Leave the lobby") or T("Annuler", "Cancel"))
				actions[#actions + 1] = button(cancelLabel, function() request("cancel") end, { icon = "::/gui/menu/icons/symbol_x.tga" })
			end
			-- (kept under the column, always in view: a long list of players or settings scrolls above them, it no longer pushes
			-- the « Start the game » button out of the page, where it could not be clicked)
			local actionsBox = box(H, actions)

			-- the mods of the host's savegame, under its picture: the player who joins sees at once which ones are missing here
			-- (the host's game cannot be loaded without them, see mpfever_auto.lua)
			local leftCol = { SavePicture{ save = lobbySave, size = { SIDE_W, SIDE_W * 9 / 16 }, fallback = "::/gui/menu/images/main.tga" } }
			local mods = decodeMods(st.hostMods)
			if #mods > 0 then
				-- each mod with what is wrong first: missing here, another version than the host's, known to break a session,
				-- then the untested scripts, the mods MPFever made work, and the others (models, interface, data)
				local W = SIDE_W - 40
				local groups = { {}, {}, {}, {}, {} }
				for _, m in ipairs(mods) do
					-- (an incompatible mod first: the player is never told to install it)
					if m.level == "bad" then m.state = "bad"
					-- (a personal mod, the host's or taken so by this player: never needed, nor in the host's version)
					elseif m.personal == "mine" then m.state = "pmine"
					elseif m.personal == "host" then m.state = isHost and "pown" or "phost"
					elseif not isHost and modInstalled(m.id) == false then m.state = "missing"
					elseif m.here == "differs" then m.state = "differs"
					else m.state = m.level ~= "" and m.level or "ok" end
					local g = (m.state == "missing" or m.state == "differs" or m.state == "bad") and 1
						or (m.state == "caution" and 2) or (m.state == "fixed" and 3) or 4
					groups[g][#groups[g] + 1] = m
				end
				local blocking = #groups[1]
				-- a mod known to break a session (another multiplayer mod, TPF3-MP): told in big, above the lobby's actions
				for _, m in ipairs(groups[1]) do
					if m.state == "bad" then
						table.insert(right, 1, box(H, {
							icon("::/gui/menu/icons/alert.tga"),
							gap(8, 1),
							box(V, {
								text((T("%s est INCOMPATIBLE avec MPFever", "%s is INCOMPATIBLE with MPFever"):gsub("%%s", (m.name:gsub("%%", "%%%%")), 1)), "font-scale-title-3, error", PAGE_W - SIDE_W - 120),
								text(T("C'est un autre mod multijoueur : il modifie les mêmes choses que MPFever et la partie se désynchronise sans cesse. L'hôte doit le désactiver dans les mods de la sauvegarde (au chargement de la partie) avant de jouer.",
									"It is another multiplayer mod: it changes the same things as MPFever and the game keeps desynchronising. The host must turn it off in the savegame's mods (when loading the game) before playing."), "font-scale-body, warning", PAGE_W - SIDE_W - 120),
							}),
						}, nil, { padding = { 8, 8, 8, 8 }, background = { 0.6, 0.1, 0.1, 0.35 } }))
						table.insert(right, 2, gap(1, 8))
					end
				end
				local rows = {}
				if blocking > 0 then
					rows[#rows + 1] = box(H, {
						icon("::/gui/menu/icons/alert.tga"),
						gap(8, 1),
						text((T("Mods à corriger : %s sur %s", "Mods to fix: %s of %s"):gsub("%%s", tostring(blocking), 1):gsub("%%s", tostring(#mods), 1)), "font-scale-title-3, error"),
					})
				else
					rows[#rows + 1] = text((T("Mods de la partie : %s", "Mods of the game: %s"):gsub("%%s", tostring(#mods), 1))
						.. (isHost and "" or T(" (tous comme chez l'hôte)", " (all as on the host's PC)")), "font-scale-title-3")
				end
				rows[#rows + 1] = gap(1, 6)
				local LABEL = {
					missing = { T("manquant", "missing"), "error" },
					differs = { T("autre version que l'hôte", "other version than the host's"), "error" },
					bad = { T("incompatible", "incompatible"), "error" },
					caution = { T("script non testé", "untested script"), "warning" },
					fixed = { T("rendu compatible", "made compatible"), "success" },
					phost = { T("mod personnel de l'hôte, pas nécessaire ici", "the host's personal mod, not needed here"), "success" },
					pown = { T("mod personnel, pas nécessaire chez les autres", "personal mod, not needed by the others"), "success" },
					pmine = { T("ignoré : pris pour personnel", "left out: taken for personal"), "warning" },
				}
				for gi = 1, 4 do
					for _, m in ipairs(groups[gi]) do
						local lab = LABEL[m.state]
						local line = m.name .. (m.source ~= "" and m.source ~= "mod.io" and " (" .. m.source .. ")" or "")
						if lab then
							rows[#rows + 1] = text(line .. " : " .. lab[1], "font-scale-title-4, " .. lab[2], W)
							local why = m.note
							if m.state == "missing" and m.hub ~= "" then
								local inst = hub.installs[m.hub]
								local hs = hub.state(m.source, m.hub)
								if hs == "downloading" then why = T("Téléchargement par le Mod Hub du jeu...", "Downloading through the game's Mod Hub...")
								elseif hs == "installed" then why = T("Installé : il apparaît dans un instant.", "Installed: it shows in a moment.")
								elseif inst and inst.state == "failed" then why = T("Installation automatique impossible : ", "Cannot be installed by itself: ") .. tostring(inst.err):gsub("[%.%s]+$", "") .. ". " .. T("Installez-le vous-même (mod.io ou Steam Workshop).", "Install it yourself (mod.io or Steam Workshop).")
								elseif inst or hs == "subscribed" then why = T("Abonné : le Mod Hub du jeu le télécharge...", "Subscribed: the game's Mod Hub downloads it...")
								elseif hub.ready(m.source) == "signed_out" then why = T("Connectez-vous au Mod Hub du jeu (bouton Mods du menu principal) pour qu'il s'installe tout seul.", "Sign in to the game's Mod Hub (Mods button of the main menu) to have it installed by itself.")
								else why = T("Installez-le (mod.io ou Steam Workshop) avant que l'hôte lance la partie.", "Install it (mod.io or Steam Workshop) before the host starts the game.") end
							elseif m.state == "missing" then why = T("Aucun Mod Hub ne le propose (mod local de l'hôte) : l'hôte peut vous l'envoyer, sinon installez-le vous-même.", "No Mod Hub has it (the host's local mod): the host can send it to you, else install it yourself.")
							elseif m.state == "differs" then why = T("Mettez-le à jour pour avoir la même version que l'hôte.", "Update it to have the host's version.")
							elseif m.state == "pmine" then why = T("La partie de l'hôte est chargée sans lui chez vous. S'il agit sur la partie, elle se désynchronisera.", "The host's game loads without it here. If it acts on the game, the game will desynchronise.")
							elseif m.state == "phost" or m.state == "pown" then why = "" end
							if why ~= "" then rows[#rows + 1] = text("   " .. why, "font-scale-body", W) end
							-- (a player may take a mod it is missing, or has in another version, for personal: the host's game is then
							-- loaded without it here, with a warning; and give it back)
							local id = m.id
							if m.state == "missing" and m.hub ~= "" and not isHost and not hub.installs[m.hub] and hub.state(m.source, m.hub) == "none" and hub.ready(m.source) == "ok" then
								if st.autoMods ~= "0" then
									hub.install(m)
								else
									local mm = m
									rows[#rows + 1] = box(H, { gap(12, 1), button(T("Installer (Mod Hub)", "Install (Mod Hub)"), function() hub.install(mm) end, { font = "font-scale-body" }) })
								end
							end
							if (m.state == "missing" or m.state == "differs") and not isHost then
								rows[#rows + 1] = box(H, { gap(12, 1), button(T("Jouer sans (le prendre pour personnel)", "Play without it (take it for personal)"),
									function() request("modpersonal", id .. " 1", playerName()) end,
									{ font = "font-scale-body", tooltip = T("Seulement pour un mod qui ne change que votre interface : un autre fera se désynchroniser la partie.", "Only for a mod that only changes your interface: any other will make the game desynchronise.") }) })
							elseif m.state == "pmine" then
								rows[#rows + 1] = box(H, { gap(12, 1), button(T("Annuler", "Undo"), function() request("modpersonal", id .. " 0", playerName()) end, { font = "font-scale-body" }) })
							end
						else
							rows[#rows + 1] = text(line, "font-scale-body", W)
						end
					end
				end
				rows[#rows + 1] = gap(1, 6)
				if blocking > 0 and not isHost then
					rows[#rows + 1] = text(T("Sans les mêmes mods que l'hôte, sa partie ne peut pas être chargée.",
						"Without the host's mods, the host's game cannot be loaded."), "font-scale-body, warning", W)
				elseif #groups[2] > 0 then
					rows[#rows + 1] = text(T("Les scripts non testés peuvent désynchroniser la partie : MPFever la recharge alors chez tout le monde.",
						"Untested scripts can desynchronise the game: MPFever then reloads it for everybody."), "font-scale-body, warning", W)
				end
				-- this player's own personal mods (only its interface: loaded in its game alone), each on or off
				if not isHost then
					local mine = {}
					for e in (st.myMods or ""):gmatch("[^;]+") do
						local id, how, on = e:match("^([^|]*)|([^|]*)|([^|]*)$")
						if id and id ~= "" then mine[#mine + 1] = { id = id, how = how, on = on == "1" } end
					end
					if #mine > 0 then
						rows[#rows + 1] = gap(1, 10)
						rows[#rows + 1] = text(T("Vos mods personnels", "Your personal mods"), "font-scale-title-3")
						rows[#rows + 1] = text(T("Ils ne changent que votre interface : ajoutés à la partie de l'hôte chez vous seul.", "They only change your interface: added to the host's game for you alone."), "font-scale-body", W)
						for _, pm in ipairs(mine) do
							local id = pm.id
							rows[#rows + 1] = box(H, {
								text(id .. (pm.how == "forced" and T(" (pris pour personnel)", " (taken for personal)") or ""), pm.on and "font-scale-body" or "font-scale-body, warning", W - 130),
								hfill(),
								button(pm.on and T("Activé", "On") or T("Désactivé", "Off"), function() request("modmine", id .. (pm.on and " 0" or " 1"), playerName()) end, { font = "font-scale-body" }),
							})
						end
					end
				end
				local picH = 220
				leftCol = {
					SavePicture{ save = lobbySave, size = { SIDE_W, picH }, fallback = "::/gui/menu/images/main.tga" },
					gap(1, 8),
					builtin.ScrollArea{
						meta = { styleSheet = style{ size = { SIDE_W, math.floor(SIDE_W * 9 / 16) - picH - 8 } } },
						content = box(V, rows, nil, { padding = { 8, 12, 8, 12 }, background = { 1, 1, 1, 0.07 }, size = { SIDE_W - 20, -1 } }),
						horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
						verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
					},
				}
			end
			body[#body + 1] = box(H, {
				box(V, leftCol),
				gap(24, 1),
				box(V, {
					builtin.ScrollArea{
						meta = { styleSheet = style{ size = { PAGE_W - SIDE_W - 40, math.floor(SIDE_W * 9 / 16) - 64 } } },
						content = box(V, right, nil, { size = { PAGE_W - SIDE_W - 60, -1 } }),
						horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
						verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
					},
					vfill(),
					actionsBox,
				}, nil, { size = { PAGE_W - SIDE_W - 40, SIDE_W * 9 / 16 } }),
			})
		elseif tab:old() == "host" then
			-- the « Host » tab ------------------------------------------------------------------------------------------
			body[#body + 1] = text(T("Mode des entreprises", "Company mode"), "font-scale-title-3")
			body[#body + 1] = gap(1, 6)
			body[#body + 1] = box(H, {
				choice(companies:old() == "shared", T("Une entreprise pour tous", "One company for everybody"),
					T("Tout le monde construit et gère la même entreprise, avec le même argent.", "Everybody builds and runs the same company, with the same money."),
					function() companies:set("shared") end, true),
				gap(8, 1),
				choice(companies:old() == "separate", T("Une entreprise par joueur", "One company per player"),
					T("Chacun son argent, son réseau, ses véhicules et sa couleur, sur la même carte. Les gares peuvent être partagées.", "Everyone has their own money, network, vehicles and colour, on the same map. Stations can be shared."),
					function() companies:set("separate") end, true),
			})
			body[#body + 1] = gap(1, 12)
			local list = {}
			local f = (filter:old() or ""):lower()
			for _, s in ipairs(saves:old()) do
				if f == "" or tostring(s.saveName):lower():find(f, 1, true) then
					list[#list + 1] = SaveTile{
						meta = { localKey = "save-" .. tostring(s.saveName) },
						save = s,
						enabled = not busy,
						onHost = function(mods)
							-- the savegame's mods, sent by MPFever.exe to the players of the lobby (read now if the tile had not yet)
							if not mods then
								pcall(function()
									local a = app.getSavegameInfo(saveId(s))
									local d = a and a:get()
									if d and d.info then mods = modsOf(d.info) end
								end)
							end
							writeFile("host_mods.txt", encodeMods(mods))
							log("savegame mods: " .. #(mods or {}))
							-- MPFever.exe opens the session as a lobby: the players join it here, then the host starts the game for everybody
							request("host", s.saveName, playerName(), companies:old())
						end,
					}
				end
			end
			body[#body + 1] = box(H, {
				text(T("Choisissez la sauvegarde à partager", "Choose the savegame to share"), "font-scale-title-3"),
				hfill(),
				builtin.TextInputField{
					meta = { class = "search-field, font-scale-body", styleSheet = style{ size = { 360, 30 } } },
					placeholderText = T("Filtrer les sauvegardes...", "Filter savegames..."),
					value = filter:old(),
					onTyping = function(v) if v ~= filter:old() then filter:set(v) end end,
				},
			})
			body[#body + 1] = gap(1, 6)
			if #list == 0 then
				body[#body + 1] = box(H, { text(#saves:old() == 0 and T("Aucune sauvegarde trouvée. Lancez une partie en solo et sauvegardez-la pour pouvoir l'héberger.", "No savegame found. Start a single-player game and save it to host it.")
					or T("Aucune sauvegarde ne correspond au filtre.", "No savegame matches the filter."), "font-scale-title-4", PAGE_W - 40) }, nil, { padding = { 24, 12, 24, 12 } })
			else
				body[#body + 1] = builtin.ScrollArea{
					meta = { class = "tile-list-scroll", styleSheet = style{ size = { PAGE_W - 16, hasError and 440 or 500 } } },
					content = builtin.Component{ layout = guiUtil.makeVerticalBox{ tiles.TileList{ elements = list, numRows = -1, numCols = 5 } } },
					horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
					verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
				}
			end
		elseif tab:old() == "servers" and st.serversOn == "1" then
			-- the « Public servers » tab: the dedicated servers of the public list (MPFever.exe reads it, menu_state servers=:
			-- one server per char 30, its fields separated by char 31: name, address, players, max, password, version, mode,
			-- world, motd) ---------------------------------------------------------------------------------------------
			body[#body + 1] = box(H, {
				text(T("Serveurs publics", "Public servers"), "font-scale-title-1"),
				hfill(),
				button(T("Actualiser", "Refresh"), function() request("servers") end, { enabled = not busy }),
			})
			body[#body + 1] = gap(1, 6)
			body[#body + 1] = text(T("Les serveurs dédiés que leurs propriétaires ont rendus publics. Il faut la même version de MPFever et du jeu que le serveur.",
				"The dedicated servers their owners made public. The same versions of MPFever and of the game as the server's are needed."), "font-scale-body", PAGE_W - 40)
			body[#body + 1] = gap(1, 10)
			local raw = st.servers or ""
			if raw == "" or raw == "-" or raw:sub(1, 1) == "!" then
				local msg = raw == "" and T("Lecture de la liste...", "Reading the list...")
					or raw == "-" and T("Aucun serveur public pour l'instant.", "No public server for now.")
					or (T("La liste des serveurs ne répond pas : ", "The server list does not answer: ") .. raw:sub(2))
				body[#body + 1] = box(H, { text(msg, "font-scale-title-4", PAGE_W - 40) }, nil, { padding = { 24, 12, 24, 12 } })
			else
				local rows = {}
				for entry in raw:gmatch("[^" .. string.char(30) .. "]+") do
					local f = {}
					for v in (entry .. string.char(31)):gmatch("(.-)" .. string.char(31)) do f[#f + 1] = v end
					local sName, sAddr, sPlayers, sMax, sPw, sVer, sMode, sWorld, sMotd = f[1] or "", f[2] or "", f[3] or "0", f[4] or "0", f[5], f[6] or "", f[7] or "", f[8] or "", f[9] or ""
					local sameVersion = sVer == "" or sVer == (st.version or sVer)
					local info = sPlayers .. " / " .. sMax .. " " .. T("joueurs", "players")
						.. "   ·   " .. (sMode == "separate" and T("une entreprise par joueur", "one company per player") or T("entreprise commune", "shared company"))
						.. (sPw == "1" and ("   ·   " .. T("mot de passe", "password")) or "")
						.. (sameVersion and "" or ("   ·   " .. T("autre version de MPFever : ", "other MPFever version: ") .. sVer))
					rows[#rows + 1] = box(H, {
						box(V, {
							text(sName, "font-scale-title-3", PAGE_W - 360),
							gap(1, 2),
							text((sWorld ~= "" and (sWorld .. "   ·   ") or "") .. info, "font-scale-body", PAGE_W - 360),
							sMotd ~= "" and text(sMotd, "font-scale-body", PAGE_W - 360) or gap(1, 1),
						}),
						hfill(),
						-- (a password: the « Join » tab with the address filled in, where the password is typed)
						button(T("Rejoindre", "Join"), function()
							if sPw == "1" then addr:set(sAddr); tab:set("join")
							else request("join", sAddr, playerName(), "") end
						end, { primary = true, enabled = sameVersion and not busy, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" }),
					}, nil, { padding = { 8, 12, 8, 12 } })
					rows[#rows + 1] = gap(1, 6)
				end
				body[#body + 1] = builtin.ScrollArea{
					meta = { class = "tile-list-scroll", styleSheet = style{ size = { PAGE_W - 16, hasError and 400 or 460 } } },
					content = box(V, rows),
					horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
					verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
				}
			end
		else
			-- the « Join » tab ------------------------------------------------------------------------------------------
			local formW = PAGE_W - SIDE_W - 40
			local canJoin = addr:old() ~= "" and not busy
			local function join()
				if addr:old() == "" then return end
				-- (one line of the request file: no tab or line break in the password)
				local pw = tostring(password:old() or ""):gsub("[%c]", "")
				request("join", addr:old(), playerName(), pw)
			end
			body[#body + 1] = box(H, {
				SavePicture{ size = { SIDE_W, SIDE_W * 9 / 16 }, fallback = "::/gui/menu/images/loadgame.tga" },
				gap(24, 1),
				box(V, {
					text(T("Rejoindre une partie", "Join a game"), "font-scale-title-1"),
					gap(1, 8),
					text(T("Entrez l'adresse que l'hôte vous a donnée. Il ouvre d'abord un salon, puis lance la partie quand tout le monde est là.",
						"Enter the address the host gave you. The host first opens a lobby, then starts the game when everybody is here."), "font-scale-body", formW),
					gap(1, 20),
					text(T("Adresse de l'hôte", "Host address"), "font-scale-title-4"),
					gap(1, 4),
					input(addr:old(), "1.2.3.4:28090", function(v) addr:set(v) end, formW - 20),
					gap(1, 14),
					text(T("Mot de passe", "Password"), "font-scale-title-4"),
					gap(1, 4),
					input(password:old(), T("seulement si le serveur en a un", "only if the server has one"), function(v) password:set(v) end, formW - 20),
					gap(1, 20),
					button(T("Rejoindre", "Join"), join, { primary = true, enabled = canJoin, icon = "::/gui/menu/icons/menu_play.tga", font = "font-scale-title-3" }),
					vfill(),
					box(H, {
						icon("::/gui/menu/icons/mod_management/platform_steam.tga"),
						gap(10, 1),
						text(T("Avec Steam, vous pouvez aussi rejoindre un ami depuis votre liste d'amis (« Rejoindre la partie ») ou accepter son invitation.",
							"With Steam, you can also join a friend from your friends list (« Join Game ») or accept their invitation."), "font-scale-body", formW - 60),
					}),
				}, nil, { size = { formW, SIDE_W * 9 / 16 } }),
			})
		end

		local content = menuUi.makeTabAnalogue(header, {
			box(V, body, nil, { size = { PAGE_W, PAGE_H }, padding = { 8, 8, 8, 8 } }),
		})
		return menuUi.makePage(pp.commonParams, "MPFever – " .. T("Multijoueur", "Multiplayer"), pp.back,
			menuUi.makeMainOuterCard(true, { content }), {})
	end)

	-- the main page, with the « Multiplayer » card in its top left corner; the MPFever page in its place once opened
	local CARD_IMAGES = {
		"::/gui/menu/images/temperate_ingame.tga",
		"::/gui/menu/images/subarctic_ingame.tga",
		"::/gui/menu/images/tropical_ingame.tga",
		"::/gui/menu/images/dry_ingame.tga",
	}
	MPPage = react.RegisterRecipe("MPFeverMainPage", function(p)
		local showMP = react.useState(os.getenv("MPFEVER_MENU_OPEN") ~= nil)
		local visited = react.useRef(false)
		-- the main menu shows: MPFever.exe ends a session the player left this way without opening the MPFever page (a new
		-- game started from here then ran in the old session). Test mode (MPFEVER_MENU_OPEN): the page opens by itself.
		react.onMount(function()
			local st0 = readState()
			log("main page shown (phase " .. tostring(st0.phase) .. ")")
			if st0.phase ~= nil and st0.phase ~= "" and st0.phase ~= "idle" then request("menu", "", st0.name or "") end
		end)
		-- MPFever starts something from here (a lobby, a join, the host's game received): the release notes window is
		-- closed now, while the main page it calls back into still exists (see NOTICE_WINDOWS). Done here and not by the
		-- MPFever page, which is not open when a player joins through a Steam invitation. (Often, as nothing is read
		-- while no such window is shown: the load may follow the phase change within a second.)
		react.onStepTimer(function()
			if next(noticeClose) == nil then return end
			local s = readState()
			if s.phase == nil or s.phase == "" or s.phase == "idle" or s.phase == "error" then return end
			for id, close in pairs(noticeClose) do
				noticeClose[id] = nil
				log("phase " .. tostring(s.phase) .. ": closing the release notes window")
				local okc, errc = pcall(close)
				if not okc then log("closing the release notes window failed: " .. tostring(errc)) end
			end
		end, 0.2)

		-- a session starts without the page (a Steam invitation accepted, the command line): the page opens to show it
		local lastPhase = react.useRef(readState().phase)
		react.onStepTimer(function()
			local phase = readState().phase
			local was = lastPhase:get()
			lastPhase:set(phase)
			if phase ~= was and busyPhase(phase) and not busyPhase(was) and phase ~= "hosting" and phase ~= "loading" and phase ~= "ingame" and not showMP:old() then
				log("phase " .. tostring(phase) .. ": opening the MPFever page")
				for id, close in pairs(noticeClose) do noticeClose[id] = nil; pcall(close) end
				showMP:set(true)
			end
		end, 0.5)

		-- (inside the menu's box layout a page must be a layout, as below)
		if showMP:old() then
			visited:set(true)
			return builtin.FloatingLayout{
				children = {
					builtin.FloatingLayoutChild{ h = -1, v = -1, item = builtin.Component{ layout = builtin.BoxLayout{ children = {
						MPFeverPage{ commonParams = p.commonParams, back = function() showMP:set(false) end },
					} } } },
				},
			}
		end

		local function open()
			log("multiplayer card clicked")
			-- (the release notes window would stay over the page)
			for id, close in pairs(noticeClose) do noticeClose[id] = nil; pcall(close) end
			showMP:set(true)
		end
		-- back from the MPFever page: the main page shows again without its release notes
		local mainParams = p
		if visited:get() and type(p) == "table" and type(p.params) == "table" and p.params.startWithReleaseNotes then
			mainParams = {}
			for k, v in pairs(p) do mainParams[k] = v end
			mainParams.params = {}
			for k, v in pairs(p.params) do mainParams.params[k] = v end
			mainParams.params.startWithReleaseNotes = false
		end
		local card = menuUi.CardButton{
			bottomComponent = menuUi.makeCardLabelBottomComponent(T("Multijoueur", "Multiplayer"), "MPFever", nil, nil, true),
			onClick = open,
			tooltip = T("Jouer à plusieurs : héberger une partie ou en rejoindre une", "Play together: host a game or join one"),
			images = CARD_IMAGES,
			initialImageIndex = 1,
			displayDurationSeconds = 12,
			class = "small-rectangle-card",
		}
		-- inside the menu's box layout a page must be a layout: the original page fills it, the card floats over it
		return builtin.FloatingLayout{
			children = {
				builtin.FloatingLayoutChild{ h = -1, v = -1, item = builtin.Component{ mouseTransparent = true, layout = builtin.BoxLayout{ children = { _react.originalRecipeFn[mainId](mainParams) } } } },
				builtin.FloatingLayoutChild{ h = 0.0, v = 0.0, item = builtin.Component{ meta = { styleSheet = style{ padding = { 96, 0, 0, 24 } } }, layout = builtin.BoxLayout{ children = { card } } } },
			},
		}
	end)
end


installReplacement = function()
	log("main page recipe id caught")
	_react.recipeReplace[mainId] = function(...)
		if not MPPage then
			local ok, err = pcall(setup)
			if not ok or not MPPage then
				log("setup failed: " .. tostring(err))
				_react.recipeReplace[mainId] = nil
				return _react.originalRecipeFn[mainId](...)
			end
			log("multiplayer page ready")
		end
		return MPPage(...)
	end
end
log("menu module loaded")
return {}
