-- Mounts MPFever's invisible UI component on the game's mod entry point (gives the UI state a per-step hook).
function data()
	return {
		type = "react-plugin ::ModEntryPointExtension",
		data = {
			filePath = "mpfever_1::/mpfever_ui.script@MPFeverEntry",
			order = 1000,
		},
	}
end
