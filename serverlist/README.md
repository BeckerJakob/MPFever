# MPFever server list

A small service that keeps the public list of MPFever dedicated servers. It runs on a Windows PC that stays on (a home server,
a VPS). Dedicated servers whose `mpfever_server.properties` says `public=true` appear in it, and players see them in the
**Servers** tab of MPFever's multiplayer page.

Nothing is stored on disk: the list lives in memory, every server announces itself every 30 seconds and leaves the list
when it stops or after 90 seconds without news.

## Install

1. Build it (`build.bat` of MPFever builds it too) or take `MPFeverServerList.exe` from `serverlist\bin\Release`.
2. Copy `MPFeverServerList.exe`, `install-service.bat` and `uninstall-service.bat` into a folder of that PC.
3. Optional: a `port.txt` file next to them with another port (default **28100**).
4. Right click `install-service.bat` → **Run as administrator**. The service starts now and with Windows, the Windows
   firewall lets the port in, and Windows restarts the service if it ever stops.
5. On the router, forward **TCP 28100** to that PC (not needed behind a reverse proxy, see below).
6. Check it from another PC: `http://<public address>:28100/api/servers` shows `{"servers":[...]}`.

## Behind a reverse proxy (HTTPS, Cloudflare)

MPFever's own list runs behind Caddy and Cloudflare, at `https://mpfever.knight-hd.fr`. With Caddy, on the PC of the service:

```
mpfever.knight-hd.fr {
	reverse_proxy localhost:28100
}
```

The connections then come from the proxy. When the proxy is on the same PC or network (a loopback or private address), the
service lists a server with the address of `X-Forwarded-For` (its last address, the one the proxy saw: Caddy and nginx set or
add it), and when that address is one of Cloudflare's, with Cloudflare's `CF-Connecting-IP`. Port 28100 then does not need to
be open on the router. Cloudflare proxies only some ports (80 and 443 among them): use the proxy's port, not 28100, in the
address.

To try it without installing anything: run `MPFeverServerList.exe` (or `MPFeverServerList.exe 28100`) in a console;
Ctrl+C stops it. The log is `serverlist.log` next to the exe (2 MB at most, one old copy kept).

## Turning it on in MPFever

MPFever uses `https://mpfever.knight-hd.fr` (`MainForm.DefaultServerList`): players need nothing. Another list can be named in
`mpfever_settings.txt` next to `MPFever.exe`, and `serverlist=0` turns the list off:

```
serverlist=http://your-address:28100
```

A dedicated server appears in the list when its `mpfever_server.properties` has `public=true` (the default).
`public-address=` gives the address players should use (a domain name, `name:port`); empty, the list uses the public IP its
announces come from and the server's `port`.

## API

| Request | Body | Answer |
|---|---|---|
| `GET /api/servers` | | `{"servers":[{id, name, address, steam, reachable, version, build, mode, world, motd, players, max, password}]}` |
| `POST /api/announce` | `{name, port, version, build, mode, world, motd, players, max, password, steam, address, token}` | `{"ok":true, id, token, every}` |
| `POST /api/remove` | `{id, token}` | `{"ok":true}` |
| `GET /api/health` | | `{"ok":true, servers}` |

- The first announce gets an `id` and a `token`; later announces send the `token` back, and only it can remove the entry.
- The service tries a TCP connection to the server's port before listing it (again every 5 minutes, or at every announce while
  it does not answer). A server that gave its Steam id is listed even when its port is closed: players then join it through
  Steam.
- Limits: 8 KiB per request, one announce per server every 10 s, 4 servers per IP address, 2000 servers. Text fields lose their
  control characters and are cut (name 40, world 60, motd 140 characters).
- Plain HTTP: nothing secret goes through it. For HTTPS, put it behind a reverse proxy (see above).
