# Do not edit these files

This folder ships with ParrotFlow. On every launch, the app copies it whole
into `~/.config/parrotflow/transforms/examples/`, replacing what was there.

Any edit you make here, or in that copied folder, is gone at the next
launch or app update.

If you want to change one of these examples:

- Copy its folder into another folder under `transforms/`, for example
  `transforms/code_identifiers/`, and point `command:` at the bare file
  name there.
- Or write your own transform directly under `transforms/`.

Either way, nothing under `transforms/examples/` is yours to edit. See
[Configuration](../../docs/configuration.md#a-folder-per-transform) for
how transform folders resolve.
