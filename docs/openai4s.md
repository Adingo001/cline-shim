# OpenAI4S notes

Everything here concerns the OpenAI4S side of this install. The shim itself is
documented in the [README](../README.md); this file is the part that does not
apply if you only run dsh.

**The OpenAI4S launcher and its patches are not part of this repository.** The
`shim.py` adapter is consumer-agnostic — it answers the OpenAI wire on
127.0.0.1:8788 and does not care who calls it — so the OpenAI4S-specific
machinery was split out: `openai4s.ps1`, `openai4s.cmd`, `patch-openai4s.sh`,
`keepalive.sh` and `detect-fake-ip.sh`. This page records what those pieces did
and why, for anyone reviving that install.

Those five files are kept on disk beside this checkout under `_legacy/`, which
git ignores — **a fresh clone will not contain them**. If you still deploy
OpenAI4S with them, keep that directory somewhere safe; this repository is no
longer a complete description of that install.

The shim stays in the distro precisely because this install still runs there:
one instance serves dsh on Windows and OpenAI4S inside the distro. See
[Why the shim runs inside WSL](../README.md#why-the-shim-runs-inside-wsl).

## Why OpenAI4S runs under WSL

OpenAI4S needs POSIX process primitives that Windows does not expose:
`start_new_session=True`, a per-cell process group with exact `SIGINT`, and a
bubblewrap / Seatbelt sandbox backend. `openai4s/platform_support.py` accepts
only `darwin` and `linux` prefixes and raises `UnsupportedPlatform` on native
Windows, so the daemon runs in the Ubuntu WSL2 distro.

This is also why the shim lands in WSL rather than on Windows: it is one process
among the others already there, and the VM keeper that keeps it alive is the
same one the daemon needs.

## Why a scheduled task

WSL2 tears its VM down once no `wsl.exe` client is attached, and that teardown
kills every process inside it — including a `serve --detached` daemon. The
default `vmIdleTimeout` is 60 seconds, so an idle session loses both services
about a minute after you stop interacting with it.

A keep-alive child started with `Start-Process` does not survive: it is torn
down together with the launching PowerShell, which removes the last attached
client. Owned by Task Scheduler instead, the `wsl.exe` client outlives every
shell the launcher opens.

The old launcher registered an `OpenAI4S keepalive` task and touched
`~/.openai4s/.keepalive`; `stop` removed the lock, stopped the task and
unregistered it. Measured: 150 seconds of complete silence left the VM boot time
unchanged and both ports listening.

The `Cline shim` task that `install-autostart.ps1` registers is a deliberately
separate, machine-level setting: `openai4s.cmd stop` unregistered its own task,
and this one has to survive that. Removing the task does not stop the shim — use
`ctl.sh stop` for that.

## Environment selection

Two interpreter paths matter, and they are not the same:

- the **web UI** goes through `openai4s/server/gateway.py`, which calls
  `environments.default_env_name()` and picks the `python` conda env;
- the **CLI** (`openai4s run`) never calls `default_env_name()` — every caller
  lives in the server layer — so it starts cells on the control-plane
  interpreter, `.venv/bin/python` (the synthetic `base` env).

`base` therefore has to carry the same 24 `CORE_PACKAGES` as the conda `python`
env. Otherwise a CLI task cannot import seaborn/sympy/lxml, and then burns turns
trying to `pip install` inside the sandbox (no network) or reaching for an
approval channel that is not attached.

Fixed through the supported entry point rather than a manual pip:

```bash
cd ~/openai4s
.venv/bin/python -c "from openai4s.kernel.preinstall import ensure_core; ensure_core(background=False)"
```

Measured on the same sympy task: 16 action groups and ~89k input tokens before,
4 action groups and ~7.5k after.

## Patches applied to the checkout

Two upstream behaviours are wrong for this install, and both live in files a
release archive replaces wholesale. The retired `patch-openai4s.sh` re-applied
them on every start, so an upgrade repaired itself instead of silently reverting
them.

| Patch | File | What it fixes |
| --- | --- | --- |
| gzip | `openai4s/webtools.py` | `_http_get` yields `response.raw` under `stream=True`, and requests decompresses only through `.content` / `.iter_content` — never through `.raw`. A gzip `Content-Encoding` therefore reached callers as raw bytes, which `decode("utf-8", errors="replace")` turned into U+FFFD. One flag, `response.raw.decode_content = True`, makes the stream transparent. |
| Cell notice | `openai4s/server/completions.py` | The post-Cell line repeated "recorded in the Notebook" after every successful intermediate Cell, while the pre-action narration had already promised the same thing one turn earlier. The pointer is gone; the counts stay. This is web-UI narration, not model context. |

The script was idempotent, printed `already applied` when nothing was needed,
and exited 3 without touching a file whose anchor had moved upstream.

## Fake-IP DNS

`web_fetch` refuses a URL that resolves into the private/loopback range, which is
correct — except that Clash-style Fake-IP DNS maps ordinary public names into RFC
2544's `198.18.0.0/15`. `webtools` accepts that range only for a hostname in the
egress catalogue, gated by `OPENAI4S_ALLOW_FAKE_IP_DNS`.

Upstream's `configure_fake_ip_dns` requires the resolv.conf nameserver **and** a
probe to land in that range. That holds only when Clash runs its DNS listener
inside WSL. With a Clash TUN on the Windows side, `resolv.conf` points at the
WSL2 NAT gateway (`10.255.255.254`) while `api.openalex.org` still resolves to
`198.18.0.x` — so upstream's gate stays shut and every `web_fetch` is refused
with a message about a private address for a perfectly public name.

The retired `detect-fake-ip.sh` treated the probe as decisive and kept the
resolver check only as a fast path that skips the lookup. It wrote the answer in
two places: `$ShimDir/.fake_ip.env` for shells the launcher started, and the
checkout's `.env`, because `openai4s run` is a separate process from the daemon
and a plain terminal would otherwise leave the bridge off.

The bridge stays narrow either way: catalogue hostnames only, never an IP
literal, loopback, link-local, or metadata address.

None of this affects the shim or dsh — it is `webtools` policy inside the
OpenAI4S checkout.

## Capability detection

`openai4s/llm/capabilities.py` treats any loopback endpoint as unproven and
reports `tool_calling=False`. That only changes the wording of a nudging
message: tool declarations are still sent (`_model_tool_specs`), and
`agent/actions.py:route_action` routes native tool calls without consulting
capabilities. Both the native `finalize_response` path and the fenced-cell
`host.submit_output` path work against this shim.

## Layout

The application lives in the WSL distro, not on a Windows drive:

| Path (WSL) | Contents |
| --- | --- |
| `~/openai4s` | OpenAI4S checkout + `.venv` control plane |
| `~/openai4s-shim` | `shim.py`, `ctl.sh`, `autostart.sh`, logs, plus the `_verify.sh` / `_diag.sh` / `_heal_test.sh` checkers |
| `/etc/systemd/system/cline-shim.service` | unit that supervises the shim (`Restart=always`) and starts it at distro boot |
| `~/.mamba` | Python 3.11 and R 4.5.3 kernel environments |
| `~/.openai4s` | Daemon data directory |

Reachable from Windows as `\\wsl.localhost\Ubuntu\home\<user>\...`.

The shim directory keeps the historical `openai4s-shim` name because that is
where existing installs already point; `install-autostart.ps1 -InstallRoot`
overrides it, and the shim itself has no OpenAI4S dependency.
