"""Runs the Kill List Stats scenario tests under Lua 5.1 with a mocked WoW API.

Usage:  python tests/run_tests.py      (needs:  pip install lupa)
"""
import pathlib
import re
import sys

from lupa import lua51

ROOT = pathlib.Path(__file__).resolve().parent.parent
ADDON = ROOT / "KillListStats"
TESTS = ROOT / "tests"


def toc_files():
    files = []
    for line in (ADDON / "KillListStats.toc").read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            files.append(line)
    return files


def main():
    lua = lua51.LuaRuntime(unpack_returned_tuples=True)
    lua.execute((TESTS / "wow_mock.lua").read_text(encoding="utf-8"))

    # Compile check every addon file first (syntax errors show the file and line).
    loader = lua.eval("function(src, name) local f, err = loadstring(src, name); return f, err end")
    ns = lua.table()
    for name in toc_files():
        src = (ADDON / name).read_text(encoding="utf-8")
        chunk, err = loader(src, "@" + name)
        if chunk is None:
            print("SYNTAX ERROR:", err)
            return 1
        chunk("KillListStats", ns)
        print("loaded", name)

    lua.execute((TESTS / "test_addon.lua").read_text(encoding="utf-8"))
    failed = lua.globals().TEST_FAILED
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
