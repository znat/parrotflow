#!/usr/bin/env python3
"""A script with a shebang and no execute bit — committed that way on purpose.

The shebang is what picks the interpreter, and it does nothing at all unless
the file is executable. That is the likeliest thing to be wrong with a
`command:` transform, and it used to be reported as "command not found", which
sends you looking for a missing script rather than at the one in front of you.
"""
import sys

sys.stdout.write(sys.stdin.read().upper())
