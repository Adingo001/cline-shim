#!/usr/bin/env python3
"""Push helper scripts into WSL via base64 so quoting never bites."""
import base64
import subprocess
import sys

targets = sys.argv[1:]
for spec in targets:
    src, dst = spec.split("=", 1)
    with open(src, "rb") as handle:
        payload = base64.b64encode(handle.read()).decode()
    cmd = ("echo %s | base64 -d > %s" % (payload, dst))
    result = subprocess.run(["wsl", "bash", "-lc", cmd],
                            capture_output=True, text=True)
    status = "ok" if result.returncode == 0 else "FAILED: " + result.stderr.strip()
    print("%s -> %s  %s" % (src, dst, status))
