-- MPFever's icon in the game's bottom bar (the row of Earnings and Transported): a disc in the session's colour and "MPFever";
-- a click opens or closes MPFever's window. The recipe always exists (an empty one when the bar cannot be reached), see
-- MPFeverBar in mpfever_ui.script.lua. The game sorts these plugins by "order": first in the row, where its scroll area
-- never hides it.
function data()
	return {
		type = "react-plugin ::GameBarInfoDisplayExtension",
		data = {
			filePath = "mpfever_1::/mpfever_ui.script@MPFeverBar",
			order = -100,
		},
	}
end
