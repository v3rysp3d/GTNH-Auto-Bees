@echo off
rem Auto Bees Discord bot: install once, then run. Reads relay\.env.
cd /d "%~dp0"
if not exist .venv (
  python -m venv .venv
  .venv\Scripts\python -m pip install -q -r requirements.txt
)
:loop
.venv\Scripts\python bot.py
echo bot stopped, restarting in 10 s (Ctrl+C to quit)
timeout /t 10 >nul
goto loop
