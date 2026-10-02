#!/usr/bin/env python3
"""A ParrotFlow transform: the text comes in on stdin, the rewrite goes out on stdout.

Copy this folder to <config dir>/transforms/<name>/, rename this file to
<name>.py, run chmod +x on it, and declare it in config.yaml:

  - name: <name>
    description: <what someone would ask for>
    command: <name>.py
    returns: json

Then score it with: ParrotFlow --eval <name>

A table that only swaps fixed words is cheaper as `replace:`. Use a script when
the rule needs code: a lookup, a branch, a change of case.
"""
import json
import os
import re
import sys

TABLE = {
    "right arrow": "→",
    "left arrow": "←",
}


def rewrite(text):
    count = 0
    for spoken, written in TABLE.items():
        text, n = re.subn(rf"\b{re.escape(spoken)}\b", written, text, flags=re.IGNORECASE)
        count += n
    return text, count


structured = os.environ.get("PARROTFLOW_PROTOCOL") == "json"
raw = sys.stdin.read()
text = json.loads(raw)["text"] if structured else raw.rstrip("\n")
out, count = rewrite(text)
if structured:
    sys.stdout.write(json.dumps({"text": out, "vars": {"count": count}}))
else:
    sys.stdout.write(out)
