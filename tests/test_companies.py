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

# ------------------------------------------------------------------------------------------------------------------------------
# One PC, two games, one Steam account (every test setup): the host 'knight-hd' and the player 'knight-hd2' announce the same
# Steam account. After a join, a merger or the host joining the client's company, both announce themselves again (a
# resynchronisation reloads the host's savegame): in either order, every member must stay where it was and no company may be
# made. A player who leaves the company where the other game's player still is must get a new company of its own.
# Each block is run twice: with the rules of the files (they must pass), and with the old rules (MPFEVER_COSIDRENAME=1
# MPFEVER_COSHAREDSID=0), which these blocks must catch: a block the old rules pass would test nothing.
run('''
ENVOVR = {}
do
  local og = os.getenv
  os.getenv = function(k) local v = ENVOVR[k] if v ~= nil then return v end return og(k) end
end
SID = "76561198015642335"
NEXT_ENT = 1000
function COPY(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = COPY(v) end
  return o
end
-- what the simulation does with an announcement (the bridge's coApply): note it, then place the player; a new company gets
-- its player entity (the interface's part)
function ANN(reg, key, isHost, at, sid)
  CO.noteAnnounce(reg, key, sid or SID, at)
  local c, isNew = CO.join(reg, key, key, isHost, key .. " Co", sid or SID, nil)
  if isNew then NEXT_ENT = NEXT_ENT + 1; c.ent = NEXT_ENT; BAL[c.ent] = 2000000 end
  return c.id
end
-- a session's start on one PC: the host takes the savegame's company, the player gets company 2
function BASE()
  local s = { co = CO.new("separate", 100, 2000000) }
  OWN[7001] = 100
  ANN(s.co, "knight-hd", true, 1000)
  ANN(s.co, "knight-hd2", false, 1000)
  return s
end
function MEMBERS(reg, id)
  local c = CO.find(reg, id)
  local t = {}
  for _, m in ipairs(CO.members(c)) do t[#t + 1] = tostring(m.key) end
  return table.concat(t, ",") .. " chief " .. tostring(CO.chief(c))
end
function PLAYS(reg, key, isHost)
  local c = CO.match(reg, key, SID, isHost)
  return c and c.id or 0
end
''')

H, P = "knight-hd", "knight-hd2"


def reload_both(chk, block, var, at, expect):
    """Both games announce themselves again at `at` (a resynchronisation), in both orders, on a copy of the registry `var`.
    expect = (host's company, player's company, {company: 'members chief x'}, number of companies)."""
    sigs = []
    for order in ((H, P), (P, H)):
        run('r = COPY(%s)' % var)
        for k in order:
            run('ANN(r.co, "%s", %s, %d)' % (k, "true" if k == H else "false", at))
        o = "%s first" % ("the host" if order[0] == H else "the player")
        chk(block, run('return PLAYS(r.co, "%s", true)' % H) == expect[0], "%s, reload (%s): the host plays company %d" % (block, o, expect[0]))
        chk(block, run('return PLAYS(r.co, "%s", false)' % P) == expect[1], "%s, reload (%s): the player plays company %d" % (block, o, expect[1]))
        for cid, want in expect[2].items():
            got = run('return MEMBERS(r.co, %d)' % cid)
            chk(block, got == want, "%s, reload (%s): company %d is '%s' (%s)" % (block, o, cid, want, got))
        chk(block, run('return #r.co.list') == expect[3], "%s, reload (%s): no new company (%d)" % (block, o, expect[3]))
        sigs.append(run('return CO.signature(r.co)'))
    chk(block, sigs[0] == sigs[1], "%s: the same registry whichever announcement comes first" % block)


def shared_blocks(chk):
    # the mark: two names, one account, one time
    run('s = BASE()')
    chk("mark", run('return CO.sharedSid(s.co, SID)') is True, "one PC: the Steam account is marked shared at the session's start")
    chk("mark", run('return PLAYS(s.co, "%s", false)' % P) == 2, "one PC: the player plays company 2")
    chk("mark", run('local s2 = { co = CO.new("separate", 100, 2000000) }; ANN(s2.co, "a", true, 1000); ANN(s2.co, "b", false, 1200); '
                    'return CO.sharedSid(s2.co, SID)') is False, "one PC: two names at two different times mark nothing (a new name)")

    # the player joins the host's company (its own company keeps a line: it stays, with nobody in it), then a reload
    run('s = BASE(); OWN[7002] = CO.find(s.co, 2).ent')
    run('E.event(s, "co_join_ask", { to = 1, mpfCo = 2, mpfFrom = "Knight-HD2#1" }, ENV)')
    run('E.event(s, "co_join_answer", { key = "knight-hd2", accept = true, mpfCo = 1, mpfFrom = "Knight-HD" }, ENV)')
    chk("join", run('return PLAYS(s.co, "%s", false)' % P) == 1, "join: the player plays company 1")
    reload_both(chk, "join", "s", 5000, (1, 1, {1: "knight-hd,knight-hd2 chief knight-hd"}, 2))

    # the session of 2026-10-25: join, leave (a new company), merge it into company 1, then a reload
    run('s = BASE(); OWN[7003] = CO.find(s.co, 2).ent')
    run('E.event(s, "co_join_ask", { to = 1, mpfCo = 2, mpfFrom = "Knight-HD2#1" }, ENV)')
    run('E.event(s, "co_join_answer", { key = "knight-hd2", accept = true, mpfCo = 1, mpfFrom = "Knight-HD" }, ENV)')
    run('E.event(s, "co_leave", { mpfCo = 1, mpfFrom = "Knight-HD2#1" }, ENV)')
    chk("merge", run('return PLAYS(s.co, "%s", false)' % P) == 0, "merge: the player left company 1 (no company: it announces itself again)")
    chk("merge", run('return ANN(s.co, "%s", false, 3000)' % P) == 3, "merge: the player gets company 3")
    run('E.event(s, "co_merge_ask", { to = 1, mpfCo = 3, mpfFrom = "Knight-HD2#1" }, ENV)')
    run('E.event(s, "co_merge_answer", { from = 3, accept = true, mpfCo = 1, mpfFrom = "Knight-HD" }, ENV)')
    chk("merge", run('return CO.find(s.co, 3).gone') == "merged", "merge: company 3 is merged into company 1")
    chk("merge", run('return PLAYS(s.co, "%s", false)' % P) == 1, "merge: the player plays company 1")
    reload_both(chk, "merge", "s", 5000, (1, 1, {1: "knight-hd,knight-hd2 chief knight-hd"}, 3))

    # the host joins the player's company (the savegame's company keeps its assets: it stays, with nobody in it), then a reload
    run('s = BASE(); OWN[7004] = 100')
    run('E.event(s, "co_join_ask", { to = 2, mpfCo = 1, mpfFrom = "Knight-HD" }, ENV)')
    run('E.event(s, "co_join_answer", { key = "knight-hd", accept = true, mpfCo = 2, mpfFrom = "Knight-HD2#1" }, ENV)')
    chk("host joins", run('return PLAYS(s.co, "%s", true)' % H) == 2, "host joins: the host plays company 2")
    reload_both(chk, "host joins", "s", 5000, (2, 2, {2: "knight-hd2,knight-hd chief knight-hd2"}, 2))

    # then the player leaves company 2, where the host still is: it plays no company (it must not take the host's), gets a new
    # one when it announces itself again, and both stay where they are at the next reload
    run('E.event(s, "co_leave", { mpfCo = 2, mpfFrom = "Knight-HD2#1" }, ENV)')
    chk("leave", run('return PLAYS(s.co, "%s", false)' % P) == 0, "leave: the player plays no company (it asks for a new one)")
    chk("leave", run('return ANN(s.co, "%s", false, 6000)' % P) == 3, "leave: the player gets company 3")
    chk("leave", run('return MEMBERS(s.co, 2)') == "knight-hd chief knight-hd", "leave: the host stays in company 2, its chief")
    reload_both(chk, "leave", "s", 7000, (2, 3, {2: "knight-hd chief knight-hd", 3: "knight-hd2 chief knight-hd2"}, 3))

    # a registry saved by 0.5.1 after the bug (the player's member renamed to the host's name): the duplicate goes at the next join
    run('''s = BASE()
CO.find(s.co, 1).members = { { key = "knight-hd", sid = SID }, { key = "knight-hd", sid = SID } }
CO.find(s.co, 2).members = {}''')
    run('ANN(s.co, "%s", true, 5000)' % H)
    chk("repair", run('return MEMBERS(s.co, 1)') == "knight-hd chief knight-hd", "repair: a member written twice is dropped")


# two PCs (two Steam accounts): a player who changed its name still finds its company (the rule kept from before)
def two_pc_blocks(chk):
    run('s = { co = CO.new("separate", 100, 2000000) }; ANN(s.co, "host", true, 1000, "s1"); ANN(s.co, "bob", false, 1000, "s2")')
    run('ANN(s.co, "host", true, 5000, "s1"); r2 = ANN(s.co, "robert", false, 5000, "s2")')
    chk("rename", run('return r2') == 2, "two PCs: 'bob' renamed 'robert' (same account) still plays company 2")
    chk("rename", run('return MEMBERS(s.co, 2)') == "robert chief robert", "two PCs: company 2's member and chief take the new name")
    chk("rename", run('return #s.co.list') == 2, "two PCs: no new company")
    chk("rename", run('return CO.sharedSid(s.co, "s2")') is False, "two PCs: no account is marked shared")


print("one PC, one Steam account (current rules)")
run('ENVOVR = {}')
shared_blocks(lambda block, cond, what: check(cond, what))
two_pc_blocks(lambda block, cond, what: check(cond, what))

print("one PC, one Steam account (old rules: these checks must fail)")
old_fail = {}


def old_chk(block, cond, what):
    old_fail.setdefault(block, 0)
    if not cond:
        old_fail[block] += 1


run('ENVOVR = { MPFEVER_COSIDRENAME = "1", MPFEVER_COSHAREDSID = "0" }')
try:
    shared_blocks(old_chk)
except Exception as e:      # (a Lua error under the old rules counts as caught)
    print("  (old rules: %s)" % str(e).splitlines()[0])
    old_fail["error"] = 1
for block in ("join", "merge", "host joins", "leave", "repair"):
    check(old_fail.get(block, 0) > 0, "the old rules fail the '%s' block (%d check(s))" % (block, old_fail.get(block, 0)))
old_fail.clear()
try:
    two_pc_blocks(old_chk)
except Exception as e:
    old_fail["error"] = 1
check(old_fail.get("rename", 0) == 0 and "error" not in old_fail, "the old rules pass the two-PC rename too (unchanged rule)")
run('ENVOVR = {}')

print()
print("FAILED: %d" % len(failures) if failures else "all passed")
sys.exit(1 if failures else 0)
