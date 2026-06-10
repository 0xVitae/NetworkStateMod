#!/usr/bin/env python3
"""
Build NetworkStateMod.civ5mod for Steam Workshop upload.

1. Recomputes the md5 attribute of every <File> entry in NetworkState.modinfo.
   The game's package installer VALIDATES these checksums and silently
   discards the package if they are missing or stale — a package built
   without this step downloads ("Transferring…") and then vanishes.
2. Builds the 7z archive with legacy-friendly settings (plain LZMA,
   non-solid, uncompressed headers) for the game's old 7z SDK.

Usage:  python3 build_package.py            -> /tmp/NetworkStateMod.civ5mod
Then:   python3 workshop_upload.py update 3742131693 /tmp/NetworkStateMod.civ5mod "<changenote>"
"""

import hashlib
import re
import subprocess
import sys
import os

REPO = os.path.dirname(os.path.abspath(__file__))
MODINFO = os.path.join(REPO, "NetworkState.modinfo")
OUT = "/tmp/NetworkStateMod.civ5mod"
PACKAGED = ["NetworkState.modinfo", "Art", "Lua", "Text", "UI", "XML"]
SEVENZIP = "/opt/homebrew/bin/7z"


def fill_md5s():
    with open(MODINFO) as f:
        content = f.read()

    def repl(m):
        path = os.path.join(REPO, m.group(2))
        digest = hashlib.md5(open(path, "rb").read()).hexdigest().upper()
        return f'<File md5="{digest}" import="{m.group(1)}">{m.group(2)}</File>'

    new, n = re.subn(r'<File md5="[^"]*" import="([01])">([^<]+)</File>', repl, content)
    if n == 0:
        sys.exit("No <File> entries found in modinfo — aborting")
    with open(MODINFO, "w") as f:
        f.write(new)
    print(f"Updated md5 for {n} file entries")


def build():
    if os.path.exists(OUT):
        os.remove(OUT)
    subprocess.run(
        [SEVENZIP, "a", "-t7z", "-m0=LZMA", "-mx=5", "-ms=off", "-mhc=off",
         OUT, *PACKAGED, "-xr!.DS_Store"],
        cwd=REPO, check=True, stdout=subprocess.DEVNULL)
    print(f"Built {OUT} ({os.path.getsize(OUT)} bytes)")


if __name__ == "__main__":
    fill_md5s()
    build()
