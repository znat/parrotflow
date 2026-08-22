# `.parrot/`

The words this project's team says out loud, for anyone who dictates about it.

`vocabulary.yaml` holds the terms. It is a hint file: the app never reads it.
Ask an agent to "pull the parrot folder from this repo" and it will screen
every term against your voice and your languages before anything is written
into your own `vocabulary.yaml`. A term that is safe for the person who
committed it is not therefore safe for you.

There is no `transforms/` here. Every transform this project ships is
installed by the app itself, into `transforms/examples/` beside your config —
see [docs/configuration.md](../docs/configuration.md#a-folder-per-transform).
A folder that shares transforms puts them under `transforms/<name>/` and lists
them in a `config.yaml` fragment; [docs/sharing.md](../docs/sharing.md) has the
layout.

Check this folder with:

```sh
scripts/check-parrot-folder.sh .parrot
```
