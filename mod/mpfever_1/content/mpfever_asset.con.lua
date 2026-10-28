-- MPFever: trees, plants and rocks another player placed with the brush (their models given as parameters). Never in the build
-- menus: only the multiplayer mod builds it, on the games of the other players.
-- Collision and automatic removal as the builder's own construction without a file (the brush's and the bulldozer's: skipCollision
-- false, autoRemovable true in their proposals): a road later built through these trees removes them on every game, as it removes
-- the builder's. With skipCollision true and no autoRemovable (0.5.1), the replayed trees stayed on the replaying games only and
-- their ids drifted apart. MPFEVER_ASSETOLDFLAGS=1: as before (read when the game loads its resources; a game whose resource
-- scripts cannot read the environment keeps the new flags, so every game of a session must be started alike)
function data()
local old = false
pcall(function() old = os.getenv("MPFEVER_ASSETOLDFLAGS") == "1" end)
return {
	description = {
		name = "MPFever assets",
		description = "Trees, plants and rocks placed by another player",
		icon = "",
	},
	params = { },
	order = 100000,
	skipCollision = old,
	autoRemovable = not old,
	updateScript = {
		fileName = "mpfever_asset.script@updateFn",
		params = { },
	},
	availability = {
		yearFrom = 0,
		yearTo = 0,
	},
}
end
