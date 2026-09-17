#!/usr/bin/env python3
"""Turn people's names into Slack mentions.

Fill the roster below. One line per person: the name as it is dictated,
then the handle. Names are matched whole and case-sensitive, so "mark it
as done" is not Mark. A name already written as a handle is left alone.

To get the list, ask the assistant in your Slack:

    List the names and Slack handles of all the people I interacted
    with in the last 90 days.

Paste what it answers into ROSTER. Never guess a handle: a wrong one
pings the wrong person. ParrotFlow never sends a message. You get text
in your composer, and the last look is yours.
"""
import os
import re
import subprocess
import sys

ROSTER = {
    # "Marie": "@marie.dupont",
    # "Thomas": "@tleroy",
}

if not ROSTER:
    subprocess.run(["open", os.path.dirname(os.path.abspath(__file__))])
    sys.stderr.write("open slack_mentions.py to set up Slack mentions\n")
    sys.exit(1)

text = sys.stdin.read()
for name, handle in ROSTER.items():
    text = re.sub(rf"(?<![@\w.]){re.escape(name)}\b", handle, text)
sys.stdout.write(text)
