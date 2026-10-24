"""Mixed modes, bankruptcy and auctions (mpfever_co.lua + mpfever_eco.lua), offline: the registry's rules and the events'
outcomes with a mocked game API (no engine). Needs lupa (pip install lupa). Run: python tests/test_companies.py
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
os = os or {}
TIME = 0
BAL = {}           -- player entity -> balance
OWN = {}           -- entity -> owner player entity
LINES = {}         -- player entity -> { line entities }
VEH = {}           -- line -> { vehicles }
NAMES = {}
SENT = {}
local function rec(kind, a, b, c) SENT[#SENT + 1] = { kind = kind, a = a, b = b, c = c } end
api = {
  type = {
    JournalEntry = { new = function() return { category = {} } end,
      Type = { OTHER = 1, CONSTRUCTION = 2, ACQUISITION = 3, MAINTENANCE = 4, INCOME = 5, LOAN = 6 },
      Construction = { STATION = 1, TRACK = 2, DEPOT = 3 }, Maintenance = { INFRASTRUCTURE = 1 }, Carrier = { RAIL = 1, OTHER = 2 } },
    Vec3f = { new = function() return {} end },
    ComponentType = { PLAYER_OWNED = "po", NAME = "name", LINE = "line", CONSTRUCTION = "con", STATION_GROUP = "sg", MOVE_PATH = "mp", BASE_EDGE_TRACK = "bet", TRANSPORT_VEHICLE = "tv" },
    SimpleProposal = { new = function() return {} end }, Context = { new = function() return {} end },
  },
  util = { getDefaultMonthDuration = function() return 1000 end },
  cmd = {
    sendCommand = function(c) SENT[#SENT + 1] = c end,
    makeJournalBookAssetCmd = function(ent, e) BAL[ent] = (BAL[ent] or 0) + e.amount; return { kind = "book", ent = ent, amount = e.amount, type = e.category.type } end,
    makeEntitySetPlayerCmd = function(e, p) OWN[e] = p; return { kind = "owner", e = e, p = p } end,
    makeVehicleSellCmd = function(v) OWN[v] = nil; return { kind = "sell", v = v } end,
    makeLineDestroyCmd = function(l) return { kind = "destroy", l = l } end,
    makeWorldBuildProposalCmd = function() return { kind = "build" } end,
  },
  engine = {
    getComponent = function(e, ct)
      if ct == "po" then return OWN[e] and { player = OWN[e] } or nil end
      if ct == "name" then return { name = NAMES[e] or ("E" .. e) } end
      if ct == "line" then return { stops = {} } end
      return nil
    end,
    forEachEntityWithComponent = function(fn, ct) if ct == "po" then local ks = {} for e in pairs(OWN) do ks[#ks + 1] = e end table.sort(ks) for _, e in ipairs(ks) do fn(e) end end end,
    util = { finance = { getPlayersBalance = function(p) return BAL[p] or 0 end } },
    system = {
      lineSystem = { getLinesForPlayer = function(p) local r = {} for l, o in pairs(OWN) do if o == p and VEH[l] then r[#r + 1] = l end end table.sort(r) return r end },
      transportVehicleSystem = { getLineVehicles = function(l) return VEH[l] or {} end, getVehiclesForPlayer = function(p) return {} end, getDepotVehicles = function() return {} end },
      streetConnectorSystem = {},
    },
  },
}
R = { allEdges = function() return {} end, entitiesWith = function() return {} end, withoutAssets = function(l) return l end,
      sgKey = function(sg) return "sg" .. sg end, ownerOf = function(e) return OWN[e] end }
LOG = {}
ENV = { log = function(s) LOG[#LOG + 1] = s end, R = R, STEP = 200, gameTime = function() return TIME end,
        journalCarrier = function() return 1 end }
'''
L.execute(MOCK)
CO = L.execute(open(os.path.join(here, "mpfever_co.lua"), encoding="utf-8").read())
L.globals().CO = CO
L.execute("ENV.CO = CO")
E = L.execute(open(os.path.join(here, "mpfever_eco.lua"), encoding="utf-8").read())
L.globals().E = E

failures = []


def check(cond, what):
    print(("  ok    " if cond else "  FAIL  ") + what)
    if not cond:
        failures.append(what)


run = L.eval("function(code) local f = assert(load(code)) return f() end")

# a registry as the bridge makes it: the savegame's company (entity 100, the host's), two players with their own
run('''
st = { co = CO.new("separate", 100, 2000000) }
CO.join(st.co, "host", "Host", true, "Host Co", "s1", 1)
local c2 = CO.join(st.co, "bob", "Bob", false, "Bob Co", "s2", 2)
c2.ent = 200
local c3 = CO.join(st.co, "carl", "Carl", false, "Carl Co", "s3", 3)
c3.ent = 300
BAL[100], BAL[200], BAL[300] = 5000000, 2000000, 2000000
''')
print("registry")
check(run('return CO.match(st.co, "bob", "s2", false).id') == 2, "bob plays company 2")
check(run('return CO.match(st.co, "host", "s1", true).id') == 1, "the host plays company 1")
check(run('return CO.signature(st.co):find("bob") ~= nil') is True, "the signature names the members")

print("joining")
run('E.event(st, "co_join_ask", { to = 1, mpfCo = 3, mpfFrom = "Carl#2" }, ENV)')
check(run('return #st.co.requests') == 1, "carl's request is kept")
run('E.event(st, "co_join_answer", { key = "carl", accept = true, mpfCo = 2, mpfFrom = "Bob#1" }, ENV)')
check(run('return #st.co.requests') == 1, "bob (not company 1's chief) cannot answer")
run('E.event(st, "co_join_answer", { key = "carl", accept = true, mpfCo = 1, mpfFrom = "Host" }, ENV)')
check(run('return CO.match(st.co, "carl", "s3", false).id') == 1, "carl now plays company 1")
check(run('return CO.find(st.co, 3).gone') == "empty", "carl's empty company is gone")
check(run('return #st.co.requests') == 0, "the request is done")

print("leaving")
run('E.event(st, "co_leave", { mpfCo = 1, mpfFrom = "Carl#2" }, ENV)')
check(run('return CO.match(st.co, "carl", "s3", false)') is None, "carl left company 1 (no company: it announces itself again)")
run('local c = CO.join(st.co, "carl", "Carl", false, "Carl Co 2", "s3", 3); c.ent = 301; BAL[301] = 2000000')
check(run('return CO.match(st.co, "carl", "s3", false).id') == 4, "carl gets a new company")
run('E.event(st, "co_leave", { mpfCo = 2, mpfFrom = "Bob#1" }, ENV)')
check(run('return CO.match(st.co, "bob", "s2", false).id') == 2, "bob, alone in company 2, cannot leave it")
check(run('local c = CO.join(st.co, "host", "Host", true, "x", "s1", 1); return c.id') == 1, "the host still claims company 1")

print("merging")
run('OWN[5001] = 200; OWN[5002] = 200; VEH[5002] = { 5003 }; OWN[5003] = 200; NAMES[5002] = "Line A"')
run('E.event(st, "co_merge_ask", { to = 4, mpfCo = 2, mpfFrom = "Bob#1" }, ENV)')
check(run('return #st.co.mergeOffers') == 1, "bob offers company 2 to company 4")
run('E.event(st, "co_merge_answer", { from = 2, accept = true, mpfCo = 4, mpfFrom = "Carl#2" }, ENV)')
check(run('return CO.find(st.co, 2).gone') == "merged", "company 2 is merged")
check(run('return OWN[5001] == 301 and OWN[5002] == 301 and OWN[5003] == 301') is True, "its assets belong to company 4")
check(run('return BAL[200] == 0 and BAL[301] == 4000000') is True, "its money moved")
check(run('return CO.match(st.co, "bob", "s2", false).id') == 4, "bob plays company 4")

print("bankruptcy")
run('st.co.rules = { bankrupt = 3 }; BAL[301] = -10; TIME = 0; E.tick(st, ENV)')
for m in range(1, 4):
    # (each month: the tick counts it, the host's look says who is in debt)
    run('TIME = %d; E.tick(st, ENV); E.event(st, "co_month", { month = st.co.month, debt = { 4 }, mpfFrom = "Host" }, ENV)' % (m * 1000))
run('E.event(st, "co_month", { month = st.co.month, debt = { 4 }, mpfFrom = "Bob#1" }, ENV)')
check(run('return CO.find(st.co, 4).gone') == "bankrupt", "company 4 is bankrupt after 3 months in debt")
check(run('return st.co.auction ~= nil and #st.co.auction.lots') == 1, "its line is at auction")
check(run('return CO.match(st.co, "bob", "s2", false)') is None, "its players have no company")
run('E.event(st, "co_bid", { seq = st.co.auction.seq, lot = 1, amount = 10, mpfCo = 1, mpfFrom = "Host" }, ENV)')
check(run('return st.co.auction.best') is None, "a bid below the reserve is refused")
run('E.event(st, "co_bid", { seq = st.co.auction.seq, lot = 1, amount = 60000, mpfCo = 1, mpfFrom = "Host" }, ENV)')
check(run('return st.co.auction.best') == 60000, "the host's company bids")
run('E.event(st, "co_lot_close", { seq = st.co.auction.seq, lot = 1, mpfFrom = "Bob#1" }, ENV)')
check(run('return st.co.auction ~= nil') is True, "only the host closes a lot")
run('E.event(st, "co_lot_close", { seq = st.co.auction.seq, lot = 1, mpfFrom = "Host" }, ENV)')
check(run('return st.co.auction') is None, "the auction is over")
check(run('return OWN[5002] == 100 and OWN[5003] == 100') is True, "the line and its vehicle are company 1's")
check(run('return BAL[100]') == 5000000 - 60000, "company 1 paid its bid")

print("tracks")
run('E.event(st, "co_track_rule", { rule = "toll", toll = 2500, mpfCo = 1, mpfFrom = "Host" }, ENV)')
check(run('return E.trackRule(st.co, CO.find(st.co, 1)).toll') == 2500, "company 1's tracks have a toll")
check(run('return E.trackRule(st.co, CO.find(st.co, 4)).rule') == "open", "a gone company's tracks are open")

print()
print("FAILED: %d" % len(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
