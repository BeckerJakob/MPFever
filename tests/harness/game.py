"""Where Transport Fever 3 is installed (Steam libraries, like GameInstall.FindGameDir in the launcher), and what the
native module knows about game builds (parsed from native/mpfever_native.cpp, the single source of these numbers)."""
import os
import re

from .lua import REPO

APP_ID = "3493540"
NATIVE_CPP = os.path.join(REPO, "native", "mpfever_native.cpp")


def steam_path():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam") as k:
            return winreg.QueryValueEx(k, "SteamPath")[0].replace("/", "\\")
    except OSError:
        return None


def library_folders(steam):
    out = [steam]
    vdf = os.path.join(steam, "steamapps", "libraryfolders.vdf")
    if os.path.exists(vdf):
        with open(vdf, encoding="utf-8", errors="replace") as f:
            for m in re.finditer(r'"path"\s+"([^"]+)"', f.read()):
                out.append(m.group(1).replace("\\\\", "\\"))
    return list(dict.fromkeys(os.path.normcase(os.path.normpath(p)) for p in out))


def find_game_dir():
    """The game folder, or None. MPF_GAME_DIR overrides the search."""
    env = os.environ.get("MPF_GAME_DIR")
    if env:
        return env if os.path.exists(os.path.join(env, "TransportFever3.exe")) else None
    steam = steam_path()
    if not steam:
        return None
    for lib in library_folders(steam):
        manifest = os.path.join(lib, "steamapps", "appmanifest_%s.acf" % APP_ID)
        if not os.path.exists(manifest):
            continue
        with open(manifest, encoding="utf-8", errors="replace") as f:
            m = re.search(r'"installdir"\s+"([^"]+)"', f.read())
        if m:
            d = os.path.join(lib, "steamapps", "common", m.group(1))
            if os.path.exists(os.path.join(d, "TransportFever3.exe")):
                return d
    return None


BUILD_FIELDS = ["stamp", "add", "move", "dtor", "handleDtor", "apply", "swap", "sync", "preIter", "lua", "pool", "loopRet"]


def native_builds(path=NATIVE_CPP):
    """{build number: {field: value, 'sites': [rva...]}} from BUILDS[] and UI_SITES_<build>[] of the native module."""
    with open(path, encoding="utf-8") as f:
        src = f.read()
    builds = {}
    for m in re.finditer(r"\{\s*((?:0x[0-9a-fA-F]+,\s*){12})UI_SITES_(\d+)", src):
        values = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", m.group(1))]
        b = dict(zip(BUILD_FIELDS, values))
        sites = re.search(r"UI_SITES_%s\[\]\s*=\s*\{(.*?)\};" % m.group(2), src, re.S)
        b["sites"] = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", re.sub(r"//[^\n]*", "", sites.group(1)))] if sites else []
        builds[int(m.group(2))] = b
    return builds


def native_bytes(name, path=NATIVE_CPP):
    """static const u8 <name>[] = { ... } of the native module."""
    with open(path, encoding="utf-8") as f:
        m = re.search(r"static const u8 %s\[\]\s*=\s*\{([^}]*)\}" % re.escape(name), f.read())
    return bytes(int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]+", m.group(1))) if m else None
