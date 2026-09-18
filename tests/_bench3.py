#!/usr/bin/env python3
"""Compare the three shim routes dsh can take to the Cline Pass gateway.

Route 1  127.0.0.1:8788   shim inside WSL, upstream egress is this machine
Route 2  127.0.0.1:8789   SSH tunnel to the shim on the relay, egress is that box
Route 3  api.cline.bot    straight to the gateway, no shim, no channel pinning

Routes 1 and 2 run the same shim code, so the only difference between them is
where the traffic leaves from. Route 3 shares route 1's egress but skips the
pin, which isolates what pinning is worth.

Requests are interleaved round-robin rather than run route-by-route: upstream
channel health drifts over minutes, and a sequential sweep would charge that
drift to whichever route happened to run during a bad window.

The API key is read from the dsh credential store and never printed.
"""

import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request

MODEL = "cline-pass/deepseek-v4.1-flash"
ROUNDS = int(os.environ.get("BENCH_ROUNDS", "5"))
MAX_TOKENS = int(os.environ.get("BENCH_MAXTOKENS", "900"))
TIMEOUT = 240

PROMPT = (
    "Write a Python function that reverses a singly linked list, including the "
    "node class and a short docstring. Then explain its time and space complexity."
)

UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)

# The shim's CLINE_UPSTREAM already carries /v1 (https://api.cline.bot/api/v1)
# and it appends the inbound path to it, so callers must NOT send /v1 prefix --
# doing so asks for /api/v1/v1/chat/completions and yields a 404 on every
# channel. The direct route needs the full path because nothing rewrites it.
ROUTES = [
    ("8788 WSL shim", "http://127.0.0.1:8788/chat/completions"),
    ("8789 relay shim", "http://127.0.0.1:8789/chat/completions"),
    ("direct no-pin", "https://api.cline.bot/api/v1/chat/completions"),
]


def load_key():
    path = os.path.expanduser("~/.dsh/.credentials.yaml")
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    match = re.search(r"CLINE_API_KEY:\s*(\S+)", text)
    if not match:
        sys.exit("CLINE_API_KEY not found in " + path)
    return match.group(1)


def one_call(url, key):
    body = {
        "model": MODEL,
        "messages": [{"role": "user", "content": PROMPT}],
        "stream": True,
        "max_tokens": MAX_TOKENS,
    }
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
            "User-Agent": UA,
        },
        method="POST",
    )

    started = time.time()
    ttfb = None
    chars = 0
    reasoning_chars = 0
    error = None
    http = None

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            http = response.status
            for raw in response:
                line = raw.decode("utf-8", "ignore").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    obj = json.loads(payload)
                except ValueError:
                    continue
                if obj.get("error"):
                    error = str(obj["error"])[:100]
                    break
                choices = obj.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                content = delta.get("content") or ""
                think = delta.get("reasoning") or delta.get("reasoning_content") or ""
                if ttfb is None and (content or think):
                    ttfb = time.time() - started
                chars += len(content)
                reasoning_chars += len(think)
    except urllib.error.HTTPError as exc:
        error = "HTTP " + str(exc.code) + " " + exc.read(200).decode("utf-8", "ignore")[:90]
        http = exc.code
    except Exception as exc:  # noqa: BLE001 - any transport failure is a datapoint
        error = type(exc).__name__ + ": " + str(exc)[:90]

    total = time.time() - started
    return {
        "ttfb": ttfb,
        "total": total,
        "chars": chars,
        "think": reasoning_chars,
        "error": error,
        "http": http,
    }


def main():
    key = load_key()
    print("model   : " + MODEL)
    print("rounds  : " + str(ROUNDS) + " per route, interleaved")
    print("maxtok  : " + str(MAX_TOKENS))
    print()

    samples = {name: [] for name, _ in ROUTES}

    for round_index in range(1, ROUNDS + 1):
        for name, url in ROUTES:
            result = one_call(url, key)
            samples[name].append(result)
            mark = "ok " if not result["error"] else "ERR"
            ttfb = "{:.2f}".format(result["ttfb"]) if result["ttfb"] else "  - "
            print(
                "  r{}  {:<16} {}  ttfb={:>6}s  total={:>6.2f}s  out={:>5}ch  think={:>5}ch{}".format(
                    round_index,
                    name,
                    mark,
                    ttfb,
                    result["total"],
                    result["chars"],
                    result["think"],
                    "  <- " + result["error"] if result["error"] else "",
                )
            )
            sys.stdout.flush()
        print()

    print("=" * 78)
    print("summary")
    print("=" * 78)
    print(
        "{:<16} {:>5} {:>9} {:>9} {:>9} {:>8} {:>8}".format(
            "route", "ok", "ttfb_med", "ttfb_min", "total_med", "out_tok", "tps"
        )
    )

    for name, _ in ROUTES:
        rows = samples[name]
        good = [r for r in rows if not r["error"] and r["ttfb"]]
        if not good:
            print("{:<16} {:>5}   (no successful sample)".format(name, 0))
            continue
        ttfb_med = statistics.median(r["ttfb"] for r in good)
        ttfb_min = min(r["ttfb"] for r in good)
        total_med = statistics.median(r["total"] for r in good)
        # ~4 chars per token for English prose and code; good enough for ranking.
        out_tok = statistics.median(r["chars"] for r in good) / 4.0
        gen_time = max(total_med - ttfb_med, 0.001)
        tps = out_tok / gen_time
        print(
            "{:<16} {:>5} {:>8.2f}s {:>8.2f}s {:>8.2f}s {:>8.0f} {:>7.1f}".format(
                name, len(good), ttfb_med, ttfb_min, total_med, out_tok, tps
            )
        )

    print()
    print("failures per route:")
    for name, _ in ROUTES:
        bad = [r for r in samples[name] if r["error"]]
        if bad:
            print("  " + name + ": " + str(len(bad)) + " -> " + bad[0]["error"])
        else:
            print("  " + name + ": none")


if __name__ == "__main__":
    main()
