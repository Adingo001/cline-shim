# Claude Code notes

`shim.py` answers two wires: the OpenAI wire on `/chat/completions` and the
Anthropic wire on `/v1/messages`. dsh uses the first. This page covers
everything specific to driving Claude Code through the second, plus the
measurements behind one particular free alias on the remote gateway.

If you only run dsh, none of this applies — see the [README](../README.md).

## Registering a custom model id

Claude Code 2.1.276 refuses to start on a model id its catalog does not know:

```text
"cline_dsflash" isn't described by this version's model catalog; update Claude
Code, or map it with behavesAs on a modelPicker row ...
```

The catalog is what tells the client how large a context window to assume and
which prompt profile, capability and effort defaults to use, so a gateway alias
it has never heard of has no answer for any of that. Two settings fix it, and
both are the error's own suggestions.

`modelPicker` adds rows — leave `replaceBuiltInOptions` out and the rows are
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
id sent upstream is not changed**, which is the point — the gateway still
receives `cline_dsflash` and the shim log confirms it. Verified on this build
with `claude -p`: exit 0, no `[claude-code:unrecognized_model]` line, no
catalog block, request reaching the gateway as `cline_dsflash`.

The ids this build knows, read out of `~/.clawgod/bunfs`, are `claude-haiku-4-5`,
`claude-sonnet-4-5`, `claude-sonnet-5`, `claude-opus-4-8`, `claude-opus-5` and
friends. The mapping above points at haiku because that is the slot
`cline_dsflash` fills in `ANTHROPIC_DEFAULT_HAIKU_MODEL`; point it at a sonnet
or opus id to get that model's handling instead.

The escape hatch below also works and is worth keeping as a belt-and-braces
measure for a model that appears outside the picker:

```json
"CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT": "1",
"CLAUDE_CODE_MAX_CONTEXT_TOKENS": "200000"
```

## Gateway mode on 8789

Two different upstreams are worth pointing a client at, so the shim runs in one
of two modes. `CLINE_MODEL_MODE=gateway` passes the caller's model id through
untouched and writes no pin, for a remote New API gateway that names its own
models; the default `prefix` mode is the Cline Pass behaviour described in the
README.

```bash
# tests/_gwctl.sh start  ->  http://127.0.0.1:8789
CLINE_UPSTREAM=https://GATEWAY_HOST/v1
CLINE_MODEL_MODE=gateway
CLINE_SHIM_PIN_MODE=off
```

It runs on its own port so it never disturbs the Cline Pass instance on 8788.
Pointing Claude Code at it is an `ANTHROPIC_BASE_URL` change, and the shim
forwards the caller's key untouched — here that is the gateway key that
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
feeling slower than a fresh one. The [README](../README.md) carries the full
size-versus-throughput curve, which applies to any client.

A note on why there is no automatic context folding here. Summarising history
silently would rewrite the conversation — the model would lose decisions it was
part of, and the resulting wrong answers would look like model failure. It also
defeats prefix caching, because every request would carry a different history.
`/compact` does the summarising with the model's own understanding, which is a
better summary than a byte-count rule can produce.

## Why the Anthropic wire is translated

Claude Code speaks the Anthropic wire on `/v1/messages`, and by default it
reaches a *remote* gateway instead of this shim:

```json
"ANTHROPIC_BASE_URL": "https://GATEWAY_HOST",
"ANTHROPIC_MODEL": "cline_dsflash"
```

That gateway is a New API instance in front of OpenRouter. Its `cline_dsflash`
alias resolves to `deepseek/deepseek-v4-flash-0731` and the extra hops cost both
latency and throughput, measured on the same prompt:

| Route | first token | output rate | worst mid-stream stall |
| --- | --- | --- | --- |
| gateway alias (what it did) | 3.1–5.9s | 24.9 tps median (1.6–54.2) | **24.6s** |
| shim -> pinned cline-pass channel | 1.1–1.6s | 38–156 tps | 0.2–2.1s |

Token counting is decisive on its own: across 46 recent Claude Code requests the
gap between the client's timestamp and the upstream's own request epoch had a
median of 13.5s and a 90th percentile of 32s. That is gateway queueing plus
OpenRouter routing, not the model thinking.

So `shim.py` terminates that wire too. `POST /v1/messages` is translated to the
OpenAI body (system prompt inlined, tool blocks converted, `stream_options`
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
and is rejected with HTTP 404. `ANTHROPIC_AUTH_TOKEN` must be the Cline key —
the shim forwards it untouched — not the New API key that gateway used.

One limit is worth knowing: a Cline Pass pin lives in the OpenAI-shaped
`providerOptions` field, so an Anthropic request never carries one. The
translation injects it afterwards, which is what makes this route stable rather
than merely shorter: without the pin the same measurement scattered over
69–92 tps with a 2.96s worst frame gap, and one blocking round spent 64.6s on a
one-word answer. With the pin, over six rounds: 110–153 tps, 1.03–2.43s first
token, worst frame gap 0.36s.

Measured on the same models through this shim, `deepseek-v4.1-flash` is the
fastest thing in the pool (155.9 tps, 1.10s first token, 0.21s worst frame
gap); `glm-5.2`, `deepseek-v4-flash`, `glm-5.3` and `deepseek-v4-pro` sit at
52–57 tps, and `glm-5.3-flash` is the outlier to avoid (8.8 tps, a 2.66s gap).

## The free `cline_dsflash` alias

Kept because it is a different question from the section above: not "which route
is fastest" but "why is this particular free alias slow", and the answer does
not involve this shim at all.

`cline_dsflash` resolves to `deepseek/deepseek-v4-flash-0731` through
OpenRouter. Measured over six rounds on the same 400-token prompt, against the
other aliases that resolve at all:

| alias | upstream | median tps | first token | worst stall |
| --- | --- | --- | --- | --- |
| `cline-free/deepseek-v4.1-flash` | `deepseek/deepseek-v4.1-flash` | **68.6** | 2.34s | 0.64s |
| `sensenova_dsflash` | `deepseek-v4-flash` | 55.8 | 2.00s | 0.23s |
| `cline_dsflash` | `deepseek/deepseek-v4-flash-0731` | 22.7 | 3.15s | 1.28s |

Two more behaviours show up under load and under a growing context:

- **Concurrency does not scale.** At six overlapping streams `cline_dsflash`
  aggregates 77.1 tps while each stream falls to 12–29 tps;
  `cline-free/deepseek-v4.1-flash` aggregates 320.9 tps at 48–120 tps per
  stream. Claude Code sends several requests at once for subagents, compaction
  and titles, so the per-stream number is what a turn feels like.
- **First token grows with the prompt.** From 1 turn to 30 turns
  (3.4k -> 101k input tokens) `cline_dsflash` goes 2.32s -> 11.47s and 56.0 ->
  19.1 tps. The gateway *does* cache — `cached_tokens` reports 101120 — so the
  growth is the gateway's own per-request overhead and the OpenRouter hop, not
  a missing cache. `/compact` and keeping sessions short are the only levers
  that move it.

`sensenova_dsflash` answers 429 once streams overlap, so it is not a drop-in
replacement despite the better per-request number.
