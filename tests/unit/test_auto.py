"""F8 (Phase 1) - mpfever_auto.lua, the application script of a game started by MPFever.exe: the autotest loads the
savegame from the main menu, the game restarts the script with the loaded game, and the restarted script must still
start the loaded game when the engine waits for a key press (before: the request was only in the lost Lua state)."""
import os

import pytest

from harness import lua

pytestmark = pytest.mark.unit

APP = """
CALLS = {}
local function call(n) CALLS[#CALLS + 1] = n end
WAITING, PROGRESS = false, 0
app = {
  SaveGameNamespace = { getSavegame = function() return "ns" end },
  findAllSavegames = function(ns) return { { saveName = "MPF-Test-Small", timestamp = 2, path = "p/MPF-Test-Small.sav" } } end,
  getSavegameInfo = function(id)
    return { isCompleted = function() return true end, get = function() return { info = { mods = {} } } end }
  end,
  loadGame = function(id, b, details) call("loadGame:" .. tostring(id.saveGameName)) end,
  isWaitForStartReadyGame = function() return WAITING end,
  getProgressMonitor = function() return { getProgress = function() return PROGRESS end } end,
  startReadyGame = function() call("startReadyGame") end,
}
api.type.SavegameId = { new = function() return {} end }
api.type.SaveGameDetails = { new = function(info) return { mods = info.mods } end }
api.type.ModId = { new = function() return {} end }
"""


def start_script(tmp_path):
    L = lua.new_runtime({"MPFEVER_DIR": str(tmp_path), "MPFEVER_NAME": "Hote", "MPFEVER_ROLE": "host"})
    os.environ["MPFEVER_SAVE"] = "MPF-Test-Small"
    try:
        L.execute(APP)
        L.execute(lua.source("mpfever_auto.lua"))
    finally:
        os.environ.pop("MPFEVER_SAVE", None)
    return L, L.eval("data()")


def frames(L, mod, n):
    for _ in range(n):
        mod.update()


def calls(L):
    return list(L.eval("CALLS").values())


def test_restarted_script_starts_the_loaded_game(tmp_path):
    L1, m1 = start_script(tmp_path)
    m1.handleEvent("x", "mainMenuReady", None)
    frames(L1, m1, 60)
    assert calls(L1) == ["loadGame:MPF-Test-Small"]
    # the engine loads the savegame and restarts the application script: a new Lua state
    L2, m2 = start_script(tmp_path)
    L2.execute("WAITING, PROGRESS = true, 1")
    frames(L2, m2, 30)
    assert calls(L2) == ["startReadyGame"]
    assert "game loaded, starting it" in open(os.path.join(str(tmp_path), "auto.log"), encoding="utf-8").read()


def test_no_start_before_loading_completes(tmp_path):
    L1, m1 = start_script(tmp_path)
    m1.handleEvent("x", "mainMenuReady", None)
    frames(L1, m1, 60)
    L2, m2 = start_script(tmp_path)
    L2.execute("WAITING, PROGRESS = true, 0.5")
    frames(L2, m2, 60)
    assert calls(L2) == []


def test_main_menu_again_does_not_load_twice(tmp_path):
    L1, m1 = start_script(tmp_path)
    m1.handleEvent("x", "mainMenuReady", None)
    frames(L1, m1, 60)
    L2, m2 = start_script(tmp_path)
    m2.handleEvent("x", "mainMenuReady", None)
    frames(L2, m2, 60)
    assert calls(L2) == []
