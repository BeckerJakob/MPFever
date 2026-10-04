-- Registers MPFever's UI hook: the game runs doReplace in the UI Lua state when the in-game UI boots.
function data()
	return {
		type = "react-replacement-config",
		data = {
			filePath = "mpfever_1::/mpfever_ui.script",
			doReplaceFn = "doReplace",
			order = 1000,
		},
	}
end
