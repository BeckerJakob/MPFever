using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading;
using System.Windows.Forms;
using static MPFever.L;

namespace MPFever
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--selftest")
            {
                Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
                Log.Line += l => Console.WriteLine(l);
                return SelfTest.Run();
            }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Log.Init(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "logs"));
            bool auto = args.Length > 0 && args[0] == "--autotest";
            MainForm.Dev = auto || args.Contains("--dev");
            if (auto) GameLink.AutoSave = args.Length > 1 ? args[1] : "test multi";
            Application.Run(new MainForm(auto));
            return 0;
        }
    }

    sealed class MainForm : Form
    {
        public const string Version = "0.1.0-experimental";
        /// <summary>Developer mode (MPFever.exe --dev): local two-game test and determinism test buttons.</summary>
        public static bool Dev;
        const long Step = 200;                 // game time units per simulation step
        const double UnitsPerSecond = 1000;    // game time units per real second at x1
        const double HashEverySeconds = 10;

        readonly TextBox nameBox = new TextBox { Text = Environment.UserName, Width = 140 };
        readonly TextBox hostBox = new TextBox { Text = "127.0.0.1", Width = 140 };
        readonly NumericUpDown portBox = new NumericUpDown { Minimum = 1024, Maximum = 65535, Value = 28090, Width = 70 };
        readonly Button hostBtn = new Button { Text = T("Héberger", "Host"), AutoSize = true };
        readonly Button joinBtn = new Button { Text = T("Rejoindre par IP", "Join by IP"), AutoSize = true };
        readonly Button localBtn = new Button { Text = T("Test local (2 jeux)", "Local test (2 games)"), AutoSize = true };
        readonly Button startBtn = new Button { Text = T("▶ Démarrer la partie", "▶ Start the game"), AutoSize = true, Enabled = false };
        readonly Button pauseBtn = new Button { Text = "Pause", AutoSize = true, Enabled = false };
        readonly Button x1Btn = new Button { Text = "x1", AutoSize = true, Enabled = false };
        readonly Button x2Btn = new Button { Text = "x2", AutoSize = true, Enabled = false };
        readonly Button x4Btn = new Button { Text = "x4", AutoSize = true, Enabled = false };
        readonly Button detBtn = new Button { Text = T("Test déterminisme", "Determinism test"), AutoSize = true, Enabled = false };
        readonly TextBox logBox = new TextBox { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill, Font = new Font("Consolas", 9f), BackColor = Color.White };
        readonly Label status = new Label { AutoSize = true, Text = T("Prêt.", "Ready."), Font = new Font("Segoe UI", 10f, FontStyle.Bold), Padding = new Padding(0, 4, 0, 0) };

        string gameDir;
        Relay relay;
        readonly List<GameLink> games = new List<GameLink>();
        readonly List<Client> clients = new List<Client>();
        string hostName;
        GameLink hostGame;
        bool running;

        // ---- host session state
        readonly object sendGate = new object();   // every host broadcast goes through this lock: same order for everybody
        readonly object sessionGate = new object();
        readonly Stopwatch clockWatch = Stopwatch.StartNew();
        sealed class PlayerClock { public long T; public int Sp; public double At; }
        readonly Dictionary<string, PlayerClock> clocks = new Dictionary<string, PlayerClock>();
        readonly HashSet<string> players = new HashSet<string>();
        bool started;
        int speed;            // session speed
        long? pauseAt;        // session paused at this game time
        long actSeq;
        int hashN;
        readonly Dictionary<int, Dictionary<string, Dictionary<object, object>>> hashes = new Dictionary<int, Dictionary<string, Dictionary<object, object>>>();
        string syncText = "—";
        int actsRelayed, actRefused, actFails, desyncs;
        volatile bool detRunning;

        // ---- determinism test
        readonly object detGate = new object();
        Dictionary<string, Dictionary<object, object>> detHashes;
        int detRound = -1;

        // ---- host authority: resynchronisation by the host's savegame
        const double ResyncCooldownSeconds = 120;   // at most one resynchronisation every 2 minutes
        const string ResyncSaveName = "MPFever resync";
        const int ResyncChunk = 256 * 1024;
        volatile bool resyncing;
        double lastResync = -1e9;
        int resyncId;
        readonly HashSet<string> resyncWaiting = new HashSet<string>();
        Dictionary<object, object> saveDone;
        string lastDiffKeys = "";
        int diffStreak;
        int postResyncHashN = -1;
        readonly HashSet<string> ignoredParts = new HashSet<string>();
        // parts every game corrects by itself from the host's values (not a reason to reload)
        static readonly HashSet<string> CorrectedParts = new HashSet<string> { "money" };

        readonly bool autotest;
        readonly List<string> autoReport = new List<string>();
        readonly Dictionary<string, string> autoDone = new Dictionary<string, string>();

        public MainForm(bool autotest = false)
        {
            this.autotest = autotest;
            Text = "MPFever " + Version + T(" – multijoueur Transport Fever 3 (expérimental)", " – Transport Fever 3 multiplayer (experimental)");
            Width = 1150; Height = 680;
            StartPosition = FormStartPosition.CenterScreen;

            var row1 = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 36, Padding = new Padding(6, 6, 6, 0) };
            row1.Controls.AddRange(new Control[] {
                new Label { Text = T("Nom :", "Name:"), AutoSize = true, Padding = new Padding(0, 6, 0, 0) }, nameBox,
                new Label { Text = T("Hôte :", "Host:"), AutoSize = true, Padding = new Padding(8, 6, 0, 0) }, hostBox,
                new Label { Text = T("Port :", "Port:"), AutoSize = true, Padding = new Padding(8, 6, 0, 0) }, portBox,
                hostBtn, joinBtn, localBtn });
            var row2 = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 36, Padding = new Padding(6, 2, 6, 0) };
            row2.Controls.AddRange(new Control[] { startBtn, pauseBtn, x1Btn, x2Btn, x4Btn, detBtn, status });
            localBtn.Visible = Dev;
            detBtn.Visible = Dev;
            Controls.Add(logBox);
            Controls.Add(row2);
            Controls.Add(row1);

            Log.Line += l => { try { BeginInvoke((Action)(() => logBox.AppendText(l + Environment.NewLine))); } catch { } };

            hostBtn.Click += (s, e) => Guard(() => StartHost(PlayerName(), true));
            joinBtn.Click += (s, e) => Guard(() => StartClient(PlayerName(), hostBox.Text.Trim(), (int)portBox.Value, true));
            localBtn.Click += (s, e) => Guard(StartLocalTest);
            startBtn.Click += (s, e) => StartSession();
            pauseBtn.Click += (s, e) => Pause(T("hôte", "host"));
            x1Btn.Click += (s, e) => SetSpeed(1, T("hôte", "host"));
            x2Btn.Click += (s, e) => SetSpeed(2, T("hôte", "host"));
            x4Btn.Click += (s, e) => SetSpeed(4, T("hôte", "host"));
            detBtn.Click += (s, e) => new Thread(RunDeterminism) { IsBackground = true }.Start();

            Shown += (s, e) => Init();
            var uiTimer = new System.Windows.Forms.Timer { Interval = 500 };
            uiTimer.Tick += (s, e) => RefreshStatus();
            uiTimer.Start();
        }

        string PlayerName() => string.IsNullOrWhiteSpace(nameBox.Text) ? "joueur" : nameBox.Text.Trim();
        double Now => clockWatch.Elapsed.TotalSeconds;

        void Guard(Action a)
        {
            if (running) { Log.W(T("Une session est déjà en cours : relancer MPFever pour en ouvrir une autre.", "A session is already running: restart MPFever to open another one.")); return; }
            try { a(); running = true; hostBtn.Enabled = joinBtn.Enabled = localBtn.Enabled = false; }
            catch (Exception e) { Log.W(T("Erreur : ", "Error: ") + e.Message); MessageBox.Show(this, e.Message, "MPFever", MessageBoxButtons.OK, MessageBoxIcon.Error); }
        }

        void Init()
        {
            gameDir = GameInstall.FindGameDir();
            if (gameDir == null) { Log.W(T("Transport Fever 3 introuvable.", "Transport Fever 3 not found.")); status.Text = T("Jeu introuvable", "Game not found"); return; }
            Log.W(T("Jeu : ", "Game: ") + gameDir);
            try { GameInstall.EnsureSteamAppId(gameDir); } catch (Exception e) { Log.W("steam_appid.txt : " + e.Message); }
            try { GameInstall.InstallNative(gameDir); } catch (Exception e) { Log.W("winhttp.dll: " + e.Message); }
            try { GameInstall.EnsureModActive(); } catch (Exception e) { Log.W("settings.lua: " + e.Message); }
            try { GameInstall.InstallMod(); } catch (Exception e) { Log.W(T("Installation du mod : ", "Mod installation: ") + e.Message); }
            if (autotest)
            {
                Guard(StartLocalTest);
                new Thread(AutoTest) { IsBackground = true, Name = "Autotest" }.Start();
            }
        }

        // ---------------------------------------------------------------- autotest (MPFever.exe --autotest [savegame])

        void AutoLine(string s) { lock (autoReport) autoReport.Add(s); Log.W("AUTOTEST " + s); }

        bool WaitUntil(Func<bool> cond, double seconds)
        {
            var end = Now + seconds;
            while (Now < end) { if (cond()) return true; Thread.Sleep(500); }
            return cond();
        }

        void AutoTest()
        {
            try
            {
                AutoLine("savegame: " + GameLink.AutoSave);
                bool ready = WaitUntil(() =>
                {
                    int n; lock (players) n = players.Count;
                    lock (clocks) return n >= 2 && clocks.Count >= 2 && clocks.Values.Select(c => c.T).Distinct().Count() == 1;
                }, 600);
                if (!ready) { AutoLine("FAILED: the two games did not get ready with the same save"); return; }
                AutoLine("both games ready");
                Thread.Sleep(3000);
                StartSession();
                Thread.Sleep(8000);
                var scenarios = (Environment.GetEnvironmentVariable("MPFEVER_SCENARIO") ?? "newroad,upgrade").Split(',');
                foreach (var scenario in scenarios)
                foreach (var role in new[] { "host", "client" })
                {
                    lock (autoDone) autoDone.Remove(role);
                    AutoLine("scenario " + scenario + " by " + role);
                    HostSend(Msg.Make(scenario, hostName, "{[\"role\"]=\"" + role + "\",[\"offset\"]=" + (role == "host" ? 0 : 7) + (role == "host" ? ",[\"ab\"]=true" : "") + "}"));
                    bool done = WaitUntil(() => { lock (autoDone) return autoDone.ContainsKey(role); }, 180);
                    lock (autoDone) AutoLine(role + " scenario: " + (done ? autoDone[role] : "TIMEOUT"));
                    Thread.Sleep(5000);
                }
                Thread.Sleep(5000);
                RequestHash();
                Thread.Sleep(12000);
                HostSend(Msg.Make("area_dump", hostName, "{}"));
                Thread.Sleep(10000);
                AutoLine("sync: " + syncText + " (desyncs " + desyncs + ", refused " + actRefused + ")");
            }
            catch (Exception e) { AutoLine("ERROR " + e); }
            finally
            {
                AutoLine("sessions: " + string.Join(" ; ", games.Select(g => g.Dir)));
                try { File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "autotest_result.txt"), autoReport); } catch { }
                foreach (var g in games) g.Kill();
                Thread.Sleep(1000);
                Environment.Exit(0);
            }
        }

        void RefreshStatus()
        {
            if (relay == null) { if (clients.Count > 0) status.Text = T("Client connecté", "Connected to the host"); return; }
            int n; lock (players) n = players.Count;
            string sp; lock (sessionGate) sp = pauseAt.HasValue ? T("pause", "paused") : "x" + speed;
            string spread = "";
            lock (clocks) if (clocks.Count > 1) { var est = clocks.Values.Select(Estimate).ToList(); spread = $" · écart {(est.Max() - est.Min()) / Step} pas"; }
            status.Text = started
                ? T($"{sp} · {n} jeu(x){spread} · actions {actsRelayed} (refus {actRefused}, échecs {actFails}) · {syncText}",
                    $"{sp} · {n} game(s){spread} · actions {actsRelayed} (refused {actRefused}, failed {actFails}) · {syncText}")
                : T($"{n} jeu(x) prêt(s) – chargez la même sauvegarde partout puis « Démarrer »",
                    $"{n} game(s) ready – load the same savegame everywhere, then « Start »");
            startBtn.Enabled = !started;
            pauseBtn.Enabled = x1Btn.Enabled = x2Btn.Enabled = x4Btn.Enabled = started;
            detBtn.Enabled = true;
        }

        // ---------------------------------------------------------------- sessions

        void StartHost(string name, bool launch)
        {
            hostName = name;
            relay = new Relay();
            relay.Joined += p =>
            {
                Log.W(T($"{p.Name} a rejoint la session", $"{p.Name} joined the session"));
                relay.Send(p, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(p.Name) + ",[\"role\"]=\"client\"}"));
                BroadcastSession();
            };
            relay.Left += p =>
            {
                Log.W(T($"{p.Name} a quitté la session", $"{p.Name} left the session"));
                lock (players) players.Remove(p.Name);
                lock (clocks) clocks.Remove(p.Name);
                HostSend(Msg.Make("peerleft", hostName, "{[\"name\"]=" + LuaLit.Quote(p.Name) + "}"));
            };
            relay.Received += (p, m) => OnHostMessage(m, p);
            relay.Start((int)portBox.Value);

            hostGame = new GameLink(name, "host");
            games.Add(hostGame);
            hostGame.FromGame += (g, m) =>
            {
                m.From = hostName;
                if (m.Kind == "hello")
                {
                    g.ToGame(Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(hostName) + ",[\"role\"]=\"host\"}"));
                    BroadcastSession();
                }
                OnHostMessage(m, null);
            };
            if (launch) hostGame.Launch(gameDir);
            new Thread(HostLoop) { IsBackground = true, Name = "Host loop" }.Start();
        }

        void StartClient(string name, string host, int port, bool launch)
        {
            var client = new Client();
            var game = new GameLink(name, "client");
            games.Add(game);
            clients.Add(client);
            client.Received += m =>
            {
                if (m.Kind == "resync_file") { OnResyncFile(game, m); return; }
                game.ToGame(m);
                if (m.Kind == "act") Log.W(T($"[{name}] reçu {m.Kind} de {m.From}", $"[{name}] received {m.Kind} from {m.From}"));
            };
            client.Closed += () => { Log.W(T($"[{name}] connexion à l'hôte perdue", $"[{name}] connection to the host lost")); game.ToGame(Msg.Make("session", "MPFever", "{[\"started\"]=false,[\"speed\"]=0}")); };
            game.FromGame += (g, m) => client.Send(m);
            client.Connect(host, port, name);
            if (launch) game.Launch(gameDir);
        }

        void StartLocalTest()
        {
            StartHost("Hote", true);
            Log.W(T("Lancement du second jeu dans 20 s...", "Starting the second game in 20 s..."));
            var t = new System.Windows.Forms.Timer { Interval = autotest ? 8000 : 20000 };
            t.Tick += (s, e) =>
            {
                t.Stop();
                try { StartClient("Client", "127.0.0.1", (int)portBox.Value, true); }
                catch (Exception ex) { Log.W(T("Client local : ", "Local client: ") + ex.Message); }
            };
            t.Start();
            Log.W(T("Chargez LA MÊME sauvegarde dans les deux jeux, puis cliquez sur « Démarrer la partie ».", "Load THE SAME savegame in both games, then click « Start the game »."));
        }

        /// <summary>Every host broadcast goes through here so that all games receive messages in the same order.</summary>
        void HostSend(Msg m)
        {
            lock (sendGate)
            {
                hostGame?.ToGame(m);
                relay?.Broadcast(m);
            }
        }

        // ---------------------------------------------------------------- clock and stamps

        double Estimate(PlayerClock c) => c.T + (Now - c.At) * c.Sp * UnitsPerSecond;

        long MaxClock()
        {
            lock (clocks) return clocks.Count == 0 ? 0 : (long)clocks.Values.Max(Estimate);
        }

        static long RoundUpToStep(double t) => (long)Math.Ceiling(t / Step) * Step;

        /// <summary>A stamp every game reaches after receiving the message: ahead of the fastest clock.</summary>
        long FutureStamp()
        {
            int sp; lock (sessionGate) sp = Math.Max(1, speed);
            return RoundUpToStep(MaxClock() + Step * (4 + 2 * sp));
        }

        string SessionPayload()
        {
            lock (sessionGate)
                return "{[\"started\"]=" + (started ? "true" : "false") + ",[\"speed\"]=" + speed +
                       (pauseAt.HasValue ? ",[\"pauseAt\"]=" + pauseAt.Value : "") + "}";
        }

        void BroadcastSession() => HostSend(Msg.Make("session", hostName ?? "hote", SessionPayload()));

        void StartSession()
        {
            List<long> times; int n;
            lock (clocks) times = clocks.Values.Select(c => c.T).Distinct().ToList();
            lock (players) n = players.Count;
            if (n < 1) { Log.W(T("Aucun jeu prêt.", "No game is ready.")); return; }
            if (times.Count > 1) { Log.W(T("Les jeux ne sont pas au même temps (", "The games are not at the same time (") + string.Join(", ", times) + T(") : chargez exactement la même sauvegarde partout.", "): load exactly the same savegame everywhere.")); return; }
            lock (sessionGate) { started = true; speed = 0; pauseAt = times.Count == 1 ? times[0] : (long?)null; }
            Log.W(T($"=== Partie démarrée avec {n} jeu(x) au temps {times.FirstOrDefault()} : vérification initiale... ===", $"=== Game started with {n} game(s) at time {times.FirstOrDefault()}: initial check... ==="));
            BroadcastSession();
            // every game just loaded the same savegame: a part already different now is a local measure
            postResyncHashN = hashN + 1;
            RequestHash();
            new Thread(() => { Thread.Sleep(1500); SetSpeed(1, T("démarrage", "start")); }) { IsBackground = true }.Start();
        }

        void SetSpeed(int s, string who)
        {
            if (!started) return;
            lock (sessionGate) { speed = Math.Max(1, Math.Min(4, s)); pauseAt = null; }
            Log.W(T($"Vitesse : x{speed} (demandée par {who})", $"Speed: x{speed} (asked by {who})"));
            BroadcastSession();
        }

        void Pause(string who)
        {
            if (!started) return;
            long at = FutureStamp();
            lock (sessionGate) pauseAt = at;
            Log.W(T($"Pause au temps {at} (demandée par {who})", $"Pause at time {at} (asked by {who})"));
            BroadcastSession();
        }

        void RequestHash()
        {
            int n = Interlocked.Increment(ref hashN);
            lock (hashes) hashes[n] = new Dictionary<string, Dictionary<object, object>>();
            long? p; lock (sessionGate) p = pauseAt;
            if (p.HasValue && MaxClock() >= p.Value)
                HostSend(Msg.Make("hash", hostName, "{[\"n\"]=" + n + ",[\"at\"]=" + p.Value + ",[\"paused\"]=true}"));
            else
                HostSend(Msg.Make("hash", hostName, "{[\"n\"]=" + n + ",[\"at\"]=" + FutureStamp() + "}"));
        }

        void HostLoop()
        {
            double lastHash = Now, lastSession = Now;
            while (true)
            {
                Thread.Sleep(250);
                if (hostGame == null) continue;
                PlayerClock hc;
                lock (clocks) clocks.TryGetValue(hostName, out hc);

                if (Now - lastSession > 3) { lastSession = Now; BroadcastSession(); }   // late joiners and lost messages
                bool paused; lock (sessionGate) paused = pauseAt.HasValue;
                if (started && !paused && !detRunning && !resyncing && Now - lastHash > HashEverySeconds) { lastHash = Now; RequestHash(); }
            }
        }

        // ---------------------------------------------------------------- host-side message handling

        void OnHostMessage(Msg m, Peer from)
        {
            switch (m.Kind)
            {
                case "hello":
                    lock (players) players.Add(m.From);
                    Log.W(T($"{m.From} : jeu prêt {m.Payload}", $"{m.From}: game ready {m.Payload}"));
                    // a game started again (resynchronisation): it needs its identity again
                    if (from != null) relay.Send(from, Msg.Make("welcome", hostName, "{[\"you\"]=" + LuaLit.Quote(from.Name) + ",[\"role\"]=\"client\"}"));
                    lock (resyncWaiting) resyncWaiting.Remove(m.From);
                    break;

                case "save_done":
                    saveDone = LuaLit.Parse(m.Payload) as Dictionary<object, object> ?? new Dictionary<object, object>();
                    Log.W(T($"{m.From} : sauvegarde de resynchronisation terminée {m.Payload}", $"{m.From}: resynchronisation save done {m.Payload}"));
                    break;

                case "clock":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        if (t != null && t.TryGetValue("t", out var tv) && tv is double td)
                        {
                            int sp = t.TryGetValue("sp", out var sv) && sv is double sd ? (int)sd : 0;
                            lock (clocks) clocks[m.From] = new PlayerClock { T = (long)td, Sp = sp, At = Now };
                            // every other game uses it as a barrier: none may run past the slowest player
                            int ah = t.TryGetValue("ah", out var av) && av is double ad ? (int)ad : 3;
                            var pc = Msg.Make("peerclock", hostName, "{[\"name\"]=" + LuaLit.Quote(m.From) + ",[\"t\"]=" + (long)td + ",[\"ah\"]=" + ah + "}");
                            lock (sendGate)
                            {
                                if (from != null) hostGame?.ToGame(pc);
                                relay.Broadcast(pc, from);
                            }
                        }
                        break;
                    }

                case "act":
                    {
                        // already stamped by its originator: relay it, in order, to every other game
                        lock (sendGate)
                        {
                            if (from != null) hostGame?.ToGame(m);
                            relay.Broadcast(m, from);
                        }
                        actsRelayed++;
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string fn = t != null && t.TryGetValue("fn", out var f) ? f.ToString() : "?";
                        string at = t != null && t.TryGetValue("at", out var a) ? LuaLit.Show(a) : "?";
                        string native = t != null && t.ContainsKey("native") ? T(" (construction native)", " (native build)") : "";
                        Log.W(T($"Action {fn} de {m.From} au temps {at}{native} ({m.Payload.Length} octets)", $"Action {fn} by {m.From} at time {at}{native} ({m.Payload.Length} bytes)"));
                        break;
                    }

                case "act_fail":
                    actFails++;
                    Log.W(T($"ATTENTION {m.From} : action non retransmise {m.Payload}", $"WARNING {m.From}: action not relayed {m.Payload}"));
                    break;

                case "act_refused":
                    actRefused++;
                    Log.W(T($"{m.From} : action refusée par le moteur {m.Payload}", $"{m.From}: action refused by the engine {m.Payload}"));
                    break;

                case "speed_req":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        if (t != null && t.TryGetValue("speed", out var sv) && sv is double d)
                        {
                            if (!started) { Log.W(T($"{m.From} demande la vitesse {d} : la partie n'est pas démarrée", $"{m.From} asks for speed {d}: the game is not started")); break; }
                            // a request for the speed already in effect changes nothing (and must not echo back)
                            bool same; lock (sessionGate) same = d > 0 && !pauseAt.HasValue && (int)d == speed || d <= 0 && pauseAt.HasValue;
                            if (same) break;
                            if (d <= 0) Pause(m.From); else SetSpeed((int)d, m.From);
                        }
                        break;
                    }

                case "sync_hash":
                    OnSyncHash(m);
                    break;

                case "autotest_done":
                    {
                        lock (sendGate)
                        {
                            if (from != null) hostGame?.ToGame(m);
                            relay.Broadcast(m, from);
                        }
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        string role = t != null && t.TryGetValue("role", out var r) ? r.ToString() : "?";
                        lock (autoDone) autoDone[role] = m.Payload;
                        break;
                    }

                case "det_hash":
                    {
                        var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
                        lock (detGate)
                        {
                            if (t != null && detHashes != null && t.TryGetValue("round", out var r) && r is double rd && (int)rd == detRound)
                            {
                                detHashes[m.From] = t.TryGetValue("parts", out var parts) ? parts as Dictionary<object, object> : null;
                                Monitor.PulseAll(detGate);
                            }
                        }
                        break;
                    }

                default:
                    lock (sendGate)
                    {
                        if (from != null) hostGame?.ToGame(m);
                        relay.Broadcast(m, from);
                    }
                    if (m.Kind != "chat") Log.W($"{m.From} : {m.Kind} {m.Payload}");
                    break;
            }
        }

        // a difference line is "name: values"; names may contain ':' themselves (script:mission)
        static string DiffKey(string d) { int i = d.IndexOf(": ", StringComparison.Ordinal); return i < 0 ? d : d.Substring(0, i); }

        void OnSyncHash(Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null || !t.TryGetValue("n", out var nv) || !(nv is double nd)) return;
            int n = (int)nd;
            var parts = t.TryGetValue("parts", out var p) ? p as Dictionary<object, object> : null;
            if (t.TryGetValue("cost", out var cost) && cost is double c && c > 0.1) Log.W(T($"{m.From} : empreinte coûteuse ({c:0.00} s)", $"{m.From}: expensive checksum ({c:0.00} s)"));
            // host authority: the host's values at this checkpoint go to every other game, which corrects itself
            if (m.From == hostName && t.TryGetValue("auth", out var av) && av is Dictionary<object, object> auth)
            {
                var sb = new System.Text.StringBuilder("{[\"n\"]=" + n);
                foreach (var kv in auth) if (kv.Value is double) sb.Append(",[" + LuaLit.Quote(kv.Key.ToString()) + "]=" + LuaLit.Show(kv.Value));
                relay?.Broadcast(Msg.Make("auth", hostName, sb.Append("}").ToString()));
            }
            Dictionary<string, Dictionary<object, object>> got = null;
            int expected; lock (players) expected = players.Count;
            lock (hashes)
            {
                if (!hashes.TryGetValue(n, out var d)) return;
                d[m.From] = parts;
                if (d.Count >= expected) { got = d; hashes.Remove(n); }
                foreach (var old in hashes.Keys.Where(k => k < n - 20).ToList()) hashes.Remove(old);
            }
            if (got == null) return;
            var names = got.Keys.OrderBy(k => k).ToList();
            var keys = got.Values.Where(v => v != null).SelectMany(v => v.Keys.Select(k => k.ToString())).Distinct().OrderBy(k => k).ToList();
            var diffs = new List<string>();
            foreach (var k in keys)
            {
                var vals = names.Select(nm => got[nm] != null && got[nm].TryGetValue(k, out var v) ? LuaLit.Show(v) : "absent").ToList();
                if (vals.Distinct().Count() > 1) diffs.Add($"{k}: " + string.Join(" | ", names.Select((nm, i) => nm + "=" + vals[i])));
            }
            string time = got[names[0]] != null && got[names[0]].TryGetValue("time", out var tv) ? LuaLit.Show(tv) : "?";
            // right after a resynchronisation every game runs the same loaded savegame: a part that still differs is a
            // local measure (display, cache...), not game state; it is left out from then on
            var diffKeys = diffs.Select(d => DiffKey(d)).ToList();
            if (n == postResyncHashN && diffKeys.Count > 0)
            {
                foreach (var k in diffKeys) ignoredParts.Add(k);
                Log.W(T("Mesures propres à chaque jeu (ignorées désormais) : ", "Local measures (ignored from now on): ") + string.Join(", ", diffKeys));
            }
            diffs = diffs.Where(d => !ignoredParts.Contains(DiffKey(d))).ToList();
            CheckResync(diffs.Select(d => DiffKey(d)).Where(k => !CorrectedParts.Contains(k)).ToList(), n);
            if (diffs.Count == 0)
            {
                bool changed = !syncText.StartsWith("SYNC");
                syncText = "SYNC ✔";
                if (changed || n % 6 == 1) Log.W(T($"Synchronisation n°{n} (temps {time}) : IDENTIQUE sur {names.Count} jeux ({keys.Count} mesures)", $"Sync check #{n} (time {time}): IDENTICAL on {names.Count} games ({keys.Count} measures)"));
            }
            else
            {
                desyncs++;
                syncText = T("DÉSYNCHRONISÉ ✖ (", "OUT OF SYNC ✖ (") + string.Join(",", diffs.Select(d => DiffKey(d))) + ")";
                Log.W(T($"!!! DÉSYNCHRONISATION n°{n} (temps {time}) : {diffs.Count} différence(s)", $"!!! OUT OF SYNC #{n} (time {time}): {diffs.Count} difference(s)"));
                foreach (var d in diffs) Log.W("    " + d);
            }
        }

        // ---------------------------------------------------------------- host authority: resynchronisation

        /// <summary>A difference the games cannot correct by themselves, seen at two checkpoints in a row: every game
        /// reloads the host's savegame.</summary>
        void CheckResync(List<string> keys, int n)
        {
            if (resyncing || autotest) return;
            string k = string.Join(",", keys.OrderBy(x => x));
            if (keys.Count == 0) { diffStreak = 0; lastDiffKeys = ""; return; }
            diffStreak = k == lastDiffKeys ? diffStreak + 1 : 1;
            lastDiffKeys = k;
            if (diffStreak < 2) return;
            if (Now - lastResync < ResyncCooldownSeconds)
            {
                if (diffStreak == 2) Log.W(T($"Écart persistant ({k}) : resynchronisation possible dans {ResyncCooldownSeconds - (Now - lastResync):0} s", $"Persistent difference ({k}): resynchronisation possible in {ResyncCooldownSeconds - (Now - lastResync):0} s"));
                return;
            }
            int remote; lock (players) remote = players.Count(p => p != hostName);
            if (remote == 0) return;
            resyncing = true;
            new Thread(() => Resync(k)) { IsBackground = true, Name = "Resync" }.Start();
        }

        void Resync(string reason)
        {
            int id = Interlocked.Increment(ref resyncId);
            int prevSpeed; lock (sessionGate) prevSpeed = Math.Max(1, speed);
            var t0 = DateTime.UtcNow;
            try
            {
                Log.W(T($"=== Resynchronisation n°{id} sur la partie de l'hôte (écart : {reason}) ===", $"=== Resynchronisation #{id} on the host's game (difference: {reason}) ==="));
                // 1. every game stops at the same time
                Pause(T("resynchronisation", "resynchronisation"));
                long at; lock (sessionGate) at = pauseAt ?? 0;
                bool stopped = WaitUntil(() => { lock (clocks) return clocks.Values.All(c => c.T >= at && c.Sp == 0); }, 120);
                if (!stopped) { Log.W(T("Resynchronisation abandonnée : les jeux ne se sont pas arrêtés.", "Resynchronisation cancelled: the games did not stop.")); return; }
                // 2. the host saves
                saveDone = null;
                hostGame.ToGame(Msg.Make("resync_save", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(ResyncSaveName) + "}"));
                if (!WaitUntil(() => saveDone != null, 180)) { Log.W(T("Resynchronisation abandonnée : l'hôte n'a pas sauvegardé.", "Resynchronisation cancelled: the host did not save.")); return; }
                if (!(saveDone.TryGetValue("ok", out var okv) && okv is bool ok && ok)) { Log.W(T("Resynchronisation abandonnée : sauvegarde refusée.", "Resynchronisation cancelled: save refused.")); return; }
                Thread.Sleep(1000);   // the file is closed by the game after its callback
                string file = GameInstall.FindSave(ResyncSaveName);
                if (file == null || File.GetLastWriteTimeUtc(file) < t0.AddSeconds(-5))
                {
                    Log.W(T($"Resynchronisation abandonnée : fichier « {ResyncSaveName}.sav » introuvable.", $"Resynchronisation cancelled: file « {ResyncSaveName}.sav » not found."));
                    return;
                }
                byte[] bytes = File.ReadAllBytes(file);
                Log.W(T($"Sauvegarde de l'hôte : {bytes.Length / 1048576.0:0.0} Mo, envoi aux autres joueurs...", $"Host savegame: {bytes.Length / 1048576.0:0.0} MB, sending it to the other players..."));
                // 3. every game (the host's too) reloads it; the others receive the file first
                lock (resyncWaiting) { resyncWaiting.Clear(); lock (players) foreach (var p in players) resyncWaiting.Add(p); }
                int parts = (bytes.Length + ResyncChunk - 1) / ResyncChunk;
                for (int i = 0; i < parts; i++)
                {
                    int len = Math.Min(ResyncChunk, bytes.Length - i * ResyncChunk);
                    string data = Convert.ToBase64String(bytes, i * ResyncChunk, len);
                    relay?.Broadcast(Msg.Make("resync_file", hostName,
                        "{[\"id\"]=" + id + ",[\"i\"]=" + i + ",[\"n\"]=" + parts + ",[\"data\"]=\"" + data + "\"}"));
                }
                hostGame.ToGame(Msg.Make("resync_load", hostName, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(ResyncSaveName) + "}"));
                bool back = WaitUntil(() => { lock (resyncWaiting) return resyncWaiting.Count == 0; }, 600);
                if (!back) { lock (resyncWaiting) Log.W(T("Resynchronisation : sans nouvelles de ", "Resynchronisation: no news from ") + string.Join(", ", resyncWaiting) + T(" (on reprend quand même).", " (resuming anyway).")); }
                // 4. all games run the same savegame: check, then resume
                Thread.Sleep(3000);
                postResyncHashN = hashN + 1;
                RequestHash();
                Thread.Sleep(2000);
                Log.W(T($"=== Resynchronisation n°{id} terminée en {(DateTime.UtcNow - t0).TotalSeconds:0} s ===", $"=== Resynchronisation #{id} done in {(DateTime.UtcNow - t0).TotalSeconds:0} s ==="));
            }
            catch (Exception e) { Log.W("Resynchronisation : " + e.Message); }
            finally
            {
                lastResync = Now;
                diffStreak = 0;
                resyncing = false;
                SetSpeed(prevSpeed, T("fin de resynchronisation", "end of resynchronisation"));
            }
        }

        // client side: the host's savegame arrives in pieces; once complete it is written next to this player's
        // savegames and the game loads it
        readonly Dictionary<int, string[]> resyncParts = new Dictionary<int, string[]>();

        void OnResyncFile(GameLink game, Msg m)
        {
            var t = LuaLit.Parse(m.Payload) as Dictionary<object, object>;
            if (t == null) return;
            int id = (int)(double)t["id"], i = (int)(double)t["i"], n = (int)(double)t["n"];
            string[] got;
            lock (resyncParts)
            {
                if (!resyncParts.TryGetValue(id, out got)) resyncParts[id] = got = new string[n];
                got[i] = t["data"] as string;
                if (got.Any(x => x == null)) return;
                resyncParts.Remove(id);
            }
            try
            {
                var bytes = got.SelectMany(Convert.FromBase64String).ToArray();
                string name = ResyncSaveName + " " + new string(game.Name.Where(char.IsLetterOrDigit).ToArray());
                foreach (var d in GameInstall.SaveDirs()) File.WriteAllBytes(Path.Combine(d, name + ".sav"), bytes);
                Log.W(T($"[{game.Name}] partie de l'hôte reçue ({bytes.Length / 1048576.0:0.0} Mo) : chargement...", $"[{game.Name}] host game received ({bytes.Length / 1048576.0:0.0} MB): loading..."));
                game.ToGame(Msg.Make("resync_load", m.From, "{[\"id\"]=" + id + ",[\"name\"]=" + LuaLit.Quote(name) + "}"));
            }
            catch (Exception e) { Log.W(T($"[{game.Name}] partie de l'hôte : {e.Message}", $"[{game.Name}] host game: {e.Message}")); }
        }

        void RunDeterminism()
        {
            if (started) { Log.W("Test déterminisme : à lancer avant « Démarrer la partie »."); return; }
            int[] schedule = { 0, 100, 500, 1500, 3000 };
            int expected;
            lock (players) expected = players.Count;
            if (expected < 2) { Log.W($"Test déterminisme : il faut au moins 2 jeux prêts (actuellement {expected})."); return; }
            detRunning = true;
            try
            {
                Log.W($"=== Test déterminisme sur {expected} jeux ===");
                int total = 0;
                for (int round = 0; round < schedule.Length; round++)
                {
                    int steps = schedule[round];
                    lock (detGate) { detRound = round; detHashes = new Dictionary<string, Dictionary<object, object>>(); }
                    HostSend(Msg.Make("det_run", hostName, "{[\"round\"]=" + round + ",[\"steps\"]=" + steps + "}"));
                    total += steps;
                    var deadline = DateTime.UtcNow.AddSeconds(300);
                    Dictionary<string, Dictionary<object, object>> got;
                    lock (detGate)
                    {
                        while (detHashes.Count < expected && DateTime.UtcNow < deadline) Monitor.Wait(detGate, 1000);
                        got = new Dictionary<string, Dictionary<object, object>>(detHashes);
                    }
                    if (got.Count < expected) { Log.W($"Tour {round} : réponses manquantes ({got.Count}/{expected}), test arrêté."); return; }
                    var names = got.Keys.OrderBy(k => k).ToList();
                    var keys = got.Values.Where(v => v != null).SelectMany(v => v.Keys.Select(k => k.ToString())).Distinct().OrderBy(k => k).ToList();
                    var diffs = new List<string>();
                    foreach (var k in keys)
                    {
                        var vals = names.Select(n => got[n] != null && got[n].TryGetValue(k, out var v) ? LuaLit.Show(v) : "absent").ToList();
                        if (vals.Distinct().Count() > 1) diffs.Add($"{k}: " + string.Join(" | ", names.Select((n, i) => n + "=" + vals[i])));
                    }
                    if (diffs.Count == 0) Log.W($"Tour {round} (+{steps} pas, total {total}) : IDENTIQUE sur {keys.Count} mesures");
                    else
                    {
                        Log.W($"Tour {round} (+{steps} pas, total {total}) : {diffs.Count} DIFFÉRENCE(S)");
                        foreach (var d in diffs) Log.W("    " + d);
                    }
                }
                Log.W("=== Fin du test déterminisme ===");
            }
            finally { detRunning = false; }
        }

        protected override void OnFormClosed(FormClosedEventArgs e)
        {
            foreach (var g in games) g.Dispose();
            foreach (var c in clients) c.Dispose();
            relay?.Dispose();
            base.OnFormClosed(e);
        }
    }
}
