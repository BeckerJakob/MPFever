using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
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
            Log.W(ok ? "SELFTEST OK" : "SELFTEST FAILED");
            return ok ? 0 : 1;
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
