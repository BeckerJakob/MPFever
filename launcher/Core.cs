using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Microsoft.Win32;

namespace MPFever
{
    /// <summary>Launcher language. The French and English texts are written in the code as T("français", "English");
    /// the other languages come from lang.json (embedded in MPFever.exe), keyed by the English text.
    /// The language is the one chosen in the launcher, else the game's language, else Windows', else English.</summary>
    static class L
    {
        public sealed class Language
        {
            public readonly string Code, Name;
            public Language(string code, string name) { Code = code; Name = name; }
        }

        /// <summary>The languages of Transport Fever 3, each named in its own language.</summary>
        public static readonly Language[] All =
        {
            new Language("de", "Deutsch"), new Language("en", "English"), new Language("es", "Español"),
            new Language("fr", "Français"), new Language("it", "Italiano"), new Language("nl", "Nederlands"),
            new Language("pl", "Polski"), new Language("pt-BR", "Português (Brasil)"), new Language("ru", "Русский"),
            new Language("ja", "日本語"), new Language("ko", "한국어"), new Language("zh-CN", "简体中文"),
            new Language("zh-TW", "繁體中文"),
        };

        public static string Code { get; private set; } = "en";
        public static bool Fr => Code == "fr";
        public static string Name => All.First(l => l.Code == Code).Name;
        public static string NameOf(string code) => All.FirstOrDefault(l => l.Code == code)?.Name ?? code;
        static volatile Dictionary<string, string> table = new Dictionary<string, string>();

        /// <summary>Raised after the language changed (on the thread that changed it).</summary>
        public static event Action Changed;

        public static string T(string fr, string en)
        {
            var c = Code;
            if (c == "fr") return fr;
            if (c == "en") return en;
            return table.TryGetValue(en, out var v) ? v : en;
        }

        /// <summary>T with {0} {1}... placeholders.</summary>
        public static string F(string fr, string en, params object[] args)
        {
            try { return string.Format(T(fr, en), args); }
            catch (FormatException) { return string.Format(Fr ? fr : en, args); }   // a broken translation
        }

        public static void Set(string code)
        {
            if (!All.Any(l => l.Code == code)) code = "en";
            table = Load(code);
            Code = code;
            Changed?.Invoke();
        }

        static Dictionary<string, object> texts;

        /// <summary>The translations of one language from lang.json: { "texts": { "English": { "de": "...", ... } } }.</summary>
        static Dictionary<string, string> Load(string code)
        {
            var d = new Dictionary<string, string>();
            if (code == "en" || code == "fr") return d;
            try
            {
                if (texts == null)
                {
                    using (var st = typeof(L).Assembly.GetManifestResourceStream("lang.json"))
                    using (var r = new StreamReader(st, Encoding.UTF8))
                    {
                        var root = Json.Parse(r.ReadToEnd()) as Dictionary<string, object>;
                        texts = root != null && root.TryGetValue("texts", out var t) ? t as Dictionary<string, object> : null;
                    }
                }
                if (texts == null) return d;
                foreach (var kv in texts)
                    if (kv.Value is Dictionary<string, object> tr && tr.TryGetValue(code, out var v) && v is string s && s.Length > 0)
                        d[kv.Key] = s;
            }
            catch (Exception e) { Log.W("lang.json: " + e.Message); }
            return d;
        }

        /// <summary>The table for the mod (lang.txt in each game's session folder): "@lang TAB code", then
        /// "English TAB translation" lines (the mod's Lua code looks its texts up by their English version).</summary>
        public static string ModTable()
        {
            var sb = new StringBuilder("@lang\t" + Code + "\n");
            foreach (var kv in table)
                if (kv.Key.IndexOfAny(new[] { '\t', '\n', '\r' }) < 0 && kv.Value.IndexOfAny(new[] { '\t', '\n', '\r' }) < 0)
                    sb.Append(kv.Key).Append('\t').Append(kv.Value).Append('\n');
            return sb.ToString();
        }

        /// <summary>A language code from a Steam language name ("german"), a game setting ("de", "de_DE") or a Windows
        /// culture ("de-DE"); null when it is none of the game's languages.</summary>
        public static string Normalize(string s)
        {
            if (string.IsNullOrWhiteSpace(s)) return null;
            s = s.Trim().ToLowerInvariant().Replace('_', '-');
            switch (s)
            {
                case "german": case "deutsch": return "de";
                case "english": return "en";
                case "french": case "francais": case "français": return "fr";
                case "italian": return "it";
                case "spanish": case "latam": return "es";
                case "dutch": return "nl";
                case "polish": return "pl";
                case "russian": return "ru";
                case "japanese": case "jp": return "ja";
                case "korean": case "koreana": case "kr": return "ko";
                case "brazilian": case "portuguese": case "pt": return "pt-BR";
                case "schinese": case "chinese": case "cn": case "zh": return "zh-CN";
                case "tchinese": case "tw": return "zh-TW";
            }
            if (s.StartsWith("zh")) return s.Contains("tw") || s.Contains("hk") || s.Contains("mo") || s.Contains("hant") ? "zh-TW" : "zh-CN";
            if (s.StartsWith("pt")) return "pt-BR";
            var two = s.Length >= 2 ? s.Substring(0, 2) : s;
            return All.Any(l => l.Code == two) && (s.Length == 2 || s[2] == '-') ? two : null;
        }

        /// <summary>The language to use and where it comes from: the launcher's setting ("auto" or empty: none),
        /// else the game's, else Windows', else English.</summary>
        public static string Detect(string saved, out string source)
        {
            var c = Normalize(saved);
            if (c != null) { source = "setting"; return c; }
            try
            {
                c = Normalize(GameInstall.GameLanguage(out var where));
                if (c != null) { source = where; return c; }
            }
            catch { }
            c = Normalize(CultureInfo.CurrentUICulture.Name);
            if (c != null) { source = "windows"; return c; }
            source = "default";
            return "en";
        }
    }

    /// <summary>Minimal JSON reader (objects, arrays, strings, numbers, true/false/null) for lang.json: keys and values
    /// are kept exactly as written, spaces included.</summary>
    static class Json
    {
        public static object Parse(string s)
        {
            int i = 0;
            var v = Value(s, ref i);
            Skip(s, ref i);
            if (i < s.Length) throw new FormatException("JSON: unexpected text at " + i);
            return v;
        }

        static void Skip(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static object Value(string s, ref int i)
        {
            Skip(s, ref i);
            if (i >= s.Length) throw new FormatException("JSON: unexpected end");
            char c = s[i];
            if (c == '{')
            {
                var d = new Dictionary<string, object>();
                i++; Skip(s, ref i);
                if (s[i] == '}') { i++; return d; }
                while (true)
                {
                    Skip(s, ref i);
                    var k = Str(s, ref i);
                    Skip(s, ref i);
                    if (s[i++] != ':') throw new FormatException("JSON: ':' expected at " + (i - 1));
                    d[k] = Value(s, ref i);
                    Skip(s, ref i);
                    if (s[i] == ',') { i++; continue; }
                    if (s[i++] == '}') return d;
                    throw new FormatException("JSON: ',' or '}' expected at " + (i - 1));
                }
            }
            if (c == '[')
            {
                var l = new List<object>();
                i++; Skip(s, ref i);
                if (s[i] == ']') { i++; return l; }
                while (true)
                {
                    l.Add(Value(s, ref i));
                    Skip(s, ref i);
                    if (s[i] == ',') { i++; continue; }
                    if (s[i++] == ']') return l;
                    throw new FormatException("JSON: ',' or ']' expected at " + (i - 1));
                }
            }
            if (c == '"') return Str(s, ref i);
            if (string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(s, i, "null", 0, 4) == 0) { i += 4; return null; }
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (i == start) throw new FormatException("JSON: unexpected '" + c + "' at " + i);
            return double.Parse(s.Substring(start, i - start), CultureInfo.InvariantCulture);
        }

        static string Str(string s, ref int i)
        {
            if (s[i] != '"') throw new FormatException("JSON: string expected at " + i);
            var sb = new StringBuilder();
            for (i++; s[i] != '"'; i++)
            {
                if (s[i] != '\\') { sb.Append(s[i]); continue; }
                char e = s[++i];
                switch (e)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'u': sb.Append((char)Convert.ToInt32(s.Substring(i + 1, 4), 16)); i += 4; break;
                    default: sb.Append(e); break;   // \" \\ \/
                }
            }
            i++;
            return sb.ToString();
        }
    }

    enum LogLevel { Auto, Muted, Success, Warning, Error, Section }

    static class Log
    {
        static readonly object Gate = new object();
        static string file;
        public static event Action<string> Line;
        /// <summary>Each line with its kind (colours of the launcher's log).</summary>
        public static event Action<string, LogLevel> Entry;

        public static void Init(string dir)
        {
            Directory.CreateDirectory(dir);
            file = Path.Combine(dir, "launcher-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".log");
        }

        public static void W(string s) => Write(s, LogLevel.Auto);
        public static void Ok(string s) => Write(s, LogLevel.Success);
        public static void Warn(string s) => Write(s, LogLevel.Warning);
        public static void Err(string s) => Write(s, LogLevel.Error);
        public static void Dim(string s) => Write(s, LogLevel.Muted);

        public static void Write(string s, LogLevel level)
        {
            var l = DateTime.Now.ToString("HH:mm:ss.fff") + " " + s;
            lock (Gate) { try { if (file != null) File.AppendAllText(file, l + Environment.NewLine); } catch { } }
            Line?.Invoke(l);
            Entry?.Invoke(l, level);
        }
    }

    /// <summary>One protocol message: kind TAB from TAB payload (payload = single-line Lua table literal).</summary>
    sealed class Msg
    {
        public string Kind, From, Payload;

        public static Msg Parse(string line)
        {
            if (string.IsNullOrEmpty(line)) return null;
            var p = line.Split(new[] { '\t' }, 3);
            if (p.Length < 3) return null;
            return new Msg { Kind = p[0], From = p[1], Payload = p[2] };
        }

        public static Msg Make(string kind, string from, string payload = "{}") => new Msg { Kind = kind, From = from, Payload = payload };

        public override string ToString() => Kind + "\t" + From + "\t" + Payload;
    }

    /// <summary>Tiny parser for the Lua table literals produced by the mod serializer.</summary>
    static class LuaLit
    {
        public static object Parse(string s)
        {
            int i = 0;
            var v = Value(s, ref i);
            return v;
        }

        static void Ws(string s, ref int i) { while (i < s.Length && char.IsWhiteSpace(s[i])) i++; }

        static object Value(string s, ref int i)
        {
            Ws(s, ref i);
            if (i >= s.Length) return null;
            char c = s[i];
            if (c == '{') return Table(s, ref i);
            if (c == '"') return Str(s, ref i);
            // (compared in place: a copy of the rest of the text at every value made a station's 850 KB build take 30 s to read,
            // and the reader of that player's messages, their clock among them, stood still meanwhile: issue #54)
            if (string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (string.CompareOrdinal(s, i, "nil", 0, 3) == 0) { i += 3; return null; }
            int st = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            double.TryParse(s.Substring(st, i - st), NumberStyles.Float, CultureInfo.InvariantCulture, out var d);
            return d;
        }

        static Dictionary<object, object> Table(string s, ref int i)
        {
            var t = new Dictionary<object, object>();
            i++; // {
            while (true)
            {
                Ws(s, ref i);
                if (i >= s.Length) return t;
                if (s[i] == '}') { i++; return t; }
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '[')
                {
                    i++;
                    var k = Value(s, ref i);
                    Ws(s, ref i);
                    if (i < s.Length && s[i] == ']') i++;
                    Ws(s, ref i);
                    if (i < s.Length && s[i] == '=') i++;
                    var v = Value(s, ref i);
                    if (k != null) t[Norm(k)] = v;
                }
                else { Value(s, ref i); }
            }
        }

        static object Norm(object k) => k is double d && d == Math.Floor(d) ? (object)(long)d : k;

        static string Str(string s, ref int i)
        {
            var sb = new StringBuilder();
            i++; // opening quote
            while (i < s.Length && s[i] != '"')
            {
                if (s[i] == '\\' && i + 1 < s.Length)
                {
                    i++;
                    char e = s[i];
                    if (e == 'n') sb.Append('\n');
                    else if (e == 'r') sb.Append('\r');
                    else if (char.IsDigit(e))
                    {
                        int st = i;
                        while (i < s.Length && i - st < 3 && char.IsDigit(s[i])) i++;
                        sb.Append((char)int.Parse(s.Substring(st, i - st)));
                        continue;
                    }
                    else sb.Append(e);
                    i++;
                }
                else { sb.Append(s[i]); i++; }
            }
            i++; // closing quote
            return sb.ToString();
        }

        public static string Show(object v)
        {
            if (v == null) return "nil";
            if (v is double d) return d.ToString("R", CultureInfo.InvariantCulture);
            if (v is Dictionary<object, object> t)
                return "{" + string.Join(",", t.OrderBy(kv => kv.Key.ToString(), StringComparer.Ordinal).Select(kv => kv.Key + "=" + Show(kv.Value))) + "}";
            return v.ToString();
        }

        public static string Quote(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (var c in s)
            {
                if (c == '"' || c == '\\') sb.Append('\\').Append(c);
                else if (c == '\n') sb.Append("\\n");
                else if (c < 32) sb.Append('\\').Append(((int)c).ToString("000"));
                else sb.Append(c);
            }
            return sb.Append('"').ToString();
        }
    }

    /// <summary>File link with one game instance: in.log (launcher to game) and out.log (game to launcher).</summary>
    sealed class GameLink : IDisposable
    {
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);
        public readonly string Dir;
        public string Name { get; private set; }
        public string Role { get; private set; }
        /// <summary>The game has loaded a savegame and its bridge said hello (false while it shows the main menu).</summary>
        public volatile bool InGame;
        readonly string inPath, outPath;
        readonly object writeGate = new object();
        long outOff;
        volatile bool stop;
        Thread poll;
        Process proc;

        public event Action<GameLink, Msg> FromGame;

        public GameLink(string name, string role)
        {
            Name = name;
            Role = role;
            // (the folder's name in ASCII as well: the player's name goes to the game in identity.txt)
            var folder = new string((name ?? "").Select(c => c < 128 && (char.IsLetterOrDigit(c) || c == '-' || c == '_') ? c : '_').ToArray());
            Dir = Path.Combine(SessionRoot(), folder + "-" + DateTime.Now.ToString("HHmmss") + "-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(Dir);
            inPath = Path.Combine(Dir, "in.log");
            outPath = Path.Combine(Dir, "out.log");
            File.WriteAllText(inPath, "");
            File.WriteAllText(outPath, "");
            poll = new Thread(Poll) { IsBackground = true, Name = "GameLink " + name };
            poll.Start();
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        static extern int GetShortPathNameW(string longPath, StringBuilder shortPath, int size);

        static bool IsAscii(string s) => s.All(c => c < 128);

        /// <summary>Folder of the session folders. The game's Lua cannot open a path with letters outside ASCII: with a
        /// Windows account named "Thöny" (the temporary folder is in the account's folder) no file of the session could be
        /// read or written by the mod, and the game had no multiplayer page (issue #59). Such a temporary folder is used by
        /// its short name (C:\Users\MAXEMI~1\...), or else replaced by an ASCII folder shared by the PC's accounts.</summary>
        static string SessionRoot()
        {
            var temp = Path.Combine(Path.GetTempPath(), "mpfever");
            if (IsAscii(temp)) return temp;
            try
            {
                Directory.CreateDirectory(temp);
                var sb = new StringBuilder(1024);
                int n = GetShortPathNameW(temp, sb, sb.Capacity);
                if (n > 0 && n < sb.Capacity && IsAscii(sb.ToString())) return sb.ToString();
            }
            catch { }
            foreach (var root in new[] { Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), Environment.GetEnvironmentVariable("PUBLIC") })
            {
                if (string.IsNullOrEmpty(root) || !IsAscii(root)) continue;
                try
                {
                    var dir = Path.Combine(root, "MPFever", "sessions");
                    Directory.CreateDirectory(dir);
                    File.WriteAllText(Path.Combine(dir, "write_test.txt"), "");
                    File.Delete(Path.Combine(dir, "write_test.txt"));
                    return dir;
                }
                catch { }
            }
            Log.Warn(L.T("Le dossier temporaire contient des lettres que le jeu ne sait pas lire : le mod risque de ne pas fonctionner (", "The temporary folder has letters the game cannot read: the mod may not work (") + temp + ")");
            return temp;
        }

        public bool GameRunning => proc != null && !proc.HasExited;

        /// <summary>The game of a dedicated server (MPFever.exe --server): the mod knows it from MPFEVER_SERVER=1 and plays
        /// no company of its own there.</summary>
        public bool Server;

        /// <summary>Name and role chosen in the main menu, read by the mod when the game loads (identity.txt).</summary>
        public void SetIdentity(string name, string role)
        {
            Name = name;
            Role = role;
            File.WriteAllText(Path.Combine(Dir, "identity.txt"), "name=" + name + "\nrole=" + role + "\n", Utf8);
        }

        /// <summary>State shown by the MPFever window of the game's main menu (menu_state.txt, key=value lines).</summary>
        /// <summary>The settings of the settings window for the mod (settings.txt, read when a game loads): the session's
        /// (the host's once received) and this player's own. Not written for the autotests (their variables decide).</summary>
        public void WriteSettings()
        {
            if (Options.Disabled) return;
            try { lock (writeGate) File.WriteAllText(Path.Combine(Dir, "settings.txt"), Options.ModFile(), Utf8); }
            catch (Exception e) { Log.W("settings.txt: " + e.Message); }
        }

        /// <summary>The texts of the current language for the mod (lang.txt, read by its Lua code).</summary>
        public void WriteLang()
        {
            try { lock (writeGate) File.WriteAllText(Path.Combine(Dir, "lang.txt"), L.ModTable(), Utf8); }
            catch (Exception e) { Log.W("lang.txt: " + e.Message); }
        }

        /// <summary>The session as the in-game MPFever window shows it (mp_status.txt: key=value lines and one
        /// "p=id TAB name TAB state TAB lag TAB role" line per player), replaced in one go.</summary>
        public void WriteStatus(string text)
        {
            var tmp = Path.Combine(Dir, "mp_status.tmp");
            var dst = Path.Combine(Dir, "mp_status.txt");
            lock (writeGate)
            {
                File.WriteAllText(tmp, text, Utf8);
                try { if (File.Exists(dst)) File.Replace(tmp, dst, null); else File.Move(tmp, dst); }
                catch { File.Copy(tmp, dst, true); }
            }
        }

        public void WriteMenuState(IDictionary<string, string> st)
        {
            var sb = new StringBuilder();
            foreach (var kv in st) sb.Append(kv.Key).Append('=').Append((kv.Value ?? "").Replace("\r", " ").Replace("\n", " ")).Append('\n');
            var tmp = Path.Combine(Dir, "menu_state.tmp");
            var dst = Path.Combine(Dir, "menu_state.txt");
            lock (writeGate)
            {
                File.WriteAllText(tmp, sb.ToString(), Utf8);
                try { if (File.Exists(dst)) File.Replace(tmp, dst, null); else File.Move(tmp, dst); }
                catch { File.Copy(tmp, dst, true); }
            }
        }

        long chatOutOff;

        /// <summary>The messages written in the in-game chat since the last call (chat_out.txt, appended by the mod: one
        /// "seq TAB text" line per message).</summary>
        public List<string> ReadChatOut()
        {
            var res = new List<string>();
            try
            {
                var f = Path.Combine(Dir, "chat_out.txt");
                if (!File.Exists(f)) return res;
                using (var fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length < chatOutOff) chatOutOff = 0;
                    if (fs.Length == chatOutOff) return res;
                    fs.Seek(chatOutOff, SeekOrigin.Begin);
                    var buf = new byte[fs.Length - chatOutOff];
                    int n = 0;
                    while (n < buf.Length) { int r = fs.Read(buf, n, buf.Length - n); if (r <= 0) break; n += r; }
                    int last = n > 0 ? Array.LastIndexOf(buf, (byte)'\n', n - 1) : -1;
                    if (last < 0) return res;   // a line still being written
                    chatOutOff += last + 1;
                    foreach (var raw in Utf8.GetString(buf, 0, last + 1).Split('\n'))
                    {
                        var line = raw.TrimEnd('\r');
                        int tab = line.IndexOf('\t');
                        if (tab >= 0) line = line.Substring(tab + 1);
                        if (line.Trim().Length > 0) res.Add(line);
                    }
                }
            }
            catch { }
            return res;
        }

        /// <summary>A line of the in-game chat (chat.txt, read by the mod): id TAB unix time TAB kind (msg, join, left,
        /// unsent) TAB player TAB text.</summary>
        public void AppendChat(long id, long time, string kind, string name, string text)
        {
            string Clean(string s) => (s ?? "").Replace('\t', ' ').Replace('\r', ' ').Replace('\n', ' ');
            try
            {
                lock (writeGate)
                    File.AppendAllText(Path.Combine(Dir, "chat.txt"), id + "\t" + time + "\t" + Clean(kind) + "\t" + Clean(name) + "\t" + Clean(text) + "\n", Utf8);
            }
            catch (Exception e) { Log.W("chat.txt: " + e.Message); }
        }

        /// <summary>The last request of the main menu's MPFever window: seq, command, argument, player name (or null).</summary>
        public string[] ReadMenuRequest()
        {
            try
            {
                var f = Path.Combine(Dir, "menu_req.txt");
                if (!File.Exists(f)) return null;
                var line = File.ReadAllText(f, Utf8).Trim('\r', '\n');
                var parts = line.Split('\t');
                return parts.Length >= 4 ? parts : null;
            }
            catch { return null; }
        }

        public event Action Exited;

        public void ToGame(Msg m)
        {
            lock (writeGate)
            {
                var b = Utf8.GetBytes(m + "\n");
                using (var fs = new FileStream(inPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite))
                    fs.Write(b, 0, b.Length);
            }
        }

        /// <summary>Autotest: savegame loaded by the autopilot script (null = the player loads one).</summary>
        public static string AutoSave;

        public void Kill()
        {
            try { if (proc != null && !proc.HasExited) proc.Kill(); } catch { }
        }

        public void Launch(string gameDir)
        {
            var exe = Path.Combine(gameDir, "TransportFever3.exe");
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = gameDir };
            psi.EnvironmentVariables["MPFEVER_DIR"] = Dir;
            psi.EnvironmentVariables["MPFEVER_NAME"] = Name;
            psi.EnvironmentVariables["MPFEVER_ROLE"] = Role;
            psi.EnvironmentVariables["MPFEVER_LANG"] = L.Code;
            // the native module's places by signature, for a game build it does not know (made by tools/mksigs.py)
            var sigs = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "mpfever_sigs.txt");
            if (File.Exists(sigs)) psi.EnvironmentVariables["MPFEVER_SIGS"] = sigs;
            if (Server) psi.EnvironmentVariables["MPFEVER_SERVER"] = "1";
            WriteLang();
            WriteSettings();
            // application script: starts the host's savegame after a resynchronisation (and loads the autotest save)
            psi.Arguments = "--script mpfever_1::/mpfever_auto.lua";
            if (AutoSave != null) psi.EnvironmentVariables["MPFEVER_SAVE"] = AutoSave;
            proc = Process.Start(psi);
            proc.EnableRaisingEvents = true;
            proc.Exited += (s, e) => Exited?.Invoke();
            // experiment (MPFEVER_AFFINITY=mask): pin the game to some CPU cores
            var aff = Environment.GetEnvironmentVariable("MPFEVER_AFFINITY");
            if (!string.IsNullOrEmpty(aff)) try { proc.ProcessorAffinity = (IntPtr)Convert.ToInt64(aff, 16); } catch (Exception e) { Log.W("affinity: " + e.Message); }
            Log.W(L.F("[{0}] jeu lancé (pid {1}), session {2}", "[{0}] game started (pid {1}), session {2}", Name, proc.Id, Dir));
        }

        void Poll()
        {
            // two producers inside the game: the game-script bridge (out.log) and the UI hook (ui.log)
            var sources = new[] { new Tail(outPath) }; // the game script forwards the UI hook's actions itself, in order with its clock
            while (!stop)
            {
                foreach (var src in sources)
                {
                    try
                    {
                        foreach (var line in src.ReadLines())
                        {
                            var m = Msg.Parse(line);
                            if (m != null) FromGame?.Invoke(this, m);
                        }
                    }
                    catch (Exception e) { Log.Warn(L.F("[{0}] lecture {1} : {2}", "[{0}] reading {1}: {2}", Name, Path.GetFileName(src.Path), e.Message)); Thread.Sleep(500); }
                }
                LogMemory();
                Thread.Sleep(5);
            }
        }

        DateTime memAt = DateTime.MinValue;
        /// <summary>Every 5 minutes, the game's memory in the launcher's log: the frame rate of a long session fell by
        /// three quarters after the fifth resynchronisation (two games on one PC, issue #50), each reload of a 165 MB
        /// savegame may keep some of the game's memory.</summary>
        void LogMemory()
        {
            if ((DateTime.UtcNow - memAt).TotalMinutes < 5) return;
            memAt = DateTime.UtcNow;
            try
            {
                if (proc == null || proc.HasExited) return;
                proc.Refresh();
                Log.W(L.F("[{0}] mémoire du jeu : {1} Mo privés, {2} Mo en mémoire vive (pointe {3} Mo)", "[{0}] game memory: {1} MB private, {2} MB in RAM (peak {3} MB)",
                    Name, proc.PrivateMemorySize64 >> 20, proc.WorkingSet64 >> 20, proc.PeakWorkingSet64 >> 20));
            }
            catch { }
        }

        sealed class Tail
        {
            public readonly string Path;
            long off;
            readonly List<byte> pending = new List<byte>();
            public Tail(string path) { Path = path; }

            public IEnumerable<string> ReadLines()
            {
                var lines = new List<string>();
                if (!File.Exists(Path)) return lines;
                using (var fs = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    if (fs.Length < off) { off = 0; pending.Clear(); }
                    if (fs.Length > off)
                    {
                        fs.Seek(off, SeekOrigin.Begin);
                        var buf = new byte[fs.Length - off];
                        int n = fs.Read(buf, 0, buf.Length);
                        off += n;
                        for (int k = 0; k < n; k++)
                        {
                            if (buf[k] == 10) { lines.Add(Utf8.GetString(pending.ToArray()).TrimEnd((char)13)); pending.Clear(); }
                            else pending.Add(buf[k]);
                        }
                    }
                }
                return lines;
            }
        }

        public void Dispose() { stop = true; }
    }

    sealed class Peer
    {
        public int Id;
        public string Name;
        public TcpClient Tcp;
        public StreamWriter Writer;
        public readonly object Gate = new object();
        /// <summary>The player was let in (its "join" accepted): only then does it receive and send session messages.</summary>
        public volatile bool Admitted;
        public string Address;
    }

    /// <summary>Host side: accepts TCP clients and relays every message to everybody else.</summary>
    sealed class Relay : IDisposable
    {
        TcpListener listener;
        readonly List<Peer> peers = new List<Peer>();
        int nextId = 1;
        volatile bool stop;

        public event Action<Peer, Msg> Received;
        public event Action<Peer> Joined, Left;

        /// <summary>Decides whether a player who says "join" may come in (a dedicated server checks its password, its
        /// version and the number of players): null lets it in, otherwise the payload of the "denied" message it receives
        /// before its connection is closed. Unset: everybody comes in.</summary>
        public Func<Peer, Msg, string> Admit;

        public int Count { get { lock (peers) return peers.Count; } }

        /// <summary>The players let in, connected right now.</summary>
        public int AdmittedCount { get { lock (peers) return peers.Count(p => p.Admitted); } }

        /// <summary>The players connected right now (name#id), including those whose game is not ready yet.</summary>
        public string[] PeerNames() { lock (peers) return peers.Where(p => In(p) && p.Name != null).Select(p => p.Name).ToArray(); }

        /// <summary>A connection that takes part in the session: every one, unless an Admit rule decides (then the players
        /// it let in only).</summary>
        bool In(Peer p) => p.Admitted || Admit == null;

        /// <summary>The players connected right now, with their address.</summary>
        public Peer[] Admitted() { lock (peers) return peers.Where(p => p.Admitted).ToArray(); }

        public void Start(int port)
        {
            // IPv4 and IPv6 on one socket (players behind DS-Lite, without a public IPv4 of their own, are reached over
            // IPv6); IPv4 only where the PC has no IPv6
            try
            {
                listener = new TcpListener(IPAddress.IPv6Any, port);
                listener.Server.DualMode = true;
                listener.Start();
            }
            catch (Exception)
            {
                try { listener?.Stop(); } catch { }
                listener = new TcpListener(IPAddress.Any, port);
                listener.Start();
            }
            new Thread(AcceptLoop) { IsBackground = true, Name = "Relay accept" }.Start();
            Log.W(L.F("Hôte : écoute TCP sur le port {0}", "Host: listening on TCP port {0}", port));
        }

        void AcceptLoop()
        {
            while (!stop)
            {
                try
                {
                    var c = listener.AcceptTcpClient();
                    c.NoDelay = true;
                    NetAddr.KeepAlive(c);
                    var p = new Peer { Id = nextId++, Tcp = c, Writer = new StreamWriter(c.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true } };
                    p.Name = "Player" + p.Id;
                    try { p.Address = c.Client.RemoteEndPoint?.ToString(); } catch { }
                    lock (peers) peers.Add(p);
                    Log.Dim(L.F("Connexion entrante de {0} (id {1})", "Incoming connection from {0} (id {1})", c.Client.RemoteEndPoint, p.Id));
                    new Thread(() => ReadLoop(p)) { IsBackground = true, Name = "Relay peer " + p.Id }.Start();
                }
                catch (Exception e) { if (!stop) Log.W("accept: " + e.Message); }
            }
        }

        void ReadLoop(Peer p)
        {
            try
            {
                var r = new StreamReader(p.Tcp.GetStream(), new UTF8Encoding(false));
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    var m = Msg.Parse(line);
                    if (m == null) continue;
                    if (m.Kind == "join")
                    {
                        if (p.Admitted) continue;
                        p.Name = Sanitize(m.From) + "#" + p.Id;
                        string refused = null;
                        try { refused = Admit?.Invoke(p, m); }
                        catch (Exception e) { Log.W("admit: " + e.Message); }
                        if (refused != null) { Deny(p, refused); break; }
                        p.Admitted = true;
                        Joined?.Invoke(p);
                        continue;
                    }
                    if (!In(p)) continue;   // nothing counts before the player is let in
                    m.From = p.Name; // the relay decides who is speaking; the host decides who receives it
                    Received?.Invoke(p, m);
                }
            }
            catch (Exception e) { if (!stop && In(p)) Log.W($"{p.Name} : {e.Message}"); }
            lock (peers) peers.Remove(p);
            if (In(p)) Left?.Invoke(p);
        }

        /// <summary>Tells a player why it may not stay ("denied", payload: { reason = "...", ... }), then closes its
        /// connection (its MPFever does not reconnect).</summary>
        public void Deny(Peer p, string payload)
        {
            Send(p, Msg.Make("denied", "MPFever", payload));
            try { p.Tcp.Client.Shutdown(SocketShutdown.Send); } catch { }
            Thread.Sleep(300);   // (closed at once, the message could be lost with the connection)
            try { p.Tcp.Close(); } catch { }
        }

        /// <summary>Closes the connections of a player known by its name (without #id, any case): it is told why first.
        /// Returns how many connections were closed.</summary>
        public int Kick(string name, string payload)
        {
            string Base(string n) { int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }
            var found = Admitted().Where(p => string.Equals(Base(p.Name), name, StringComparison.OrdinalIgnoreCase) || p.Name == name).ToList();
            foreach (var p in found) new Thread(() => Deny(p, payload)) { IsBackground = true, Name = "Kick " + p.Id }.Start();
            return found.Count;
        }

        static string Sanitize(string s)
        {
            var t = new string((s ?? "").Where(ch => char.IsLetterOrDigit(ch) || ch == '_' || ch == '-').ToArray());
            return t.Length == 0 ? "Player" : (t.Length > 24 ? t.Substring(0, 24) : t);
        }

        /// <summary>A player who comes back (reconnection) under the same name: the old connection, which may still look
        /// alive after a network cut, is closed.</summary>
        public void DropOlder(Peer p)
        {
            string Base(string n) { int i = n.LastIndexOf('#'); return i < 0 ? n : n.Substring(0, i); }
            Peer[] all;
            lock (peers) all = peers.ToArray();
            foreach (var o in all)
                if (o != p && Base(o.Name) == Base(p.Name))
                {
                    Log.Warn(L.F("{0} : ancienne connexion fermée (reconnexion)", "{0}: old connection closed (reconnection)", o.Name));
                    try { o.Tcp.Close(); } catch { }
                }
        }

        public void Send(Peer p, Msg m)
        {
            try { lock (p.Gate) p.Writer.WriteLine(m.ToString()); }
            catch (Exception e) { Log.Warn(L.F("envoi vers {0} : {1}", "sending to {0}: {1}", p.Name, e.Message)); }
        }

        public void Broadcast(Msg m, Peer except = null)
        {
            Peer[] all;
            lock (peers) all = peers.Where(In).ToArray();   // (a connection not let in gets nothing, a savegame least of all)
            foreach (var p in all) if (p != except) Send(p, m);
        }

        public void Dispose()
        {
            stop = true;
            try { listener?.Stop(); } catch { }
            lock (peers) foreach (var p in peers) try { p.Tcp.Close(); } catch { }
        }
    }

    /// <summary>Client side: one TCP connection to the host.</summary>
    sealed class Client : IDisposable
    {
        TcpClient tcp;
        StreamWriter writer;
        readonly object gate = new object();
        volatile bool stop;
        public event Action<Msg> Received;
        public event Action Closed;
        /// <summary>The host refused this player (wrong password, server full, other version, kicked): raised with the
        /// "denied" payload, before Closed.</summary>
        public event Action<Dictionary<object, object>> Denied;

        /// <summary>Connects to the host. host may list several addresses (a Steam invitation gives the host's IPv4 and
        /// IPv6 addresses, "1.2.3.4:28090,[2a02:...]:28090"); each one may carry its port, else port. IPv6 is tried first:
        /// a host behind DS-Lite is only reachable that way. On a PC without IPv6 those attempts fail at once: the error
        /// then names the other attempts first and ends with one short note on IPv6 (issue #31).
        /// The password is the one of a dedicated server (none: null); the join also tells this MPFever's version
        /// (a dedicated server only lets in its own).</summary>
        public void Connect(string host, int port, string name, string password = null)
        {
            var targets = new List<IPEndPoint>();
            var errors = new List<string>();
            foreach (var t in NetAddr.Parse(host, port))
            {
                if (IPAddress.TryParse(t.Key, out var ip)) { targets.Add(new IPEndPoint(ip, t.Value)); continue; }
                try { foreach (var a in Dns.GetHostAddresses(t.Key)) targets.Add(new IPEndPoint(a, t.Value)); }
                catch (Exception e) { errors.Add(NetAddr.Show(t.Key, t.Value) + " : " + e.Message); }
            }
            targets = targets.Where(e => e.AddressFamily == AddressFamily.InterNetworkV6).Concat(targets.Where(e => e.AddressFamily != AddressFamily.InterNetworkV6)).ToList();
            IPEndPoint used = null;
            bool noIPv6 = false;   // an IPv6 address failed because this PC has no IPv6
            foreach (var ep in targets)
            {
                TcpClient c = null;
                try
                {
                    c = new TcpClient(ep.AddressFamily) { NoDelay = true };   // fails at once on a PC without IPv6
                    var task = c.ConnectAsync(ep.Address, ep.Port);
                    if (!task.Wait(TimeSpan.FromSeconds(targets.Count > 1 ? 8 : 20))) throw new TimeoutException(L.T("pas de réponse", "no answer"));
                    tcp = c;
                    NetAddr.KeepAlive(c);
                    used = ep;
                    break;
                }
                catch (Exception e)
                {
                    try { c?.Close(); } catch { }
                    var inner = e is AggregateException ae && ae.InnerException != null ? ae.InnerException : e;
                    // no route to IPv6 or IPv6 turned off: this PC has no IPv6, not an error of the host. Its long Windows
                    // message per address came first and hid the reason of the IPv4 attempt ("host unreachable" stays an
                    // error of the host)
                    if (ep.AddressFamily == AddressFamily.InterNetworkV6 && inner is SocketException se
                        && (se.SocketErrorCode == SocketError.NetworkUnreachable || se.SocketErrorCode == SocketError.AddressFamilyNotSupported))
                        noIPv6 = true;
                    else
                        errors.Add(NetAddr.Show(ep.Address.ToString(), ep.Port) + " : " + inner.Message);
                }
            }
            if (tcp == null)
            {
                // after the other errors, and kept: for a host only reachable over IPv6 it is the reason
                if (noIPv6) errors.Add(L.T("IPv6 : indisponible sur ce PC", "IPv6: not available on this PC"));
                throw new IOException(errors.Count > 0 ? string.Join("  |  ", errors) : L.T("adresse vide", "empty address"));
            }
            writer = new StreamWriter(tcp.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
            Send(Msg.Make("join", name, "{[\"v\"]=" + LuaLit.Quote(MainForm.Version)
                + (string.IsNullOrEmpty(password) ? "" : ",[\"pw\"]=" + LuaLit.Quote(password)) + "}"));
            new Thread(ReadLoop) { IsBackground = true, Name = "Client read" }.Start();
            Log.Ok(L.F("Client : connecté à {0}", "Client: connected to {0}", NetAddr.Show(used.Address.ToString(), used.Port)));
        }

        void ReadLoop()
        {
            try
            {
                var r = new StreamReader(tcp.GetStream(), new UTF8Encoding(false));
                string line;
                while ((line = r.ReadLine()) != null)
                {
                    var m = Msg.Parse(line);
                    if (m == null) continue;
                    if (m.Kind == "denied")
                    {
                        Denied?.Invoke(LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>());
                        continue;
                    }
                    Received?.Invoke(m);
                }
            }
            catch (Exception e) { if (!stop) Log.W("client : " + e.Message); }
            Closed?.Invoke();
        }

        public void Send(Msg m)
        {
            try { lock (gate) writer.WriteLine(m.ToString()); }
            catch (Exception e) { Log.Warn(L.T("envoi vers l'hôte : ", "sending to the host: ") + e.Message); }
        }

        public void Dispose() { stop = true; try { tcp?.Close(); } catch { } }
    }

    /// <summary>Host addresses as players type them: "1.2.3.4:28090", "[2a02:8071::1]:28090", "2a02:8071::1" (IPv6 without
    /// port), "name:28090", several separated by commas.</summary>
    static class NetAddr
    {
        /// <summary>TCP keepalive after 15 s of silence, every 3 s: a connection that died without a word (a router, a lost
        /// Wi-Fi) is noticed within about half a minute instead of hours. Issue #60: the host kept a player's dead connection
        /// until the player came back on a new one.</summary>
        public static void KeepAlive(TcpClient c)
        {
            try
            {
                c.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.KeepAlive, true);
                var v = new byte[12];
                BitConverter.GetBytes(1u).CopyTo(v, 0);
                BitConverter.GetBytes(15000u).CopyTo(v, 4);
                BitConverter.GetBytes(3000u).CopyTo(v, 8);
                c.Client.IOControl(IOControlCode.KeepAliveValues, v, null);
            }
            catch (Exception e) { Log.W("keepalive: " + e.Message); }
        }

        public static List<KeyValuePair<string, int>> Parse(string spec, int defaultPort)
        {
            var res = new List<KeyValuePair<string, int>>();
            foreach (var raw in (spec ?? "").Split(new[] { ',', ';', ' ' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var s = raw.Trim();
                string host = s;
                int port = defaultPort;
                if (s.StartsWith("["))
                {
                    int close = s.IndexOf(']');
                    if (close < 0) { host = s.Trim('['); }
                    else
                    {
                        host = s.Substring(1, close - 1);
                        var rest = s.Substring(close + 1);
                        if (rest.StartsWith(":") && int.TryParse(rest.Substring(1), out int p)) port = p;
                    }
                }
                else if (s.Count(ch => ch == ':') == 1)
                {
                    int c = s.IndexOf(':');
                    if (int.TryParse(s.Substring(c + 1), out int p)) { port = p; host = s.Substring(0, c); }
                }
                if (host.Length > 0) res.Add(new KeyValuePair<string, int>(host, port));
            }
            return res;
        }

        public static string Show(string host, int port) => (host.Contains(":") ? "[" + host + "]" : host) + ":" + port;

        /// <summary>The first address of a list, to show it: "1.2.3.4:28090".</summary>
        public static string First(string spec, int defaultPort)
        {
            var l = Parse(spec, defaultPort);
            return l.Count == 0 ? (spec ?? "") : Show(l[0].Key, l[0].Value);
        }

        /// <summary>This PC's public IPv6 addresses for invitations, the best first, or an empty list. First the address
        /// Windows uses for its own connections to the Internet (often a temporary one): routers that open a port per
        /// device (Vodafone Station "IPv6 Host Exposure") open it for the address they see that device use. Then the
        /// most stable one, when it is another.</summary>
        public static List<string> PublicIPv6List()
        {
            var res = new List<string>();
            try
            {
                // the source address of a route to a public IPv6 address (UDP "connect": nothing is sent)
                using (var u = new Socket(AddressFamily.InterNetworkV6, SocketType.Dgram, ProtocolType.Udp))
                {
                    u.Connect(IPAddress.Parse("2001:4860:4860::8888"), 53);
                    var a = ((IPEndPoint)u.LocalEndPoint).Address;
                    var b = a.GetAddressBytes();
                    if ((b[0] & 0xE0) == 0x20 && !(b[0] == 0x20 && b[1] == 0x02) && !a.IsIPv6Teredo) { a.ScopeId = 0; res.Add(a.ToString()); }
                }
            }
            catch { }
            var stable = PublicIPv6();
            if (stable != null && !res.Contains(stable)) res.Add(stable);
            return res;
        }

        /// <summary>This PC's public IPv6 address (global, the most stable one: given by the router's DHCPv6, else not a
        /// temporary one), or null.</summary>
        public static string PublicIPv6()
        {
            try
            {
                var found = new List<KeyValuePair<int, IPAddress>>();
                foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (nic.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
                    if (nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback
                        || nic.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Tunnel) continue;
                    foreach (var u in nic.GetIPProperties().UnicastAddresses)
                    {
                        var a = u.Address;
                        if (a.AddressFamily != AddressFamily.InterNetworkV6) continue;
                        var b = a.GetAddressBytes();
                        if ((b[0] & 0xE0) != 0x20 || (b[0] == 0x20 && b[1] == 0x02) || a.IsIPv6Teredo) continue;   // global unicast, not 6to4 / Teredo
                        int rank = 2;
                        try
                        {
                            if (u.PrefixOrigin == System.Net.NetworkInformation.PrefixOrigin.Dhcp) rank = 0;
                            else if (u.SuffixOrigin != System.Net.NetworkInformation.SuffixOrigin.Random) rank = 1;
                            else if (u.AddressPreferredLifetime < 86400 * 2) rank = 3;   // a temporary address
                        }
                        catch { }
                        found.Add(new KeyValuePair<int, IPAddress>(rank, a));
                    }
                }
                return found.Count == 0 ? null : found.OrderBy(kv => kv.Key).First().Value.ToString();
            }
            catch { return null; }
        }
    }

    static class GameInstall
    {
        public const string AppId = "3493540";

        public static string FindGameDir()
        {
            // 1. launcher placed inside the game folder (MPFever\...)
            var d = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (d != null)
            {
                if (File.Exists(Path.Combine(d.FullName, "TransportFever3.exe"))) return d.FullName;
                d = d.Parent;
            }
            // 2. Steam libraries
            foreach (var lib in SteamLibraries())
            {
                var p = Path.Combine(lib, "steamapps", "common", "Transport Fever 3");
                if (File.Exists(Path.Combine(p, "TransportFever3.exe"))) return p;
            }
            return null;
        }

        /// <summary>The game's language as written by the game or Steam (raw value, see L.Normalize), and where it was
        /// found: "game" (the language chosen in the game's options: profile.lua, language = { code = "de" }) or "steam"
        /// (the language Steam uses for the game, appmanifest_3493540.acf). Null when neither has one.</summary>
        public static string GameLanguage(out string where)
        {
            where = null;
            var steam = SteamPath();
            if (steam == null) return null;
            // 1. the game's own option: the most recently written profile.lua of the Steam users of this computer
            try
            {
                var userdata = Path.Combine(steam, "userdata");
                if (Directory.Exists(userdata))
                {
                    var files = Directory.GetDirectories(userdata)
                        .SelectMany(u => new[] { Path.Combine(u, AppId, "local", "profile.lua"), Path.Combine(u, AppId, "local", "settings.lua") })
                        .Where(File.Exists).OrderByDescending(File.GetLastWriteTimeUtc).ToList();
                    foreach (var f in files)
                    {
                        var code = LanguageInLua(File.ReadAllText(f));
                        if (code != null) { where = "game"; return code; }
                    }
                }
            }
            catch { }
            // 2. Steam's language for the game (Properties > General > Language)
            foreach (var lib in SteamLibraries())
            {
                try
                {
                    var acf = Path.Combine(lib, "steamapps", "appmanifest_" + AppId + ".acf");
                    if (!File.Exists(acf)) continue;
                    var m = System.Text.RegularExpressions.Regex.Match(File.ReadAllText(acf), @"""language""\s+""([^""]+)""");
                    if (m.Success) { where = "steam"; return m.Groups[1].Value; }
                }
                catch { }
            }
            return null;
        }

        /// <summary>The language code in the game's profile.lua (language = { code = "de", mod = { "" } }), or a plain
        /// language = "de" line; null when there is none.</summary>
        public static string LanguageInLua(string text)
        {
            var m = System.Text.RegularExpressions.Regex.Match(text, @"(?s)\blanguage\s*=\s*\{.{0,300}?\bcode\s*=\s*""([^""]+)""");
            if (!m.Success) m = System.Text.RegularExpressions.Regex.Match(text, @"(?m)^\s*(?:language|lang|locale)\s*=\s*""([^""]+)""");
            return m.Success && L.Normalize(m.Groups[1].Value) != null ? m.Groups[1].Value : null;
        }

        public static string SteamPath()
        {
            // The user's SteamPath can be stale (Steam reinstalled elsewhere: it still named the old folder, where only a
            // library was left, so the mod went nowhere and no savegame was found): the first of these that holds steam.exe,
            // then the running Steam's folder
            var cands = new List<string>();
            try { cands.Add(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamPath", null) as string); } catch { }
            try { cands.Add(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Valve\Steam", "InstallPath", null) as string); } catch { }
            try { cands.Add(Registry.GetValue(@"HKEY_LOCAL_MACHINE\SOFTWARE\Valve\Steam", "InstallPath", null) as string); } catch { }
            try { cands.Add(Path.GetDirectoryName(Registry.GetValue(@"HKEY_CURRENT_USER\Software\Valve\Steam", "SteamExe", null) as string ?? "")); } catch { }
            try { foreach (var p in System.Diagnostics.Process.GetProcessesByName("steam")) try { cands.Add(Path.GetDirectoryName(p.MainModule.FileName)); } catch { } } catch { }
            foreach (var c in cands)
            {
                if (string.IsNullOrEmpty(c)) continue;
                var d = c.Replace('/', Path.DirectorySeparatorChar);
                try { if (File.Exists(Path.Combine(d, "steam.exe")) && Directory.Exists(Path.Combine(d, "userdata"))) return d; } catch { }
            }
            return cands.FirstOrDefault(c => !string.IsNullOrEmpty(c))?.Replace('/', Path.DirectorySeparatorChar);
        }

        public static IEnumerable<string> SteamLibraries()
        {
            var steam = SteamPath();
            if (steam == null) yield break;
            yield return steam;
            var vdf = Path.Combine(steam, "steamapps", "libraryfolders.vdf");
            if (!File.Exists(vdf)) yield break;
            foreach (var line in File.ReadAllLines(vdf))
            {
                var t = line.Trim();
                if (!t.StartsWith("\"path\"")) continue;
                var parts = t.Split('"');
                if (parts.Length >= 4) yield return parts[3].Replace(@"\\", @"\");
            }
        }

        /// <summary>Allows direct launches (and several instances) without Steam restarting the game.</summary>
        public static void EnsureSteamAppId(string gameDir)
        {
            var f = Path.Combine(gameDir, "steam_appid.txt");
            if (!File.Exists(f)) { File.WriteAllText(f, AppId); Log.W(L.T("steam_appid.txt créé dans le dossier du jeu", "steam_appid.txt created in the game folder")); }
        }

        public static string FindModSource()
        {
            var d = new DirectoryInfo(AppDomain.CurrentDomain.BaseDirectory);
            while (d != null)
            {
                var m = Path.Combine(d.FullName, "mod", "mpfever_1");
                if (File.Exists(Path.Combine(m, "mod.json"))) return m;
                d = d.Parent;
            }
            return null;
        }

        /// <summary>Copies the mod into every Steam user's TF3 mods folder.</summary>
        public static int InstallMod()
        {
            var src = FindModSource();
            var steam = SteamPath();
            if (src == null || steam == null) { Log.Err(L.T("Mod ou Steam introuvable, installation du mod ignorée", "Mod or Steam not found, mod installation skipped")); return 0; }
            int n = 0;
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return 0;
            foreach (var u in Directory.GetDirectories(userdata))
            {
                var local = Path.Combine(u, AppId, "local");
                if (!Directory.Exists(local)) continue;
                var dst = Path.Combine(local, "mods", "mpfever_1");
                if (Directory.Exists(dst)) Directory.Delete(dst, true); // mirror: drop files removed from the mod
                CopyDir(src, dst);
                n++;
                Log.Ok(L.T("Mod installé dans ", "Mod installed in ") + dst);
            }
            return n;
        }

        /// <summary>Adds the mod to the game's default mod selection (settings.lua, mainMenuState.activeModsState), so
        /// that every new game includes it. Only while the game is closed (it rewrites settings.lua on exit).</summary>
        public static void EnsureModActive()
        {
            if (Process.GetProcessesByName("TransportFever3").Length > 0) return;
            var steam = SteamPath();
            if (steam == null) return;
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return;
            foreach (var u in Directory.GetDirectories(userdata))
            {
                var f = Path.Combine(u, AppId, "local", "settings.lua");
                if (!File.Exists(f)) continue;
                var s = File.ReadAllText(f);
                int i = s.IndexOf("activeModsState = {", StringComparison.Ordinal);
                if (i < 0) continue;
                int open = s.IndexOf('{', i), close = s.IndexOf('}', open);
                if (close < 0) continue;
                if (s.Substring(open, close - open).Contains("\"mpfever_1\"")) continue;
                var bak = f + ".bak_mpfever";
                if (!File.Exists(bak)) File.Copy(f, bak);
                s = s.Substring(0, open + 1) + " \"mpfever_1\"," + s.Substring(open + 1);
                File.WriteAllText(f, s);
                Log.Ok(L.T("Mod activé pour les nouvelles parties (", "Mod enabled for new games (") + f + ")");
            }
        }

        /// <summary>Puts the native module next to the game as winhttp.dll: the game imports WINHTTP.dll and Windows
        /// looks in the game folder first, so the game loads the module itself at startup (it relays every WinHTTP
        /// call to the system library, and stays inert unless the game was started by MPFever).</summary>
        public static void InstallNative(string gameDir)
        {
            var src = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "winhttp.dll");
            var dst = Path.Combine(gameDir, "winhttp.dll");
            // a game started by Steam from an MPFever invitation starts MPFever.exe from this path
            try { File.WriteAllText(Path.Combine(gameDir, "mpfever_path.txt"), System.Reflection.Assembly.GetExecutingAssembly().Location, Encoding.Unicode); } catch (Exception e) { Log.W("mpfever_path.txt: " + e.Message); }
            if (!File.Exists(src)) { Log.Warn(L.T("winhttp.dll absent à côté de MPFever.exe : module natif non installé", "winhttp.dll missing next to MPFever.exe: native module not installed")); return; }
            if (File.Exists(dst))
            {
                var cur = File.ReadAllBytes(dst);
                if (cur.SequenceEqual(File.ReadAllBytes(src))) return;
                if (Encoding.ASCII.GetString(cur).IndexOf("mpfever_native", StringComparison.Ordinal) < 0)
                {
                    Log.Warn(L.T("Un autre winhttp.dll (autre mod ?) est déjà dans le dossier du jeu : module natif non installé", "Another winhttp.dll (another mod?) is already in the game folder: native module not installed"));
                    return;
                }
            }
            try
            {
                File.Copy(src, dst, true);
                Log.Ok(L.T("Module natif installé : ", "Native module installed: ") + dst);
            }
            catch (IOException) { Log.Warn(L.T("Module natif : fermez Transport Fever 3 puis relancez MPFever pour le mettre à jour", "Native module: close Transport Fever 3, then restart MPFever to update it")); }
        }

        /// <summary>The savegame folders of every Steam user of this PC (created if missing).</summary>
        public static List<string> SaveDirs()
        {
            var dirs = new List<string>();
            var steam = SteamPath();
            if (steam == null) return dirs;
            var userdata = Path.Combine(steam, "userdata");
            if (!Directory.Exists(userdata)) return dirs;
            foreach (var u in Directory.GetDirectories(userdata))
            {
                var local = Path.Combine(u, AppId, "local");
                if (!Directory.Exists(local)) continue;
                var save = Path.Combine(local, "save");
                Directory.CreateDirectory(save);
                dirs.Add(save);
            }
            return dirs;
        }

        /// <summary>The most recent file of a savegame (name.sav), or null.</summary>
        public static string FindSave(string name)
        {
            return SaveDirs().Select(d => Path.Combine(d, name + ".sav")).Where(File.Exists)
                .OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
        }

        static void CopyDir(string src, string dst)
        {
            Directory.CreateDirectory(dst);
            foreach (var f in Directory.GetFiles(src)) File.Copy(f, Path.Combine(dst, Path.GetFileName(f)), true);
            foreach (var d in Directory.GetDirectories(src)) CopyDir(d, Path.Combine(dst, Path.GetFileName(d)));
        }
    }
}
