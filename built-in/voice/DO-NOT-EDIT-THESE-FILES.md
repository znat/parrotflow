# Do not edit these files

These are the voice's built-in prompts. On every launch, the app copies this
folder whole into `voice/built-in/` in your config folder, replacing what was
there, so you can read the text it uses.

Any edit you make here, or in that copied folder, is gone at the next launch
or app update.

To change a prompt, copy its file one folder up, into `voice/`, for example
`~/.config/parrotflow/voice/explain.md`, and edit the copy. It is read again
for each line the voice says, so no restart is needed. Delete the copy to go
back to the built-in prompt.

The reply format is not in these files. The app adds it after your text, so a
prompt of yours cannot break it. See
[Configuration](../../docs/configuration.md#prompts).
