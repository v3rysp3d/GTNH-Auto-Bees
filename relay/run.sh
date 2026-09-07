#!/usr/bin/env sh
# Auto Bees Discord bot: install once, then run. Reads relay/.env.
cd "$(dirname "$0")" || exit 1
if [ ! -d .venv ]; then
  python3 -m venv .venv
  .venv/bin/python -m pip install -q -r requirements.txt
fi
while true; do
  .venv/bin/python bot.py
  echo "bot stopped, restarting in 10 s (Ctrl+C to quit)"
  sleep 10
done
