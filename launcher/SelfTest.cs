using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace MPFever
{
    /// <summary>Headless check of relay + client + file links, simulating two games (MPFever.exe --selftest).</summary>
    static class SelfTest
    {
        static void GameWrites(GameLink g, string line)
        {
            File.AppendAllText(Path.Combine(g.Dir, "out.log"), line + "\n", new UTF8Encoding(false));
        }

        public static int Run()
        {
            int port = 28191;
            var relay = new Relay();
            var hostGame = new GameLink("Host", "host");
            var clientGame = new GameLink("Client", "client");
            relay.Received += (p, m) => hostGame.ToGame(m);
            relay.Joined += p => relay.Send(p, Msg.Make("welcome", "Host", "{[\"you\"]=\"" + p.Name + "\"}"));
            hostGame.FromGame += (g, m) => { m.From = "Host"; relay.Broadcast(m); };
            relay.Start(port);

            var client = new Client();
            client.Received += m => clientGame.ToGame(m);
            clientGame.FromGame += (g, m) => client.Send(m);
            client.Connect("127.0.0.1", port, "Client");

            GameWrites(hostGame, "hello\tHost\t{[\"name\"]=\"Host\"}");
            GameWrites(clientGame, "det_hash\tClient\t{[\"round\"]=0,[\"parts\"]={[\"time\"]=123,[\"txt\"]=\"a\\\"b\"}}");
            File.AppendAllText(Path.Combine(clientGame.Dir, "out.log"), "act_req" + (char)9 + "Client" + (char)9 + "{}" + (char)10, new UTF8Encoding(false));
            Thread.Sleep(800);

            var hostIn = File.ReadAllText(Path.Combine(hostGame.Dir, "in.log"));
            var clientIn = File.ReadAllText(Path.Combine(clientGame.Dir, "in.log"));
            Log.W("host in.log  : " + hostIn.Replace("\n", " | "));
            Log.W("client in.log: " + clientIn.Replace("\n", " | "));
            var parsed = LuaLit.Show(LuaLit.Parse("{[\"round\"]=0,[\"parts\"]={[\"time\"]=123,[\"txt\"]=\"a\\\"b\"}}"));
            Log.W("parse: " + parsed);
            bool ok = hostIn.Contains("act_req" + (char)9 + "Client#1") && hostIn.Contains("det_hash\tClient#1\t") && clientIn.Contains("welcome\tHost") && clientIn.Contains("hello\tHost") && parsed == "{parts={time=123,txt=a\"b},round=0}";
            client.Dispose(); relay.Dispose();
            Log.W("transport: " + (ok ? "ok" : "FAILED"));
            ok &= RunServer();
            ok &= RunUpdater();
            ok &= RunPortMap();
            Log.W(ok ? "SELFTEST OK" : "SELFTEST FAILED");
            return ok ? 0 : 1;
        }

        /// <summary>Automatic update: which release of GitHub's list is taken (newest published one with a zip, the players' or
        /// the server's archive), and the files put into a folder from a release zip (the player's settings kept).</summary>
        static bool RunUpdater()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            string Asset(string name) => "{\"name\":\"" + name + "\",\"size\":10,\"digest\":\"sha256:AB\",\"browser_download_url\":\"https://github.com/x/" + name + "\"}";
            string Rel(string tag, bool draft, bool pre, params string[] assets) =>
                "{\"tag_name\":\"" + tag + "\",\"draft\":" + (draft ? "true" : "false") + ",\"prerelease\":" + (pre ? "true" : "false")
                + ",\"html_url\":\"https://github.com/x/" + tag + "\",\"assets\":[" + string.Join(",", assets) + "]}";
            var json = "[" + string.Join(",",
                Rel("0.3.20", true, false, Asset("MPFever-0.3.20.zip")),
                Rel("0.3.19", false, true, Asset("MPFever-0.3.19.zip")),
                Rel("0.3.15", false, false, Asset("MPFever-0.3.15-experimental-server.zip"), Asset("MPFever-0.3.15-experimental.zip")),
                Rel("0.3.14", false, false, Asset("MPFever-0.3.14-experimental.zip")),
                Rel("0.3.16", false, false, Asset("notes.txt"))) + "]";
            var u = Updater.Newest(json, "0.3.14-experimental");
            Check(u != null && u.Version == "0.3.15" && u.ZipUrl.EndsWith("MPFever-0.3.15-experimental.zip") && u.Sha256 == "ab",
                "update: newest published release with a zip, the players' archive (" + (u == null ? "none" : u.Version + " " + u.ZipUrl) + ")");
            var us = Updater.Newest(json, "0.3.14-experimental", true);
            Check(us != null && us.ZipUrl.EndsWith("-server.zip"), "update: a dedicated server takes the server's archive");
            Check(Updater.Newest(json, "0.3.15-experimental") == null, "update: nothing newer than 0.3.15");
            Check(Updater.CompareVersions(Updater.ParseVersion("0.3.10"), Updater.ParseVersion("0.3.9")) > 0, "update: 0.3.10 is newer than 0.3.9");
            // (from 0.3.22 the archives lose "-experimental": the older launchers must still take them)
            var json2 = "[" + Rel("0.3.22", false, false, Asset("MPFever-0.3.22-server.zip"), Asset("MPFever-0.3.22.zip")) + ","
                + Rel("0.3.21", false, false, Asset("MPFever-0.3.21-experimental-server.zip"), Asset("MPFever-0.3.21-experimental.zip")) + "]";
            var u2 = Updater.Newest(json2, "0.3.21-experimental");
            Check(u2 != null && u2.Version == "0.3.22" && u2.ZipUrl.EndsWith("/MPFever-0.3.22.zip"), "update: 0.3.21-experimental takes MPFever-0.3.22.zip");
            var us2 = Updater.Newest(json2, "0.3.21-experimental", true);
            Check(us2 != null && us2.ZipUrl.EndsWith("/MPFever-0.3.22-server.zip"), "update: a 0.3.21-experimental server takes MPFever-0.3.22-server.zip");
            Check(Updater.Newest(json2, "0.3.22") == null, "update: nothing newer than 0.3.22");

            var root = Path.Combine(Path.GetTempPath(), "mpfever_selftest_update_" + System.Diagnostics.Process.GetCurrentProcess().Id);
            try
            {
                if (Directory.Exists(root)) Directory.Delete(root, true);
                var app = Path.Combine(root, "app");
                Directory.CreateDirectory(Path.Combine(app, "mod", "mpfever_1", "old"));
                File.WriteAllText(Path.Combine(app, "MPFever.exe"), "old");
                File.WriteAllText(Path.Combine(app, "mpfever_settings.txt"), "name=me");
                File.WriteAllText(Path.Combine(app, "mod", "mpfever_1", "old", "gone.lua"), "x");
                var zip = Path.Combine(root, "u.zip");
                using (var z = System.IO.Compression.ZipFile.Open(zip, System.IO.Compression.ZipArchiveMode.Create))
                {
                    void Add(string name, string text) { using (var w = new StreamWriter(z.CreateEntry(name).Open())) w.Write(text); }
                    Add("MPFever/MPFever.exe", "new");
                    Add("MPFever/mpfever_settings.txt", "name=default");
                    Add("MPFever/mod/mpfever_1/mod.json", "{}");
                }
                var files = Path.Combine(root, "files");
                Updater.Unpack(zip, files);
                Updater.Install(files, app);
                Check(File.ReadAllText(Path.Combine(app, "MPFever.exe")) == "new", "update: files replaced");
                Check(File.ReadAllText(Path.Combine(app, "mpfever_settings.txt")) == "name=me", "update: the player's settings kept");
                Check(File.Exists(Path.Combine(app, "mod", "mpfever_1", "mod.json")) && !Directory.Exists(Path.Combine(app, "mod", "mpfever_1", "old")),
                    "update: the mod folder replaced as a whole");
            }
            catch (Exception e) { Check(false, "update: " + e.Message); }
            finally { try { Directory.Delete(root, true); } catch { } }
            return ok;
        }

        /// <summary>Port mapping: a router's description read, and the SOAP requests a fake router on this PC receives.</summary>
        static bool RunPortMap()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }
            var desc = "<root><URLBase>http://192.168.1.1:5000/</URLBase><device><serviceList>"
                + "<service><serviceType>urn:schemas-upnp-org:service:Layer3Forwarding:1</serviceType><controlURL>/l3f</controlURL></service>"
                + "<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>/ctl/IPConn</controlURL></service>"
                + "</serviceList></device></root>";
            var igd = PortMap.FromDescription("http://192.168.1.1:5000/rootDesc.xml", desc);
            Check(igd != null && igd.ControlUrl == "http://192.168.1.1:5000/ctl/IPConn" && igd.ServiceType.EndsWith("WANIPConnection:1"), "upnp: WAN connection service of a description");
            Check(PortMap.ProblemOf("100.72.3.4") != null && PortMap.ProblemOf("192.168.0.2") != null && PortMap.ProblemOf("82.64.10.20") == null, "upnp: CGNAT and private router addresses recognised");

            // a fake router: answers every SOAP request, keeps what it was asked
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var asked = new List<string>();
            var server = new Thread(() =>
            {
                try
                {
                    for (int i = 0; i < 3; i++)
                    {
                        using (var c = listener.AcceptTcpClient())
                        using (var st = c.GetStream())
                        {
                            var buf = new byte[8192]; int n = 0; string text = "";
                            st.ReadTimeout = 3000;
                            // (headers, then the body announced by Content-Length)
                            while (true)
                            {
                                int k = st.Read(buf, n, buf.Length - n); if (k <= 0) break; n += k;
                                text = Encoding.UTF8.GetString(buf, 0, n);
                                int he = text.IndexOf("\r\n\r\n", StringComparison.Ordinal);
                                if (he < 0) continue;
                                var cl = System.Text.RegularExpressions.Regex.Match(text, @"Content-Length:\s*(\d+)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                                if (!cl.Success || n - he - 4 >= int.Parse(cl.Groups[1].Value)) break;
                            }
                            lock (asked) asked.Add(text);
                            var body = text.Contains("GetExternalIPAddress") ? "<NewExternalIPAddress>100.80.1.2</NewExternalIPAddress>" : "<ok/>";
                            var resp = "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\nContent-Length: " + body.Length + "\r\nConnection: close\r\n\r\n" + body;
                            var rb = Encoding.UTF8.GetBytes(resp);
                            st.Write(rb, 0, rb.Length);
                        }
                    }
                }
                catch { }
            }) { IsBackground = true };
            server.Start();
            var fake = new PortMap.Igd { Host = "127.0.0.1", ControlUrl = "http://127.0.0.1:" + port + "/ctl/IPConn", ServiceType = "urn:schemas-upnp-org:service:WANIPConnection:1" };
            string ext = null;
            try
            {
                ext = fake.ExternalAddress();
                fake.AddMapping(28190, "192.168.1.20");
                fake.DeleteMapping(28190);
            }
            catch (Exception e) { Check(false, "upnp: SOAP " + e.Message); }
            server.Join(5000);
            listener.Stop();
            string all; lock (asked) all = string.Join("\n----\n", asked);
            Check(ext == "100.80.1.2", "upnp: the router's public address read (" + ext + ")");
            Check(all.Contains("SOAPAction: \"urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping\"") && all.Contains("<NewExternalPort>28190</NewExternalPort>")
                && all.Contains("<NewInternalClient>192.168.1.20</NewInternalClient>") && all.Contains("<NewProtocol>TCP</NewProtocol>"), "upnp: AddPortMapping sent as a router expects it");
            Check(all.Contains("#DeletePortMapping\""), "upnp: the mapping removed");
            return ok;
        }

        /// <summary>Dedicated server: its settings file, and who its relay lets in (password, version, places), over TCP.</summary>
        static bool RunServer()
        {
            bool ok = true;
            void Check(bool cond, string what) { Log.W((cond ? "  ok    " : "  FAIL  ") + what); ok &= cond; }

            // 1. the settings: the file written the first time reads back as the defaults; values, and lines that are ignored
            var dir = Path.Combine(Path.GetTempPath(), "mpfever-selftest-" + Guid.NewGuid().ToString("N").Substring(0, 6));
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, ServerConfig.FileName);
            var problems = new List<string>();
            var c = ServerConfig.Load(path, problems, out bool created);
            Check(created && problems.Count == 0 && c.Port == 28090 && c.World == "" && c.Password == "" && c.MaxPlayers == 8
                  && c.CompanyMode == "shared" && c.PauseWhenEmpty && c.AutosaveMinutes == 10 && c.RestartOnCrash, "settings: template = defaults");
            File.WriteAllText(path, "# comment\nworld=My Map 2\nport=28100\npassword=s3cr#t = x\nmax-players=1\ncompany-mode=separate\nowner=Lena\n"
                + "start-speed=3\nwatchdog-seconds=5\nstart-money=abc\npause-when-empty=no\nbogus\n", new UTF8Encoding(false));
            problems.Clear();
            c = ServerConfig.Load(path, problems, out created);
            Check(!created && c.World == "My Map 2" && c.Port == 28100 && c.Password == "s3cr#t = x" && c.MaxPlayers == 1 && c.CompanyMode == "separate"
                  && c.Owner == "Lena" && c.StartSpeed == 1 && c.WatchdogSeconds == 30 && c.StartMoney == 2000000 && !c.PauseWhenEmpty && problems.Count == 3,
                  "settings: values, " + problems.Count + " line(s) ignored");
            try { Directory.Delete(dir, true); } catch { }

            // 2. who comes in
            int port = 28192;
            var relay = new Relay();
            relay.Admit = (p, m) => c.Admission(m.Payload, MainForm.OthersConnected(relay, p), out _);
            relay.Start(port);

            Dictionary<object, object> Join(string name, string pw, out Client cl, out List<Msg> got)
            {
                Dictionary<object, object> denied = null;
                var closed = new ManualResetEvent(false);
                var list = new List<Msg>();
                cl = new Client();
                cl.Denied += d => denied = d;
                cl.Closed += () => closed.Set();
                cl.Received += m => { lock (list) list.Add(m); };
                cl.Connect("127.0.0.1", port, name, pw);
                closed.WaitOne(1500);
                got = list;
                return denied;
            }
            string Reason(Dictionary<object, object> d) => d != null && d.TryGetValue("reason", out var r) ? r as string : null;

            var d1 = Join("Lena", "wrong", out var c1, out _);
            Check(Reason(d1) == "password", "wrong password refused (" + Reason(d1) + ")");
            var d2 = Join("Lena", null, out var c2, out _);
            Check(Reason(d2) == "password", "missing password refused (" + Reason(d2) + ")");

            // an older MPFever (no version in its join) is refused
            string oldReply = null;
            using (var raw = new TcpClient("127.0.0.1", port))
            {
                var w = new StreamWriter(raw.GetStream(), new UTF8Encoding(false)) { NewLine = "\n", AutoFlush = true };
                w.WriteLine("join\tOld\t{}");
                raw.ReceiveTimeout = 1500;
                try { oldReply = new StreamReader(raw.GetStream()).ReadLine(); } catch { }
            }
            Check(oldReply != null && oldReply.StartsWith("denied\t") && oldReply.Contains("\"version\""), "other version refused (" + oldReply + ")");

            var d3 = Join("Lena", "s3cr#t = x", out var lena, out var lenaGot);
            Check(d3 == null && relay.AdmittedCount == 1, "right password let in");
            var d4 = Join("Max", "s3cr#t = x", out var c4, out _);
            Check(Reason(d4) == "full" && relay.AdmittedCount == 1, "server full (" + Reason(d4) + ")");

            // the same player coming back (a reconnection) keeps its place
            var d5 = Join("lena", "s3cr#t = x", out var lena2, out _);
            Check(d5 == null, "reconnection of a player keeps its place");
            lena2.Dispose();
            Thread.Sleep(300);

            // a connection not let in gets nothing of the session
            using (var idle = new TcpClient("127.0.0.1", port))
            {
                Thread.Sleep(200);
                relay.Broadcast(Msg.Make("session", "Server", "{[\"started\"]=true}"));
                Thread.Sleep(400);
                idle.ReceiveTimeout = 300;
                bool leaked = false;
                try { leaked = idle.GetStream().ReadByte() >= 0; } catch { }
                bool lenaGets; lock (lenaGot) lenaGets = lenaGot.Any(m => m.Kind == "session");
                Check(!leaked && lenaGets, "broadcast: to the players let in only");
            }

            // kicked: told why, and not reconnected
            Dictionary<object, object> kicked = null;
            var gone = new ManualResetEvent(false);
            lena.Denied += d => kicked = d;
            lena.Closed += () => gone.Set();
            int n = relay.Kick("lena", "{[\"reason\"]=\"kicked\"}");
            gone.WaitOne(2000);
            Check(n == 1 && Reason(kicked) == "kicked", "kick");
            Check(MainForm.DeniedText(new Dictionary<object, object> { ["reason"] = "full", ["max"] = 8.0 }).Contains("8"), "refusal told to the player");

            foreach (var x in new[] { c1, c2, lena, c4 }) x.Dispose();
            relay.Dispose();
            return ok;
        }
    }
}
