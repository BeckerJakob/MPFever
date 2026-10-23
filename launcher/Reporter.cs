using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32;
using static MPFever.L;

namespace MPFever
{
    /// <summary>"Report a problem": every file a bug report needs, in one zip, and a GitHub issue ready to send.
    /// The zip goes to reports\ next to MPFever.exe and is shown in the Explorer; the browser opens a new issue of
    /// github.com/dkdknight/MPFever with its title and text filled in (version, game build, company mode, players, sync
    /// state, processor), and the text is also put on the clipboard. The player drags the zip into the issue and sends it:
    /// GitHub lets nobody create an issue or attach a file without an account of their own (a key shipped in MPFever would
    /// let anyone post anything in the project's name), so the last click is theirs.
    /// The game rewrites its log (stdout.txt) each time it starts: MPFever copies it into the session folder when the game
    /// closes, and the previous one into logs\ before it starts the game.</summary>
    static class Reporter
    {
        public static string ReportsDir => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "reports");
        public static string LogsDir => Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs");
        /// <summary>GitHub's limit for a file attached to an issue.</summary>
        const long AttachLimit = 25L * 1024 * 1024;
        /// <summary>Files larger than this are left out of the zip (savegames, census dumps): the text says so.</summary>
        const long FileLimit = 20L * 1024 * 1024;

        /// <summary>The game's crash_dump folders (one per Steam account that played it), the newest first.</summary>
        public static List<string> CrashDumpDirs()
        {
            var list = new List<string>();
            try
            {
                var steam = GameInstall.SteamPath();
                var userdata = steam == null ? null : Path.Combine(steam, "userdata");
                if (userdata == null || !Directory.Exists(userdata)) return list;
                foreach (var u in Directory.GetDirectories(userdata))
                {
                    var d = Path.Combine(u, GameInstall.AppId, "local", "crash_dump");
                    if (Directory.Exists(d)) list.Add(d);
                }
            }
            catch { }
            return list.OrderByDescending(d => LastWrite(Path.Combine(d, "stdout.txt"))).ToList();
        }

        static DateTime LastWrite(string f) { try { return File.Exists(f) ? File.GetLastWriteTimeUtc(f) : DateTime.MinValue; } catch { return DateTime.MinValue; } }

        /// <summary>The game's log as it is now (the newest stdout.txt), or null.</summary>
        public static string GameLog() => CrashDumpDirs().Select(d => Path.Combine(d, "stdout.txt")).FirstOrDefault(File.Exists);

        /// <summary>Before the game starts: the log of its previous run is kept (logs\stdout-previous.txt), the game
        /// rewrites stdout.txt at its start.</summary>
        public static void KeepPreviousGameLog()
        {
            try
            {
                var f = GameLog();
                if (f == null) return;
                Directory.CreateDirectory(LogsDir);
                File.Copy(f, Path.Combine(LogsDir, "stdout-previous.txt"), true);
            }
            catch (Exception e) { Log.Dim("report: " + e.Message); }
        }

        /// <summary>The game closed: its log goes into the session folder (complete only now).</summary>
        public static void KeepGameLog(string sessionDir)
        {
            try
            {
                var f = GameLog();
                if (f != null && sessionDir != null && Directory.Exists(sessionDir)) File.Copy(f, Path.Combine(sessionDir, "stdout.txt"), true);
            }
            catch (Exception e) { Log.Dim("report: " + e.Message); }
        }

        /// <summary>Did the game crash after <paramref name="since"/>? (a crash dump or a crash savegame written since)</summary>
        public static bool CrashedSince(DateTime since)
        {
            foreach (var d in CrashDumpDirs())
                try { if (Directory.GetFiles(d, "*.dmp").Any(f => File.GetLastWriteTime(f) > since)) return true; } catch { }
            return false;
        }

        [DllImport("kernel32.dll")] static extern bool IsProcessorFeaturePresent(int feature);

        /// <summary>The processor, and whether it has AVX2 (the C library's maths then take their FMA3 versions: two players
        /// with and without them may compute some values a little differently).</summary>
        public static string Processor()
        {
            string name = "?";
            try { name = (Registry.GetValue(@"HKEY_LOCAL_MACHINE\HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString", "?") as string ?? "?").Trim(); } catch { }
            string avx2 = "?";
            try { avx2 = IsProcessorFeaturePresent(40) ? "AVX2/FMA3 yes" : "AVX2/FMA3 no"; } catch { }
            return name + " (" + Environment.ProcessorCount + " threads, " + avx2 + ")";
        }

        /// <summary>Windows' name and build, from the registry (Environment.OSVersion says 6.2 to a program without a
        /// manifest, whatever the Windows).</summary>
        public static string WindowsVersion()
        {
            try
            {
                const string k = @"HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion";
                var name = Registry.GetValue(k, "ProductName", null) as string;
                var build = Registry.GetValue(k, "CurrentBuild", null) as string;
                var ubr = Registry.GetValue(k, "UBR", null);
                // (Windows 11 still names itself Windows 10 there: its builds start at 22000)
                if (name != null && int.TryParse(build, out var b) && b >= 22000) name = name.Replace("Windows 10", "Windows 11");
                if (name != null) return name + " (build " + build + (ubr != null ? "." + ubr : "") + ")";
            }
            catch { }
            return "Windows " + Environment.OSVersion.Version;
        }

        /// <summary>The game build: TransportFever3.exe's link timestamp, with its name when known.</summary>
        public static string GameBuild(string gameDir)
        {
            try
            {
                var exe = Path.Combine(gameDir ?? "", "TransportFever3.exe");
                if (!File.Exists(exe)) return "?";
                using (var f = File.OpenRead(exe))
                {
                    var b = new byte[1024];
                    f.Read(b, 0, b.Length);
                    int pe = BitConverter.ToInt32(b, 0x3c);
                    uint stamp = BitConverter.ToUInt32(b, pe + 8);
                    string known = stamp == 0x6ad0e4e5 ? "40423" : stamp == 0x6ac50427 ? "40420" : stamp == 0x6ab69fe5 ? "40408" : "unknown build";
                    return known + " (" + stamp.ToString("x8") + ")";
                }
            }
            catch { return "?"; }
        }

        sealed class Entry { public string Path, Name; }

        /// <summary>Writes the zip: the session folders given (the current game's first), the launcher's logs of today and
        /// the previous run's, the game's log (and the previous one), its newest crash dump, and report.txt (what the zip
        /// is, the session's state). Returns the zip's path.</summary>
        public static string Collect(IEnumerable<string> sessionDirs, string summary, out List<string> left)
        {
            left = new List<string>();
            Directory.CreateDirectory(ReportsDir);
            var stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            var zip = Path.Combine(ReportsDir, "MPFever-report-" + stamp + ".zip");
            var files = new List<Entry>();
            void Add(string path, string name)
            {
                try { if (File.Exists(path)) files.Add(new Entry { Path = path, Name = name.Replace('\\', '/') }); } catch { }
            }
            foreach (var dir in sessionDirs.Where(d => d != null && Directory.Exists(d)).Distinct())
                foreach (var f in Directory.GetFiles(dir, "*", SearchOption.AllDirectories))
                    Add(f, "session/" + Path.GetFileName(dir) + "/" + f.Substring(dir.Length).TrimStart('\\', '/'));
            try
            {
                foreach (var f in Directory.GetFiles(LogsDir, "launcher-*.log").OrderByDescending(File.GetLastWriteTimeUtc).Take(3))
                    Add(f, "launcher/" + Path.GetFileName(f));
                Add(Path.Combine(LogsDir, "stdout-previous.txt"), "game/stdout-previous.txt");
            }
            catch { }
            var game = GameLog();
            if (game != null) Add(game, "game/stdout.txt");
            foreach (var d in CrashDumpDirs().Take(1))
                try
                {
                    var dmp = Directory.GetFiles(d, "*.dmp").OrderByDescending(File.GetLastWriteTimeUtc).FirstOrDefault();
                    if (dmp != null && File.GetLastWriteTime(dmp) > DateTime.Now.AddDays(-2)) Add(dmp, "game/" + Path.GetFileName(dmp));
                }
                catch { }
            using (var z = ZipFile.Open(zip, ZipArchiveMode.Create))
            {
                var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                foreach (var e in files)
                {
                    if (!seen.Add(e.Name)) continue;
                    long size = 0;
                    try { size = new FileInfo(e.Path).Length; } catch { continue; }
                    if (size > FileLimit) { left.Add(e.Name + " (" + (size >> 20) + " MB)"); continue; }
                    try
                    {
                        // (the game may still be writing its logs: read them shared)
                        using (var src = new FileStream(e.Path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                        using (var dst = z.CreateEntry(e.Name, CompressionLevel.Optimal).Open())
                            src.CopyTo(dst);
                    }
                    catch (Exception ex) { left.Add(e.Name + " (" + ex.Message + ")"); }
                }
                var info = z.CreateEntry("report.txt");
                using (var w = new StreamWriter(info.Open(), new UTF8Encoding(false)))
                {
                    w.WriteLine(summary);
                    if (left.Count > 0) { w.WriteLine(); w.WriteLine("Left out (too large or unreadable):"); foreach (var l in left) w.WriteLine("  " + l); }
                }
            }
            return zip;
        }

        /// <summary>The browser opens a new issue with this title and text; the text is cut to what a link can carry.</summary>
        public static void OpenIssue(string title, string body)
        {
            const int max = 6000;
            if (body.Length > max) body = body.Substring(0, max) + "\n…";
            var url = "https://github.com/" + Updater.Repo + "/issues/new?title=" + Uri.EscapeDataString(title) + "&body=" + Uri.EscapeDataString(body);
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception e) { Log.W("report: " + e.Message); }
        }

        public static void ShowInExplorer(string file)
        {
            try { Process.Start("explorer.exe", "/select,\"" + file + "\""); }
            catch (Exception e) { Log.W("report: " + e.Message); }
        }

        /// <summary>The issue's text (English: the issues are written in English).</summary>
        public static string IssueBody(string zipName, long zipSize, string summary, bool crashed)
        {
            var sb = new StringBuilder();
            sb.AppendLine("### What happened");
            sb.AppendLine(crashed ? "The game crashed. What was I doing just before:" : "What I did just before (built a station, bulldozed a road, bought a vehicle...):");
            sb.AppendLine();
            sb.AppendLine("At what time (my clock): " + DateTime.Now.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
            sb.AppendLine("Does it happen again:");
            sb.AppendLine();
            sb.AppendLine("### Logs");
            if (zipSize <= AttachLimit)
                sb.AppendLine("**Drag `" + zipName + "` here** (MPFever just showed it in the Explorer, in its `reports` folder). The other players can send theirs with the same button.");
            else
                sb.AppendLine("`" + zipName + "` is " + (zipSize >> 20) + " MB, over GitHub's 25 MB: link to it on Google Drive, Dropbox or WeTransfer.");
            sb.AppendLine("The savegame helps a lot too (over 25 MB: a link).");
            sb.AppendLine();
            sb.AppendLine("### Session");
            sb.AppendLine("```");
            sb.AppendLine(summary.Trim());
            sb.AppendLine("```");
            return sb.ToString();
        }
    }
}
