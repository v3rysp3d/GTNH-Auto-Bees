# Auto Bees relay

Buttons and slash commands for the controller. A webhook is one-way and an OpenComputers computer cannot
receive Discord interactions, so this small service runs on a machine of yours and passes clicks through.

```
Discord  <-- gateway -->  relay/bot.py  <-- plain HTTP -->  OpenComputers controller
```

It keeps one **main card** in your channel with buttons: Status, Queue, Cells, Library, Find, Plan, Needs,
Breed, Cancel, Rescan library. Find, Plan, Needs, Breed and Cancel open a small form. There is also a
`/bee <line>` slash command that accepts anything the controller understands. The card's embed is redrawn
from the status snapshot the controller pushes.

## Setup

1. In the [Discord developer portal](https://discord.com/developers/applications) open your application,
   go to **Bot**, add a bot, copy the token. Under **OAuth2 > URL Generator** pick the scopes `bot` and
   `applications.commands` with the permission *Send Messages*, open the generated URL and invite it.
2. On the host machine:

   ```
   pip install -U discord.py aiohttp
   set DISCORD_TOKEN=<token>
   set DISCORD_CHANNEL=<channel id>
   set RELAY_PORT=8080
   python relay/bot.py
   ```

   Use `export` instead of `set` on Linux. Keep it running (a systemd unit, a screen session, or a Windows
   scheduled task all work).
3. Open the port on the host's firewall for the Minecraft server's address.
4. On the controller: `settings host http://<host ip>:8080`. The controller now polls `/commands` every
   few seconds and pushes its status to `/status`.

Optional: set `RELAY_SECRET` on the host and add the same value as `host.secret` in `config.lua` to reject
requests from anyone else.

## Protocol

| Call | Direction | Body |
|---|---|---|
| `GET /commands` | controller polls | `{"commands":[{"id":"...","line":"find naqua","user":"name"}]}` |
| `POST /result` | controller answers | Discord message JSON plus `"id"` |
| `POST /status` | controller pushes | status snapshot |
| `GET /` | health | counters |
