#!/usr/bin/env python3
"""Every transformation a dictation goes through, as it lands.

    scripts/watch.py                    # follow live dictations
    scripts/watch.py --last 10          # the last 10, then follow
    scripts/watch.py --last 10 --no-follow
    scripts/watch.py --stage repetitions   # only where that stage changed something
    scripts/watch.py --all              # include cli sweeps and evals

**No model call anywhere in this file.** It reads `trace.jsonl`, which the app
already writes — one complete record per dictation, at the moment it finishes.

Reads the trace rather than the log. The log streams prose while a dictation is
in flight, but a dictation is one to three seconds end to end, so the middle of
it is not worth reassembling. The trace record turns up complete.

Two things that are not obvious and cost an afternoon each if you skip them.

**`source` is filtered.** The Dev trace holds 11,948 `cli` records against
3,789 `live` ones — every `--eval`, sweep and `--pipeline` writes to the same
file. Unfiltered, a check script running in another terminal floods this one
with things nobody dictated.

**Records reach 17.8 KB**, which is past the size where a single append is
reliably atomic, so a read can land mid-record. Only lines that arrived with a
newline are parsed; the rest is held until the tail of it turns up.
"""
import argparse
import difflib
import json
import os
import re
import sys
import time
from pathlib import Path

# The dev app writes here. The release variant has its own directory and has
# been uninstalled on this machine since 2026-08-03 — pass --archive for it.
ARCHIVE = Path.home() / "Recordings/ParrotFlow Dev"

C = {
    "dim": "\033[2m", "red": "\033[31m", "green": "\033[32m",
    "yellow": "\033[33m", "blue": "\033[34m", "bold": "\033[1m", "off": "\033[0m",
}
if not sys.stdout.isatty():
    C = {k: "" for k in C}

WORD = re.compile(r"\S+|\s+")


def diff(before, after):
    """What one stage changed, as words rather than as two sentences.

    Seven stages printing their input and their output is fourteen copies of the
    same line. The change is the only part worth reading.
    """
    a, b = WORD.findall(before or ""), WORD.findall(after or "")
    out = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, a, b).get_opcodes():
        if tag == "equal":
            continue
        gone, came = "".join(a[i1:i2]).strip(), "".join(b[j1:j2]).strip()
        if tag == "delete" and gone:
            out.append(f"{C['red']}−{gone}{C['off']}")
        elif tag == "insert" and came:
            out.append(f"{C['green']}+{came}{C['off']}")
        elif gone or came:
            out.append(f"{C['red']}{gone}{C['off']}"
                       f"{C['dim']}→{C['off']}{C['green']}{came}{C['off']}")
    return "  ".join(out)


def render(record, only=None):
    """One dictation, one block. Returns False when nothing was worth printing."""
    stages = record.get("stages") or []
    if only:
        hit = [s for s in stages
               if s.get("name") == only and s.get("before") != s.get("after")]
        if not hit:
            return False

    asr = record.get("asr") or {}
    app = (record.get("app") or {}).get("name") or "—"
    when = (record.get("at") or "")[11:19]
    head = (f"{C['bold']}{when}{C['off']}  {app}  {record.get('lang') or '?'}"
            f"  {C['dim']}{record.get('source')}"
            f"  {asr.get('duration', 0):.1f}s audio{C['off']}")
    print(f"\n{head}")

    text = asr.get("text")
    if text is not None:
        conf = asr.get("confidence")
        print(f"  {C['bold']}{'asr':<14}{C['off']}  {text}"
              + (f"  {C['dim']}conf {conf:.2f}{C['off']}" if conf is not None else ""))

    for stage in stages:
        # `transform punctuation` is a name and a target; the target is what
        # you are reading for, so the word "transform" is what gets cut.
        name = stage.get("name", "?").replace("transform ", "")[:13]
        if stage.get("skipped") or stage.get("skip_reason"):
            why = stage.get("skip_reason") or stage.get("skipped")
            print(f"  {C['dim']}{name:<14}  skipped: {why}{C['off']}")
            continue
        before, after = stage.get("before"), stage.get("after")
        ms = (stage.get("seconds") or 0) * 1000
        cost = f"{C['dim']}{ms:6.1f}ms{C['off']}" if ms >= 0.05 else ""
        if before == after:
            print(f"  {C['dim']}{name:<14}  —{C['off']}        {cost}")
        else:
            print(f"  {C['yellow']}{name:<14}{C['off']}  {diff(before, after)}   {cost}")
        # Only the variables a stage chose to publish; the pipeline's own
        # ran/ok/ms are noise here because the line above already says them.
        published = {k: v for k, v in (stage.get("vars") or {}).items()
                     if k not in ("ran", "ok", "ms", "changed")}
        if name == "input" and "before" in published:
            # The three blocks are the whole point of this stage and a 40
            # character sample of them says nothing. Shown as one line with the
            # caret in place, which is how you read it anyway.
            before, sel, after = (published.pop("before", ""),
                                  published.pop("selection", ""),
                                  published.pop("after", ""))
            marked = (f"{C['dim']}…{before[-60:]}{C['off']}"
                      + (f"{C['red']}[{sel}]{C['off']}" if sel else "")
                      + f"{C['bold']}‸{C['off']}"
                      + f"{C['dim']}{after[:60]}…{C['off']}")
            print(f"  {'':<16}{marked}")
        if published:
            shown = "  ".join(f"{k}={json.dumps(v)[:40]}" for k, v in published.items())
            print(f"  {C['dim']}{'':<16}{shown}{C['off']}")

    final = record.get("final")
    if final is not None and final != text:
        print(f"  {C['blue']}{'=':<14}  {final}{C['off']}")
    return True


def records(path, tail_bytes=None):
    """Parse whole lines from a file, skipping anything that will not decode."""
    with path.open("rb") as handle:
        if tail_bytes:
            handle.seek(max(0, path.stat().st_size - tail_bytes))
            handle.readline()
        for line in handle:
            try:
                yield json.loads(line)
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue


def follow(path, wanted, only):
    """Poll for appended lines. 200ms is imperceptible and beats fsevents for
    a file this simple; a partial record is held until its newline arrives."""
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        pending = b""
        while True:
            chunk = handle.read()
            if not chunk:
                time.sleep(0.2)
                continue
            pending += chunk
            *lines, pending = pending.split(b"\n")
            for line in lines:
                if not line.strip():
                    continue
                try:
                    record = json.loads(line)
                except (json.JSONDecodeError, UnicodeDecodeError):
                    continue
                if wanted and record.get("source") not in wanted:
                    continue
                if record.get("kind") != "dictation":
                    continue
                render(record, only)
                sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", default=str(ARCHIVE))
    parser.add_argument("--last", type=int, default=0,
                        help="replay this many recent records before following")
    parser.add_argument("--stage", help="only records where this stage changed the text")
    parser.add_argument("--all", action="store_true",
                        help="include cli sweeps and evals, not just live dictations")
    parser.add_argument("--no-follow", action="store_true")
    args = parser.parse_args()

    path = Path(args.archive) / "trace.jsonl"
    if not path.exists():
        print(f"no trace.jsonl in {args.archive}")
        return 1
    wanted = None if args.all else {"live"}

    if args.last:
        # Bounded read from the end: the Dev trace is tens of MB and almost all
        # of it is sweeps nobody is asking for.
        keep = []
        for record in records(path, tail_bytes=4_000_000):
            if wanted and record.get("source") not in wanted:
                continue
            if record.get("kind") != "dictation":
                continue
            keep.append(record)
        for record in keep[-args.last:]:
            render(record, args.stage)

    if args.no_follow:
        return 0
    print(f"\n{C['dim']}watching {path}"
          f"{'' if args.all else ' (live only)'} — ctrl-c to stop{C['off']}")
    try:
        follow(path, wanted, args.stage)
    except KeyboardInterrupt:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
