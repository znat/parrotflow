"""The envelope a `returns: json` transform reads, and the reply it returns.

`ParrotFlow --envelope-schema` prints the same shapes as a JSON Schema, and
`scripts/check-envelope.sh` fails when this file and that schema disagree.

For a type checker. A transform imports it only under `TYPE_CHECKING`, so it
costs nothing at run time and needs no package:

    from __future__ import annotations
    from typing import TYPE_CHECKING
    if TYPE_CHECKING:
        from envelope import Envelope, Reply

    def run(envelope: Envelope) -> Reply:
        return {"text": envelope["text"].upper()}
"""
from __future__ import annotations

from typing import TYPE_CHECKING, TypedDict, Union

if TYPE_CHECKING:
    from typing_extensions import NotRequired

Scalar = Union[str, int, float, bool]


class Ctx(TypedDict):
    """The pipeline's scope. Any other bare name is a `Scalar` too."""
    vars: dict[str, dict[str, Scalar]]
    text: NotRequired[str]
    app: NotRequired[str]
    bundle_id: NotRequired[str]
    language: NotRequired[str]


class Token(TypedDict):
    at: int
    len: int
    text: str
    tag: str
    lemma: NotRequired[str]


class AsrWord(TypedDict):
    word: str
    start: float
    end: float
    confidence: float


class Asr(TypedDict):
    model: str
    arm: NotRequired[str]
    text: str
    confidence: float
    duration: float
    processing: float
    words: list[AsrWord]


class Vad(TypedDict):
    seconds: NotRequired[float]
    speech: float
    total: float
    segments: list[list[float]]


class Change(TypedDict):
    at: int
    was: str
    now: str


class Part(TypedDict):
    name: str
    seconds: float
    note: NotRequired[str]


class Stage(TypedDict):
    name: str
    skip_reason: NotRequired[str]
    skipped: NotRequired[str]
    edits: NotRequired[list[Change]]
    parts: NotRequired[list[Part]]
    seconds: NotRequired[float]
    vars: NotRequired[dict[str, Scalar]]


class Trace(TypedDict):
    wav: str
    source: str
    lang: NotRequired[str]
    asr: NotRequired[Asr]
    vad: NotRequired[Vad]
    stages: list[Stage]


class Word(TypedDict):
    at: int
    len: int
    text: str
    upos: str
    feats: dict[str, str]
    head: int
    deprel: str
    ner: str | None
    tags: list[float]
    vector: NotRequired[str]


class Parse(TypedDict):
    language: str
    tag_names: list[str]
    words: list[Word]


class Boundary(TypedDict):
    at: int
    mark: str
    word_at: int
    means: dict[str, float]
    winner: str


class Readings(TypedDict):
    language: str
    boundaries: list[Boundary]
    missing: NotRequired[str]


class Envelope(TypedDict):
    text: str
    ctx: Ctx
    tokens: list[Token]
    trace: NotRequired[Trace]
    aligned: bool
    parse: NotRequired[Parse]
    readings: NotRequired[Readings]


class Reply(TypedDict):
    text: NotRequired[str | None]
    vars: NotRequired[dict[str, Scalar]]
