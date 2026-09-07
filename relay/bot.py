"""Auto Bees Discord relay: buttons and slash commands for the controller.

Runs on a machine of yours (the "custom host"). It keeps one main card with
buttons in your channel, queues every click or slash command, and the
OpenComputers controller picks them up over plain HTTP:

    GET  /commands  -> {"commands": [{"id": "...", "line": "find naqua", "user": "name"}]}
    POST /result    <- {"id": "...", "content": "...", "embeds": [...]}   (Discord message JSON)
    POST /status    <- the controller's status snapshot (drawn on the main card)
    GET  /          -> health check

Setup
    pip install -U discord.py aiohttp
    set DISCORD_TOKEN=<bot token>  DISCORD_CHANNEL=<channel id>  [RELAY_PORT=8080] [RELAY_SECRET=<shared secret>]
    python relay/bot.py

Discord side: in the developer portal open your application, add a Bot, copy
its token, and invite it with the `bot` and `applications.commands` scopes
and the Send Messages permission. Then on the controller:
    settings host http://<your ip>:8080
"""
import asyncio
import json
import os
import time
import uuid

import discord
from aiohttp import web
from discord import app_commands

TOKEN = os.environ.get("DISCORD_TOKEN", "")
CHANNEL_ID = int(os.environ.get("DISCORD_CHANNEL", "0") or 0)
PORT = int(os.environ.get("RELAY_PORT", "8080"))
SECRET = os.environ.get("RELAY_SECRET", "")
STATE_FILE = os.environ.get("RELAY_STATE", "relay_state.json")
RESULT_TIMEOUT = 45  # seconds a button waits for the controller

COLOR_STATUS = 0x95A5A6

# ---------------------------------------------------------------------------
# shared state
# ---------------------------------------------------------------------------
pending = []            # commands the controller has not fetched yet
waiting = {}            # command id -> asyncio.Future for the result
status = {"time": 0}    # last status snapshot from the controller
status_received = 0.0
state = {"card_message": None}


def load_state():
    try:
        with open(STATE_FILE, encoding="utf-8") as f:
            state.update(json.load(f))
    except FileNotFoundError:
        pass


def save_state():
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f)


def queue_command(line, user):
    cid = uuid.uuid4().hex[:12]
    pending.append({"id": cid, "line": line, "user": user, "at": time.time()})
    fut = asyncio.get_event_loop().create_future()
    waiting[cid] = fut
    return cid, fut


def payload_to_message(payload):
    """Discord message JSON from the controller -> kwargs for send()."""
    kwargs = {}
    if payload.get("content"):
        kwargs["content"] = str(payload["content"])[:2000]
    embeds = payload.get("embeds") or []
    if embeds:
        kwargs["embeds"] = [discord.Embed.from_dict(e) for e in embeds[:10]]
    if not kwargs:
        kwargs["content"] = "(empty reply)"
    return kwargs


# ---------------------------------------------------------------------------
# Discord side
# ---------------------------------------------------------------------------
intents = discord.Intents.default()
client = discord.Client(intents=intents)
tree = app_commands.CommandTree(client)


async def run_and_reply(interaction: discord.Interaction, line: str):
    """Queue a command line and answer the interaction with the controller's reply."""
    await interaction.response.defer(thinking=True)
    cid, fut = queue_command(line, interaction.user.display_name)
    try:
        payload = await asyncio.wait_for(fut, timeout=RESULT_TIMEOUT)
    except asyncio.TimeoutError:
        waiting.pop(cid, None)
        pending[:] = [c for c in pending if c["id"] != cid]
        await interaction.followup.send("The controller did not answer within %d s. Is `main` running and the host link set?" % RESULT_TIMEOUT)
        return
    await interaction.followup.send(**payload_to_message(payload))


class SpeciesModal(discord.ui.Modal):
    """Asks for a species (number or name) and runs `<verb> <species> ...`."""

    def __init__(self, verb: str, title: str, with_keep: bool = False):
        super().__init__(title=title)
        self.verb = verb
        self.species = discord.ui.TextInput(label="Species number or name", placeholder="4137 or naquadah", max_length=60)
        self.add_item(self.species)
        self.keep = None
        if with_keep:
            self.keep = discord.ui.TextInput(label="Drones to keep (optional)", placeholder="8", required=False, max_length=4)
            self.add_item(self.keep)

    async def on_submit(self, interaction: discord.Interaction):
        line = "%s %s" % (self.verb, self.species.value.strip())
        if self.keep is not None and self.keep.value.strip():
            line += " keep " + self.keep.value.strip()
        await run_and_reply(interaction, line)


class TextModal(discord.ui.Modal):
    def __init__(self, verb: str, title: str, label: str):
        super().__init__(title=title)
        self.verb = verb
        self.text = discord.ui.TextInput(label=label, max_length=80)
        self.add_item(self.text)

    async def on_submit(self, interaction: discord.Interaction):
        await run_and_reply(interaction, "%s %s" % (self.verb, self.text.value.strip()))


class MainCard(discord.ui.View):
    """The persistent button panel."""

    def __init__(self):
        super().__init__(timeout=None)

    @discord.ui.button(label="Status", style=discord.ButtonStyle.primary, custom_id="ab:status", row=0)
    async def status_btn(self, interaction, _):
        await run_and_reply(interaction, "status")

    @discord.ui.button(label="Queue", style=discord.ButtonStyle.primary, custom_id="ab:queue", row=0)
    async def queue_btn(self, interaction, _):
        await run_and_reply(interaction, "queue")

    @discord.ui.button(label="Cells", style=discord.ButtonStyle.primary, custom_id="ab:cells", row=0)
    async def cells_btn(self, interaction, _):
        await run_and_reply(interaction, "cells")

    @discord.ui.button(label="Library", style=discord.ButtonStyle.primary, custom_id="ab:library", row=0)
    async def library_btn(self, interaction, _):
        await run_and_reply(interaction, "library")

    @discord.ui.button(label="Find", style=discord.ButtonStyle.secondary, custom_id="ab:find", row=1)
    async def find_btn(self, interaction, _):
        await interaction.response.send_modal(TextModal("find", "Find a species", "Name or part of it"))

    @discord.ui.button(label="Plan", style=discord.ButtonStyle.secondary, custom_id="ab:plan", row=1)
    async def plan_btn(self, interaction, _):
        await interaction.response.send_modal(SpeciesModal("plan", "Plan a species"))

    @discord.ui.button(label="Needs", style=discord.ButtonStyle.secondary, custom_id="ab:needs", row=1)
    async def needs_btn(self, interaction, _):
        await interaction.response.send_modal(SpeciesModal("needs", "What does a species need"))

    @discord.ui.button(label="Breed", style=discord.ButtonStyle.success, custom_id="ab:breed", row=2)
    async def breed_btn(self, interaction, _):
        await interaction.response.send_modal(SpeciesModal("breed", "Breed a species", with_keep=True))

    @discord.ui.button(label="Cancel", style=discord.ButtonStyle.danger, custom_id="ab:cancel", row=2)
    async def cancel_btn(self, interaction, _):
        await interaction.response.send_modal(TextModal("cancel", "Cancel a job or request", "Job or request id, e.g. j12 or r3"))

    @discord.ui.button(label="Rescan library", style=discord.ButtonStyle.secondary, custom_id="ab:scan", row=2)
    async def scan_btn(self, interaction, _):
        await run_and_reply(interaction, "scan")


def status_embed():
    e = discord.Embed(title="Auto Bees", color=COLOR_STATUS)
    age = time.time() - status_received if status_received else None
    if age is None:
        e.description = "Waiting for the controller. On it: `settings host http://<this machine>:%d`" % PORT
        return e
    fresh = age < 120
    e.description = ("Live" if fresh else "Stale, last update %d min ago" % (age // 60))
    for name, c in sorted((status.get("cells") or {}).items()):
        if c.get("job"):
            value = "%s -> %s\ngen %s, %s" % (c.get("job"), c.get("target"), c.get("generation", 0), c.get("phase", "-"))
        else:
            value = str(c.get("status", "?"))
        e.add_field(name=name, value=value, inline=True)
    queue = status.get("queue") or []
    e.add_field(name="Queue", value=("\n".join("%s %s (%s)" % (q.get("id"), q.get("target"), q.get("status")) for q in queue[:8]) or "empty"), inline=False)
    e.add_field(name="Library", value="%s species, %s princesses" % (status.get("librarySpecies", 0), status.get("princesses", 0)), inline=True)
    e.set_footer(text="GTNH Auto Bees relay")
    return e


async def ensure_card():
    channel = client.get_channel(CHANNEL_ID) or await client.fetch_channel(CHANNEL_ID)
    view = MainCard()
    msg = None
    if state.get("card_message"):
        try:
            msg = await channel.fetch_message(int(state["card_message"]))
        except discord.NotFound:
            msg = None
    if msg is None:
        msg = await channel.send(embed=status_embed(), view=view)
        state["card_message"] = msg.id
        save_state()
    else:
        await msg.edit(embed=status_embed(), view=view)
    return msg


async def refresh_card_loop():
    await client.wait_until_ready()
    while not client.is_closed():
        try:
            await ensure_card()
        except Exception as exc:  # noqa: BLE001
            print("card refresh failed:", exc)
        await asyncio.sleep(30)


@client.event
async def on_ready():
    client.add_view(MainCard())
    await tree.sync()
    print("relay ready as", client.user, "in channel", CHANNEL_ID)


@tree.command(name="bee", description="Run an Auto Bees command (find, plan, needs, breed, status, queue, library, cancel ...)")
@app_commands.describe(line="e.g. find naquadah  or  breed 4137 keep 16")
async def bee_command(interaction: discord.Interaction, line: str):
    await run_and_reply(interaction, line)


# ---------------------------------------------------------------------------
# HTTP side (the controller talks to this)
# ---------------------------------------------------------------------------
def authorized(request):
    return not SECRET or request.headers.get("X-Auth") == SECRET


async def http_commands(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    out, keep = [], []
    now = time.time()
    for c in pending:
        if now - c["at"] > RESULT_TIMEOUT:
            continue  # the interaction has already timed out
        out.append({"id": c["id"], "line": c["line"], "user": c["user"]})
    pending[:] = keep
    return web.json_response({"commands": out})


async def http_result(request):
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    payload = await request.json()
    fut = waiting.pop(str(payload.get("id")), None)
    if fut and not fut.done():
        fut.set_result(payload)
        return web.json_response({"ok": True})
    return web.json_response({"ok": False, "reason": "unknown or expired command id"}, status=404)


async def http_status(request):
    global status_received
    if not authorized(request):
        return web.json_response({"error": "unauthorized"}, status=401)
    status.clear()
    status.update(await request.json())
    status_received = time.time()
    return web.json_response({"ok": True})


async def http_root(_request):
    return web.json_response({"service": "auto-bees-relay", "pending": len(pending), "statusAge": time.time() - status_received if status_received else None})


async def main():
    load_state()
    app = web.Application()
    app.add_routes([web.get("/", http_root), web.get("/commands", http_commands), web.post("/result", http_result), web.post("/status", http_status)])
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", PORT).start()
    print("http listening on port", PORT)
    asyncio.create_task(refresh_card_loop())
    await client.start(TOKEN)


if __name__ == "__main__":
    if not TOKEN or not CHANNEL_ID:
        raise SystemExit("set DISCORD_TOKEN and DISCORD_CHANNEL")
    asyncio.run(main())
