# OpenAI4S launcher (WSL-backed)

**English** | [简体中文](README.zh-CN.md)

Windows entry point for an OpenAI4S install that runs inside WSL, wired to the
Cline Pass subscription gateway.

## Usage

| Command | Effect |
| --- | --- |
| `openai4s.cmd start` | Bring up shim + daemon, keep the VM alive, open the web UI |
| `openai4s.cmd stop` | Stop daemon and shim |
| `openai4s.cmd restart` | stop, then start |
| `openai4s.cmd status` | Shim health + daemon status |
| `openai4s.cmd doctor` | OpenAI4S environment checks |
| `openai4s.cmd logs` | Tail daemon and shim logs |
| `openai4s.cmd url` | Print and open the web UI URL |
| `openai4s.cmd shell` | Interactive shell in the install directory |

`start` accepts `-NoBrowser` to skip opening the browser, e.g.
`openai4s.cmd start -NoBrowser`. `logs` accepts `-Tail N`.

## Why WSL

OpenAI4S needs POSIX process primitives that Windows does not expose:
`start_new_session=True`, a per-cell process group with exact `SIGINT`, and a
bubblewrap / Seatbelt sandbox backend. `openai4s/platform_support.py` accepts
only `darwin` and `linux` prefixes and raises `UnsupportedPlatform` on native
Windows, so the daemon runs in the Ubuntu WSL2 distro.

## Why a scheduled task

WSL2 tears its VM down once no `wsl.exe` client is attached, and that teardown
kills every process inside it — including a `serve --detached` daemon. The
default `vmIdleTimeout` is 60 seconds, so an idle session loses both services
about a minute after you stop interacting with it.

A keep-alive child started with `Start-Process` does not survive: it is torn
down together with the launching PowerShell, which removes the last attached
client. Owned by Task Scheduler instead, the `wsl.exe` client outlives every
shell the launcher opens.

`start` registers the `OpenAI4S keepalive` task and touches
`~/.openai4s/.keepalive`; `stop` removes the lock, stops the task and
unregisters it. Measured: 150 seconds of complete silence left the VM boot
time unchanged and both ports listening.

## Why a shim

`https://api.cline.bot/api/v1` speaks the OpenAI wire, but four details break a
plain client:

1. Non-streaming replies are wrapped in `{"data": {...}, "success": true}`, so
   OpenAI4S's blocking path (`body["choices"]`) raises `KeyError`.
2. Reasoning arrives as `reasoning` / `reasoning_details`, while OpenAI4S reads
   `reasoning_content`.
3. Model ids must be `cline-pass/<name>`. A bare `z-ai/<name>` id resolves
   through Cline Credits instead of the subscription and returns HTTP 402.
4. Routing misses surface as HTTP 500 `empty response content` and are worth a
   transparent retry.
5. The gateway's automatic channel choice is neither the steadiest nor the
   fastest one, and a miss costs the whole turn.

`shim.py` repairs all five on `127.0.0.1:8788` without patching OpenAI4S. It
uses the standard library only, forwards the caller's `Authorization` header,
and stores no credential.

Point OpenAI4S at it in `.env`:

```dotenv
OPENAI4S_LLM_PROVIDER=ark
OPENAI4S_LLM_BASE_URL=http://127.0.0.1:8788
OPENAI4S_LLM_API_KEY=sk_...
OPENAI4S_LLM_MODEL=cline-pass/glm-5.3
```

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

* **Failover is only allowed before the first token.** Once content has reached
  the caller the reply is theirs; re-sending it would duplicate output. A
  routing miss on the streaming wire is *not* an HTTP error — the gateway
  answers `200 text/event-stream` whose very first frame is
  `{"error":{"code":"stream_initialization_failed",...}}`. The shim therefore
  holds frames back until one carries content, and only then commits the 200.
  A stream that ends without content becomes `EMPTY_RESPONSE`, the same verdict
  the reference `dsh-cline-pass` adapter reaches.
* **A dead key or a credits wall is never retried.** Every channel sits behind
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
| `CLINE_SHIM_PIN` | *(built-in)* | comma-separated channel order |
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

Register both layers:

```powershell
powershell -ExecutionPolicy Bypass -File install-autostart.ps1
powershell -ExecutionPolicy Bypass -File install-autostart.ps1 -Remove
```

This installs the systemd unit through `wsl -u root` and registers a
logon-triggered task named `Cline shim` running as the current user. Not at
boot: WSL distros are per-user, so a SYSTEM task sees no distro.
Not in the Startup folder either — a `Start-Process` child is torn down with
the shell that launched it, which removes the last attached client and lets the
VM idle out. Task Scheduler owns the `wsl.exe` client instead, so it outlives
every shell the launcher opens.

The task is deliberately separate from `OpenAI4S keepalive`, which
`openai4s.cmd stop` unregisters. This one is a machine-level setting for dsh
and survives that. Removing the task does not stop the shim — use
`openai4s-shim/ctl.sh stop`.

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

## What breaks without the shim

| Consumer | Configured at | Without the shim |
| --- | --- | --- |
| dsh (`settings.yaml`) | `baseURL: http://127.0.0.1:8788` | No fallback. Every turn fails with `fetch failed` / `ECONNREFUSED`, which dsh's classifier calls `TRANSPORT` — so it retries 5 times with backoff and then reports a transport error. |
| OpenAI4S (`.env`) | `OPENAI4S_LLM_BASE_URL=http://127.0.0.1:8788` | Same failures; its cells cannot run. |
| Claude Code CLI | `~/.claude/settings.json` | Unaffected — its `ANTHROPIC_BASE_URL` names a remote gateway. Point it at the shim instead and it inherits the pinned channel (see the Claude Code section above). |

## Environment selection

Two interpreter paths matter here, and they are not the same:

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

## Gateway channel pinning

Cline Pass routes one model across ~15 inference channels, and unpinned the
router picks by its own heuristic. Measured here on 2026-09-17 with
`cline-pass/deepseek-v4.1-flash`:

| `CLINE_SHIM_PIN_MODE` | Result |
| --- | --- |
| `off` | 0/8 — every request HTTP 500 `upstream_routing` |
| `preferred` | 10/10 |
| `strict` | 10/10 |

`ctl.sh` defaults to `strict`, because `off` shows the unpinned pool is the pool
that fails: a `preferred` fallthrough can only reach channels already known to be
dead. `shim.py` carries the ordered channel list, measured by time-to-first-token
against the live gateway. `ctl.sh status` reports the mode the running process
actually has.

## Local patches to the checkout

Two upstream behaviours are wrong for this install, and both live in files a
release archive replaces wholesale. `patch-openai4s.sh` re-applies them on every
start, so an upgrade repairs itself instead of silently reverting them.

| Patch | File | What it fixes |
| --- | --- | --- |
| gzip | `openai4s/webtools.py` | `_http_get` yields `response.raw` under `stream=True`, and requests decompresses only through `.content` / `.iter_content` — never through `.raw`. A gzip `Content-Encoding` therefore reached callers as raw bytes, which `decode("utf-8", errors="replace")` turned into U+FFFD. One flag, `response.raw.decode_content = True`, makes the stream transparent. |
| Cell notice | `openai4s/server/completions.py` | The post-Cell line repeated "recorded in the Notebook" after every successful intermediate Cell, while the pre-action narration had already promised the same thing one turn earlier. The pointer is gone; the counts stay. This is web-UI narration, not model context. |

The script is idempotent, prints `already applied` when nothing is needed, and
exits 3 without touching a file whose anchor has moved upstream.

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

`detect-fake-ip.sh` treats the probe as decisive and keeps the resolver check
only as a fast path that skips the lookup. It writes the answer in two places:
`$ShimDir/.fake_ip.env` for shells the launcher starts, and the checkout's
`.env`, because `openai4s run` is a separate process from the daemon and a plain
terminal would otherwise leave the bridge off.

The bridge stays narrow either way: catalogue hostnames only, never an IP
literal, loopback, link-local, or metadata address.

## Claude Code

### Registering a custom model id

Claude Code 2.1.276 refuses to start on a model id its catalog does not know:

```text
"cline_dsflash" isn't described by this version's model catalog; update Claude
Code, or map it with behavesAs on a modelPicker row ...
```

The catalog is what tells the client how large a context window to assume and
which prompt profile, capability and effort defaults to use, so a gateway alias
it has never heard of has no answer for any of that. Two settings fix it, and
both are the error's own suggestions.

`modelPicker` adds rows -- leave `replaceBuiltInOptions` out and the rows are
appended to the built-in lineup rather than replacing it:

```json
"modelPicker": {
  "options": [
    { "model": "cline_dsflash", "label": "DS Flash (cline)",
      "behavesAs": "claude-haiku-4-5" }
  ]
}
```

`behavesAs` names a model this build *does* know, and only its client-side
handling is borrowed: the prompt profile, capability and effort defaults. **The
id sent upstream is not changed**, which is the point -- the gateway still
receives `cline_dsflash` and the shim log confirms it. Verified on this build
with `claude -p`: exit 0, no `[claude-code:unrecognized_model]` line, no
catalog block, request reaching the gateway as `cline_dsflash`.

The ids this build knows, read out of `~/.clawgod/bunfs`, are `claude-haiku-4-5`,
`claude-sonnet-4-5`, `claude-sonnet-5`, `claude-opus-4-8`, `claude-opus-5` and
friends. The mapping here points at haiku because that is the slot
`cline_dsflash` fills in `ANTHROPIC_DEFAULT_HAIKU_MODEL`; point it at a sonnet
or opus id to get that model's handling instead.

The escape hatch below also works and is worth keeping as a belt-and-braces
measure for a model that appears outside the picker:

```json
"CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1",
"CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000"
```

### Gateway mode

Two different upstreams are worth pointing Claude Code at, so the shim runs in
one of two modes. `CLINE_MODEL_MODE=gateway` passes the caller's model id
through untouched and writes no pin, for the remote New API gateway that names
its own models; the default `prefix` mode is the Cline Pass behaviour below.

```bash
# tests/_gwctl.sh start  ->  http://127.0.0.1:8789
CLINE_UPSTREAM=https://GATEWAY_HOST/v1
CLINE_MODEL_MODE=gateway
CLINE_SHIM_PIN_MODE=off
```

It runs on its own port so it never disturbs the Cline Pass instance on 8788.
Pointing Claude Code at it is a `ANTHROPIC_BASE_URL` change, and the shim
forwards the caller's key untouched -- here that is the gateway key that
`https://GATEWAY_HOST` already accepts, not the Cline key.

What this buys is observation, not speed: the shim adds a hop, so it is not
faster than talking to the gateway directly. What it does add is a log line per
request carrying the numbers that actually govern the rate on this route.

```text
[cline-shim] POST /v1/messages model='cline_dsflash' stream cv=3 msgs in=2.0k tok (est) max=1.4k tools=0
```

`cv` is the message count and `in` is an input estimate (characters / 4, the
same ratio the local `count_tokens` route uses). Watch `in` across a session:
past roughly 34k the rate halves, which is the whole story of a long session
feeling slower than a fresh one.

A note on why there is no automatic context folding here. Summarising history
silently would rewrite the conversation -- the model would lose decisions it was
part of, and the resulting wrong answers would look like model failure. It also
defeats prefix caching, because every request would carry a different history.
`/compact` does the summarising with the model's own understanding, which is a
better summary than a byte-count rule can produce.

### Empty completions are retried here, not by the caller

The gateway intermittently answers with a well-formed 200 whose completion is
empty: `finish_reason=stop`, no content, no error. In the log it looks like
this, and it is not correlated with tool count -- three tools reproduce it as
readily as twenty-four:

```text
POST /v1/messages?beta=true model='cline_dsflash' cv=6 msgs in=4.8k tools=24
POST [auto] empty response content (finish_reason=stop)
POST /v1/messages?beta=true -> HTTP 500 (empty) after 1 channel(s)
```

Claude Code treats that 500 as a retryable API error and starts its own backoff,
which is what `API error . Retrying in 1s . attempt 2/10` on screen means. The
shim now repeats the request itself instead: nothing has been committed at that
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
time, and the only lever measured to move it is input size -- see the curve
above.

### Against the Cline Pass pool

Claude Code speaks the Anthropic wire on `/v1/messages`, and it was reaching a
*remote* gateway instead of this shim:

```json
"ANTHROPIC_BASE_URL": "https://GATEWAY_HOST",
"ANTHROPIC_MODEL": "cline_dsflash"
```

That gateway is a New API instance in front of OpenRouter. Its `cline_dsflash`
alias resolves to `deepseek/deepseek-v4-flash-0731` and the extra hops cost
both latency and throughput, measured on the same prompt:

| Route | first token | output rate | worst mid-stream stall |
| --- | --- | --- | --- |
| gateway alias (what it did) | 3.1–5.9s | 24.9 tps median (1.6–54.2) | **24.6s** |
| shim -> pinned cline-pass channel | 1.1–1.6s | 38–156 tps | 0.2–2.1s |

Token counting is decisive on its own: across 46 recent Claude Code requests the
gap between the client's timestamp and the upstream's own request epoch had a
median of 13.5s and a 90th percentile of 32s. That is gateway queueing plus
OpenRouter routing, not the model thinking.

So `shim.py` now terminates that wire too. `POST /v1/messages` is translated to
the OpenAI body (system prompt inlined, tool blocks converted, `stream_options`
added) and the OpenAI frames are rebuilt as Anthropic SSE: `message_start`,
`thinking` and `text` blocks with stable indexes, then `message_delta` and
`message_stop`. `POST /v1/messages/count_tokens` is answered locally. Blocking
bodies are converted to the Anthropic message object, with `reasoning_content`
becoming a `thinking` block rather than being dropped.

Point Claude Code at it:

```json
"ANTHROPIC_BASE_URL": "http://127.0.0.1:8788",
"ANTHROPIC_AUTH_TOKEN": "sk_<the Cline key>",
"ANTHROPIC_MODEL": "cline-pass/deepseek-v4.1-flash",
"ANTHROPIC_DEFAULT_FABLE_MODEL": "cline-pass/deepseek-v4.1-flash",
"ANTHROPIC_DEFAULT_HAIKU_MODEL": "cline-pass/deepseek-v4.1-flash",
"CLAUDE_CODE_SUBAGENT_MODEL": "cline-pass/deepseek-v4.1-flash"
```

The model id has to be a `cline-pass/<name>` id (or a bare name that normalises
to one): a gateway-private alias such as `cline_dsflash` means nothing upstream
and is rejected with HTTP 404. `ANTHROPIC_AUTH_TOKEN` must be the Cline key --
the shim forwards it untouched -- not the New API key that gateway used.

One limit is worth knowing: a Cline Pass pin lives in the OpenAI-shaped
`providerOptions` field, so an Anthropic request never carries one. The
translation injects it afterwards, which is what makes this route stable rather
than merely shorter: without the pin the same measurement scattered over
69-92 tps with a 2.96s worst frame gap, and one blocking round spent 64.6s on a
one-word answer. With the pin, over six rounds: 110-153 tps, 1.03-2.43s first
token, worst frame gap 0.36s.

Measured on the same models through this shim, `deepseek-v4.1-flash` is the
fastest thing in the pool (155.9 tps, 1.10s first token, 0.21s worst frame
gap); `glm-5.2`, `deepseek-v4-flash`, `glm-5.3` and `deepseek-v4-pro` sit at
52–57 tps, and `glm-5.3-flash` is the outlier to avoid (8.8 tps, a 2.66s gap).

## Endpoints

| Route | Purpose |
| --- | --- |
| `GET /health` | Shim liveness, upstream, subscription model count, wires |
| `GET /v1/models` | The 16 `cline-pass/*` subscription models |
| `POST /chat/completions` | Proxied completion (OpenAI wire) |
| `POST /v1/messages` | Proxied completion (Anthropic wire, translated) |
| `POST /v1/messages/count_tokens` | Local token estimate |

## The free `cline_dsflash` alias

Kept because it is a different question from the section above: not "which
route is fastest" but "why is this particular free alias slow", and the answer
does not involve this shim at all.

`cline_dsflash` resolves to `deepseek/deepseek-v4-flash-0731` through
OpenRouter. Measured over six rounds on the same 400-token prompt, against the
other aliases that resolve at all:

| alias | upstream | median tps | first token | worst stall |
| --- | --- | --- | --- | --- |
| `cline-free/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash` | **68.6** | 2.34s | 0.64s |
| `sensenova_dsflash` | `deepseek-v4-flash` | 55.8 | 2.00s | 0.23s |
| `cline_dsflash` | `deepseek/deepseek-v4-flash-0731` | 22.7 | 3.15s | 1.28s |

Two more behaviours show up under load and under a growing context:

* **Concurrency does not scale.** At six overlapping streams `cline_dsflash`
  aggregates 77.1 tps while each stream falls to 12-29 tps;
  `cline-free/deepseek-v4.1-flash` aggregates 320.9 tps at 48-120 tps per
  stream. Claude Code sends several requests at once for subagents, compaction
  and titles, so the per-stream number is what a turn feels like.
* **First token grows with the prompt.** From 1 turn to 30 turns
  (3.4k -> 101k input tokens) `cline_dsflash` goes 2.32s -> 11.47s and 56.0 ->
  19.1 tps. The gateway *does* cache -- `cached_tokens` reports 101120 -- so the
  growth is the gateway's own per-request overhead and the OpenRouter hop, not
  a missing cache. `/compact` and keeping sessions short are the only levers
  that move it.

`sensenova_dsflash` answers 429 once streams overlap, so it is not a drop-in
replacement despite the better per-request number.

**Context size is the dominant variable, not the alias.** Walking one alias up
the sizes a session actually reaches, `max_tokens` 400 throughout:

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
spends its life on the steep part of this curve -- which is why throughput feels
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

## Note on capability detection

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
| `~/openai4s-shim` | `shim.py`, `ctl.sh`, `autostart.sh`, `keepalive.sh`, logs, plus the `_verify.sh` / `_diag.sh` / `_heal_test.sh` checkers |
| `/etc/systemd/system/cline-shim.service` | unit that supervises the shim (`Restart=always`) and starts it at distro boot |
| `~/.mamba` | Python 3.11 and R 4.5.3 kernel environments |
| `~/.openai4s` | Daemon data directory |

Reachable from Windows as `\\wsl.localhost\Ubuntu\home\<user>\...`.