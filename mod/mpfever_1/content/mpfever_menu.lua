-- MPFever page of the game's main menu.
-- The main menu's UI runs in its own Lua state, where mods are not loaded: the native module (winhttp.dll) puts
-- require("mpfever_1::/mpfever_menu.lua") in front of gui/menu/main_menu.tl. This file then wraps the main page through
-- the UI's recipe replacement table: the page is drawn as usual, with a « Multiplayer » button on top of it, which opens
-- the MPFever window (host one of the player's savegames, or join a host by its address).
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
local function readState()
	local st = {}
	for line in (readFile("menu_state.txt") or ""):gmatch("[^" .. NL .. "]+") do
		local k, v = line:match("^([%w_]+)=(.*)$")
		if k then st[k] = v:gsub(string.char(13), "") end
	end
	return st
end

local reqSeq = 0
local function request(cmd, arg, name, option)
	reqSeq = reqSeq + 1
	local seq = tostring(os.time()) .. "." .. reqSeq
	writeFile("menu_req.txt", seq .. TAB .. cmd .. TAB .. (arg or "") .. TAB .. (name or "") .. TAB .. (option or "") .. NL)
	log("request " .. cmd .. " " .. tostring(arg))
end

local function listSaves()
	local out = {}
	local ok, err = pcall(function()
		local ns = app.SaveGameNamespace.getSavegame()
		local byName = {}
		for _, s in ipairs(app.findAllSavegames(ns) or {}) do
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

local function setup()
	local react = ug_require("::/gui/main/react.lua")
	local builtin = ug_require("::/gui/main/builtin.lua")
	local V = builtin.type.Orientation.Vertical
	local H = builtin.type.Orientation.Horizontal

	local WIDTH = 760   -- width of the MPFever window's content
	local autoClosed = false
	local function text(s, class, width)
		return builtin.TextView{ meta = { class = class or "font-scale-title-4" }, text = s, width = width }
	end
	local function button(label, onClick, enabled, class, width)
		return builtin.Button{
			meta = { class = "secondary", enabled = enabled ~= false },   -- game style: outlined button
			content = text(label, class or "font-scale-title-4", width),
			onClick = onClick,
		}
	end
	local function gap() return text(" ", "font-scale-body") end
	local function box(orientation, children, class)
		return builtin.Component{
			meta = { class = class },
			layout = builtin.BoxLayout{ orientation = orientation, children = children },
		}
	end

	local MPWindow = react.RegisterWrapperRecipe("MPFeverWindow", builtin.Window, function(wp)
		local st0 = readState()
		-- The window opens from the main menu only: a session still "in game" (or hosting) is the one the player left by going back
		-- to the main menu. MPFever.exe ends it, and the window offers to host or join again.
		-- (only when the window opens: once open, "hosting" is the session the player just started from it)
		local opened = react.useState(false)
		local left = react.useState(false)
		if not opened:old() then
			opened:set(true)
			if st0.phase == "ingame" or st0.phase == "hosting" then
				left:set(true)
				request("leave", "", st0.name or "")
				st0.phase = "idle"
				st0.text = ""
				autoClosed = false
			end
		end
		local tab = react.useState("host")
		local saves = react.useStateLazy(listSaves)
		local selected = react.useState(nil)
		local name = react.useState(st0.name or "")
		local companies = react.useState("shared")     -- hosting: everybody plays one company, or each player has its own
		local addr = react.useState(st0.addr or "")
		local password = react.useState("")            -- joining: the password of a dedicated server (none: empty)
		local state = react.useState(st0)
		-- (the host's savegame, once received, is loaded by the application script mpfever_auto.lua)
		react.onStepTimer(function()
			local s = readState()
			if s.lang and s.lang ~= "" and s.lang ~= LANGCODE then loadLang() end
			-- (the end of the left session is on its way: not a reason to close the window; once MPFever.exe says it ended,
			-- a new session started from this window closes it as usual)
			if left:old() then
				if s.phase == "ingame" or s.phase == "hosting" then s.phase = "idle"; s.text = ""
				else left:set(false) end
			end
			state:set(s)
			-- the game is about to load (the host's own, or the host's game received by a player who joins) or is loaded: the
			-- window has done its job and goes away. Left open it stayed over the game as a leftover whose close button no
			-- longer answered, so it is closed before the load starts.
			if s.phase == "hosting" or s.phase == "loading" or s.phase == "ingame" then
				if not autoClosed then
					autoClosed = true
					log("phase " .. tostring(s.phase) .. ": closing the MPFever window")
					local ok, err = pcall(wp.onClose)
					if not ok then log("closing the window failed: " .. tostring(err)) end
				end
			else
				autoClosed = false
			end
		end, 0.5)

		local st = state:old()
		local busy = st.phase ~= nil and st.phase ~= "" and st.phase ~= "idle" and st.phase ~= "error"
		local rows = {}

		rows[#rows + 1] = text(T("Jouer à plusieurs à Transport Fever 3", "Play Transport Fever 3 together"), "font-scale-title-2", WIDTH)
		rows[#rows + 1] = gap()
		rows[#rows + 1] = box(H, {
			text(T("Pseudo :  ", "Player name:  ")),
			builtin.TextInputField{
				meta = { class = "font-scale-title-4" },
				placeholderText = T("Votre pseudo", "Your name"),
				value = name:old(),
				onTyping = function(v) name:set(v) end,
			},
		})
		rows[#rows + 1] = gap()
		rows[#rows + 1] = box(H, {
			button((tab:old() == "host" and "> " or "") .. T("Héberger une partie", "Host a game"), function() tab:set("host") end, not busy, "font-scale-title-3", WIDTH / 2 - 10),
			button((tab:old() == "join" and "> " or "") .. T("Rejoindre une partie", "Join a game"), function() tab:set("join") end, not busy, "font-scale-title-3", WIDTH / 2 - 10),
		})
		rows[#rows + 1] = gap()

		if tab:old() == "host" then
			rows[#rows + 1] = text(T("Choisissez la sauvegarde à partager :", "Choose the savegame to share:"))
			local list = {}
			for i, s in ipairs(saves:old()) do
				if i > 12 then break end
				local isSel = selected:old() == s.saveName
				list[#list + 1] = button((isSel and ">  " or "    ") .. s.saveName .. (s.timestamp and ("   (" .. os.date("%d/%m/%Y %H:%M", s.timestamp) .. ")") or ""), function() selected:set(s.saveName) end, not busy, nil, WIDTH)
			end
			if #list == 0 then list[1] = text(T("Aucune sauvegarde trouvée.", "No savegame found.")) end
			rows[#rows + 1] = box(V, list)
			rows[#rows + 1] = gap()
			rows[#rows + 1] = text(T("Entreprises :", "Companies:"))
			rows[#rows + 1] = box(H, {
				button((companies:old() == "shared" and "> " or "") .. T("Une entreprise pour tous", "One company for everybody"), function() companies:set("shared") end, not busy, "font-scale-title-4", WIDTH / 2 - 10),
				button((companies:old() == "separate" and "> " or "") .. T("Une entreprise par joueur", "One company per player"), function() companies:set("separate") end, not busy, "font-scale-title-4", WIDTH / 2 - 10),
			})
			if companies:old() == "separate" then
				-- the companies mode is still being developed: the host is told before hosting
				rows[#rows + 1] = text(T("ATTENTION : « Une entreprise par joueur » est en cours de développement.", "WARNING: \"One company per player\" is still in development."), "font-scale-body, error-font", WIDTH)
				rows[#rows + 1] = text(T("Il reste énormément de bugs à corriger. Utilisez ce mode surtout pour tester", "Many bugs remain to be fixed. Use this mode mainly to test it and"), "font-scale-body, error-font", WIDTH)
				rows[#rows + 1] = text(T("et aider au développement du mod (signalez les problèmes sur GitHub).", "help the development of the mod (report the problems on GitHub)."), "font-scale-body, error-font", WIDTH)
			end
			rows[#rows + 1] = gap()
			rows[#rows + 1] = button(T("Ouvrir le salon", "Open the lobby"), function()
				local sel = selected:old()
				if not sel then return end
				-- MPFever.exe opens the session as a lobby: the players join it here, then the host starts the game for everybody
				request("host", sel, name:old(), companies:old())
			end, selected:old() ~= nil and not busy, "font-scale-title-3", WIDTH)
		else
			rows[#rows + 1] = box(H, {
				text(T("Adresse de l'hôte : ", "Host address: ")),
				builtin.TextInputField{
					meta = { class = "font-scale-title-4" },
					placeholderText = "1.2.3.4:28090",
					value = addr:old(),
					onTyping = function(v) addr:set(v) end,
				},
			})
			rows[#rows + 1] = gap()
			rows[#rows + 1] = box(H, {
				text(T("Mot de passe : ", "Password: ")),
				builtin.TextInputField{
					meta = { class = "font-scale-title-4" },
					placeholderText = T("seulement si le serveur en a un", "only if the server has one"),
					value = password:old(),
					onTyping = function(v) password:set(v) end,
				},
			})
			rows[#rows + 1] = gap()
			rows[#rows + 1] = button(T("Rejoindre", "Join"), function()
				if addr:old() == "" then return end
				-- (one line of the request file: no tab or line break in the password)
				local pw = tostring(password:old() or ""):gsub("[%c]", "")
				request("join", addr:old(), name:old(), pw)
			end, addr:old() ~= "" and not busy, "font-scale-title-3", WIDTH)
		end
		rows[#rows + 1] = gap()

		-- the host's lobby: every game loads the savegame at once when the host starts the game
		if st.lobby == "host" then
			rows[#rows + 1] = text((T("Salon : %s", "Lobby: %s"):gsub("%%s", function() return st.lobbySave or "" end)), "font-scale-title-3", WIDTH)
			rows[#rows + 1] = button(T("Lancer la partie", "Start the game"), function() request("start", "", name:old()) end, true, "font-scale-title-3", WIDTH)
			rows[#rows + 1] = gap()
		end
		if st.invite == "1" then rows[#rows + 1] = button(T("Inviter des amis Steam", "Invite Steam friends"), function() request("invite") end, true, "font-scale-title-3", WIDTH) end
		if busy and st.phase ~= "hosting" and st.phase ~= "ingame" then rows[#rows + 1] = button(T("Annuler", "Cancel"), function() request("cancel") end) end
		if st.text and st.text ~= "" then rows[#rows + 1] = text(st.text, nil, WIDTH) end
		if st.players and st.players ~= "" then rows[#rows + 1] = text(T("Joueurs : ", "Players: ") .. st.players, nil, WIDTH) end

		return builtin.Window{
			title = "MPFever – " .. T("Multijoueur", "Multiplayer"),
			id = "window.mpfever",
			initialX = 0.5,
			initialY = 0.5,
			movable = true,
			closable = true,
			onClose = wp.onClose,
			content = box(V, rows),
		}
	end)

	MPPage = react.RegisterRecipe("MPFeverMainPage", function(p)
		local function open()
			local wc = p.commonParams.windowContainer:get():getApi()
			wc.addSingletonWindow(MPWindow, {
				onClose = function() p.commonParams.windowContainer:get():getApi().removeAllWindows(MPWindow) end,
			})
		end
		-- the main menu shows: MPFever.exe ends a session the player left this way without opening the MPFever window (a new
		-- game started from here then ran in the old session). Test mode (MPFEVER_MENU_OPEN): the window opens by itself.
		react.onMount(function()
			local st0 = readState()
			log("main page shown (phase " .. tostring(st0.phase) .. ")")
			if st0.phase ~= nil and st0.phase ~= "" and st0.phase ~= "idle" then request("menu", "", st0.name or "") end
			if os.getenv("MPFEVER_MENU_OPEN") then open() end
		end)
		-- MPFever starts something from here (a lobby, a join, the host's game received): the release notes window is
		-- closed now, while the main page it calls back into still exists (see NOTICE_WINDOWS). Done here and not by the
		-- MPFever window, which is not open when a player joins through a Steam invitation. (Often, as nothing is read
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
		-- inside the menu's box layout a page must be a layout: the original page fills it, the button floats over it
		return builtin.FloatingLayout{
			children = {
				builtin.FloatingLayoutChild{ h = -1, v = -1, item = builtin.Component{ mouseTransparent = true, layout = builtin.BoxLayout{ children = { _react.originalRecipeFn[mainId](p) } } } },
				builtin.FloatingLayoutChild{ h = 0.02, v = 0.5, item = button(T("  MULTIJOUEUR  ", "  MULTIPLAYER  ") .. string.char(10) .. "  MPFever", open, true, "font-scale-title-1") },
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
