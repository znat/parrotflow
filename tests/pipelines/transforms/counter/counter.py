#!/usr/bin/env python3
"""A `returns: json` transform that does nothing useful, on purpose.

The variable machinery has to be scored on its own, separately from any stage
whose job is interesting — otherwise a case that fails leaves you asking whether
the carry-through broke or whether `code_identifiers` changed its mind about a
word. So this contributes variables you choose from the fixture, and rewrites
the text only when asked.

    counter.py --count 3            -> vars {"count": 3}
    counter.py --count 3 --upper    -> and the text upper-cased
    counter.py --no-text            -> variables only; the sentence is untouched
    counter.py --echo numbers.count -> vars {"saw": <that, from the context>}
    counter.py --garbage            -> prints something that is not JSON
    counter.py --fail               -> exits non-zero

`--echo` is the one that matters most: it is the only way to show that what the
pipeline carries actually reaches a script, rather than merely surviving inside
Swift where a test can see it and a transform cannot.

`--bump` and `--label-once` exist for one case: the same transform twice in one
pipeline, which is the only way a namespace gets written over. A transform has
one command, so two runs of it publish identical variables unless the script
looks at what it published last time — and then the two runs differ:

    counter.py --bump counter.count --label-once first-run

    run 1   sees nothing          -> {"count": 1, "label": "first-run"}
    run 2   sees counter.count=1  -> {"count": 2}

which is both halves of the rule in one fixture. `count` is republished and must
end at 2; `label` is *not* republished by the second run and must survive it.
"""
import argparse
import json
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int)
    parser.add_argument("--label")
    parser.add_argument("--echo")
    parser.add_argument("--bump")
    parser.add_argument("--label-once")
    parser.add_argument("--upper", action="store_true")
    parser.add_argument("--no-text", action="store_true")
    parser.add_argument("--garbage", action="store_true")
    parser.add_argument("--fail", action="store_true")
    args = parser.parse_args()

    if args.fail:
        sys.stderr.write("asked to fail\n")
        raise SystemExit(3)

    if args.garbage:
        # Declared `returns: json` and printed prose. The pipeline has to keep
        # the transcript and record that this stage did not work — the one
        # failure `--check-config` cannot catch, because it is in the script.
        sys.stdout.write("this is not JSON")
        return

    envelope = json.loads(sys.stdin.read())
    text = envelope["text"]
    ctx = envelope.get("ctx", {})

    def look(path):
        namespace, _, name = path.partition(".")
        return ctx.get("vars", {}).get(namespace, {}).get(name)

    variables = {}
    if args.count is not None:
        variables["count"] = args.count
    if args.label is not None:
        variables["label"] = args.label
    if args.echo is not None:
        # A missing value is reported as -1 rather than omitted: "the script
        # could not see it" and "the script did not look" are different
        # failures, and a variable that is simply absent cannot tell them apart.
        found = look(args.echo)
        variables["saw"] = found if found is not None else -1
    if args.bump is not None:
        previous = look(args.bump)
        variables["count"] = (previous if isinstance(previous, int) else 0) + 1
        # Only on the run that found nothing, which is the first one. The second
        # run must leave this key alone entirely — not republish it, not blank
        # it — so that the pipeline is the only thing that could have carried it.
        if args.label_once is not None and previous is None:
            variables["label"] = args.label_once

    reply = {"vars": variables}
    if not args.no_text:
        reply["text"] = text.upper() if args.upper else text

    sys.stdout.write(json.dumps(reply))


if __name__ == "__main__":
    main()
