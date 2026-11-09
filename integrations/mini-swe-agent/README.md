# parrotflow-mini

ParrotFlow speaks what [mini-swe-agent](https://github.com/SWE-agent/mini-swe-agent)
does and what it answers. mini has no hooks, so this small Python package
sends its events to the app instead. The app writes nothing for mini: you
install the package once, by hand, into the Python environment mini runs in.

## Install

With `uv`:

```sh
uv tool install mini-swe-agent \
  --with "parrotflow-mini @ git+https://github.com/znat/parrotflow#subdirectory=integrations/mini-swe-agent"
```

With `pipx`, after `pipx install mini-swe-agent`:

```sh
pipx inject mini-swe-agent \
  "parrotflow-mini @ git+https://github.com/znat/parrotflow#subdirectory=integrations/mini-swe-agent"
```

From a clone, pass the folder instead: `--with ~/parrotflow/integrations/mini-swe-agent`
for `uv`, or `pipx inject mini-swe-agent ~/parrotflow/integrations/mini-swe-agent`.

The plugin stays through `uv tool upgrade mini-swe-agent` (uv 0.6.11) and
`pipx upgrade mini-swe-agent` (pipx 1.8.0). Both were tried from mini 2.4.5 to
2.4.6. `uv tool install --upgrade mini-swe-agent` without `--with` takes it out.

## Turn it on

Add `mini:` under `voice.agents` in ParrotFlow's `config.yaml`. Without that
key, the app ignores mini's events. An agent left out of `agents` is off, so
keep `claude:` in the list if you use Claude Code too.

```yaml
voice:
  agents:
    claude:
    mini:
```

Then run mini with the plugin's agent class:

```sh
mini --agent-class parrotflow_mini.ParrotFlowAgent
# or, from a config: -c mini.yaml -c agent.agent_class=parrotflow_mini.ParrotFlowAgent
```

## What it sends

The task, each command before it runs, the wait for your approval in confirm
mode, and the end of the task with the model's last text as the answer. A run
that stops on its step, cost or time limit, or on an error, is not spoken.
Each `mini` process is one session.

The plugin sends to the release app's socket,
`~/Library/Application Support/ParrotFlow/claude.sock`. For the dev app, set
`PARROTFLOW_SOCKET` to `~/Library/Application Support/ParrotFlow Dev/claude.sock`.
When the app is not running, mini runs as before: each send gives up after
0.2 s and never raises.

The plugin is written against mini 2.4.6 and uses four of its private methods,
so a later mini can drop events.

## Test

From the repository root:

```sh
scripts/check-mini-plugin.sh                  # on a stub of mini 2.4.6
PYTHON=<mini's python> scripts/check-mini-plugin.sh   # on the real mini
```

The full reference is in [docs/configuration.md](../../docs/configuration.md#voice).
