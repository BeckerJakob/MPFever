using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Text;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>The public list of dedicated servers (the service of serverlist\ in the sources): a dedicated server whose
    /// mpfever_server.properties says public=true announces itself there every 30 s while its world runs, and the players'
    /// multiplayer page shows the list in its « Servers » tab. serverlist= in mpfever_settings.txt names another list, else
    /// DefaultServerList; serverlist=0 turns it off.</summary>
    sealed partial class MainForm
    {
        /// <summary>The list MPFever uses when mpfever_settings.txt names none (empty: none).</summary>
        public const string DefaultServerList = "https://mpfever.knight-hd.fr";

        static string ServerListUrl()
        {
            var u = LoadSettings().TryGetValue("serverlist", out var v) ? v.Trim() : DefaultServerList;
            if (u == "" || u == "0" || u.Equals("off", StringComparison.OrdinalIgnoreCase)) return "";
            if (!u.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !u.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) u = "http://" + u;
            return u.TrimEnd('/');
        }

        static string ListRequest(string url, string body)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = req.ReadWriteTimeout = 6000;
            req.UserAgent = "MPFever/" + Version;
            req.ServicePoint.Expect100Continue = false;
            if (body != null)
            {
                req.Method = "POST";
                req.ContentType = "application/json";
                var b = Encoding.UTF8.GetBytes(body);
                req.ContentLength = b.Length;
                using (var s = req.GetRequestStream()) s.Write(b, 0, b.Length);
            }
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream(), Encoding.UTF8))
                return r.ReadToEnd();
        }

        static string JsonStr(string s)
        {
            var sb = new StringBuilder("\"");
            foreach (var ch in s ?? "")
            {
                if (ch == '"' || ch == '\\') sb.Append('\\').Append(ch);
                else if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                else sb.Append(ch);
            }
            return sb.Append('"').ToString();
        }

        // ---------------------------------------------------------------- the dedicated server's side

        string listId, listToken;
        bool listShown;

        /// <summary>Started with the server: every 30 s while the world runs, the server tells the list who it is.</summary>
        void ServerListAnnounceLoop()
        {
            var url = ServerListUrl();
            if (server == null || !server.Public) return;
            if (url == "") { Log.Warn(T("public=true, mais aucune liste de serveurs n'est connue (serverlist= dans mpfever_settings.txt) : le serveur n'y apparaît pas.", "public=true, but no server list is known (serverlist= in mpfever_settings.txt): the server is not listed.")); return; }
            string build = "";
            try { build = Reporter.GameBuild(gameDir) ?? ""; } catch { }
            while (serverStarted && !serverStopping)
            {
                bool st; lock (sessionGate) st = started;
                if (st)
                {
                    try
                    {
                        var body = "{\"name\":" + JsonStr(server.Name) + ",\"port\":" + server.Port + ",\"version\":" + JsonStr(Version) + ",\"build\":" + JsonStr(build)
                            + ",\"mode\":" + JsonStr(server.CompanyMode) + ",\"world\":" + JsonStr(server.World) + ",\"motd\":" + JsonStr(server.Motd)
                            + ",\"players\":" + (relay?.AdmittedCount ?? 0) + ",\"max\":" + server.MaxPlayers + ",\"password\":" + (server.Password != "" ? "true" : "false")
                            + ",\"steam\":" + JsonStr(hostSteamId ?? "") + ",\"address\":" + JsonStr(server.PublicAddress) + ",\"token\":" + JsonStr(listToken ?? "") + "}";
                        var d = Json.Parse(ListRequest(url + "/api/announce", body)) as Dictionary<string, object>;
                        if (d != null && d.TryGetValue("ok", out var ok) && ok is bool okb && okb)
                        {
                            listId = d.TryGetValue("id", out var id) ? id as string : listId;
                            listToken = d.TryGetValue("token", out var tk) ? tk as string : listToken;
                            if (!listShown) { listShown = true; Log.Ok(F("Le serveur apparaît dans la liste publique ({0}).", "The server is in the public list ({0}).", url)); }
                        }
                        else if (d != null && d.TryGetValue("error", out var err) && !(err as string ?? "").StartsWith("too often", StringComparison.Ordinal))
                            Log.Warn(F("Liste des serveurs : {0}", "Server list: {0}", err));
                    }
                    catch (Exception e) { Log.Dim(F("Liste des serveurs injoignable : {0}", "Server list unreachable: {0}", e.Message)); }
                }
                for (int i = 0; i < 30 && serverStarted && !serverStopping; i++) Thread.Sleep(1000);
            }
        }

        /// <summary>The server stops: it leaves the list at once (else after 90 s).</summary>
        void ServerListRemove()
        {
            var url = ServerListUrl();
            if (url == "" || listId == null) return;
            try { ListRequest(url + "/api/remove", "{\"id\":" + JsonStr(listId) + ",\"token\":" + JsonStr(listToken) + "}"); } catch { }
            listId = null;
        }

        // ---------------------------------------------------------------- the players' side

        volatile string serverListView = "";
        volatile bool serverListWanted;

        /// <summary>Started with the game's menu: the list read every 20 s (at once when the page asks) while no session runs,
        /// for the « Servers » tab (menu_state servers=, one server per \u001e, its fields separated by \u001f: name, address to
        /// join, players, max, password 1/0, version, mode, world, motd).</summary>
        void ServerListFetchLoop()
        {
            double last = -1000;
            while (running)
            {
                Thread.Sleep(500);
                var url = ServerListUrl();
                if (url == "" || menuGame == null || !menuGame.GameRunning) continue;
                bool idle = menuPhase == "idle" || menuPhase == "error";
                if (!(serverListWanted || (idle && Now - last >= 20))) continue;
                serverListWanted = false;
                last = Now;
                string view;
                try
                {
                    var d = Json.Parse(ListRequest(url + "/api/servers", null)) as Dictionary<string, object>;
                    var list = d != null && d.TryGetValue("servers", out var s) ? s as List<object> : null;
                    var rows = new List<string>();
                    foreach (var o in (list ?? new List<object>()).OfType<Dictionary<string, object>>().Take(200))
                    {
                        string S(string k) => o.TryGetValue(k, out var v) && v is string sv ? sv.Replace("\u001e", " ").Replace("\u001f", " ") : "";
                        string N(string k) => o.TryGetValue(k, out var v) && v is double dv ? ((int)dv).ToString(CultureInfo.InvariantCulture) : "0";
                        var address = S("address");
                        var steam = S("steam");
                        // (through the server's Steam and its address at once: whichever answers, see Client.Connect)
                        var join = (steam != "" ? "steam:" + steam + (address != "" ? "," : "") : "") + address;
                        if (join == "") continue;
                        bool pw = o.TryGetValue("password", out var p) && p is bool pb && pb;
                        rows.Add(string.Join("\u001f", S("name"), join, N("players"), N("max"), pw ? "1" : "0", S("version"), S("mode"), S("world"), S("motd")));
                    }
                    view = rows.Count == 0 ? "-" : string.Join("\u001e", rows);
                }
                catch (Exception e)
                {
                    view = "!" + e.Message.Replace("\u001e", " ").Replace("\u001f", " ");
                }
                if (view != serverListView) { serverListView = view; MenuStatus(); }
            }
        }
    }
}
