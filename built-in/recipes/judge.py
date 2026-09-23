"""Jev, through Pydantic AI's TypeSafe model.

Each question is one field of the output type. A pick is a `Literal` of the
option keys, with each key's text in the schema; a yes/no is a float from 0 to
1, which comes back as Jev's probability of yes. One question alone is asked
as a bare output, so its instructions are the question itself, as before.

Configured by the app, through the runner's environment: PARROTFLOW_JEV_KEY,
PARROTFLOW_JEV_KEY_SOURCE, PARROTFLOW_JEV_URL, PARROTFLOW_JEV_MODEL,
PARROTFLOW_JEV_TIMEOUT.
"""

import asyncio
import json
import os
import time
import urllib.parse
from typing import Annotated, Literal

from pydantic import Field, WithJsonSchema, create_model
import httpx2
from typesafe_sdk import AsyncTypeSafeClient, RetryPolicy, TypeSafeAPITimeoutError
from pydantic_ai import Agent
from pydantic_ai.exceptions import ModelAPIError, ModelHTTPError, UnexpectedModelBehavior, UserError
from pydantic_ai.models.typesafe import TypeSafeModel
from pydantic_ai.providers.typesafe import TypeSafeProvider

PATH = "/v1/systemone"
# See planner.PLAIN: httpx2 2.13 fails on every brotli answer.
PLAIN = {"Accept-Encoding": "gzip, deflate"}
# Today's client retried once, and only a kept connection that had dropped.
RETRY = RetryPolicy(max_retries=1, http_statuses=set(), api_timeout_error=False,
                    backoff_initial=0, timeout=None)


class Failure(Exception):
    pass


def base_url(endpoint):
    """The SDK's base URL: the endpoint without `/v1/systemone`."""
    parts = urllib.parse.urlsplit(endpoint)
    path = parts.path.rstrip("/")
    if path.endswith(PATH):
        path = path[:-len(PATH)]
    return urllib.parse.urlunsplit((parts.scheme, parts.netloc, path, "", ""))


class Pick:
    """One of `options`, a dict of key to text, in that order."""

    def __init__(self, question, options):
        self.question = question
        self.options = dict(options)

    def type(self):
        schema = {"anyOf": [{"const": k, "description": v} for k, v in self.options.items()]}
        return Annotated[Literal[tuple(self.options)], WithJsonSchema(schema)]


class Chance:
    """Jev's probability of yes, 0 to 1."""

    def __init__(self, question):
        self.question = question

    def type(self):
        return Annotated[float, Field(ge=0, le=1)]


class Answer:
    """`value`: the key picked, or the probability of yes. `p`: the pick's
    probability. `probabilities`: every option's."""

    def __init__(self, value, probabilities=None):
        self.value = value
        self.probabilities = probabilities or {}
        self.p = value if isinstance(value, float) else float(self.probabilities.get(value, 0))


class Answers(dict):
    input_tokens = 0


class _Sent(Exception):
    pass


class Jev:
    def __init__(self, url, key, model, timeout, source):
        self.url = url
        self.key = key
        self.model = model
        self.timeout = timeout
        self.source = source
        self._agent = None
        self._events = None

    @classmethod
    def from_env(cls):
        env = os.environ
        return cls(
            env.get("PARROTFLOW_JEV_URL", "https://api.typesafe.ai/v1/systemone"),
            env.pop("PARROTFLOW_JEV_KEY", "").strip(), env.get("PARROTFLOW_JEV_MODEL", "jev-latest"),
            float(env.get("PARROTFLOW_JEV_TIMEOUT", "10")),
            env.get("PARROTFLOW_JEV_KEY_SOURCE", "no key configured"),
        )

    def _agent_on(self, **transport):
        client = AsyncTypeSafeClient(api_key=self.key or "none", base_url=base_url(self.url),
                                     model=self.model, timeout=self.timeout, headers=PLAIN,
                                     retry=RETRY, **transport)
        model = TypeSafeModel(self.model, provider=TypeSafeProvider(typesafe_client=client),
                              settings={"timeout": self.timeout})
        return Agent(model, retries={"output": 0})

    @property
    def agent(self):
        """One provider and one HTTP client per runner, so the connection is
        kept: a fresh TLS handshake cost 702 ms against 259-307 ms."""
        if self._agent is None:
            self._agent = self._agent_on()
        return self._agent

    def _run(self, coroutine):
        """The runner's one event loop: the client's connections belong to it."""
        if self._events is None:
            self._events = asyncio.new_event_loop()
        return self._events.run_until_complete(coroutine)

    @staticmethod
    def _asked(state, questions):
        """The run's prompt, output type and instructions."""
        text = state if isinstance(state, str) else json.dumps(state, ensure_ascii=False)
        if len(questions) == 1:
            only = next(iter(questions.values()))
            return text, only.type(), only.question
        fields = {name: (q.type(), Field(description=q.question)) for name, q in questions.items()}
        return text, create_model("Answers", **fields), None

    def ask(self, state, questions, settings=None):
        """`questions`: name to Pick or Chance, asked in that order about
        `state`, a dict or text. Returns name to Answer."""
        if not self.key:
            raise Failure(f"No key for the action decider — {self.source}.")
        # A pick of one option is refused before sending: `none` alone, when
        # nothing was offered.
        only = {name: next(iter(q.options)) for name, q in questions.items()
                if isinstance(q, Pick) and len(q.options) == 1}
        if only:
            asked = {n: q for n, q in questions.items() if n not in only}
            answers = self.ask(state, asked, settings) if asked else Answers()
            given = {n: Answer(key, {key: 1.0}) for n, key in only.items()}
            ordered = Answers((n, answers.get(n) or given[n]) for n in questions)
            ordered.input_tokens = answers.input_tokens
            return ordered
        text, output, instructions = self._asked(state, questions)
        try:
            result = self._run(self.agent.run(text, output_type=output, instructions=instructions,
                                               model_settings=settings))
        except ModelHTTPError as error:
            raise Failure(f"The action decider answered {error.status_code}: {str(error.body)[:200]}")
        except UnexpectedModelBehavior as error:
            raise Failure(f"The action decider's answer could not be read: {error}")
        except (ModelAPIError, UserError) as error:
            if isinstance(error.__cause__, TypeSafeAPITimeoutError):
                raise Failure("The request timed out.")
            raise Failure(str(error) or type(error).__name__)
        chances = (result.response.provider_details or {}).get("probabilities") or {}
        names = list(questions)
        if len(names) == 1:
            values = {names[0]: result.output}
            chances = {names[0]: chances.get("response")}
        else:
            values = result.output.model_dump()
        answers = Answers((name, Answer(values[name], chances.get(name))) for name in names)
        answers.input_tokens = result.response.usage.input_tokens
        return answers

    def body(self, state, questions):
        """The request `ask` would send, as JSON text. Nothing is sent."""
        sent = []

        def keep(request):
            sent.append(request.content.decode("utf-8"))
            raise _Sent()

        text, output, instructions = self._asked(state, questions)
        agent = self._agent_on(transport=httpx2.MockTransport(keep))
        events = asyncio.new_event_loop()
        try:
            events.run_until_complete(agent.run(text, output_type=output, instructions=instructions))
        except _Sent:
            pass
        finally:
            events.close()
        return sent[0]


def timed(name, jev, state, questions):
    start = time.monotonic()
    try:
        return jev.ask(state, questions)
    finally:
        print(f"jev {name} {int((time.monotonic() - start) * 1000)} ms")
