# Permissions

**Microphone** — required. Requested on first launch.

**Accessibility** — required for `insert_mode: paste` (the default) and for
spoken corrections, because reading your selection is exactly what that
permission governs. `insert_mode: clipboard` works without it: the transcript
is copied and you press ⌘V.

Nothing else is asked for. Gating a pipeline stage by app reads the frontmost
app from `NSWorkspace` rather than off the focused element, so it costs no
permission that gating by text does not.

## Checking them

`--check-config` reports the microphone honestly. It cannot report
Accessibility: macOS credits a permission check made from a terminal to the
terminal, not to ParrotFlow, so it reads as missing even when granted. The app
tests it properly at launch and writes the answer down:

```sh
grep "launched —" ~/Library/Logs/ParrotFlow.log | tail -1
```

## Why permissions don't survive a rebuild

Only relevant if you build from source. Released builds are signed with a
stable certificate, so upgrading does not cost you your grants.

TCC — the subsystem behind these grants — identifies an app by its **code
signature**, not its path. With an ad-hoc signature the designated requirement
pins the binary's `cdhash`, which changes on every single build.

So the grant you gave to yesterday's build does not apply to today's. Worse,
the entry stays in System Settings pointing at a binary that no longer exists,
so it *looks* granted. Un-ticking and re-ticking that entry doesn't help —
it reuses the same dead record. Accessibility enforces this strictly;
Microphone is more forgiving but still breaks when the bundle is replaced.

The symptom is unmistakable: System Settings shows the app ticked, and the app
insists the permission isn't granted.

**The fix, once:**

```sh
make dev-certificate                 # asks for your password
make install                         # picks the identity up automatically
```

That creates a self-signed code-signing certificate. The designated requirement
then keys on the certificate rather than the binary hash, so grants survive
every rebuild. Grant permissions *after* that install, not before.

Since the dev build is a separate application, this only ever costs you the dev
app's grants. The copy you rely on is untouched by anything you rebuild — see
[development.md](development.md).

If a grant is already stuck, `make reset-permissions` deletes the record
properly — un-ticking the box in System Settings does not, it leaves the dead
entry in place, which is why re-ticking it never helps.
