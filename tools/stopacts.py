"""Stop and signal builds of a session: how far the ends of each replaced segment lie off its nodes, and what the replay did.

    python -I tools/stopacts.py <folder> [<folder> ...]

A folder is a game's session folder (in.log and mod.log, as in a problem report: <report>/session/<name>-<time>-<id>) or any
folder above such folders: every game folder found below it is read. Give the folders of all the games of the session when
you have them: the builder's own build stats are then shown next to the replay's.

For every act a game received (its in.log) that adds or removes edge objects (stops, signals), it prints:
  - the act: its uid, natId, step, the tool's flags, its cost and its objects;
  - for each segment the builder added: how far its ends (position0/1) lie off its nodes, per axis in float32 steps and in
    metres. Up to 0.5.1 the stop replay put the ends on the nodes: when they were off at all (even one float step), the
    engine laid the segment on the ground again on the replaying game only (terrain aligned, town buildings taken away and
    put back), and the towns drifted apart (resyncs of 2026-10-24 23:35 and 23:38);
  - the fields in which the builder's segment differs from the one it replaced (the stop tool copies it exactly);
  - the replaying game's lines for it in mod.log (build stats, dust, the stop replay's own lines, among them "ends off its
    nodes here by ..." from 0.5.2 on), and the builder's build stats at the same step when its folder was read.
"LAID AGAIN" marks a replay that aligned terrain or took town buildings away while its builder did not, "DIFFERS" one whose
build stats differ from its builder's otherwise; without the builder's folder, "ALIGNED HERE" only says that the replay did
(a bulldozed street aligns the ground on every game). The build stats are the proof: a missing dust line proves little (the
game shows dust for its first builds only).
"""
import os
import re
import struct
import sys

# ---- the Lua tables of in.log (C.ser: %.17g numbers, ["key"]=value, nested tables) ----
NUM = re.compile(r'-?nan\(ind\)|-?1\.#INF|-?1\.#IND|-?inf|-?nan|-?[0-9][0-9.eE+-]*')
KEY = re.compile(r'[A-Za-z_]\w*\s*=')
DIG = re.compile(r'\d{1,3}')
BS = chr(92)


class Parser:
    def __init__(self, t):
        self.t = t
        self.i = 0

    def ws(self):
        while self.i < len(self.t) and self.t[self.i] in ' \t\r\n':
            self.i += 1

    def val(self):
        self.ws()
        c = self.t[self.i]
        if c == '{':
            return self.table()
        if c == '"':
            return self.string()
        for word, v in (('true', True), ('false', False), ('nil', None)):
            if self.t.startswith(word, self.i):
                self.i += len(word)
                return v
        m = NUM.match(self.t, self.i)
        if m:
            self.i = m.end()
            x = m.group(0)
            try:
                return int(x) if re.fullmatch(r'-?\d+', x) else float(x)
            except ValueError:
                return x
        raise ValueError('bad value at %d: %r' % (self.i, self.t[self.i:self.i + 40]))

    def string(self):
        self.i += 1
        out = []
        while True:
            c = self.t[self.i]
            if c == BS:
                n = self.t[self.i + 1]
                if n.isdigit():
                    m = DIG.match(self.t, self.i + 1)
                    out.append(chr(int(m.group(0))))
                    self.i = m.end()
                    continue
                out.append({'n': '\n', 't': '\t', 'r': '\r'}.get(n, n))
                self.i += 2
                continue
            if c == '"':
                self.i += 1
                return ''.join(out)
            out.append(c)
            self.i += 1

    def table(self):
        self.i += 1
        d = {}
        n = 1
        while True:
            self.ws()
            if self.t[self.i] == '}':
                self.i += 1
                return d
            if self.t[self.i] == '[':
                self.i += 1
                k = self.val()
                self.ws()
                assert self.t[self.i] == ']'
                self.i += 1
                self.ws()
                assert self.t[self.i] == '='
                self.i += 1
                d[k] = self.val()
            else:
                m = KEY.match(self.t, self.i)
                if m:
                    self.i = m.end()
                    d[m.group(0)[:-1].strip()] = self.val()
                else:
                    d[n] = self.val()
                    n += 1
            self.ws()
            if self.t[self.i] in ',;':
                self.i += 1


def parse(t):
    return Parser(t).val()


def arr(d):
    if not isinstance(d, dict):
        return []
    return [d[k] for k in sorted(k for k in d if isinstance(k, int) and k >= 1)]


# ---- float32 steps ----
def ordered(f):
    """The float32 value as an integer that counts float steps (negative values mirrored), for differences in steps."""
    i = struct.unpack('<i', struct.pack('<f', f))[0]
    return i if i >= 0 else -(i & 0x7fffffff)


def steps(a, b):
    try:
        return ordered(b) - ordered(a)
    except (OverflowError, struct.error):
        return None


def dist(p, q):
    return sum((p[k] - q[k]) ** 2 for k in 'xyz') ** 0.5


# ---- games ----
class Game:
    def __init__(self, folder):
        self.folder = folder
        self.name, self.role = os.path.basename(folder), '?'
        try:
            for line in open(os.path.join(folder, 'identity.txt'), encoding='utf-8', errors='replace'):
                k, _, v = line.strip().partition('=')
                if k == 'name':
                    self.name = v
                elif k == 'role':
                    self.role = v
        except OSError:
            pass
        self.mod = open(os.path.join(folder, 'mod.log'), encoding='utf-8', errors='replace').read().splitlines()
        # the builds this game shipped: (uid, step) -> line index of "native build shipped"
        self.shipped = {}
        # "build stats t=" lines by step
        self.stats = {}
        for i, line in enumerate(self.mod):
            m = re.search(r'native build shipped (\S+) \(built here at t=(\d+)', line)
            if m:
                self.shipped[(m.group(1), int(m.group(2)))] = i
            m = re.search(r'build stats t=(\d+): ', line)
            if m:
                self.stats.setdefault(int(m.group(1)), []).append(i)

    def label(self):
        return '%s (%s)' % (self.name, self.role)

    def acts(self):
        """The acts this game received that add or remove edge objects, in order: (line number, act)."""
        path = os.path.join(self.folder, 'in.log')
        for ln, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
            if not line.startswith('act\t') or 'edgeObjectsTo' not in line:
                continue
            parts = line.rstrip('\r\n').split('\t', 2)
            if len(parts) < 3:
                continue
            try:
                a = parse(parts[2])
            except (ValueError, IndexError, AssertionError) as e:
                print('%s in.log:%d: not read (%s)' % (self.name, ln, e))
                continue
            m = (a.get('args') or {}).get(1)
            sp = m.get('proposal') if isinstance(m, dict) else None
            if not isinstance(sp, dict):
                continue
            if not arr(sp.get('edgeObjectsToAdd')) and not arr(sp.get('edgeObjectsToRemove')):
                continue
            yield ln, a

    def replay_lines(self, uid, at):
        """This game's mod.log lines of the replay of act uid applied at step at (the uid alone repeats after a resync)."""
        tag = 'NATIVE REPLAY %s ' % uid
        for i in self.stats.get(at, []):
            first = None
            for j in range(i - 1, max(-1, i - 15), -1):
                if tag in self.mod[j]:
                    first = j
                elif first is not None and 'NATIVE REPLAY ' in self.mod[j]:
                    break
            if first is None:
                continue
            out, last = [self.mod[first]], first
            for j in range(first + 1, min(len(self.mod), i + 80)):
                line = self.mod[j]
                if j > i and 'NATIVE REPLAY ' in line and tag not in line:
                    break
                if j > i and 'build stats t=' in line:
                    # (the stops a street build places again are builds of their own at the same step, each just after
                    # its "stop context" line: kept; any other build ends the block)
                    if 'build stats t=%d:' % at in line and j - last <= 3 and 'stop context' in self.mod[last]:
                        out.append(line)
                        continue
                    break
                if tag in line:
                    last = j
                    out.append(line)
                elif j == i or 'build effects: dust' in line or ('refund: build %s ' % uid) in line:
                    out.append(line)
            return i, out
        return None, []

    def builder_stats(self, uid, at):
        """The build stats of this game's own build uid at step at, if it built it."""
        k = self.shipped.get((uid, at))
        if k is None:
            return None
        for j in range(k - 1, max(-1, k - 80), -1):
            if 'build stats t=%d:' % at in self.mod[j]:
                return self.mod[j]
        return None


def stats_of(line):
    """(terrain alignment a, b, town buildings removed) of a build stats line, or None."""
    if not line:
        return None
    m = re.search(r'terrain alignment ([\d.]+)/([\d.]+)', line)
    r = re.search(r'removed (\d+)', line)
    if not m:
        return None
    return float(m.group(1)), float(m.group(2)), int(r.group(1)) if r else 0


def laid(st):
    return st is not None and (st[0] > 0 or st[1] > 0 or st[2] > 0)


def short(line):
    # the time of day stays (it ties the line to the others of the logs)
    return line.strip()


def describe_ends(comp):
    """How far each end of a segment's comp lies off its node: text, and the largest distance (None if not known)."""
    parts, worst = [], None
    for k in (0, 1):
        n, p = comp.get('node%d' % k), comp.get('position%d' % k)
        if not (isinstance(n, dict) and isinstance(n.get('p'), dict) and isinstance(p, dict)):
            parts.append('end%d: node %r (new or unresolved)' % (k, n))
            continue
        q = n['p']
        try:
            d = dist(p, q)
        except (KeyError, TypeError):
            parts.append('end%d: not read' % k)
            continue
        worst = d if worst is None else max(worst, d)
        if d == 0:
            parts.append('end%d node %s: on its node' % (k, n.get('id')))
        else:
            st = [steps(q[a], p[a]) for a in 'xyz']
            parts.append('end%d node %s: OFF by %.5f m, float32 steps x/y/z %s (the end minus the node)' % (k, n.get('id'), d, '/'.join(str(s) for s in st)))
    return '; '.join(parts), worst


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    folders = []
    for root in argv:
        for d, _, files in os.walk(root):
            if 'in.log' in files and 'mod.log' in files:
                folders.append(os.path.abspath(d))
    folders = sorted(set(folders))
    if not folders:
        print('no game folder (in.log and mod.log) below ' + ', '.join(argv))
        return 1
    games = [Game(f) for f in folders]
    print('games: ' + ', '.join(g.label() + ' ' + g.folder for g in games))
    total = {'acts': 0, 'off': 0, 'off_laid': 0, 'off_unknown': 0, 'on': 0, 'on_laid': 0, 'on_unknown': 0, 'no_replay': 0}
    for g in games:
        print()
        print('==== acts received by %s' % g.label())
        for ln, a in g.acts():
            uid, at = a.get('uid'), a.get('at')
            m = a['args'][1]
            sp = m['proposal']
            added, removed = arr(sp.get('addedSegments')), arr(sp.get('removedSegments'))
            eoa, eor = arr(sp.get('edgeObjectsToAdd')), arr(sp.get('edgeObjectsToRemove'))
            objs = ', '.join('%s %s %.4f' % (str(o.get('model', '?')).split('/')[-1].replace('.con', ''),
                                             'left' if o.get('left') else 'right', float(o.get('param') or 0)) for o in eoa)
            total['acts'] += 1
            print()
            print('%s natId %s t=%s flags %s cost %s (in.log:%d): +segments %d -segments %d, +%d object(s)%s, -%d'
                  % (uid, a.get('natId'), at, a.get('ctx'), a.get('cost'), ln, len(added), len(removed), len(eoa),
                     (' (' + objs + ')') if objs else '', len(eor)))
            worst = None
            for k, s in enumerate(added, 1):
                comp = s.get('comp') or {}
                text, w = describe_ends(comp)
                if w is not None:
                    worst = w if worst is None else max(worst, w)
                print('  segment +%d %s %s: %s' % (k, str(comp.get('roadTemplate', '')).split('/')[-1], 'type %s/%s'
                                                    % (comp.get('type'), comp.get('typeIndex')), text))
            if len(added) == 1 and len(removed) == 1:
                ca, cr = added[0].get('comp') or {}, removed[0].get('comp') or {}
                diff = [f for f in ('position0', 'position1', 'tangent0', 'tangent1', 'roadTemplate', 'roadStyle',
                                    'roadDevelopmentLocked', 'type', 'typeIndex', 'distance')
                        if ca.get(f) != cr.get(f)]
                print('  the builder\'s segment against the one it replaced: ' + (('differs in ' + ', '.join(diff)) if diff else 'the same (objects aside)'))
            # the replaying game: this one
            i, lines = g.replay_lines(uid, at) if isinstance(at, int) else (None, [])
            # (the largest of the block's builds: the replay itself and the stops placed again after it)
            rst = None
            for line in lines:
                st = stats_of(line) if 'build stats t=' in line else None
                if st is not None:
                    rst = st if rst is None else (max(rst[0], st[0]), max(rst[1], st[1]), max(rst[2], st[2]))
            if not lines:
                total['no_replay'] += 1
                print('  replay on %s: no replay lines at t=%s' % (g.label(), at))
            else:
                print('  replay on %s:' % g.label())
                for line in lines:
                    print('    ' + short(line))
            # the builder, if read
            bst = None
            for b in games:
                if b is g:
                    continue
                line = b.builder_stats(uid, at)
                if line:
                    bst = stats_of(line)
                    print('  builder %s: %s' % (b.label(), short(line)))
            if rst is not None:
                key = 'off' if worst else 'on'
                total[key] += 1
                if bst is None:
                    if laid(rst):
                        total[key + '_unknown'] += 1
                        print("  ALIGNED HERE (the builder's folder not read: did its build align too?): terrain alignment %.3f/%.3f, "
                              "%d town building(s) taken away" % (rst[0], rst[1], rst[2]))
                elif laid(rst) and not laid(bst):
                    total[key + '_laid'] += 1
                    print('  LAID AGAIN on %s: terrain alignment %.3f/%.3f, %d town building(s) taken away, its builder none'
                          % (g.name, rst[0], rst[1], rst[2]))
                elif rst != bst:
                    total[key + '_laid'] += 1
                    print('  DIFFERS on %s: terrain alignment %.3f/%.3f, %d town building(s) taken away; its builder %.3f/%.3f, %d'
                          % (g.name, rst[0], rst[1], rst[2], bst[0], bst[1], bst[2]))
    print()
    print("%(acts)d act(s) with edge objects. Replays found: %(off)d with an end off its node (%(off_laid)d laid again or "
          "different, %(off_unknown)d aligned without the builder's stats), %(on)d with every end on its node (%(on_laid)d laid "
          "again or different, %(on_unknown)d aligned without the builder's stats); %(no_replay)d without replay lines" % total)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
