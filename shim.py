#!/usr/bin/env python3
"""OpenAI-compatible adapter in front of the Cline Pass gateway.

OpenAI4S speaks the plain OpenAI wire. The Cline Pass gateway answers on the
same wire but differs in five places that break a naive client:

1. Non-streaming replies are wrapped in ``{"data": {...}, "success": true}``,
   so a client reading ``body["choices"]`` raises KeyError.
2. Assistant reasoning arrives as ``reasoning`` / ``reasoning_details`` rather
   than the ``reasoning_content`` field OpenAI4S reads.
3. Model ids must be ``cline-pass/<name>``. A bare ``z-ai/<name>`` id bills
   against Cline Credits (normally empty, HTTP 402) instead of the
   subscription.
4. Routing failures surface as HTTP 500 ``empty response content`` and are
   worth one transparent retry before the client ever sees them.
5. Every model is served by a pool of upstream channels, and the gateway's
   automatic pick is neither the fastest nor the steadier one. The shim pins
   the channel and fails over before the first token.

This process repairs those five without patching OpenAI4S. It depends on the
standard library only, forwards the caller's Authorization header, and never
stores a credential.

Anthropic callers
-----------------
The pinning only pays off for a caller that reaches this process, and Claude
Code does not: it speaks the Anthropic wire on ``/v1/messages``, so it went
straight to whichever gateway its ANTHROPIC_BASE_URL named and inherited that
gateway's own routing. Measured on the same prompt against the live pool, the
subscription channel this shim pins answered at 155.9 tps with a 1.10s first
token, while the gateway alias route sat at 25-31 tps with a 3-9s first token
and one round that stalled 24.6 seconds mid-stream.

So ``/v1/messages`` is translated here: the request body is rewritten to the
OpenAI shape (system prompt inlined, tool blocks converted, ``stream_options``
added) and the OpenAI frames that come back are rebuilt as Anthropic SSE --
``message_start`` first, then ``thinking`` and ``text`` blocks with stable
indexes, then ``message_delta`` and ``message_stop``. The upstream path is
``/chat/completions`` either way; the wire is the caller's choice.

Upstream pinning
----------------
A Cline Pass model is routed to one of ~15 inference channels (``togetherai``,
``novita``, ``deepinfra``, ...). Unpinned, the gateway's router picks by its
own heuristic, which for ``cline-pass/deepseek-v4.1-flash`` missed with HTTP
500 ``empty response content`` in roughly one request in six, and sometimes
landed on a channel that took 65 seconds for a one-word answer.

The gateway honours two pin spellings, both set under
``providerOptions.gateway``:

``only``  an allow-list. The router must use one of these channels, or fail.
``order`` a preference list. The router tries these first, in order, and may
          fall through to the remaining channels.

``provider.only`` / ``provider.order`` (the OpenRouter spelling) are accepted
and ignored -- verified by pinning an impossible channel name under each
spelling and watching which one produced the router's complaint.

Two rules from the reference implementation matter and are reimplemented here:

* **Failover is only allowed before the first token.** Once a content or
  reasoning frame has reached the client the reply is theirs; re-sending it
  would duplicate output.
* **A dead key or a quota wall is never retried.** Cycling channels cannot fix
  either, and the retries only add latency to a failure the caller has to see.

The awkward part is detection. A routing miss on the streaming wire is *not*
an HTTP error: the gateway answers ``200 text/event-stream`` and puts the
failure in the very first SSE frame::

    data: {"error":{"code":"stream_initialization_failed","message":"..."
    data: [DONE]

So the shim buffers frames until one carries content, and only then commits the
200 to the client. A stream that ends without ever producing content is an
``EMPTY_RESPONSE`` -- the same verdict the reference implementation reaches --
and fails over to the next channel.

Configuration (environment):
    CLINE_UPSTREAM       default https://api.cline.bot/api/v1
    CLINE_SHIM_PORT      default 8788
    CLINE_SHIM_TIMEOUT   default 600 (seconds, whole request)
    CLINE_SHIM_RETRIES   default 2  (tries per channel on a transport error)
    CLINE_SHIM_LOG       default 1  (set 0 to silence per-request lines)
    CLINE_SHIM_PIN_MODE  default preferred; preferred | strict | off
    CLINE_SHIM_PIN       default empty (use the built-in order below)
    CLINE_SHIM_EXCLUDE   default empty (channels to route around)
    CLINE_SHIM_BUDGET    default 120 (seconds spent failing over, not
                         generating)
"""

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

UPSTREAM = os.environ.get("CLINE_UPSTREAM", "https://api.cline.bot/api/v1").rstrip("/")
PORT = int(os.environ.get("CLINE_SHIM_PORT", "8788"))
TIMEOUT = float(os.environ.get("CLINE_SHIM_TIMEOUT", "600"))
RETRIES = max(1, int(os.environ.get("CLINE_SHIM_RETRIES", "2")))
LOG_ON = os.environ.get("CLINE_SHIM_LOG", "1") not in ("0", "false", "no", "off")
PIN_MODE = os.environ.get("CLINE_SHIM_PIN_MODE", "preferred").strip().lower()
BUDGET = float(os.environ.get("CLINE_SHIM_BUDGET", "120"))
# Cloudflare in front of the remote gateway answers 403 to python-urllib, so the
# forwarded request carries a browser UA unless the caller sends its own.
UA = os.environ.get(
    "CLINE_SHIM_UA",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36")

MODEL_PREFIX = "cline-pass/"
# "gateway" passes the caller's model id through untouched, for an upstream that
# uses its own aliases (the gateway names them cline_dsflash,
# cline-free/deepseek-v4.1-flash, ...). "prefix" is the Cline Pass behaviour and
# stays the default so nothing that already works changes.
MODEL_MODE = os.environ.get("CLINE_MODEL_MODE", "prefix").strip().lower()
ANTHROPIC_PATH = "/v1/messages"
COUNT_TOKENS_PATH = "/v1/messages/count_tokens"
CATALOG_TTL = 600.0
CHANNEL_TTL = 3600.0
# Frames held back while waiting for the first content frame. The gateway's
# preamble is a role frame plus keep-alives; anything larger is pathological.
# Kept small on purpose: the size to reach here is per-translated-frame on the
# Anthropic path, and every held-back frame is first-token latency.
MAX_PENDING_FRAMES = 16


def _csv(name):
    """Read a comma-separated environment variable into a list."""
    return [part.strip() for part in os.environ.get(name, "").split(",")
            if part.strip()]


PIN_ORDER = _csv("CLINE_SHIM_PIN")
EXCLUDE = frozenset(_csv("CLINE_SHIM_EXCLUDE"))

# Status used when an upstream answered HTTP 200 with an empty completion. It is
# not a channel verdict: the same body usually answers on the next try, and one
# measured gateway returned content roughly half the time per attempt. The
# distinct value is what tells the retry logic "repeat this, do not move on".
RETRYABLE_EMPTY = 200

# Built-in channel order, measured 2026-09-17 against the live gateway with a
# 32-token streaming request against cline-pass/deepseek-v4.1-flash. Ordered by
# observed time-to-first-token; the channels left out (baseten, fireworks,
# relace) answered HTTP 429 at capacity, particle answered with empty content,
# and modal took 65s.
DEFAULT_PINS = {
    MODEL_PREFIX + "deepseek-v4.1-flash": [
        "togetherai", "novita", "deepinfra", "parasail", "alibaba",
        "runware", "boundless", "gmicloud",
    ],
}

# The universe an `exclude` list is subtracted from, per model. Kept separate
# from DEFAULT_PINS so that excluding a channel the pin order does not name
# still removes it from a `preferred` fallback.
KNOWN_CHANNELS = {
    MODEL_PREFIX + "deepseek-v4.1-flash": [
        "alibaba", "baseten", "boundless", "deepinfra", "deepseek",
        "fireworks", "gmicloud", "modal", "morph", "novita", "parasail",
        "particle", "relace", "runware", "togetherai",
    ],
}

HOP_BY_HOP = frozenset({
    "host", "content-length", "connection", "accept-encoding",
    "transfer-encoding", "keep-alive", "proxy-connection", "upgrade",
})

_CATALOG = {"at": 0.0, "ids": ()}
_CHANNELS = {}


def log(msg):
    if LOG_ON:
        sys.stderr.write("[cline-shim] " + msg + "\n")
        sys.stderr.flush()


# --------------------------------------------------------------------------
# upstream pinning
# --------------------------------------------------------------------------

def known_channels(model):
    """Every channel the gateway lists for one model (cached, best effort)."""
    entry = _CHANNELS.get(model)
    if entry is not None and time.time() - entry["at"] < CHANNEL_TTL:
        return entry["names"]
    for source in (KNOWN_CHANNELS, DEFAULT_PINS):
        names = source.get(model)
        if names:
            _CHANNELS[model] = {"at": time.time(), "names": list(names)}
            return list(names)
    return []


def pin_attempts(model):
    """Expand one model's pin configuration into ordered failover candidates.

    Mirrors the reference implementation's ``buildAttempts``: a model with a
    channel list is tried channel by channel, and a model without one is a
    single automatic candidate whose exclusions become an allow-list.
    """
    if MODEL_MODE == "gateway":
        return [{"upstream": None, "rest": [], "allow": (), "strict": False,
                 "disabled": True}]
    if PIN_MODE not in ("preferred", "strict"):
        return [{"upstream": None, "rest": [], "allow": (), "strict": False}]
    listed = [name for name in (PIN_ORDER or DEFAULT_PINS.get(model) or [])
              if name not in EXCLUDE and name != model]
    if not listed:
        allow = tuple(name for name in known_channels(model)
                      if name not in EXCLUDE)
        # Nothing to prefer and nothing to exclude: leave routing alone.
        if not allow or len(allow) == len(known_channels(model)):
            return [{"upstream": None, "rest": [], "allow": (), "strict": False}]
        return [{"upstream": None, "rest": [], "allow": allow, "strict": False}]
    strict = PIN_MODE == "strict"
    return [
        {
            "upstream": name,
            "rest": [] if strict else [other for other in listed
                                       if other != name],
            "allow": (),
            "strict": strict,
        }
        for name in listed
    ]


def inject_pin(payload, attempt):
    """Write one attempt's channel preference into a request body.

    An exclude list is compiled into an ``only`` allow-list because the gateway
    has no exclude field of its own; ``order`` carries the preference so the
    router can still fall through.
    """
    if not isinstance(payload, dict):
        return payload
    if attempt.get("disabled"):
        # A pin is Cline Pass machinery. A generic gateway may not understand
        # providerOptions at all, so gateway mode writes nothing into the body.
        return payload
    upstream, rest = attempt["upstream"], attempt["rest"]
    allow = list(attempt["allow"])
    gateway = {}
    if upstream is not None:
        if attempt["strict"]:
            gateway["only"] = [upstream]
        else:
            gateway["order"] = [upstream] + list(rest)
            if allow:
                gateway["only"] = allow
    elif allow:
        gateway["only"] = allow
    if not gateway:
        return payload
    options = payload.get("providerOptions")
    options = dict(options) if isinstance(options, dict) else {}
    current = options.get("gateway")
    current = dict(current) if isinstance(current, dict) else {}
    current.update(gateway)
    options["gateway"] = current
    payload["providerOptions"] = options
    return payload


def attempt_label(attempt):
    """A short name for one attempt, for the log and for error text."""
    if attempt["upstream"] is None:
        return "auto" + ("/only=%d" % len(attempt["allow"])
                         if attempt["allow"] else "")
    return attempt["upstream"] + ("!" if attempt["strict"] else "")


# --------------------------------------------------------------------------
# wire repairs
# --------------------------------------------------------------------------

def unwrap(obj):
    """Strip the ``{"data": {...}}`` envelope the gateway adds to JSON replies."""
    if isinstance(obj, dict):
        data = obj.get("data")
        if isinstance(data, dict) and "choices" in data:
            merged = dict(data)
            for key, value in obj.items():
                if key not in ("data", "success"):
                    merged.setdefault(key, value)
            return merged
    return obj


def fix_message(msg):
    """Mirror the gateway's reasoning fields onto reasoning_content."""
    if not isinstance(msg, dict):
        return msg
    if not msg.get("reasoning_content"):
        alt = msg.get("reasoning")
        if isinstance(alt, str) and alt.strip():
            msg["reasoning_content"] = alt
        else:
            details = msg.get("reasoning_details")
            if isinstance(details, list):
                text = "".join(
                    str(item.get("text") or "")
                    for item in details
                    if isinstance(item, dict)
                )
                if text.strip():
                    msg["reasoning_content"] = text
    return msg


def fix_delta(delta):
    if isinstance(delta, dict) and not delta.get("reasoning_content"):
        alt = delta.get("reasoning")
        if isinstance(alt, str) and alt:
            delta["reasoning_content"] = alt
    return delta


# --------------------------------------------------------------------------
# Anthropic wire
# --------------------------------------------------------------------------

def _openai_messages(payload):
    """Anthropic messages + system -> OpenAI messages.

    Anthropic carries the system prompt as a top-level field and pairs tool
    results with the preceding assistant turn; OpenAI carries the prompt as a
    leading system message and splits tool results into their own role. The
    first system message is inserted in place so multi-turn history keeps its
    order, and only the leading assistant turns that carry tool_use become a
    tool role.
    """
    out = []
    system = payload.get("system")
    if isinstance(system, list):
        text = "".join(str(block.get("text") or "")
                       for block in system if isinstance(block, dict))
    else:
        text = str(system or "")
    if text.strip():
        out.append({"role": "system", "content": text})

    for message in payload.get("messages") or []:
        if not isinstance(message, dict):
            continue
        role = message.get("role")
        content = message.get("content")
        if isinstance(content, str):
            out.append({"role": role, "content": content})
            continue
        texts = []
        tool_uses = []
        tool_results = []
        for block in content or []:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "text":
                texts.append(str(block.get("text") or ""))
            elif kind == "tool_use":
                tool_uses.append({
                    "id": block.get("id"),
                    "type": "function",
                    "function": {
                        "name": block.get("name"),
                        "arguments": json.dumps(block.get("input") or {}),
                    },
                })
            elif kind == "tool_result":
                value = block.get("content")
                if isinstance(value, list):
                    value = "".join(str(item.get("text") or "")
                                    for item in value
                                    if isinstance(item, dict))
                tool_results.append({
                    "role": "tool",
                    "tool_call_id": block.get("tool_use_id") or "",
                    "content": str(value) if value is not None else "",
                })
        if tool_results and not texts:
            out.extend(tool_results)
            continue
        if texts or tool_uses:
            entry = {"role": role, "content": "".join(texts) or None}
            if tool_uses:
                entry["tool_calls"] = tool_uses
            out.append(entry)
        out.extend(tool_results)
    return out


def anthropic_to_openai(payload):
    """Translate a /v1/messages body into the /chat/completions body.

    Cline Pass speaks the OpenAI wire only, so an Anthropic caller -- Claude
    Code among them -- has to be translated before it can reach the pinning
    machinery this shim exists for.
    """
    if not isinstance(payload, dict):
        return payload
    body = {
        "model": rewrite_model(payload.get("model")),
        "messages": _openai_messages(payload),
        "stream": bool(payload.get("stream")),
    }
    if payload.get("max_tokens") is not None:
        body["max_tokens"] = payload["max_tokens"]
    if payload.get("temperature") is not None:
        body["temperature"] = payload["temperature"]
    if payload.get("top_p") is not None:
        body["top_p"] = payload["top_p"]
    if payload.get("stop_sequences"):
        body["stop"] = payload["stop_sequences"]
    if payload.get("stream"):
        body["stream_options"] = {"include_usage": True}
    tools = payload.get("tools")
    if isinstance(tools, list):
        converted = []
        for tool in tools:
            if not isinstance(tool, dict):
                continue
            converted.append({"type": "function", "function": {
                "name": tool.get("name"),
                "description": tool.get("description") or "",
                "parameters": tool.get("input_schema") or {},
            }})
        if converted:
            body["tools"] = converted
            choice = payload.get("tool_choice") or {}
            if isinstance(choice, dict) and choice.get("type") == "tool":
                body["tool_choice"] = {
                    "type": "function",
                    "function": {"name": choice.get("name")}}
            else:
                body["tool_choice"] = "auto"
    return body


def rewrite_model(model):
    """Accept a bare model name and normalise it to the subscription id.

    Only the OpenAI wire is prefixed here. An Anthropic request is re-prefixed
    from its own path because a gateway-specific alias such as ``cline_dsflash``
    means something only to that gateway, while the subscription pool serves
    cline-pass ids.
    """
    if not isinstance(model, str) or not model.strip():
        return model
    name = model.strip()
    if MODEL_MODE == "gateway":
        # The upstream owns its naming; rewriting here would turn
        # "cline-free/deepseek-v4.1-flash" into a 404.
        return name
    if name.startswith(MODEL_PREFIX):
        return name
    # A bare "z-ai/glm-5.3" is an upstream catalog id; only the trailing
    # segment survives as a cline-pass id.
    if "/" in name:
        head, _, tail = name.rpartition("/")
        if head.lower() in ("z-ai", "zai", "deepseek", "anthropic", "openai",
                            "moonshotai", "qwen", "minimax", "xiaomi", "meta"):
            return MODEL_PREFIX + tail
    return MODEL_PREFIX + name


# --------------------------------------------------------------------------
# failure classification
# --------------------------------------------------------------------------

def classify(text):
    """Coarse upstream failure class (mirrors the reference implementation).

    The pin-miss test has to run before the generic "no available providers"
    one: both describe the same words, but a pin miss means *this* channel was
    unusable and the next one is worth trying, whereas a dead model id will be
    dead everywhere.
    """
    low = str(text or "").lower()
    if "empty response content" in low:
        return "empty"
    if "no available providers match" in low or "limited providers" in low:
        return "limited"
    if "insufficient" in low or "balance" in low or "402" in low:
        return "credits"
    if "429" in low or "rate-?limited" in low or "rate limit" in low:
        return "limited"
    if "unauthorized" in low or "re-authenticate" in low or "401" in low:
        return "auth"
    if any(k in low for k in ("invalid_request", "modelid", "no allowed providers",
                              "no available providers", "not found",
                              "unsupported", "invalid model format")):
        return "bad"
    return "unknown"


def final_status(status):
    """The status a client should see after retries are exhausted.

    ``RETRYABLE_EMPTY`` is an internal marker, never a real reply: the caller
    gets a 500 because no content was produced. Sending the marker itself would
    claim success on an empty body.
    """
    return 500 if status == RETRYABLE_EMPTY else status


def same_channel_retry(status, note):
    """Whether one *channel* is worth asking twice.

    Two different questions live here, and conflating them is the bug this
    separates out:

    * a routing verdict -- ``empty response content``, ``429``, a pin miss --
      means the channel already answered "not me". Asking it again wastes the
      caller's latency; the next channel is the fix.
    * a transport hiccup -- a dropped connection, an unreadable 5xx -- says
      nothing about the channel at all, so it is the one case worth repeating
      in place.

    An empty completion arriving as HTTP 200 is a third case, and the ``empty``
    class alone cannot tell it apart from a routing miss. Measured against the
    remote New API gateway, the same body answered with content roughly half
    the time -- the upstream re-rolls per request -- so repeating it in place is
    worth far more than surfacing the failure. The 500 is the marker the stream
    path leaves behind in that case; a routing miss carries 200.
    """
    kind = classify(note)
    if status == 200 and kind == "empty":
        return True
    if kind in ("bad", "auth", "credits", "empty", "limited"):
        return False
    return status in (500, 502, 503, 504, 408)


def failover_allowed(note):
    """Whether a failed attempt may be handed to the next channel.

    A dead key and a credits wall are terminal by construction: every channel
    sits behind the same account, so retrying only rehearses the failure. Every
    other failure -- a router miss, a full channel, a broken stream -- is
    channel-specific and is exactly what the next attempt is for.
    """
    return classify(note) not in ("auth", "credits")


def error_note(value):
    """The failure text of an ``error`` field, or ``None`` when it is absent.

    An SSE frame carries either a ``choices`` list or an ``error`` object, never
    both, so an error field that is present and non-empty is the whole verdict
    for that frame.
    """
    if value is None:
        return None
    text = error_text(value).strip()
    return text or None


def error_text(value):
    """Turn any error-shaped value into display text."""
    if value is None:
        return ""
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        for key in ("message", "code", "error"):
            found = value.get(key)
            if isinstance(found, str) and found:
                return found
        try:
            return json.dumps(value)
        except Exception:
            pass
    return str(value)


def normalize_error(status, raw):
    """Reshape an upstream error into the OpenAI error object."""
    kind = classify(raw)
    message = ""
    try:
        obj = json.loads(raw)
        err = obj.get("error") if isinstance(obj, dict) else None
        if isinstance(err, str):
            message = err
        elif isinstance(err, dict):
            message = str(err.get("message") or err.get("code") or "")
        if not message and isinstance(obj, dict):
            message = str(obj.get("message") or obj.get("error") or "")
    except Exception:
        message = raw.decode("utf-8", "replace") if isinstance(raw, bytes) else str(raw)

    if kind == "credits":
        hint = (" (this model resolved through Cline Credits instead of the "
                "subscription; use a cline-pass/<name> model id)")
        code = "insufficient_credits"
    elif kind == "empty":
        hint = (" (every pinned channel failed before the first token; check "
                "GET /channels?model=<id>)")
        code = "upstream_routing"
    elif kind == "bad":
        hint = " (check the model id against GET /v1/models)"
        code = "invalid_request_error"
    elif kind == "auth":
        hint = " (the API key was rejected upstream)"
        code = "invalid_api_key"
    else:
        hint = ""
        code = "upstream_error"

    return {
        "error": {
            "message": (message or "upstream failure") + hint,
            "type": code,
            "code": code,
            "param": None,
        }
    }


# --------------------------------------------------------------------------
# catalogs
# --------------------------------------------------------------------------

def catalog_ids():
    """Subscription model ids advertised by the gateway (cached)."""
    now = time.time()
    if _CATALOG["ids"] and now - _CATALOG["at"] < CATALOG_TTL:
        return _CATALOG["ids"]
    req = urllib.request.Request(UPSTREAM + "/ai/cline/recommended-models")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            payload = json.loads(resp.read())
    except Exception as exc:
        log("catalog fetch failed: %s" % exc)
        return _CATALOG["ids"]

    entries = payload.get("clinePass") if isinstance(payload, dict) else None
    if not entries and isinstance(payload, dict):
        data = payload.get("data")
        if isinstance(data, dict):
            entries = data.get("clinePass")
    ids = []
    for item in entries or ():
        if isinstance(item, dict):
            value = item.get("id") or item.get("name")
        else:
            value = item
        if isinstance(value, str) and value.strip():
            ids.append(value.strip())
    if ids:
        _CATALOG["at"] = now
        _CATALOG["ids"] = tuple(ids)
    return _CATALOG["ids"]


def discover_channels(model, key):
    """Ask the gateway which channels serve one model.

    The probe channels an impossible ``only`` value, so the router fails before
    spending a token and names every provider it could have used. Free, and it
    needs no catalog the gateway does not already publish.
    """
    body = {
        "model": model,
        "messages": [{"role": "user", "content": "ping"}],
        "max_tokens": 1,
        "stream": False,
        "providerOptions": {"gateway": {"only": ["__shim_discovery__"]}},
    }
    req = urllib.request.Request(
        UPSTREAM + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + key,
                 "Content-Type": "application/json",
                 "Accept": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            text = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        text = exc.read().decode("utf-8", "replace")
    except Exception as exc:
        log("channel discovery failed: %s" % exc)
        return []
    match = re.search(r"available providers are:\s*([^.]+)", text, re.I)
    if not match:
        return []
    names = [token.strip() for token in match.group(1).split(",")]
    return [name for name in names if re.fullmatch(r"[a-z0-9][a-z0-9-]*", name)]


# --------------------------------------------------------------------------
# HTTP
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "cline-shim/1.2"

    def log_message(self, fmt, *args):
        pass  # replaced by log()

    def _forward_headers(self, body_len=None):
        out = {}
        for key, value in self.headers.items():
            if key.lower() in HOP_BY_HOP:
                continue
            out[key] = value
        # Some gateways sit behind Cloudflare, which answers 403 to the default
        # python-urllib user agent and can reject a CLI UA too. The UA is a
        # property of the hop to the upstream, not of the caller, so it is
        # always replaced.
        out["User-Agent"] = UA
        if body_len is not None:
            out["Content-Length"] = str(body_len)
        return out

    def _bearer(self):
        header = self.headers.get("Authorization") or ""
        return header[7:].strip() if header[:7].lower() == "bearer " else header.strip()

    def do_GET(self):
        split = urlsplit(self.path)
        path = split.path.rstrip("/") or "/"
        if path in ("/health", "/healthz"):
            ids = catalog_ids()
            self._send_json(200, {
                "ok": True,
                "upstream": UPSTREAM,
                "models": len(ids),
                "model_prefix": MODEL_PREFIX,
                "model_mode": MODEL_MODE,
                "wires": ["openai:/chat/completions", "anthropic:/v1/messages"],
                "pin_mode": PIN_MODE if PIN_MODE in ("preferred", "strict") else "off",
                "exclude": sorted(EXCLUDE),
            })
            return
        if path in ("/models", "/v1/models"):
            ids = catalog_ids() or (MODEL_PREFIX + "glm-5.3",)
            self._send_json(200, {
                "object": "list",
                "data": [
                    {"id": mid, "object": "model", "created": 0, "owned_by": "cline"}
                    for mid in ids
                ],
            })
            return
        if path in ("/channels", "/v1/channels"):
            query = parse_qs(split.query)
            model = (query.get("model") or [""])[0] or (
                catalog_ids() or [MODEL_PREFIX + "deepseek-v4.1-flash"])[0]
            attempted = (query.get("discover") or ["0"])[0] not in ("0", "no", "off")
            live = discover_channels(model, self._bearer()) if attempted else []
            if live:
                _CHANNELS[model] = {"at": time.time(), "names": live}
            self._send_json(200, {
                "model": model,
                "pin_mode": PIN_MODE if PIN_MODE in ("preferred", "strict") else "off",
                "exclude": sorted(EXCLUDE),
                "attempts": [attempt_label(a) for a in pin_attempts(model)],
                "known": live or known_channels(model),
                "source": "gateway probe" if live else "built-in",
            })
            return
        self._relay(self.path, b"", "GET")

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        if urlsplit(self.path).path.rstrip("/") == COUNT_TOKENS_PATH:
            body = json.loads(body) if body else {}
            estimate = len(json.dumps(body.get("messages") or [])) // 4
            self._send_json(200, {"input_tokens": max(estimate, 1)})
            return
        stream = False
        payload = None
        try:
            payload = json.loads(body)
        except Exception:
            payload = None
        if isinstance(payload, dict):
            original = payload.get("model")
            fixed = rewrite_model(original)
            if fixed != original:
                payload["model"] = fixed
                log("model %r -> %r" % (original, fixed))
            stream = bool(payload.get("stream"))
            if urlsplit(self.path).path.rstrip("/") == ANTHROPIC_PATH:
                # Translate once, here, so every attempt below reuses the same
                # OpenAI body instead of repeating the conversion per channel.
                payload = anthropic_to_openai(payload)
            if stream:
                log("POST %s model=%r stream%s" % (
                    self.path, payload.get("model"), ctx_note(payload)))
        self._relay(self.path, payload, "POST", stream=stream, raw=body)

    # ---------------------------------------------------------------- relay

    def _relay(self, path, payload, method, stream=False, raw=b""):
        """Try each pinned channel in turn, stopping at the first reply.

        Only failures that happen *before* the client has seen a token are
        retried here; ``_attempt`` returns status 0 the moment a reply is
        committed, because after that the answer belongs to the caller.
        """
        base = "anthropic" if urlsplit(path).path.rstrip("/") == ANTHROPIC_PATH \
            else "openai"
        model = payload.get("model") if isinstance(payload, dict) else None
        attempts = pin_attempts(model) if method == "POST" and model else [
            {"upstream": None, "rest": [], "allow": (), "strict": False}]
        headers = self._forward_headers()
        deadline = time.time() + BUDGET
        last_error = (502, "no attempt was made")

        for index, attempt in enumerate(attempts):
            label = attempt_label(attempt)
            # Retries only help if the caller cannot retry better. Claude Code
            # already backs off and redials on a 5xx, so the shim's own budget
            # is kept tight: a slow upstream multiplies by the try count, and a
            # 3-try run behind a 130s gateway stall reads as a hung command.
            # Two in-place tries catch the common single empty roll without
            # stretching the worst case past what the caller would tolerate.
            tries_limit = RETRIES if len(attempts) > 1 else max(RETRIES, 2)
            if not isinstance(payload, dict):
                body = raw
            else:
                # A pin lives in providerOptions, which the OpenAI wire carries
                # natively; an Anthropic request never had one, so it is
                # injected after the translation. Without it this path still
                # removes the gateway hops but leaves the channel a lottery --
                # one measured round took 64.6s for a one-word answer.
                body = json.dumps(inject_pin(dict(payload), attempt)).encode()
            for tries in range(tries_limit):
                try:
                    status, note = self._attempt(
                        "/chat/completions" if base == "anthropic" else path,
                        body, headers, stream, label, base)
                except urllib.error.HTTPError as exc:
                    status = exc.code
                    note = exc.read().decode("utf-8", "replace")
                except Exception as exc:
                    status, note = 502, str(exc)
                if status == 0:
                    return  # the reply is the client's now
                last_error = (status, note)

                if not failover_allowed(note):
                    log("%s %s [%s] terminal: %s" % (
                        method, path, label, classify(note)))
                    self._send_json(final_status(status),
                                    normalize_error(status, note))
                    return
                if tries + 1 < tries_limit and time.time() < deadline \
                        and same_channel_retry(status, note):
                    log("%s %s [%s] %s, retry %d/%d in place" % (
                        method, path, label, classify(note) or "failed",
                        tries + 1, tries_limit - 1))
                    time.sleep(0.5 * (tries + 1))
                    continue
                break
            if index + 1 < len(attempts) and time.time() < deadline:
                log("%s %s [%s] %s -> next channel" % (
                    method, path, label, classify(last_error[1]) or "failed"))
                continue
            break

        status, note = last_error
        log("%s %s -> HTTP %d (%s) after %d channel(s)" % (
            method, path, final_status(status), classify(note),
            min(index + 1, len(attempts))))
        self._send_json(final_status(status), normalize_error(status, note))

    def _attempt(self, path, body, headers, stream, label, base="openai"):
        """Run one attempt against one channel.

        Returns ``(0, channel)`` once the reply has been handed to the client,
        or ``(status, note)`` when this channel failed before the first token.
        """
        req = urllib.request.Request(
            UPSTREAM + path, data=body or None,
            headers=dict(headers, **{"Content-Length": str(len(body))}),
            method="POST")
        started = time.time()
        try:
            resp = urllib.request.urlopen(req, timeout=TIMEOUT)
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode("utf-8", "replace")
        ctype = resp.headers.get("Content-Type", "") or ""
        if base == "anthropic":
            if stream and "event-stream" in ctype:
                return self._anthropic_stream(resp, label, started)
            return self._anthropic_blocking(resp, label, started)
        if stream and "event-stream" in ctype:
            return self._stream(resp, label, started)
        served = self._json_body(resp, label, started)
        if served is None:
            return 500, "empty response content"
        return 0, served

    # ------------------------------------------------------------- bodies

    def _json_body(self, resp, label, started):
        """Forward a blocking reply; ``None`` when it carried no content.

        The gateway answers HTTP 200 for a routing miss too, wrapping the
        failure in the same envelope it uses for a completion, so the body --
        not the status -- is what decides whether this channel answered.
        """
        raw = resp.read()
        try:
            decoded = json.loads(raw)
        except Exception:
            log("POST [%s] HTTP 200 with an unparseable body" % label)
            return None
        body = unwrap(decoded)
        if not isinstance(body, dict) or not body.get("choices"):
            note = error_text(body.get("error") if isinstance(body, dict) else decoded)
            log("POST [%s] HTTP 200 with no choices: %s" % (label, note[:120]))
            return None
        for choice in body.get("choices") or ():
            fix_message(choice.get("message"))
        served = provider_of_choice(body.get("choices")) or "unknown"
        log("POST [%s] %.1fs blocking, served by %s" % (
            label, time.time() - started, served))
        self._send_json(200, None, raw=json.dumps(body).encode("utf-8"))
        return served

    def _stream(self, resp, label, started):
        """Forward an SSE reply, holding it back until it has real content.

        A routing miss arrives as ``200 text/event-stream`` whose first frame is
        an error object, so nothing may be committed to the client until a
        content or reasoning frame has been seen. Returns ``(0, served)`` after
        committing, or ``(500, note)`` when the stream never produced content.
        """
        pending = []
        committed = False
        served = None
        finish = None
        try:
            for raw in resp:
                line = raw.decode("utf-8", "replace")
                text = line.strip()
                if text.startswith("data:") and text[5:].strip() not in ("", "[DONE]"):
                    try:
                        obj = json.loads(text[5:].strip())
                    except Exception:
                        obj = None
                    if isinstance(obj, dict):
                        note = error_note(obj.get("error"))
                        if note:
                            if not committed:
                                return 500, note
                            self._write(line)
                            break
                        for choice in obj.get("choices") or ():
                            fix_delta(choice.get("delta"))
                            if choice.get("finish_reason"):
                                finish = choice["finish_reason"]
                        served = served or provider_of_choice(obj.get("choices"))
                        line = "data: " + json.dumps(obj) + "\n"
                if committed:
                    self._write(line)
                    continue
                pending.append(line)
                if len(pending) > MAX_PENDING_FRAMES or yields_content_obj(line):
                    committed = True
                    self._begin_stream()
                    for entry in pending:
                        self._write(entry)
                    pending = []
            if not committed:
                note = ("empty response content (finish_reason=%s)" % finish
                        if finish else "empty response content")
                log("POST [%s] %s" % (label, note))
                # Retryable in place: the upstream rolled an empty completion,
                # and the same body usually answers on the next try. The caller
                # never saw a byte, so a repeat is free.
                return RETRYABLE_EMPTY, note
        except Exception as exc:
            if not committed:
                log("POST [%s] stream failed before content: %s" % (label, exc))
                return 500, str(exc)
            log("POST [%s] stream aborted after content: %s" % (label, exc))
        log("POST [%s] %.1fs streamed, served by %s" % (
            label, time.time() - started, served or "unknown"))
        return 0, served

    def _anthropic_block(self, idx, kind, payload, stop=False):
        """One content-block event, or the stop event when asked."""
        name = "content_block_stop" if stop \
            else ("content_block_start" if payload is not None
                  else "content_block_delta")
        if stop:
            event = {"type": name, "index": idx}
        elif payload is not None:
            event = {"type": name, "index": idx, "content_block": payload}
        else:
            event = {"type": name, "index": idx, "delta": dict(kind)}
        return "event: %s\ndata: %s\n\n" % (name, json.dumps(event))

    def _anthropic_blocking(self, resp, label, started):
        """Forward a blocking reply as an Anthropic message, or fail over.

        Same verdict rule as the OpenAI path: a routing miss answers 200 with
        the failure in the envelope, so the body decides whether this channel
        answered -- not the status.
        """
        raw = resp.read()
        try:
            decoded = json.loads(raw)
        except Exception:
            log("POST [%s] anthropic: HTTP 200 with an unparseable body" % label)
            return 500, "empty response content"
        body = unwrap(decoded)
        if not isinstance(body, dict) or not body.get("choices"):
            note = error_text(body.get("error") if isinstance(body, dict)
                              else decoded)
            log("POST [%s] anthropic: HTTP 200 with no choices: %s"
                % (label, note[:120]))
            return 500, "empty response content"
        for choice in body.get("choices") or ():
            fix_message(choice.get("message"))
        message = openai_to_anthropic(body)
        served = provider_of_choice(body.get("choices")) or "unknown"
        log("POST [%s] %.1fs blocking (anthropic), served by %s" % (
            label, time.time() - started, served))
        self._send_json(200, None,
                        raw=json.dumps(message).encode("utf-8"))
        return 0, served

    def _anthropic_stream(self, resp, label, started):
        """Serve an Anthropic SSE reply out of OpenAI frames.

        The same rule as the OpenAI path applies: nothing is committed until a
        frame carries real content, because a routing miss arrives as a healthy
        200 whose first frame is an error object. Unlike the OpenAI path the
        frames have to be translated, so they are buffered as Anthropic events
        and all of them -- starting with the synthesised ``message_start`` --
        are written the moment content shows up.
        """
        pending = []
        committed = False
        served = None
        started_emitted = False
        think_open = text_open = -1
        tool_blocks = {}
        next_index = 0
        model = None
        in_tok = out_tok = 0
        finish = None
        try:
            for raw in resp:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                body = line[5:].strip()
                if body in ("", "[DONE]"):
                    continue
                try:
                    obj = json.loads(body)
                except Exception:
                    continue
                if not isinstance(obj, dict):
                    continue

                note = error_note(obj.get("error"))
                if note:
                    if not committed:
                        return 500, note
                    break

                if not started_emitted:
                    model = model or obj.get("model")
                    started_emitted = True
                for choice in obj.get("choices") or ():
                    delta = choice.get("delta") or {}
                    if choice.get("finish_reason"):
                        finish = choice["finish_reason"]
                    meta = holder_metadata(choice)
                    served = served or meta
                    reasoning = delta.get("reasoning_content") \
                        or delta.get("reasoning")
                    if reasoning:
                        if think_open < 0:
                            text_open, think_open = self._close_block(
                                pending, text_open, think_open, True)
                            think_open = next_index
                            next_index += 1
                            pending.append(self._anthropic_block(
                                think_open, None,
                                {"type": "thinking", "thinking": ""}))
                        pending.append(self._anthropic_block(
                            think_open, {"type": "thinking_delta",
                                         "thinking": reasoning}, None))
                    content = delta.get("content")
                    if content:
                        text_open, think_open = self._close_block(
                            pending, text_open, think_open, False)
                        if text_open < 0:
                            text_open = next_index
                            next_index += 1
                            pending.append(self._anthropic_block(
                                text_open, None, {"type": "text", "text": ""}))
                        pending.append(self._anthropic_block(
                            text_open, {"type": "text_delta", "text": content},
                            None))
                    for call in delta.get("tool_calls") or ():
                        if not isinstance(call, dict):
                            continue
                        slot = call.get("index")
                        if slot is None:
                            slot = len(tool_blocks)
                        if slot not in tool_blocks:
                            text_open, think_open = self._close_block(
                                pending, text_open, think_open, False)
                            block = next_index
                            next_index += 1
                            tool_blocks[slot] = block
                            name = ((call.get("function") or {})
                                    .get("name") or "tool")
                            pending.append(self._anthropic_block(
                                block, None, {"type": "tool_use",
                                              "id": call.get("id")
                                              or "toolu_%d" % block,
                                              "name": name, "input": {}}))
                        args = (call.get("function") or {}).get("arguments")
                        if args:
                            pending.append(self._anthropic_block(
                                tool_blocks[slot], {"type": "input_json_delta",
                                                    "partial_json": args}, None))
                if obj.get("usage"):
                    usage = obj["usage"]
                    in_tok = usage.get("prompt_tokens") or in_tok
                    out_tok = usage.get("completion_tokens") or out_tok

                if committed:
                    self._write("".join(pending))
                    pending = []
                    continue
                if yields_content(obj) or len(pending) > MAX_PENDING_FRAMES:
                    committed = True
                    self._begin_stream("text/event-stream")
                    head = {
                        "type": "message_start",
                        "message": {"id": "msg_shim", "type": "message",
                                    "role": "assistant", "model": model,
                                    "content": [],
                                    "stop_reason": None,
                                    "stop_sequence": None,
                                    "usage": {"input_tokens": in_tok,
                                              "output_tokens": 0}},
                    }
                    pending.insert(0, "event: message_start\ndata: %s\n\n"
                                   % json.dumps(head))
                    self._write("".join(pending))
                    pending = []
            if not committed:
                note = ("empty response content (finish_reason=%s)" % finish
                        if finish else "empty response content")
                log("POST [%s] %s" % (label, note))
                # Retryable in place: the upstream rolled an empty completion,
                # and the same body usually answers on the next try. The caller
                # never saw a byte, so a repeat is free.
                return RETRYABLE_EMPTY, note
        except Exception as exc:
            if not committed:
                log("POST [%s] anthropic stream failed before content: %s"
                    % (label, exc))
                return 500, str(exc)
            log("POST [%s] anthropic stream aborted after content: %s"
                % (label, exc))

        tail = []
        for block in (text_open, think_open):
            if block >= 0:
                tail.append(self._anthropic_block(block, None, None, stop=True))
        for block in tool_blocks.values():
            tail.append(self._anthropic_block(block, None, None, stop=True))
        tail.append("event: message_delta\ndata: %s\n\n" % json.dumps({
            "type": "message_delta",
            "delta": {"stop_reason": stop_reason(finish),
                      "stop_sequence": None},
            "usage": {"output_tokens": out_tok}}))
        tail.append("event: message_stop\ndata: %s\n\n"
                    % json.dumps({"type": "message_stop"}))
        self._write("".join(tail))
        log("POST [%s] %.1fs streamed (anthropic), served by %s" % (
            label, time.time() - started, served or "unknown"))
        return 0, served

    def _close_block(self, pending, text_open, think_open, keep_thinking):
        """Close whichever block is open when the stream moves on."""
        if keep_thinking:
            if text_open >= 0:
                pending.append(self._anthropic_block(
                    text_open, None, None, stop=True))
                text_open = -1
        elif think_open >= 0:
            pending.append(self._anthropic_block(
                think_open, None, None, stop=True))
            think_open = -1
        return text_open, think_open

    def _begin_stream(self, ctype="text/event-stream"):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

    def _write(self, line):
        self.wfile.write(line.encode("utf-8"))
        self.wfile.flush()

    def _send_json(self, code, obj, raw=None):
        if raw is None:
            raw = json.dumps(obj).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(raw)
        except Exception as exc:
            log("client went away before the reply: %s" % exc)


def yields_content(frame):
    """Whether one SSE payload carries model output rather than a preamble.

    A terminal ``finish_reason`` alone does not count: a channel that answers
    with a role frame and then stops is the empty reply this shim exists to
    route around, and committing that to the client would spend the turn on a
    blank answer.
    """
    if not isinstance(frame, dict):
        return False
    for choice in frame.get("choices") or ():
        delta = choice.get("delta") or {}
        if not isinstance(delta, dict):
            continue
        if delta.get("content"):
            return True
        if delta.get("reasoning") or delta.get("reasoning_details"):
            return True
        if delta.get("tool_calls"):
            return True
    return False


def yields_content_obj(line):
    """Same test, applied to a raw SSE line."""
    text = line.strip()
    if not text.startswith("data:"):
        return False
    body = text[5:].strip()
    if body in ("", "[DONE]"):
        return False
    try:
        return yields_content(json.loads(body))
    except Exception:
        return False


def holder_metadata(choice):
    """The channel named in one choice's metadata, without building a reply."""
    if not isinstance(choice, dict):
        return None
    for holder in (choice.get("delta"), choice.get("message"), choice):
        if not isinstance(holder, dict):
            continue
        meta = holder.get("provider_metadata")
        if not isinstance(meta, dict):
            continue
        routing = (meta.get("gateway") or {}).get("routing") or {}
        if routing.get("finalProvider"):
            return routing["finalProvider"]
        names = [key for key in meta if key != "gateway"]
        if names:
            return names[0]
    return None


def context_shape(payload):
    """Summarise how big a request is, without logging its contents.

    Throughput on a gateway route is governed by input size rather than by the
    model, so the size of each request is the number worth having in the log:
    a session that has grown past ~34k tokens answers at a third of the rate it
    answered at 3k. Only counts are reported, never message text.

    ``chars`` is a character count, not a token count; real tokenisation is the
    upstream's job. As a rule of thumb the log's ``~N.Nk tok`` estimate divides
    it by 4, which is the same ratio the local count_tokens route uses.
    """
    if not isinstance(payload, dict):
        return None
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return None
    chars = 0
    biggest = 0
    for message in messages:
        try:
            size = len(json.dumps(message))
        except Exception:
            continue
        chars += size
        biggest = max(biggest, size)
    tools = payload.get("tools") or []
    try:
        tools = len(tools) if isinstance(tools, list) else 0
    except Exception:
        tools = 0
    return {"messages": len(messages), "chars": chars, "largest": biggest,
            "tools": tools}


def ctx_note(payload):
    """One compact line describing a request's size, for the log."""
    shape = context_shape(payload)
    if not shape:
        return ""
    return (" cv=%d msgs in=%.1fk tok (est) max=%.1fk tools=%d" % (
        shape["messages"], shape["chars"] / 4000.0,
        shape["largest"] / 4000.0, shape["tools"]))


def stop_reason(finish):
    """OpenAI finish_reason -> the Anthropic stop_reason a client checks."""
    return {"stop": "end_turn", "length": "max_tokens",
            "tool_calls": "tool_use", "function_call": "tool_use",
            "content_filter": "refusal"}.get(finish or "", "end_turn")


def openai_to_anthropic(body, model=None):
    """Reshape a blocking completion into the Anthropic message object.

    Anthropic has no structured reasoning field: a model's reasoning is a
    ``thinking`` content block, so the mirrored ``reasoning_content`` becomes
    one instead of being dropped.
    """
    choices = []
    if isinstance(body, dict):
        choices = body.get("choices") or []
    choice = choices[0] if choices else {}
    message = choice.get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        content = "".join(str(item.get("text") or "")
                          for item in content if isinstance(item, dict))
    blocks = []
    reasoning = message.get("reasoning_content") or message.get("reasoning")
    if isinstance(reasoning, str) and reasoning.strip():
        blocks.append({"type": "thinking", "thinking": reasoning})
    if content:
        blocks.append({"type": "text", "text": content})
    for call in message.get("tool_calls") or []:
        if not isinstance(call, dict):
            continue
        function = call.get("function") or {}
        try:
            params = json.loads(function.get("arguments") or "{}")
        except Exception:
            params = {}
        blocks.append({"type": "tool_use", "id": call.get("id") or "",
                       "name": function.get("name") or "", "input": params})
    if not blocks:
        blocks.append({"type": "text", "text": ""})
    usage = body.get("usage") if isinstance(body, dict) else {}
    usage = usage or {}
    return {
        "id": body.get("id") if isinstance(body, dict) else None,
        "type": "message",
        "role": "assistant",
        "model": (body.get("model") if isinstance(body, dict) else None)
                 or model or "",
        "content": blocks,
        "stop_reason": stop_reason(choice.get("finish_reason")),
        "stop_sequence": None,
        "usage": {"input_tokens": usage.get("prompt_tokens") or 0,
                  "output_tokens": usage.get("completion_tokens") or 0},
    }


def provider_of_choice(choices):
    """Read the channel that served a reply out of its metadata.

    The gateway reports routing on the terminal frame under
    ``delta.provider_metadata.gateway.routing.finalProvider``, and names the
    channel directly as a sibling key (``{"deepinfra": {}, "gateway": {...}}``)
    when the router was pinned.
    """
    for choice in choices or ():
        if not isinstance(choice, dict):
            continue
        for holder in (choice.get("delta"), choice.get("message"), choice):
            if not isinstance(holder, dict):
                continue
            meta = holder.get("provider_metadata")
            if not isinstance(meta, dict):
                continue
            routing = (meta.get("gateway") or {}).get("routing") or {}
            if routing.get("finalProvider"):
                return routing["finalProvider"]
            names = [key for key in meta if key != "gateway"]
            if names:
                return names[0]
    return None


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    log("listening on http://127.0.0.1:%d -> %s (retries=%d, pin=%s%s)" % (
        PORT, UPSTREAM, RETRIES,
        PIN_MODE if PIN_MODE in ("preferred", "strict") else "off",
        (" exclude=" + ",".join(sorted(EXCLUDE))) if EXCLUDE else ""))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()