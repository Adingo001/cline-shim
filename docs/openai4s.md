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

The distro no longer runs a shim. The shim lives on a Linux relay and every
consumer tunnels to it — see [Where the shim runs](../README.md#where-the-shim-runs).
What the distro runs instead is `cline-shim-tunnel.service`, an ssh forward
from its loopback 8788 to the relay's, which is why `OPENAI4S_LLM_BASE_URL`
still reads `http://127.0.0.1:8788` and needed no change.

## Why OpenAI4S runs under WSL

OpenAI4S needs POSIX process primitives that Windows does not expose:
`start_new_session=True`, a per-cell process group with exact `SIGINT`, and a
bubblewrap / Seatbelt sandbox backend. `openai4s/platform_support.py` accepts
only `darwin` and `linux` prefixes and raises `UnsupportedPlatform` on native
Windows, so the daemon runs in the Ubuntu WSL2 distro.

The distro also carries the forward to the relay's shim, as
`cline-shim-tunnel.service`. That is an ordinary systemd unit, so it comes back
with the distro and needs no supervisor of its own.

## Why a scheduled task, and whether it is still needed

The `Cline shim` task that `install-autostart.ps1` registers runs
`wsl.exe -d Ubuntu -- sleep infinity` on logon. It was written to hold the
distro up, on the reasoning that WSL2 tears its VM down once no `wsl.exe` client
is attached — default `vmIdleTimeout` 60 seconds — killing every process inside,
including a `serve --detached` daemon. A keep-alive child started with
`Start-Process` would not survive, since it dies with the launching PowerShell;
owned by Task Scheduler, the client outlives every shell the launcher opens.

**That reasoning no longer holds here, and the keep-alive holds nothing up.**
Measured: the keep-alive process was killed and the machine left alone for 100
seconds. The distro stayed up (`PID 1 = systemd`, `systemctl is-system-running`
reported `running`), the tunnel unit stayed `active`, and the distro's
`127.0.0.1:8788` still answered `/health` with 200.

The cause is `/etc/wsl.conf`:

```ini
[boot]
systemd=true
```

With systemd as PID 1 a process always exists in the distro, so the idle
teardown the task was written against never fires. The 60-second behaviour
belongs to a distro **without** systemd, where the last `wsl.exe` client exiting
really does end the session.

That leaves the task's **logon trigger**, which starts the distro after a
Windows reboot. That is optional too:

- **dsh** runs on Windows and reaches the relay through its own tunnel. It never
  touches the distro.
- **OpenAI4S** is launched by `./start.sh` from a shell, which starts the distro
  on demand; `cline-shim-tunnel.service` is `enabled`, so systemd brings the
  forward up along with it.

Removing the task therefore costs nothing on this install; it is kept only
because a distro already running at logon makes the first OpenAI4S launch
marginally faster.

The task stays deliberately separate from OpenAI4S's own launcher, which
unregistered its `OpenAI4S keepalive` task on `stop`; this one has to survive
that.

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
| `~/openai4s-shim` | `shim.py`, `ctl.sh`, `autostart.sh`, logs and the `_verify.sh` / `_diag.sh` / `_heal_test.sh` checkers — **no longer running**; kept only so the old install can be revived |
| `/etc/systemd/system/cline-shim.service` | the retired shim supervisor (`inactive`, `disabled`) |
| `/etc/systemd/system/cline-shim-tunnel.service` | forwards the distro's `127.0.0.1:8788` to the relay's shim (`Restart=always`, enabled at boot) |
| `~/.ssh/relay_shim` | the key that tunnel authenticates with |
| `~/.mamba` | Python 3.11 and R 4.5.3 kernel environments |
| `~/.openai4s` | Daemon data directory |

Reachable from Windows as `\\wsl.localhost\Ubuntu\home\<user>\...`.

The shim directory keeps the historical `openai4s-shim` name because that is
where existing installs already point; `install-autostart.ps1 -InstallRoot`
overrides it, and the shim itself has no OpenAI4S dependency.
