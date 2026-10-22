using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The mods of a session's savegame: where each one is installed on this PC, which version (a fingerprint of
    /// its files), what it does (models only, game data changed at load, interface, or a script acting in the game) and
    /// how it goes with MPFever. The host sends its list to the players, whose launcher compares it with their own mods:
    /// a player with another version of a mod cannot load the host's game (it would never match it).
    ///
    /// Lists travel as "id|name|source|fingerprint|kind" entries joined by ";;" (the menu's own list is "id|name|source").</summary>
    static class Mods
    {
        public const string Assets = "assets", Load = "load", Ui = "ui", Sim = "sim";

        /// <summary>What MPFever knows of a mod: "ok", "fixed" (made to work by MPFever), "caution" (untested script acting in the
        /// game), "bad" (known to break a session), with a short note.</summary>
        public sealed class Verdict { public string Level, Note; }

        // the mods seen in issue reports (see docs/MODS.md); the others are judged by what their files do
        static readonly Dictionary<string, Func<Verdict>> Known = new Dictionary<string, Func<Verdict>>
        {
            ["tpf3mp_1"] = () => new Verdict { Level = "bad", Note = T("Autre mod multijoueur : il modifie les mêmes choses que MPFever. Désactivez-le.", "Another multiplayer mod: it changes the same things as MPFever. Turn it off.") },
            ["auto_line_namer_1"] = () => new Verdict { Level = "fixed", Note = T("Les noms donnés par le jeu de l'hôte s'appliquent partout (0.4.0).", "The names given by the host's game apply everywhere (0.4.0).") },
            ["zhenya_auto_color_lines"] = () => new Verdict { Level = "fixed", Note = T("Les couleurs données par le jeu de l'hôte s'appliquent partout (0.4.0).", "The colours given by the host's game apply everywhere (0.4.0).") },
            ["zhenya_auto_assign_terminals"] = () => new Verdict { Level = "fixed", Note = T("Les quais choisis par le jeu de l'hôte s'appliquent partout (0.4.0).", "The platforms chosen by the host's game apply everywhere (0.4.0).") },
            ["auto_signals_1"] = () => new Verdict { Level = "fixed", Note = T("Les signaux ajoutés ne sont construits qu'une fois, par le jeu qui a posé le signal (0.4.0).", "Added signals are built once, by the game where the signal was placed (0.4.0).") },
        };

        public static Verdict Judge(string id, string kind)
        {
            if (id != null && Known.TryGetValue(id, out var k)) return k();
            if (kind == Sim) return new Verdict { Level = "caution", Note = T("Script qui agit sur la partie : pas encore testé avec MPFever.", "Script acting on the game: not tested with MPFever yet.") };
            return new Verdict { Level = "ok", Note = "" };
        }

        // ---- where the mods are installed

        static Dictionary<string, string> dirs;
        static DateTime dirsAt;
        static readonly Regex ModIdRx = new Regex("\"modId\"\\s*:\\s*\"([^\"]+)\"");

        /// <summary>The folder of an installed mod (mod.io, Steam Workshop, this player's own mods, the game's), or null.</summary>
        public static string Dir(string id)
        {
            lock (Known)
            {
                if (dirs == null || (DateTime.UtcNow - dirsAt).TotalSeconds > 30) { dirs = Scan(); dirsAt = DateTime.UtcNow; }
                return id != null && dirs.TryGetValue(id, out var d) ? d : null;
            }
        }

        static Dictionary<string, string> Scan()
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var roots = new List<string>();
            try
            {
                var pub = Environment.GetEnvironmentVariable("PUBLIC") ?? @"C:\Users\Public";
                var modio = Path.Combine(pub, "mod.io");
                if (Directory.Exists(modio)) foreach (var g in Directory.GetDirectories(modio)) roots.Add(Path.Combine(g, "mods"));
            }
            catch { }
            try { foreach (var s in GameInstall.SaveDirs()) roots.Add(Path.Combine(Path.GetDirectoryName(s), "mods")); } catch { }
            try { foreach (var lib in GameInstall.SteamLibraries()) roots.Add(Path.Combine(lib, "steamapps", "workshop", "content", GameInstall.AppId)); } catch { }
            try { var g = GameInstall.FindGameDir(); if (g != null) { roots.Add(Path.Combine(g, "mods")); roots.Add(Path.Combine(g, "mods", "release")); } } catch { }
            foreach (var root in roots)
            {
                try
                {
                    if (!Directory.Exists(root)) continue;
                    foreach (var d in Directory.GetDirectories(root))
                    {
                        string id = null;
                        try
                        {
                            var mj = Path.Combine(d, "mod.json");
                            if (File.Exists(mj)) { var m = ModIdRx.Match(File.ReadAllText(mj)); if (m.Success) id = m.Groups[1].Value; }
                        }
                        catch { }
                        id = id ?? Path.GetFileName(d);
                        if (!map.ContainsKey(id)) map[id] = d;
                    }
                }
                catch { }
            }
            return map;
        }

        // ---- what a mod is

        static readonly Regex Skip = new Regex(@"(^|[\\/])(texture_metadata_cache\.lua|_metadata|texture_cache)([\\/]|$)|\.cache$", RegexOptions.IgnoreCase);

        /// <summary>The version of an installed mod: its files' paths and sizes, and the contents of its scripts and data.</summary>
        public static string Fingerprint(string dir)
        {
            try
            {
                var files = Directory.GetFiles(dir, "*", SearchOption.AllDirectories)
                    .Select(f => f.Substring(dir.Length).TrimStart('\\', '/').Replace('\\', '/'))
                    .Where(r => !Skip.IsMatch(r)).OrderBy(r => r, StringComparer.Ordinal).ToList();
                using (var sha = SHA1.Create())
                using (var md5 = MD5.Create())
                {
                    var sb = new StringBuilder();
                    foreach (var r in files)
                    {
                        var fi = new FileInfo(Path.Combine(dir, r));
                        sb.Append(r.ToLowerInvariant()).Append(':').Append(fi.Length);
                        var ext = Path.GetExtension(r).ToLowerInvariant();
                        if ((ext == ".lua" || ext == ".json" || ext == ".tl") && fi.Length < 4000000)
                            sb.Append(':').Append(BitConverter.ToString(md5.ComputeHash(File.ReadAllBytes(fi.FullName))).Replace("-", ""));
                        sb.Append('\n');
                    }
                    return BitConverter.ToString(sha.ComputeHash(Encoding.UTF8.GetBytes(sb.ToString()))).Replace("-", "").Substring(0, 12).ToLowerInvariant();
                }
            }
            catch { return ""; }
        }

        static readonly Regex RunScript = new Regex("\"(pre|post)?[Rr]unScript\"\\s*:\\s*\\{\\s*\"fileName\"\\s*:\\s*\"[^\"]+\"");

        /// <summary>sim: a game script that runs in the simulation (it can change the game by itself); ui: interface only;
        /// load: the game's data changed when it loads (the same on every PC with the same version); assets: models only.</summary>
        public static string Kind(string dir)
        {
            try
            {
                bool ui = false, load = false;
                foreach (var f in Directory.GetFiles(dir, "*.lua", SearchOption.AllDirectories))
                {
                    var name = Path.GetFileName(f).ToLowerInvariant();
                    var rel = f.Replace('\\', '/').ToLowerInvariant();
                    if (name.EndsWith(".gs.lua") || rel.Contains("/game_script/"))
                    {
                        var s = File.ReadAllText(f);
                        if (s.Contains("updateScript") || s.Contains("handleEventScript") || (rel.Contains("/game_script/") && Regex.IsMatch(s, @"\b(update|handleEvent)\s*=")))
                            return Sim;
                        ui = true;
                    }
                    else if (name.EndsWith(".res.lua") && new FileInfo(f).Length < 200000)
                    {
                        var s = File.ReadAllText(f);
                        if (s.Contains("react-")) ui = true;
                    }
                    else if (name == "mod.lua" && Regex.IsMatch(File.ReadAllText(f), @"\b(runFn|postRunFn|preRunFn)\b")) load = true;
                }
                var mj = Path.Combine(dir, "mod.json");
                if (File.Exists(mj) && RunScript.IsMatch(File.ReadAllText(mj))) load = true;
                return ui ? Ui : load ? Load : Assets;
            }
            catch { return ""; }
        }

        static readonly Dictionary<string, Tuple<string, string>> infoCache = new Dictionary<string, Tuple<string, string>>();

        /// <summary>The fingerprint and kind of an installed mod ("" when not found here), computed once per folder and date.</summary>
        static Tuple<string, string> Info(string id)
        {
            var d = Dir(id);
            if (d == null) return Tuple.Create("", "");
            string key;
            try { key = d + "@" + Directory.GetLastWriteTimeUtc(d).Ticks; } catch { key = d; }
            lock (infoCache)
            {
                if (infoCache.TryGetValue(key, out var t)) return t;
                t = Tuple.Create(Fingerprint(d), Kind(d));
                infoCache[key] = t;
                return t;
            }
        }

        public sealed class Entry { public string Id, Name, Source, Fp, Kind; }

        public static List<Entry> Parse(string list)
        {
            var r = new List<Entry>();
            foreach (var e in (list ?? "").Split(new[] { ";;" }, StringSplitOptions.RemoveEmptyEntries))
            {
                var f = e.Split('|');
                if (f[0].Trim() == "") continue;
                r.Add(new Entry { Id = f[0].Trim(), Name = f.Length > 1 && f[1].Trim() != "" ? f[1].Trim() : f[0].Trim(), Source = f.Length > 2 ? f[2].Trim() : "",
                    Fp = f.Length > 3 ? f[3].Trim() : "", Kind = f.Length > 4 ? f[4].Trim() : "" });
            }
            return r;
        }

        static string Clean(string s) => Regex.Replace(s ?? "", "[|;\\p{Cc}]", " ");

        static bool BuiltIn(Entry e) => e.Source.IndexOf("BuiltIn", StringComparison.OrdinalIgnoreCase) >= 0 || e.Source.Equals("DLC", StringComparison.OrdinalIgnoreCase);

        /// <summary>The host: its savegame's mods ("id|name|source", from its menu) with the fingerprint and kind of each.</summary>
        public static string Describe(string list)
        {
            return string.Join(";;", Parse(list).Select(e =>
            {
                var i = BuiltIn(e) ? Tuple.Create("", Assets) : Info(e.Id);
                return string.Join("|", Clean(e.Id), Clean(e.Name), Clean(e.Source), i.Item1, i.Item2);
            }));
        }

        /// <summary>A player: the host's mods compared with this PC's. View: "id|name|source|kind|level|here|note" for the
        /// menu, here = "ok", "differs" (another version), "notfound" (no folder found here: the menu asks the game whether it
        /// is installed), "" (not compared: the host's own list, a mod of the game itself, or a folder the host could not find).</summary>
        public sealed class Check { public string View = ""; public List<string> Differs = new List<string>(), Missing = new List<string>(), Bad = new List<string>(); }

        public static Check Compare(string hostList, bool isHost)
        {
            var c = new Check();
            var rows = new List<string>();
            foreach (var e in Parse(hostList))
            {
                string here = "";
                string kind = e.Kind;
                if (!isHost && !BuiltIn(e))
                {
                    var mine = Info(e.Id);
                    if (Dir(e.Id) == null) { here = "notfound"; c.Missing.Add(e.Name); }
                    else if (e.Fp != "" && mine.Item1 != "") { here = mine.Item1 == e.Fp ? "ok" : "differs"; if (here == "differs") c.Differs.Add(e.Name); }
                    if (kind == "") kind = mine.Item2;
                }
                var v = Judge(e.Id, kind);
                if (v.Level == "bad") c.Bad.Add(e.Name);
                rows.Add(string.Join("|", Clean(e.Id), Clean(e.Name), Clean(e.Source), kind, v.Level, here, Clean(v.Note)));
            }
            c.View = string.Join(";;", rows);
            return c;
        }

    }
}
