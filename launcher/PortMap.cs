using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using static MPFever.L;

namespace MPFever
{
    /// <summary>Opens the host's TCP port on the router by itself, so that friends can join over the Internet without
    /// forwarding it by hand: UPnP (the router's Internet Gateway Device: AddPortMapping), else NAT-PMP (RFC 6886, routers
    /// with miniupnpd or Apple's). The mapping is removed when the session ends or MPFever closes. The router's own public
    /// address tells whether the Internet can reach this PC at all: an address of the provider's own network (CGNAT,
    /// 100.64.0.0/10) or a private one means the provider shares one public address among many customers, and no port can be
    /// opened (IPv6 or a tunnel such as Radmin or Porthole then). upnp=0 in mpfever_settings.txt turns it off.</summary>
    static class PortMap
    {
        public sealed class Result
        {
            public string Method;        // "UPnP", "NAT-PMP", or null (none worked)
            public string External;      // the router's public address, when it said
            public string Problem;       // why nobody outside can reach this PC, when known (CGNAT...)
            public string Error;
        }

        static readonly object Gate = new object();
        static Action close;             // removes the current mapping
        static int openPort;

        public static bool Enabled => !(MainForm.LoadSettings().TryGetValue("upnp", out var v) && v.Trim() == "0");

        /// <summary>Maps <paramref name="port"/> (TCP) in the background; <paramref name="done"/> gets the result.</summary>
        public static void OpenAsync(int port, Action<Result> done = null)
        {
            if (!Enabled) { Log.Dim(T("Ouverture automatique du port désactivée (upnp=0).", "Automatic port opening off (upnp=0).")); return; }
            new Thread(() =>
            {
                Result r;
                try { r = Open(port); }
                catch (Exception e) { r = new Result { Error = e.Message }; }
                Report(port, r);
                try { done?.Invoke(r); } catch { }
            }) { IsBackground = true, Name = "Port mapping" }.Start();
        }

        static void Report(int port, Result r)
        {
            if (r.Method != null)
                Log.Ok(F("Port {0} (TCP) ouvert automatiquement sur la box ({1}){2}.", "Port {0} (TCP) opened on the router by itself ({1}){2}.",
                    port, r.Method, r.External != null ? F(", adresse publique {0}", ", public address {0}", r.External) : ""));
            else
                Log.Warn(F("Le port {0} n'a pas pu être ouvert automatiquement sur la box ({1}) : redirigez-le à la main pour jouer par Internet.",
                    "Port {0} could not be opened on the router by itself ({1}): forward it by hand to play over the Internet.", port, r.Error ?? "UPnP / NAT-PMP"));
            if (r.Problem != null) Log.Warn(r.Problem);
        }

        /// <summary>The mapping made last is removed (at most 2 s).</summary>
        public static void Close()
        {
            Action c;
            lock (Gate) { c = close; close = null; }
            if (c == null) return;
            var t = new Thread(() => { try { c(); } catch { } }) { IsBackground = true };
            t.Start();
            t.Join(2000);
            Log.Dim(F("Port {0} refermé sur la box.", "Port {0} closed again on the router.", openPort));
        }

        public static Result Open(int port)
        {
            Close();
            var r = new Result();
            string why = null;
            try
            {
                var igd = DiscoverUpnp(2500);
                if (igd != null)
                {
                    var local = LocalAddressTowards(igd.Host);
                    string ext = null;
                    try { ext = igd.ExternalAddress(); } catch { }
                    r.External = ext;
                    r.Problem = ProblemOf(ext);
                    igd.AddMapping(port, local);
                    r.Method = "UPnP";
                    lock (Gate) { openPort = port; close = () => igd.DeleteMapping(port); }
                    return r;
                }
                why = T("pas de réponse UPnP", "no UPnP answer");
            }
            catch (Exception e) { why = "UPnP: " + e.Message; }
            try
            {
                foreach (var gw in Gateways())
                {
                    var ext = NatPmp.ExternalAddress(gw);
                    if (ext == null) continue;
                    r.External = ext.ToString();
                    r.Problem = ProblemOf(r.External);
                    if (NatPmp.Map(gw, port, 7200))
                    {
                        r.Method = "NAT-PMP";
                        var renew = new Timer(_ => { try { NatPmp.Map(gw, port, 7200); } catch { } }, null, 3_000_000, 3_000_000);
                        lock (Gate) { openPort = port; close = () => { renew.Dispose(); NatPmp.Map(gw, port, 0); }; }
                        return r;
                    }
                }
                why += T(" ; pas de NAT-PMP", "; no NAT-PMP");
            }
            catch (Exception e) { why += "; NAT-PMP: " + e.Message; }
            r.Error = why;
            return r;
        }

        /// <summary>Why nobody outside reaches this PC when the router's public address is <paramref name="ext"/>.</summary>
        public static string ProblemOf(string ext)
        {
            if (ext == null || !IPAddress.TryParse(ext, out var ip) || ip.AddressFamily != AddressFamily.InterNetwork) return null;
            var b = ip.GetAddressBytes();
            bool cgnat = b[0] == 100 && (b[1] & 0xC0) == 64;
            bool priv = b[0] == 10 || (b[0] == 172 && (b[1] & 0xF0) == 16) || (b[0] == 192 && b[1] == 168);
            if (!cgnat && !priv) return null;
            return F("La box a l'adresse {0}, qui n'est pas une adresse publique : votre fournisseur d'accès partage une adresse entre plusieurs clients (CGNAT). Les autres joueurs ne pourront pas vous rejoindre par votre adresse IPv4 : utilisez IPv6 si vous l'avez tous les deux, un serveur dédié chez quelqu'un d'autre, ou un tunnel (Radmin VPN, Porthole...).",
                "The router's address is {0}, not a public one: your provider shares one address among several customers (CGNAT). Other players cannot join you through your IPv4 address: use IPv6 if you both have it, a dedicated server at someone else's, or a tunnel (Radmin VPN, Porthole...).", ext);
        }

        /// <summary>This PC's address on the network of <paramref name="host"/> (the one a connection to it leaves from).</summary>
        static string LocalAddressTowards(string host)
        {
            using (var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
            {
                s.Connect(host, 1900);
                return ((IPEndPoint)s.LocalEndPoint).Address.ToString();
            }
        }

        static IEnumerable<IPAddress> Gateways()
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
                .SelectMany(n => n.GetIPProperties().GatewayAddresses.Select(g => g.Address))
                .Where(a => a.AddressFamily == AddressFamily.InterNetwork && !a.Equals(IPAddress.Any))
                .Distinct();
        }

        // ---------------------------------------------------------------- UPnP

        /// <summary>A router's WANIPConnection (or WANPPPConnection) service.</summary>
        public sealed class Igd
        {
            public string Host, ControlUrl, ServiceType;

            public string ExternalAddress()
            {
                var resp = Soap("GetExternalIPAddress", "");
                var m = Regex.Match(resp, "<NewExternalIPAddress>([^<]*)</NewExternalIPAddress>");
                return m.Success && m.Groups[1].Value.Trim() != "" ? m.Groups[1].Value.Trim() : null;
            }

            public void AddMapping(int port, string local)
            {
                string Args(int lease) =>
                    "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>"
                    + "<NewInternalPort>" + port + "</NewInternalPort><NewInternalClient>" + local + "</NewInternalClient>"
                    + "<NewEnabled>1</NewEnabled><NewPortMappingDescription>MPFever</NewPortMappingDescription>"
                    + "<NewLeaseDuration>" + lease + "</NewLeaseDuration>";
                // (a permanent mapping first; some routers only take a limited one: 2 hours then)
                try { Soap("AddPortMapping", Args(0)); }
                catch (WebException) { Soap("AddPortMapping", Args(7200)); }
            }

            public void DeleteMapping(int port)
            {
                Soap("DeletePortMapping", "<NewRemoteHost></NewRemoteHost><NewExternalPort>" + port + "</NewExternalPort><NewProtocol>TCP</NewProtocol>");
            }

            public string Soap(string action, string args)
            {
                var body = "<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\">"
                    + "<s:Body><u:" + action + " xmlns:u=\"" + ServiceType + "\">" + args + "</u:" + action + "></s:Body></s:Envelope>";
                var req = (HttpWebRequest)WebRequest.Create(ControlUrl);
                req.Method = "POST";
                req.Timeout = req.ReadWriteTimeout = 3000;
                req.ContentType = "text/xml; charset=\"utf-8\"";
                req.Headers.Add("SOAPAction", "\"" + ServiceType + "#" + action + "\"");
                var bytes = Encoding.UTF8.GetBytes(body);
                using (var s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);
                using (var resp = req.GetResponse())
                using (var r = new StreamReader(resp.GetResponseStream())) return r.ReadToEnd();
            }
        }

        static readonly string[] SearchTypes = {
            "urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
            "urn:schemas-upnp-org:service:WANIPConnection:1", "urn:schemas-upnp-org:service:WANIPConnection:2",
            "urn:schemas-upnp-org:service:WANPPPConnection:1",
        };

        /// <summary>The first router that answers an SSDP search and describes a WAN connection service, or null.</summary>
        public static Igd DiscoverUpnp(int timeoutMs)
        {
            var locations = new List<string>();
            using (var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp))
            {
                s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                s.Bind(new IPEndPoint(IPAddress.Any, 0));
                s.ReceiveTimeout = 300;
                var to = new IPEndPoint(IPAddress.Parse("239.255.255.250"), 1900);
                foreach (var st in SearchTypes)
                {
                    var msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: " + st + "\r\n\r\n";
                    var b = Encoding.ASCII.GetBytes(msg);
                    s.SendTo(b, to);
                }
                var buf = new byte[4096];
                var until = DateTime.UtcNow.AddMilliseconds(timeoutMs);
                while (DateTime.UtcNow < until)
                {
                    try
                    {
                        EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                        int n = s.ReceiveFrom(buf, ref from);
                        var m = Regex.Match(Encoding.ASCII.GetString(buf, 0, n), @"^LOCATION:\s*(\S+)", RegexOptions.IgnoreCase | RegexOptions.Multiline);
                        if (m.Success && !locations.Contains(m.Groups[1].Value)) locations.Add(m.Groups[1].Value);
                    }
                    catch (SocketException) { if (locations.Count > 0) break; }
                }
            }
            foreach (var loc in locations)
            {
                try
                {
                    var igd = FromDescription(loc, Fetch(loc));
                    if (igd != null) return igd;
                }
                catch { }
            }
            return null;
        }

        static string Fetch(string url)
        {
            var req = (HttpWebRequest)WebRequest.Create(url);
            req.Timeout = req.ReadWriteTimeout = 3000;
            using (var resp = req.GetResponse())
            using (var r = new StreamReader(resp.GetResponseStream())) return r.ReadToEnd();
        }

        /// <summary>The WAN connection service of a device description (its controlURL made absolute), or null.</summary>
        public static Igd FromDescription(string location, string xml)
        {
            var baseUri = new Uri(location);
            var ub = Regex.Match(xml, "<URLBase>([^<]+)</URLBase>", RegexOptions.IgnoreCase);
            if (ub.Success && Uri.TryCreate(ub.Groups[1].Value.Trim(), UriKind.Absolute, out var u)) baseUri = u;
            foreach (Match svc in Regex.Matches(xml, "<service>(.*?)</service>", RegexOptions.Singleline | RegexOptions.IgnoreCase))
            {
                var type = Regex.Match(svc.Groups[1].Value, "<serviceType>([^<]+)</serviceType>", RegexOptions.IgnoreCase).Groups[1].Value.Trim();
                if (!type.StartsWith("urn:schemas-upnp-org:service:WANIPConnection:") && !type.StartsWith("urn:schemas-upnp-org:service:WANPPPConnection:")) continue;
                var ctl = Regex.Match(svc.Groups[1].Value, "<controlURL>([^<]+)</controlURL>", RegexOptions.IgnoreCase).Groups[1].Value.Trim();
                if (ctl == "") continue;
                var abs = new Uri(baseUri, ctl);
                return new Igd { Host = abs.Host, ControlUrl = abs.ToString(), ServiceType = type };
            }
            return null;
        }

        // ---------------------------------------------------------------- NAT-PMP (RFC 6886)

        public static class NatPmp
        {
            static byte[] Ask(IPAddress gw, byte[] req, int answerLen)
            {
                using (var u = new UdpClient())
                {
                    u.Client.ReceiveTimeout = 250;
                    u.Connect(gw, 5351);
                    // (the RFC's retries: 250 ms, then 500 ms)
                    for (int i = 0; i < 2; i++)
                    {
                        u.Send(req, req.Length);
                        try
                        {
                            var from = new IPEndPoint(IPAddress.Any, 0);
                            var a = u.Receive(ref from);
                            if (a.Length >= answerLen) return a;
                        }
                        catch (SocketException) { u.Client.ReceiveTimeout = 500; }
                    }
                }
                return null;
            }

            public static IPAddress ExternalAddress(IPAddress gw)
            {
                var a = Ask(gw, new byte[] { 0, 0 }, 12);
                if (a == null || a[1] != 128 || a[2] != 0 || a[3] != 0) return null;
                return new IPAddress(new[] { a[8], a[9], a[10], a[11] });
            }

            /// <summary>Maps the TCP port for <paramref name="lifetime"/> seconds (0 removes the mapping).</summary>
            public static bool Map(IPAddress gw, int port, int lifetime)
            {
                var req = new byte[12];
                req[1] = 2;    // TCP
                req[4] = (byte)(port >> 8); req[5] = (byte)port;
                req[6] = (byte)(lifetime == 0 ? 0 : port >> 8); req[7] = (byte)(lifetime == 0 ? 0 : port);
                req[8] = (byte)(lifetime >> 24); req[9] = (byte)(lifetime >> 16); req[10] = (byte)(lifetime >> 8); req[11] = (byte)lifetime;
                var a = Ask(gw, req, 16);
                return a != null && a[1] == 130 && a[2] == 0 && a[3] == 0;
            }
        }
    }
}
