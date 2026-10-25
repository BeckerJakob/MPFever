"""Groups of trees as references (mpfever_refs.lua), offline: a group removed by the bulldozer must be described on the builder's
game whatever its models (a forest of the map has thin models only: 0.5.1 described none of them, the removal was dropped and the
games drifted apart) and found again on the other games, by its id or by one of its trees nearby. Mocked game API (no engine).
Needs lupa (pip install lupa). Run: python tests/test_assets.py
"""
import os
import sys

try:
    import lupa.lua52 as lua52
except ImportError:
    print("lupa is not installed (pip install lupa): test skipped")
    sys.exit(0)

here = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "mod", "mpfever_1", "content")
L = lua52.LuaRuntime(unpack_returned_tuples=True)

MOCK = r'''
ENVV = {}
os = { getenv = function(k) return ENVV[k] end, clock = function() return 0 end }
-- a native vector: :size() and :at(i) from 1
local function vec(t) return { size = function() return #t end, at = function(_, i) return t[i] end } end
local function mat(x, y, z) local m = { 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, x, y, z, 1 } return m end
local function thin(id, x, y, z) return { modelId = id, pos = { x = x, y = y, z = z }, rot = 0.5, scale = 1 } end
local function fat(id, x, y, z) return { modelId = id, transf = mat(x, y, z) } end
-- the world: entity -> components
W = {}
function group(e, fats, thins, ag, bbox)
  local c = {}
  -- (the converted tables fail, as a forest too big to copy would: the native vectors must be read)
  c.mil = setmetatable({ fatInstances_native = vec(fats or {}), thinInstances_native = vec(thins or {}) },
    { __index = function(_, k) error("no " .. k) end })
  if ag then c.ag = {} end
  if bbox then c.bv = { bbox = { min = bbox[1], max = bbox[2] } } end
  W[e] = c
end
FAT, THIN, MAT = fat, thin, mat
NAMES = { [7] = "assets/trees/a.mdl", [8] = "/assets/trees/b.mdl", [9] = "::/assets/rocks/c.mdl" }
api = {
  type = {
    ComponentType = { CONSTRUCTION = "con", ASSET_GROUP = "ag", MODEL_INSTANCE_LIST = "mil", BOUNDING_VOLUME = "bv",
      PLAYER_OWNED = "po", TOWN_BUILDING = "tb", BASE_NODE = "bn", BASE_EDGE = "be" },
    Vec2f = { new = function(x, y) return { x = x, y = y } end },
  },
  res = { modelRep = { getName = function(id) return NAMES[id] end } },
  engine = {
    entityExists = function(e) return W[e] ~= nil end,
    getComponent = function(e, ct) local c = W[e]; return c and c[ct] or nil end,
    forEachEntityWithComponent = function(fn, ct) error("a full scan of the map (0.5.1 did one per removal)") end,
    util = { octree = { findEntitiesInCircle = function(c, r, ct)
      OCTREE = (OCTREE or 0) + 1
      local out = {}
      for e, comps in pairs(W) do
        if comps[ct] then
          -- (its bounding box across the circle, else its first model in it)
          local p = nil
          local m = comps.mil
          if comps.bv then
            local a, b = comps.bv.bbox.min, comps.bv.bbox.max
            p = { x = math.max(a.x, math.min(c.x, b.x)), y = math.max(a.y, math.min(c.y, b.y)) }
          elseif m then
            if m.fatInstances_native:size() > 0 then local t = m.fatInstances_native:at(1).transf; p = { x = t[13], y = t[14] }
            elseif m.thinInstances_native:size() > 0 then p = m.thinInstances_native:at(1).pos end
          end
          if p and (p.x - c.x) ^ 2 + (p.y - c.y) ^ 2 <= r * r then out[#out + 1] = e end
        end
      end
      return out
    end } },
    system = { streetSystem = { getNode2SegmentMap = function() return {} end } },
  },
}
'''
L.execute(MOCK)
R = L.execute(open(os.path.join(here, "mpfever_refs.lua"), encoding="utf-8").read())
L.globals().R = R
L.execute('''
  -- a forest of the map: thin models only (the friends' 22:23 group)
  group(100, {}, { THIN(7, 10, 20, 5), THIN(7, 12, 22, 5), THIN(8, 14, 21, 5) }, true, { { x = 9, y = 19, z = 4 }, { x = 15, y = 23, z = 9 } })
  -- a brush stroke: fat models
  group(101, { FAT(8, 50, 60, 7), FAT(7, 52, 61, 7) }, {}, true)
  -- trees another game's replay made: fat models, no AssetGroup, one of them where group 100's second tree stands
  group(102, { FAT(9, 300, 300, 1), FAT(7, 12, 22, 5) }, {}, false, { { x = 11, y = 21, z = 0 }, { x = 301, y = 301, z = 9 } })
  -- a group with no model to read: its bounding box
  group(103, {}, {}, true, { { x = 100, y = 100, z = 0 }, { x = 110, y = 120, z = 10 } })
  -- a construction (not a group of trees)
  W[200] = { con = { fileName = "station.con", transf = MAT(1, 2, 3) }, mil = W[101].mil }
''')

failures = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        failures.append(what)


def lua(src):
    return L.execute(src)


print("describe (builder's game)")
d = lua("return R.describe('con', 100)")
check(d is not None and d.k == "asset", "a forest of thin models is described (0.5.1: nil)")
check(lua("return R.describeAssetOld(100)") is None, "the 0.5.1 description of it was nil (the cause of the 22:30 resync)")
check(d is not None and abs(d.p.x - 10) < 1e-9 and abs(d.p.y - 20) < 1e-9 and abs(d.p.z - 5) < 1e-9, "its place is its first tree's pos")
check(d is not None and d.m == "assets/trees/a.mdl" and d.n == 3 and d.ag is True and not d.bb, "its model by name, 3 models, an AssetGroup")
d = lua("return R.describe('con', 101)")
check(d is not None and d.m == "assets/trees/b.mdl" and abs(d.p.x - 50) < 1e-9, "a fat group: its first model's matrix, the name without its prefix")
d = lua("return R.describe('con', 103)")
check(d is not None and d.bb is True and abs(d.p.x - 105) < 1e-9 and abs(d.p.y - 110) < 1e-9, "no model to read: the centre of its bounding box")
d = lua("return R.describe('con', 200)")
check(d is not None and d.k == "con" and d.f == "station.con", "a construction is still a construction")
check(lua("return R.describe('con', 999)") is None, "a missing entity is not described")
check(lua("return R.normModel('::/assets/x.mdl') == R.normModel('/assets/x.mdl') and R.normModel('assets/x.mdl') == 'assets/x.mdl'"), "model names compared without their prefix")
check(lua("return R.isTreeGroup(100) and R.isTreeGroup(102) and not R.isTreeGroup(200) and not R.isTreeGroup(999)"), "groups of trees told from constructions")
check(lua("local f, t = R.instanceCounts(100) return f == 0 and t == 3"), "instance counts read from the native vectors")

print("resolve (the other games)")
check(lua("return R.resolve(R.describe('con', 100))") == 100, "by its own id")
check(lua("OCTREE = 0 local d = R.describe('con', 100) d.id = -1 return R.resolve(d) == 100 and OCTREE >= 1"), "by its place when the id differs (octree, no scan of the map)")
check(lua("local d = R.describe('con', 100) d.id = 101 return R.resolve(d)") == 100, "an id naming another group: found by its place")
check(lua("return R.resolve({ k = 'asset', id = -1, p = { x = 12, y = 22, z = 5 }, m = 'assets/trees/a.mdl' })") == 100,
      "any tree of a group, not only its first (the lowest id on a tie)")
L.execute("W[100] = nil")
check(lua("return R.resolve({ k = 'asset', id = 100, p = { x = 12.2, y = 22, z = 5 }, m = 'assets/trees/a.mdl' })") == 102,
      "trees a replay made (fat, no AssetGroup) found by a tree of theirs")
check(lua("return R.resolve({ k = 'asset', id = 100, p = { x = 10, y = 20, z = 5 }, m = 'assets/trees/a.mdl' })") is None,
      "a removed group whose tree stands nowhere: not found")
check(lua("return R.resolve({ k = 'asset', id = 102, p = { x = 12, y = 22, z = 5 }, m = 'assets/trees/b.mdl' })") is None,
      "another model at the place: not found")
check(lua("return R.resolve({ k = 'asset', id = 200, p = { x = 50, y = 60, z = 7 }, m = 'assets/trees/b.mdl' })") == 101,
      "a construction is never taken for a group of trees")
check(lua("return R.resolve({ k = 'asset', id = -1, p = { x = 105, y = 110.5, z = 5 }, bb = true })") == 103,
      "a group described by its bounding box")
check(lua("return R.resolve({ k = 'asset', id = 101 })") == 101, "a group described without a place: its id while it is a group")

print("as before (MPFEVER_ASSETREF=0)")
L.execute("ENVV.MPFEVER_ASSETREF = '0'")
L.execute("group(100, {}, { THIN(7, 10, 20, 5) }, true)")
check(lua("return R.describe('con', 100)") is None, "a forest of thin models is not described, as 0.5.1")

print()
if failures:
    print("%d FAILED" % len(failures))
    sys.exit(1)
print("all passed")
