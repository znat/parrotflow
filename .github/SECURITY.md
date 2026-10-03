# Reporting a security problem

ParrotFlow holds the microphone, the Accessibility grant and the keystroke
path. A bug in any of those is worth reporting privately first.

**Report it here:**
[github.com/znat/parrotflow/security/advisories/new](https://github.com/znat/parrotflow/security/advisories/new).
Please do not open a public issue.

One maintainer, so: first reply within 72 hours, a fix or a plan within two
weeks for anything that leaks audio, text or credentials. Only the latest
release is patched.

Useful in the report: what an attacker can reach, the steps, the version, and
the config if it is part of the path. A `command:` transform runs code by
design — that is config, not a vulnerability. A way to make the app run code
its owner did not put in the config is one.
