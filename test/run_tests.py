"""Run the pure-logic Lua tests under a real Lua 5.2 (OpenComputers' default).

Usage:  python test/run_tests.py            (needs `pip install lupa`)
"""
import os
import sys
import glob

try:
    from lupa import lua52 as luamod
except ImportError:  # pragma: no cover
    import lupa as luamod

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LIB = ROOT.replace("\\", "/")
TESTS = os.path.join(ROOT, "test").replace("\\", "/")

BOOT = r"""
package.path = LIB .. "/?.lua;" .. LIB .. "/?/init.lua;" .. TESTS .. "/?.lua;" .. package.path
-- Stub the OpenComputers libraries the modules touch at load time.
package.preload["computer"] = function() return { uptime = os.clock } end
package.preload["filesystem"] = function() return { exists = function() return true end, makeDirectory = function() end } end
T = {}
T.failures, T.passed = {}, 0
local function fmt(v)
  if type(v) == "table" then
    local util = require("src.util")
    return util.serialize(v)
  end
  return tostring(v)
end
function T.eq(a, b, msg)
  local sa, sb = fmt(a), fmt(b)
  if sa == sb then T.passed = T.passed + 1
  else T.failures[#T.failures + 1] = (msg or "eq") .. ": expected " .. sb .. " got " .. sa end
end
function T.ok(v, msg)
  if v then T.passed = T.passed + 1 else T.failures[#T.failures + 1] = (msg or "ok") .. ": got " .. tostring(v) end
end
function T.run(name, fn)
  local ok, err = pcall(fn)
  if not ok then T.failures[#T.failures + 1] = name .. ": ERROR " .. tostring(err) end
end
"""


def main():
    rt = luamod.LuaRuntime(unpack_returned_tuples=True)
    g = rt.globals()
    g.LIB = LIB
    g.TESTS = TESTS
    rt.execute(BOOT)
    os.makedirs(os.path.join(ROOT, "test", "tmp"), exist_ok=True)
    files = sorted(glob.glob(os.path.join(ROOT, "test", "test_*.lua")))
    total_fail = 0
    for f in files:
        name = os.path.basename(f)
        with open(f, "r", encoding="utf-8") as fh:
            src = fh.read()
        rt.execute("T.failures = {} T.passed = 0")
        try:
            rt.execute(src)
        except Exception as e:  # noqa: BLE001
            print(f"FAIL {name}: {e}")
            total_fail += 1
            continue
        failures = list(g.T.failures.values())
        passed = g.T.passed
        if failures:
            total_fail += len(failures)
            print(f"FAIL {name}: {len(failures)} failure(s), {passed} passed")
            for m in failures:
                print("   - " + m)
        else:
            print(f"ok   {name}: {passed} assertions")
    print("TOTAL FAILURES:", total_fail)
    sys.exit(1 if total_fail else 0)


if __name__ == "__main__":
    main()
