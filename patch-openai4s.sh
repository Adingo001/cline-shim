#!/usr/bin/env bash
# Reapply the local OpenAI4S patches. Idempotent, and safe to run on every
# start: both targets are files an upgrade replaces wholesale, so they get
# re-applied rather than hand-edited and forgotten.
#
# p1  openai4s/webtools.py
#     `_http_get` yields `response.raw` while `stream=True`, and requests
#     decompresses only through `.content` / `.iter_content`. A gzip
#     `Content-Encoding` therefore reached callers as raw bytes, and the later
#     `decode("utf-8", errors="replace")` turned every one of them into U+FFFD.
#
# p2  openai4s/server/completions.py
#     Drop the post-Cell "recorded in the Notebook" pointer. The pre-action
#     narration already promised the Notebook, so the sentence restated one
#     constant fact once per Cell.
#
# Exit 0 when both are in place (applied now or already), 3 when an anchor is
# gone because upstream moved it, 2 when the checkout itself is missing.
set -u

APP="${OPENAI4S_APP:-$HOME/openai4s}"
if [ ! -d "$APP" ]; then
    echo "patch-openai4s: no checkout at $APP" >&2
    exit 2
fi

python3 - "$APP" <<'PYEOF'
import io
import sys

app = sys.argv[1]
missing = 0


def load(rel):
    return io.open(app + "/" + rel, encoding="utf-8").read()


def store(rel, text):
    io.open(app + "/" + rel, "w", encoding="utf-8", newline="").write(text)


def patch(label, rel, mark, old, new):
    """Apply one patch unless `mark` proves it is already there."""
    global missing
    src = load(rel)
    if mark in src:
        print(f"{label}: already applied")
        return
    if src.count(old) != 1:
        print(f"{label}: ANCHOR MISSING in {rel} -- upstream changed, not touched")
        missing = 1
        return
    store(rel, src.replace(old, new, 1))
    print(f"{label}: applied")


P1_OLD = '''                if not 200 <= status_code < 300:
                    response.raise_for_status()
                    raise RuntimeError(f"HTTP request failed with status {status_code}")
                yield (
                    response.raw,'''

P1_NEW = '''                if not 200 <= status_code < 300:
                    response.raise_for_status()
                    raise RuntimeError(f"HTTP request failed with status {status_code}")
                # `stream=True` leaves the urllib3 stream undecoded, and requests
                # decompresses only through `.content` / `.iter_content` -- never
                # through `.raw`. Handing `.raw` on unchanged passes the server's
                # `Content-Encoding: gzip` bytes straight to the caller, and the
                # later `decode("utf-8", errors="replace")` turns every one of
                # them into U+FFFD. This flag is what makes `.raw` transparent to
                # that encoding.
                response.raw.decode_content = True
                yield (
                    response.raw,'''

P2_OLD = '''    if details:
        joined = "、".join(details) if zh else " and ".join(details)
        return (
            f"这个 Cell 已成功完成，产生了 {joined}；实际输出已记录在 Notebook。"
            if zh
            else f"This cell completed successfully with {joined}; the actual output is recorded in the Notebook."
        )
    return (
        "这个 Cell 已成功完成（没有 stdout 或 stderr）；运行状态已保留在 Notebook。"
        if zh
        else "This cell completed successfully with no stdout or stderr; its runtime state is recorded in the Notebook."
    )'''

P2_NEW = '''    if details:
        joined = "、".join(details) if zh else " and ".join(details)
        # The pre-action narration already promised the Notebook, and the
        # Notebook dock fills in by itself. Repeating that pointer after every
        # Cell restated one constant fact once per turn, while the part that
        # varies -- the counts -- is the part worth reading.
        return (
            f"这个 Cell 已成功完成，产生了 {joined}。"
            if zh
            else f"This cell completed successfully with {joined}."
        )
    return (
        "这个 Cell 已成功完成（没有 stdout 或 stderr）。"
        if zh
        else "This cell completed successfully with no stdout or stderr."
    )'''


patch("p1 gzip        ", "openai4s/webtools.py",
      "response.raw.decode_content = True", P1_OLD, P1_NEW)
patch("p2 cell notice  ", "openai4s/server/completions.py",
      "这个 Cell 已成功完成，产生了 {joined}。", P2_OLD, P2_NEW)

sys.exit(3 if missing else 0)
PYEOF
