# Models

Plain dictation needs no model. The default pipeline is free and local. A model
is needed for `prompt:` transforms (the `G` grammar chip), for "hey parrot"
commands, and for spelling a name out loud.

## Local, with Ollama

```sh
brew install ollama
ollama pull gemma4:e4b-mlx
```

```yaml
models:
  gemma:
    api: ollama
    model: gemma4:e4b-mlx
    keep_loaded: true
    default: true
```

- `keep_loaded: true` keeps the model in memory while the app runs. Ollama
  otherwise unloads it after five idle minutes, and the next call takes about
  6.7 s instead of 1.5 s. It costs the model's size in RAM: 9.6 GB for
  `gemma4:e4b`. On a 16 GB Mac set it to `false`. On 32 GB, keep it.
- Check what is installed: `curl -s -m 1 http://localhost:11434/api/tags`.
  Name a model from that list.

## Cloud

```yaml
models:
  gpt:
    api: openai              # the protocol: ollama, openai or anthropic
    model: gpt-5.6-luna
    reasoning: off           # off | minimal | low | medium | high
    timeout_seconds: 30
  claude:
    api: anthropic
    model: claude-sonnet-5
    reasoning: off
```

- **A cloud model sends every text it rewrites off the Mac.** Say so before
  adding one. `--check-config` says so too.
- `api` is the protocol, not the vendor. Another provider works through
  `endpoint:` with the protocol it speaks:
  `{api: openai, endpoint: https://api.deepseek.com/v1, model: deepseek-chat}`.
- **The key.** Leave `api_key:` out. The app then reads the keychain and asks
  for the key the first time. Or the user runs `"$PF" --set-key gpt` and types
  it. Never put a key in `config.yaml` or in chat. Other forms:
  `api_key: file:~/path/to/key` (works everywhere),
  `api_key: env:NAME` (only from a terminal: the app started from Finder sees
  no shell environment).
- `temperature:` is sent only when written. Reasoning models reject it.
- `max_tokens:` replaces the computed budget.
- `params:` is merged into the request body as is. `null` removes a field the
  app sends by default: `params: {reasoning_effort: null}`.

## Which model runs what

- With one model, it is the default. With several, exactly one has
  `default: true`. None or two is an error.
- A transform names one: `model: gpt`, or with per-call settings:

  ```yaml
  model:
    use: gpt          # a name from models:
    reasoning: low
    max_tokens: 800
  ```

  The mapping may change `reasoning`, `temperature`, `max_tokens`,
  `timeout_seconds` and `params`. Not `api`, `model`, `endpoint` or
  `api_key`: a different connection is another entry in `models:`.
- `commands.router`, `commands.spelling`, `commands.catch_all` pick the model
  for each part of "hey parrot". See `spoken-commands.md`. Keep the router local.
- A model name nothing defines falls back to the default model, and
  `--check-config` names it.

## Failing open

No key, a rate limit, a timeout, no network, Ollama not running: each one
leaves the text exactly as it arrived. Prove it for any new prompt stage with
the test in `cli.md`, "Fail open".

`timeout_seconds` on a model is how long before the text goes through
unchanged.
