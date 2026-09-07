"""Exercise the relay's HTTP side without Discord.

    python relay/test_relay.py
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bot  # noqa: E402
from aiohttp.test_utils import TestClient, TestServer  # noqa: E402


async def run():
    failures = 0

    def check(cond, msg):
        nonlocal failures
        print(("ok   " if cond else "FAIL ") + msg)
        if not cond:
            failures += 1

    async with TestClient(TestServer(bot.make_app())) as c:
        r = await c.get("/")
        check(r.status == 200 and (await r.json())["service"] == "auto-bees-relay", "health check")

        # nothing queued
        r = await c.get("/commands")
        check((await r.json())["commands"] == [], "empty command queue")

        # a click queues a command; the controller fetches it once
        cid, fut = bot.queue_command("find naqua", "tester")
        r = await c.get("/commands")
        cmds = (await r.json())["commands"]
        check(len(cmds) == 1 and cmds[0]["id"] == cid and cmds[0]["line"] == "find naqua", "click delivered to the controller")
        r = await c.get("/commands")
        check((await r.json())["commands"] == [], "delivered once only")

        # the controller answers; the waiting click receives the payload
        payload = {"id": cid, "embeds": [{"title": "find: [4137] Naquadah", "description": "4137 Naquadah (GregTech)"}]}
        r = await c.post("/result", json=payload)
        check(r.status == 200, "result accepted")
        check(fut.done() and fut.result()["embeds"][0]["title"].startswith("find:"), "click resolved with the embed")
        kwargs = bot.payload_to_message(fut.result())
        check(kwargs["embeds"][0].title == "find: [4137] Naquadah", "embed converted for discord.py")

        # unknown id
        r = await c.post("/result", json={"id": "nope", "content": "x"})
        check(r.status == 404, "unknown command id rejected")

        # status push feeds the main card
        r = await c.post("/status", json={"cells": {"cell1": {"status": "busy", "job": "j3", "target": "[1001] Common", "targetUid": "forestry.speciesCommon", "generation": 4, "phase": "purify"}},
                                          "queue": [{"id": "r1", "target": "[1001] Common", "status": "active"}], "librarySpecies": 12, "princesses": 3,
                                          "imageBase": "https://raw.githubusercontent.com/v3rysp3d/GTNH-Auto-Bees/main/docs/bees/"})
        check(r.status == 200, "status accepted")
        e = bot.status_embed()
        check(e.description == "Live" and any(f.name == "cell1" for f in e.fields), "main card shows the cell")
        check(e.thumbnail.url.endswith("forestry_speciesCommon.png"), "main card shows the species icon")

        # shared secret
        bot.SECRET = "s3cret"
        r = await c.get("/commands")
        check(r.status == 401, "secret required when configured")
        r = await c.get("/commands", headers={"X-Auth": "s3cret"})
        check(r.status == 200, "secret accepted")
        bot.SECRET = ""

    print("FAILURES:", failures)
    return failures


if __name__ == "__main__":
    sys.exit(1 if asyncio.run(run()) else 0)
