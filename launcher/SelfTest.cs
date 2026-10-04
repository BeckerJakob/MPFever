using System;
using System.IO;
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
            var hostGame = new GameLink("Hote", "host");
            var clientGame = new GameLink("Client", "client");
            relay.Received += (p, m) => hostGame.ToGame(m);
            relay.Joined += p => relay.Send(p, Msg.Make("welcome", "Hote", "{[\"you\"]=\"" + p.Name + "\"}"));
            hostGame.FromGame += (g, m) => { m.From = "Hote"; relay.Broadcast(m); };
            relay.Start(port);

            var client = new Client();
            client.Received += m => clientGame.ToGame(m);
            clientGame.FromGame += (g, m) => client.Send(m);
            client.Connect("127.0.0.1", port, "Client");

            GameWrites(hostGame, "hello\tHote\t{[\"name\"]=\"Hote\"}");
            GameWrites(clientGame, "det_hash\tClient\t{[\"round\"]=0,[\"parts\"]={[\"time\"]=123,[\"txt\"]=\"a\\\"b\"}}");
            File.AppendAllText(Path.Combine(clientGame.Dir, "out.log"), "act_req" + (char)9 + "Client" + (char)9 + "{}" + (char)10, new UTF8Encoding(false));
            Thread.Sleep(800);

            var hostIn = File.ReadAllText(Path.Combine(hostGame.Dir, "in.log"));
            var clientIn = File.ReadAllText(Path.Combine(clientGame.Dir, "in.log"));
            Log.W("host in.log  : " + hostIn.Replace("\n", " | "));
            Log.W("client in.log: " + clientIn.Replace("\n", " | "));
            var parsed = LuaLit.Show(LuaLit.Parse("{[\"round\"]=0,[\"parts\"]={[\"time\"]=123,[\"txt\"]=\"a\\\"b\"}}"));
            Log.W("parse: " + parsed);
            bool ok = hostIn.Contains("act_req" + (char)9 + "Client#1") && hostIn.Contains("det_hash\tClient#1\t") && clientIn.Contains("welcome\tHote") && clientIn.Contains("hello\tHote") && parsed == "{parts={time=123,txt=a\"b},round=0}";
            Log.W(ok ? "SELFTEST OK" : "SELFTEST FAILED");
            client.Dispose(); relay.Dispose();
            return ok ? 0 : 1;
        }
    }
}
