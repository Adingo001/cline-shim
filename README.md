# cline-shim

**English** | [简体中文](README.zh-CN.md)

A local OpenAI-compatible adapter in front of the Cline Pass subscription
gateway. It listens on `127.0.0.1:8788`, repairs four wire details that a plain
client trips over, and pins the upstream channel so a turn does not land on a
slow one at random.

It is built for [dsh](https://github.com/deepseek-ai) — a harness that points its
`cline` provider here with no fallback — but it is consumer-agnostic: anything
speaking the OpenAI wire can use it. Notes for other consumers live in
[`docs/`](docs/): [OpenAI4S](docs/openai4s.md),
[Claude Code](docs/claude-code.md).

## Scope

What this is:

- A **loopback-only** adapter. It binds `127.0.0.1`, forwards the caller's
  `Authorization` header untouched, and stores no credential of its own.
- A **wire normaliser**: response envelope, reasoning field name, bare model
  ids, and transient routing misses.
- A **channel pin**: it names the inference channel instead of letting the
  router choose per request.

What this is not:

- Not a proxy or a sharing service. It is not a gateway for other machines, and
  nothing in it is designed to be reachable off-host.
- Not a way around billing. It carries no key, so every request is billed to
  whichever account the caller's own key belongs to. Pinning changes which
  server answers, never who pays.
- Not a Cline account tool. It needs a working subscription key that you already
  have; it does not obtain, rotate, or validate one beyond passing it upstream.
- Not an OpenAI4S or Claude Code installer any more. The launchers that drove
  those two installs were split out of this repository — see [docs](docs/).

## What gets installed

`install-autostart.ps1` is the only entry point. Running it changes exactly
these things:

| Where | What | Why |
| --- | --- | --- |
| `$HOME/openai4s-shim/` (inside WSL) | `shim.py`, `ctl.sh`, `autostart.sh`, `_verify.sh`, `_diag.sh`, `_heal_test.sh` | the adapter and its checkers; copied over `\\wsl.localhost`, then line endings are normalised and exec bits set |
| `/etc/systemd/system/cline-shim.service` | a systemd unit, `Restart=always`, `RestartSec=5`, enabled at boot | owns the shim process; written through `wsl -u root` |
| Windows Task Scheduler | a task named `Cline shim`, logon-triggered, running as the current user, `wsl.exe -d Ubuntu -- sleep infinity` | owns the WSL2 VM, which otherwise idles out ~60s after the last `wsl.exe` client detaches |

It does **not** touch the registry, `PATH`, drivers, or any Windows file outside
Task Scheduler. It does not install Python packages. The `-ExecutionPolicy
Bypass` flag applies to that one PowerShell process, not to the machine.

Two things are worth knowing before you run it:

- The unit write and the boot enable need root. `install-autostart.ps1` uses
  `wsl -u root` rather than `sudo`, so it never prompts for a password.
- The task is registered with an empty run-as password, so `schtasks` will warn
  that it "may not run because of the security policy". A manual trigger
  returns `LastResult: 0`; whether the logon trigger itself fires has not been
  confirmed across a real reboot. If the shim is down after a restart, start the
  task by hand and check `_diag.sh` — that is a reporting gap, not a broken
  install.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File install-autostart.ps1
```

Optional overrides: `-Distro Ubuntu`, `-TaskName 'Cline shim'`,
`-InstallRoot <path>`. The install root defaults to `$HOME/openai4s-shim` inside
the distro — a historical name that existing installs already point at. The shim
itself has no OpenAI4S dependency.

Then point dsh at it in `settings.yaml`:

```yaml
llm-pi-ai:
  providers:
    cline:
      baseURL: http://127.0.0.1:8788
```

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove
```

That stops and unregisters the task, disables and deletes the unit, and runs
`systemctl daemon-reload`. It deliberately leaves `$HOME/openai4s-shim/` on disk
so your logs survive; delete it yourself if you want it gone.

If `-Remove` fails — usually because the task was already deleted by hand, or
the distro is not running — do the two layers separately:

```powershell
Unregister-ScheduledTask -TaskName 'Cline shim' -Confirm:$false
wsl -u root -d Ubuntu -- bash -lc "systemctl disable --now cline-shim.service; rm -f /etc/systemd/system/cline-shim.service; systemctl daemon-reload"
```

Removing the task alone does **not** stop the shim: the task owns the VM, while
systemd owns the process. Stop the shim with `ctl.sh stop`.

## What breaks without the shim

| Consumer | Configured at | Without the shim |
| --- | --- | --- |
| dsh (`settings.yaml`) | `baseURL: http://127.0.0.1:8788` | No fallback. Every turn fails with `fetch failed` / `ECONNREFUSED`, which dsh's classifier calls `TRANSPORT` — so it retries 5 times with backoff and then reports a transport error. |

## Why a shim

`https://api.cline.bot/api/v1` speaks the OpenAI wire, but four details break a
plain client:

1. Non-streaming replies are wrapped in `{"data": {...}, "success": true}`, so a
   blocking path that indexes `body["choices"]` raises `KeyError`.
2. Reasoning arrives as `reasoning` / `reasoning_details`, while the OpenAI
   convention is `reasoning_content`.
3. Model ids must be `cline-pass/<name>`. A bare `z-ai/<name>` id resolves
   through Cline Credits instead of the subscription and returns HTTP 402.
4. Routing misses surface as HTTP 500 `empty response content` and are worth a
   transparent retry.
5. The gateway's automatic channel choice is neither the steadiest nor the
   fastest one, and a miss costs the whole turn.

`shim.py` repairs all five on `127.0.0.1:8788` without patching any client. It
uses the standard library only, forwards the caller's `Authorization` header,
and stores no credential.

A bare model name (`glm-5.3`) and an upstream catalog id (`z-ai/glm-5.3`) are
both normalised to `cline-pass/glm-5.3`.

## Upstream pinning

A Cline Pass model is not served by one machine. The gateway routes it across
around fifteen inference channels, and which one you get is decided per
request. Measured on `cline-pass/deepseek-v4.1-flash` on 2026-09-17, the
router's own choice answered correctly every time but scattered across
whichever channel it liked (`fireworks:4 alibaba:3 novita:1` over 8 rounds),
and some channels in that pool need a minute to produce a first token. The
shim removes the lottery by naming the channel itself: same measurement, 1.4s
mean instead of 2.5s, and always the same server.

### The wire format

The gateway reads a pin from `providerOptions.gateway`:

| Field | Meaning |
| --- | --- |
| `only` | allow-list — the router must use one of these, or fail |
| `order` | preference list — try these first, then the rest |
| `sort` | `cost` \| `ttft` \| `tps` — pick the winner by a metric |

The OpenRouter spelling (`provider.only` / `provider.order`) is accepted and
silently ignored: pinning an impossible name under each spelling, only the
`providerOptions.gateway` one produced the router's complaint. `sort` cannot be
folded into `order`'s list either — this gateway *rejects* an unknown provider
name in `order` rather than deprioritising it, so an unverified name is a hard
failure, not a fallback.

### The two rules

- **Failover is only allowed before the first token.** Once content has reached
  the caller the reply is theirs; re-sending it would duplicate output. A
  routing miss on the streaming wire is *not* an HTTP error — the gateway
  answers `200 text/event-stream` whose very first frame is
  `{"error":{"code":"stream_initialization_failed",...}}`. The shim therefore
  holds frames back until one carries content, and only then commits the 200.
  A stream that ends without content becomes `EMPTY_RESPONSE`.
- **A dead key or a credits wall is never retried.** Every channel sits behind
  the same account, so cycling them only rehearses the failure. Everything
  else — a router miss, a full channel, a dropped stream — is channel-specific
  and is exactly what the next attempt is for.

### Defaults

The built-in order for `cline-pass/deepseek-v4.1-flash` is `togetherai, novita,
deepinfra, parasail, alibaba, runware, boundless, gmicloud`: the subset that
answered cleanly when the list was measured, ranked by observed
time-to-first-token. The other channels were not excluded for being broken —
capacity comes and goes within a day (`fireworks` was at capacity in the
morning and served four of eight unpinned rounds in the evening) — but a pin
only pays for itself if it is stable, so the order names the servers that were
both fast and consistently up.

### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `CLINE_SHIM_PIN_MODE` | `strict` (via `ctl.sh`) | `strict` \| `preferred` \| `off` |
| `CLINE_SHIM_PIN` | *(built-in)* | comma-separated channel order; fully replaces the built-in list |
| `CLINE_SHIM_EXCLUDE` | *(none)* | channels to route around |
| `CLINE_SHIM_BUDGET` | `120` | seconds spent failing over, not generating |

`preferred` walks the list with `order`, so the router may still fall through
to an unvetted channel. `strict` pins each channel with `only` in turn — the
only way to force an unpopular channel, at the cost of making a dead one a hard
failure within one attempt before the shim moves to the next entry. `off`
restores plain pass-through.

Measured over 8 streaming rounds each: `off` 8/8 in 2.5s mean,
`strict` 8/8 in 1.4s mean on one channel, `preferred` 7/8 (one empty response
from the channel the router fell through to). `off` is *not* broken; the
reason to pin is that a dsh turn is long, so the first token is the expensive
one and a steady 1.4s beats a variable 1.5–4s.

### Inspecting it

| Route | Purpose |
| --- | --- |
| `GET /health` | liveness, pin mode, exclusions |
| `GET /models` | the subscription model ids |
| `GET /channels?model=<id>` | the resolved attempt order for one model |

`/channels` reports the built-in order by default. Adding `&discover=1` spends
one request (no tokens — the router fails before generating) to have the
gateway name its own channels, and caches the answer for an hour.

## Why the shim runs inside WSL

`shim.py` itself has no POSIX dependency. It imports `json`, `os`, `re`, `sys`,
`time`, `urllib` and `http.server`, and `main()` is a `ThreadingHTTPServer`
bound to `127.0.0.1`. It would run on Windows unchanged.

It lives in the distro because that is where the other consumer is. OpenAI4S
needs `start_new_session=True`, a per-cell process group with exact `SIGINT`,
and a bubblewrap sandbox backend, so it only runs under Linux — the shim was
written for it and stayed there. One instance then serves both:

| Consumer | Runs on | Reaches the shim at |
| --- | --- | --- |
| dsh | Windows | `127.0.0.1:8788`, through WSL2's localhost forwarding |
| OpenAI4S | inside the distro | `127.0.0.1:8788`, directly |

That is also why the shim binds loopback only. A Windows-native shim would not
be reachable from inside the distro without binding `0.0.0.0`, which would turn
it into an open relay for anyone on the LAN holding a key of their own.

If the OpenAI4S install ever goes away, this whole WSL layer stops being
necessary: `shim.py` runs on Windows as-is, a user-level scheduled task can own
it — no administrator rights, no `wsl -u root` — and the VM keeper, the systemd
unit and the 30-second supervisor loop all disappear together.

## Keeping the shim up

Two facts make "just start it" insufficient:

1. dsh in `settings.yaml` points its `cline` provider at
   `http://127.0.0.1:8788` with no fallback, so a stopped shim is a dsh that
   cannot answer at all.
2. The shim runs inside the WSL2 VM, and WSL2 tears the VM down about 60
   seconds after the last `wsl.exe` client detaches — taking the shim with it.

Three layers cover that, each owning exactly one failure mode:

| Layer | Owns | Mechanism |
| --- | --- | --- |
| `Cline shim` scheduled task | the VM | a resident `wsl.exe -d Ubuntu -- sleep infinity`, so a client stays attached and the VM never idles out |
| `cline-shim.service` (systemd) | the shim process | `Restart=always`, 5s — measured to bring back a killed shim in 3s |
| `autostart.sh` | the port | calls `ctl.sh start`, then re-checks every 30 seconds (idempotent — `ctl.sh` returns immediately while the port is bound) |

The split matters. `autostart.sh` is a loop, which is why it also holds the VM
open — that was the original design, with the task running it directly. But
that made the task a second manager of the shim, and every task start left
another supervisor running beside systemd's. The task now owns only the VM;
systemd owns the shim, and there is exactly one supervisor.

Not at boot: WSL distros are per-user, so a SYSTEM task sees no distro.
Not in the Startup folder either — a `Start-Process` child is torn down with
the shell that launched it, which removes the last attached client and lets the
VM idle out. Task Scheduler owns the `wsl.exe` client instead, so it outlives
every shell a user opens.

### Two traps

Both were hit during setup, and both present as "the shim did not start".

**Do not make the unit depend on the network.** An `After=network-online.target`
line looks harmless and is not: with the network down the target never becomes
active, the unit waits on it, and the shim never starts — even though it only
listens on loopback and needs no network to bind. Measured with the network
down: `network-online.target` inactive, service `active`, `/health` ok.

**Do not give the task a one-shot command.** Changing it to
`wsl.exe -d Ubuntu -- true` removes the resident client, so the VM idles out
about a minute later and takes the shim with it. The task has to keep a process
alive; `sleep infinity` is the minimal form.

### Verifying

```powershell
wsl -d Ubuntu -- bash -lc 'bash ~/openai4s-shim/_verify.sh'
```

`boot_id` is the part that matters: a steady `boot_id` with growing `uptime`
means the VM stayed up, and a changed one means it restarted and the task's
resident client is not doing its job. Measured end to end with `wsl --shutdown`
followed by the task's own command: fresh `boot_id`, service `active`, shim
listening, `/health` ok, one supervisor.

`_diag.sh` dumps unit state, blocking dependencies and both logs when something
is wrong; `_heal_test.sh` kills the shim outright and reports how long it took
to come back.

## Endpoints

| Route | Purpose |
| --- | --- |
| `GET /health` | Shim liveness, upstream, subscription model count, wires |
| `GET /v1/models` | The 16 `cline-pass/*` subscription models |
| `POST /chat/completions` | Proxied completion (OpenAI wire) |
| `POST /v1/messages` | Proxied completion (Anthropic wire, translated) |
| `POST /v1/messages/count_tokens` | Local token estimate |

## Empty completions are retried here, not by the caller

The gateway intermittently answers with a well-formed 200 whose completion is
empty: `finish_reason=stop`, no content, no error. It is not correlated with
tool count — three tools reproduce it as readily as twenty-four:

```text
POST /v1/messages?beta=true model='cline_dsflash' cv=6 msgs in=4.8k tools=24
POST [auto] empty response content (finish_reason=stop)
POST /v1/messages?beta=true -> HTTP 500 (empty) after 1 channel(s)
```

A client treats that 500 as a retryable API error and starts its own backoff,
which is what `API error . Retrying in 1s . attempt 2/10` on screen means. The
shim repeats the request itself instead: nothing has been committed at that
point, the caller never saw a byte, and re-sending the same body succeeds
because the upstream re-rolls per request. Measured over ten tool-using turns,
client-visible failures went from roughly half to **0/10**.

Two details make this work. `RETRYABLE_EMPTY` is an internal status meaning
"empty, worth repeating", kept distinct from a routing miss (which carries 200
and must move to the next channel); `final_status()` maps it to 500 before
anything reaches the caller. A lone attempt also gets a wider retry budget than
a pinned one, because it has no next channel to fail over to.

Stalls are a separate problem and this does not fix them: three of those ten
turns took 77s, 98s and 130s, against a median of 24.8s. That is upstream queue
time, and the only lever measured to move it is input size — see below.

## Context size is the dominant variable

Walking one alias up the sizes a session actually reaches, `max_tokens` 400
throughout:

| input | cache hit | first token | tps |
| --- | --- | --- | --- |
| 3k | 0% | 2.27s | 79.9 |
| 17k | 19% | 3.72s | 85.0 |
| 34k | 49% | 5.25s | 68.2 |
| 68k | 79% | 7.93s | 28.7 |
| 102k | 53% | 11.59s | 19.8 |
| 170k | 59% | 18.80s | 13.9 |

The cliff sits between 34k and 68k: the rate halves there and keeps sliding,
while first-token latency grows roughly linearly. Session logs show the main
model averaging **57.6k** input and peaking at **98.3k**, so a working session
spends its life on the steep part of this curve — which is why throughput feels
high right after a fresh start and low an hour later. The cache hit percentage
climbing to 79% does not rescue it, because what is paid is the gateway's own
per-request cost on top of the prefix.

Compacting is the lever that moves it, measured back to back on a 67k context:

```text
before /compact   in 67601  cached 67584  ttfb 5.77s  tps 67.0
after  /compact   in   130  cached     0  ttfb 1.83s  tps 53.8
before /compact   in 67601  cached 67584  ttfb 6.74s  tps 17.8
after  /compact   in   130  cached     0  ttfb 2.61s  tps 31.2
before /compact   in 67601  cached 66304  ttfb 6.91s  tps 20.4
after  /compact   in   130  cached     0  ttfb 2.14s  tps 37.0
```

Median 20.4 -> 37.0 tps and 6.5s -> 2.2s to first token. Reusing one session all
day is what makes a model look like it degraded; the alias never changed.

## Layout

The shim lives in the WSL distro, not on a Windows drive:

| Path (WSL) | Contents |
| --- | --- |
| `~/openai4s-shim` | `shim.py`, `ctl.sh`, `autostart.sh`, logs, plus the `_verify.sh` / `_diag.sh` / `_heal_test.sh` checkers |
| `/etc/systemd/system/cline-shim.service` | unit that supervises the shim (`Restart=always`) and starts it at distro boot |

Reachable from Windows as `\\wsl.localhost\Ubuntu\home\<user>\...`.

## Tests

There is no unit-test suite in this repository — no `pytest.ini`, no
`conftest.py`, no `test_*.py`. What exists is a set of operational checkers,
which is what the failure modes here actually need:

| Script | Runs where | Purpose |
| --- | --- | --- |
| `_verify.sh` | WSL | end-to-end state: `boot_id`, `uptime`, unit state, listening port, `/health` |
| `_diag.sh` | WSL | unit state, blocking dependencies, both logs |
| `_heal_test.sh` | WSL | kills the shim and reports how long systemd took to bring it back |
| `_gwctl.sh` | WSL | runs a second shim instance in gateway mode on 8789 |
| `_deploy.sh` | WSL | pushes a patched `shim.py` and restarts |

`tests/_e2e.py` is deliberately **not** distributed here. It is a live-protocol
probe, not a unit test: it drives eight `CLINE_SHIM_PIN` combinations
(`CLINE_SHIM_PIN_MODE`, `CLINE_SHIM_EXCLUDE`), calls `/channels?model=...&discover=1`
against the real gateway, and compares `/health`. Every one of those paths needs
a live upstream and a working subscription key, so on a machine without
credentials it does not run — it fails at the first request. Publishing it would
describe a test nobody can execute, and its results are a snapshot of which
upstream channels happened to be healthy on the day, not a property of this
code. It is kept out of the repository for the same reason the other probes are:
see `tests/_probe*` in `.gitignore`. The `.gitignore` entry is the record of
that decision.

To re-run it locally, keep it beside the shim and give it the environment it
expects:

```bash
cd ~/openai4s-shim
CLINE_SHIM_PIN_MODE=strict python3 tests/_e2e.py   # needs a live gateway + key
```

## Security notes

- **Do not rebind 8788 to `0.0.0.0`.** The shim forwards whatever
  `Authorization` header the caller sends. On loopback that is your own client;
  on a LAN interface it is an open relay for anyone who can reach the port with
  a key of their own. Nothing in this repository is designed for that use.
- **The shim stores no credential.** `shim.py` uses the standard library only,
  keeps no key on disk, and writes request metadata (model, message count, an
  input-size estimate) to its log — not request bodies.
- **Logs may still be sensitive.** They carry model ids, sizes and timings. If
  that matters to you, keep `~/openai4s-shim` off any synced or shared path.
