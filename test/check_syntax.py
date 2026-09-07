"""Compile every Lua file without running it.

Our code targets Lua 5.2 (OpenComputers' lowest architecture); the vendored
libs in lib/ use Lua 5.3 syntax, which is what GTNH's OpenComputers runs by
default, so they are checked with 5.3.

Usage:  python test/check_syntax.py
"""
import glob
import os
import sys

from lupa import lua52, lua53

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECK = "function(src, name) local fn, err = load(src, name) if fn then return true, nil end return false, err end"


def check(runtime, files):
    fn = runtime.eval(CHECK)
    failures = 0
    for f in files:
        rel = os.path.relpath(f, ROOT)
        with open(f, encoding="utf-8") as fh:
            src = fh.read()
        if rel.endswith(".cfg") or os.path.basename(rel) == "config.lua":
            src_to_check = src if rel.endswith(".lua") else "return " + src
        else:
            src_to_check = src
        ok, err = fn(src_to_check, "=" + rel)
        if not ok:
            failures += 1
            print(f"FAIL {rel}: {err}")
    return failures


def main():
    ours = sorted(glob.glob(os.path.join(ROOT, "*.lua")) + glob.glob(os.path.join(ROOT, "src", "*.lua")))
    libs = sorted(glob.glob(os.path.join(ROOT, "lib", "**", "*.lua"), recursive=True))
    failures = check(lua52.LuaRuntime(), ours) + check(lua53.LuaRuntime(), libs)
    print(f"checked {len(ours)} project files (Lua 5.2) and {len(libs)} library files (Lua 5.3), failures: {failures}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
