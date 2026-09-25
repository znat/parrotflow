"""The planner: a remote chat model that knows how apps work. The agent
(`agent.py`) calls it with tools; `ground.py` and `review.py` use it too.

Configured through the runner's environment, like Jev: PARROTFLOW_PLANNER_MODEL,
PARROTFLOW_PLANNER_URL, PARROTFLOW_PLANNER_KEY, PARROTFLOW_PLANNER_KEY_SOURCE,
PARROTFLOW_PLANNER_REASONING, PARROTFLOW_PLANNER_TIMEOUT. No model, no planner.
The call goes through the `openai` package. Its base URL is the endpoint
without `/chat/completions`. Each attempt may take PARROTFLOW_PLANNER_TIMEOUT
seconds, and a failed attempt is tried twice more (see `Planner.client`).
PARROTFLOW_PLANNER_LOOP is `agent`; the old `plan` runs the agent too.
PARROTFLOW_PLANNER_TRACE is where the agent writes one JSON line per call.
PARROTFLOW_PLANNER_REVIEW_REASONING is the effort of the review after a run
(`review.py`), `high` by default.
"""

import asyncio
import json
import os
import time
import urllib.parse
from typing import Literal

import openai
from pydantic import BaseModel, ConfigDict

import decider
import runlog as recording

Do = Literal["click", "pick", "type", "write", "key", "scroll"]


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True)


NAME_CHARS = 60


class Failure(Exception):
    pass


def describe_step(step):
    said = step["do"]
    if step["target"]:
        said += f" “{step['target']}”"
    if step["value"]:
        said += f" = “{decider.prefix(step['value'], 60)}”"
    if step["expect"]:
        said += f" → {step['expect']}"
    return said


def doing(step):
    """The step as the run panel says it while it runs."""
    do, target, value = step["do"], step["target"], decider.prefix(step["value"], 40)
    if do in ("type", "write"):
        said = f"{'typing' if do == 'type' else 'writing'} “{value}”"
        return said + (f" in {decider.prefix(target, 40)}…" if target else "…")
    if do == "key":
        return f"pressing {value}…"
    if do == "scroll":
        return f"scrolling {value or 'down'}…"
    return f"{'picking' if do == 'pick' else 'clicking'} “{decider.prefix(target, 40)}”…"


_SYMBOLS = {"⌘": "cmd+", "⌥": "alt+", "⇧": "shift+", "⌃": "ctrl+", "↩": "return", "⎋": "escape",
            "←": "left", "→": "right", "↑": "up", "↓": "down"}


def chord(value):
    """The plus form Swift reads: ⌘⌥L and "Cmd + L" both become cmd+alt+l."""
    text = value.strip()
    for symbol, word in _SYMBOLS.items():
        text = text.replace(symbol, word)
    parts = [p.strip().lower() for p in text.split("+")]
    if text.endswith("++"):
        parts = [p for p in parts if p] + ["+"]
    else:
        parts = [p for p in parts if p]
    parts = [p.replace(" ", "").replace("_", "") if len(p) > 1 else p for p in parts]
    parts = [_NAMES.get(p, p) for p in parts]
    if "fn" in parts[:-1] and parts[-1] in ("delete", "backspace"):
        parts = [p for p in parts[:-1] if p != "fn"] + ["forwarddelete"]
    # macOS has no ⌘Home: ⌘↑ and ⌘↓ go to the start and end of the text.
    if "cmd" in parts[:-1] and parts[-1] in ("home", "end"):
        parts[-1] = "up" if parts[-1] == "home" else "down"
    return "+".join(parts)


_NAMES = {"command": "cmd", "option": "alt", "opt": "alt", "control": "ctrl",
          "enter": "return", "esc": "escape", "pgup": "pageup", "pgdn": "pagedown",
          "pgdown": "pagedown", "fndelete": "forwarddelete", "del": "forwarddelete",
          "arrowleft": "left", "arrowright": "right", "arrowup": "up", "arrowdown": "down"}


# Context


def _value(item):
    """` = "16:00"` for a field that holds something other than its name.
    Seen 09-23: the model retyped a time it had set, because the line showed
    only the field's name."""
    if item["kind"] != "text":
        return ""
    value = " ".join((item.get("value") or "").split())
    if not value or value == " ".join(item["name"].split()):
        return ""
    return f" = \"{decider.prefix(value, NAME_CHARS)}\""


def _line(item):
    role = item["role"].replace("AX", "") or "Item"
    name = decider.prefix(" ".join(item["name"].split()), NAME_CHARS)
    notes = [f"in the {item['in']}"] if item.get("in") else []
    notes += item.get("state") or []
    notes = f" ({', '.join(notes)})" if notes else ""
    if name:
        return f"{role} \"{name}\"{_value(item)}{notes}"
    if item["kind"] == "text":
        if item["role"] == "AXComboBox":
            return f"{role} (no name: looks people and channels up as you type){_value(item)}{notes}"
        return f"{role} (no name){_value(item)}{notes}"
    return role + notes


GAZE_CM = 1.5


def gaze_item(snapshot, offers):
    """What "this" is: the nearest clickable or text item, when one is close.
    The snapshot is sorted by distance from the gaze."""
    for item in offers:
        if float(item.get("cm", 0)) > GAZE_CM:
            return None
        if item.get("clickable", item["kind"] in ("click", "text")):
            return item
    return None


# The call


RETRIES = 2
# Arguments `create()` takes by name in openai 1.57.4. The rest, such as
# `reasoning_effort`, goes in the body as given.
NAMED = {"tools", "tool_choice", "parallel_tool_calls", "response_format"}
# httpx2 2.13 calls brotli 1.1's Decompressor.process() with a keyword it
# does not take: every brotli answer failed with a TypeError (09-23).
PLAIN = {"Accept-Encoding": "gzip, deflate"}


def base_url(endpoint):
    """The SDK's base URL: the endpoint without `/chat/completions`. An
    endpoint that does not end with it is taken as the base."""
    parts = urllib.parse.urlsplit(endpoint)
    path = parts.path.rstrip("/")
    if path.endswith("/chat/completions"):
        path = path[:-len("/chat/completions")]
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))


class Planner:
    def __init__(self, url, key, model, reasoning="none", timeout=15.0, source="",
                 loop="agent", trace="", review_reasoning="high"):
        self.url = urllib.parse.urlsplit(url)
        self.review_reasoning = review_reasoning
        self.loop = loop
        self.trace = trace
        self.key = key
        self.model = model
        self.reasoning = reasoning
        self.timeout = timeout
        self.source = source
        self.recorder = recording.OFF
        self._client = None
        self._agent_model = None
        self._events = None
        # The last request body the agent's client sent: what the model got.
        # The agent's calls go to /v1/responses; `chat` stays on chat completions.
        self.sent = None

    @classmethod
    def from_env(cls):
        env = os.environ
        model = env.get("PARROTFLOW_PLANNER_MODEL", "").strip()
        key = env.pop("PARROTFLOW_PLANNER_KEY", "").strip()
        if not model:
            return None
        return cls(
            env.get("PARROTFLOW_PLANNER_URL", "https://api.openai.com/v1/chat/completions"),
            key, model, env.get("PARROTFLOW_PLANNER_REASONING", "none"),
            float(env.get("PARROTFLOW_PLANNER_TIMEOUT", "15")),
            env.get("PARROTFLOW_PLANNER_KEY_SOURCE", "no key configured"),
            env.get("PARROTFLOW_PLANNER_LOOP", "agent").strip() or "agent",
            env.get("PARROTFLOW_PLANNER_TRACE", "")
            or os.path.expanduser("~/Library/Logs/ParrotFlow-agent.jsonl"),
            env.get("PARROTFLOW_PLANNER_REVIEW_REASONING", "high").strip(),
        )

    @property
    def host(self):
        return self.url.hostname or ""

    @property
    def client(self):
        """One client per runner, so the connection is kept. The timeout is
        httpx's: connect, write, and each wait for bytes of the answer, per
        attempt. Retried: connection errors, timeouts, 408, 409, 429 and 5xx,
        after about 0.5 s then 1 s, or the server's Retry-After up to 60 s."""
        if self._client is None:
            query = dict(urllib.parse.parse_qsl(self.url.query))
            self._client = openai.OpenAI(
                api_key=self.key, base_url=base_url(urllib.parse.urlunsplit(self.url)),
                timeout=self.timeout, max_retries=RETRIES, default_query=query or None,
                default_headers=PLAIN)
        return self._client

    @property
    def agent_model(self):
        """The agent's model: the same host, key, timeout and retries, on the
        Responses API, through Pydantic AI and the SDK's async client. On
        /v1/chat/completions gpt-6-luna answers 400 to any reasoning effort
        but none when tools are sent (09-23)."""
        if self._agent_model is None:
            async def keep(request):
                try:
                    self.sent = json.loads(request.content)
                except ValueError:
                    self.sent = None

            self._agent_model = self.responses_model(
                self.async_client(self.timeout, RETRIES, keep))
        return self._agent_model

    def async_client(self, timeout, retries, keep=None):
        """An async client to the planner's host. Its connections belong to
        the event loop that first uses it."""
        query = dict(urllib.parse.parse_qsl(self.url.query))
        return openai.AsyncOpenAI(
            api_key=self.key, base_url=base_url(urllib.parse.urlunsplit(self.url)),
            timeout=timeout, max_retries=retries, default_query=query or None,
            default_headers=PLAIN,
            http_client=openai.DefaultAsyncHttpxClient(
                event_hooks={"request": [keep]} if keep else None))

    def responses_model(self, client):
        from pydantic_ai.models.openai import OpenAIResponsesModel
        from pydantic_ai.providers.openai import OpenAIProvider
        return OpenAIResponsesModel(self.model, provider=OpenAIProvider(openai_client=client))

    def run(self, coroutine):
        """Runs a coroutine on the runner's one event loop: the async client's
        connections belong to it."""
        if self._events is None:
            self._events = asyncio.new_event_loop()
        return self._events.run_until_complete(coroutine)

    def chat(self, messages, **extra):
        """One call, retried by the SDK. (the message that came back, usage, ms)."""
        if not self.key:
            raise Failure(f"No key for the planner — {self.source}.")
        if self.reasoning:
            extra["reasoning_effort"] = self.reasoning
        named = {k: v for k, v in extra.items() if k in NAMED}
        body = {k: v for k, v in extra.items() if k not in NAMED}
        started = time.monotonic()
        try:
            raw = self.client.chat.completions.with_raw_response.create(
                model=self.model, messages=messages, extra_body=body or None, **named)
            data = raw.http_response.content
        except openai.APITimeoutError:
            raise Failure(f"The planner timed out after {RETRIES + 1} tries.")
        except openai.APIStatusError as error:
            raise Failure(self._clean(f"The planner answered {error.status_code}: "
                                      f"{error.response.text[:200]}"))
        except openai.APIConnectionError as error:
            cause = error.__cause__ or error
            raise Failure(self._clean(str(cause) or type(cause).__name__))
        ms = int((time.monotonic() - started) * 1000)
        try:
            top = json.loads(data)
            message = top["choices"][0]["message"]
        except (ValueError, KeyError, IndexError, TypeError):
            raise Failure("The planner's answer could not be read")
        if message.get("refusal"):
            raise Failure(self._clean(f"The planner refused: {message['refusal'][:200]}"))
        return message, top.get("usage") or {}, ms

    def _clean(self, text):
        return text.replace(self.key, "…") if self.key else text
