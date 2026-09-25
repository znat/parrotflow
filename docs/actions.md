# Acting on what is on screen

Hold the action key, say what to do. "Click on Antonio." "Open the thread
with Ian." "Reply here: on it, thanks."

This is not dictation and it is not a transform. Nothing is typed, nothing is
rewritten, and the words never reach the document — they say what to do in the
focused window of the app in front.

Off by default, and off completely: no key registered, nothing sent.

The agent's rules as decision trees: [actions-trees.md](actions-trees.md).

## Before you turn it on

**It sends the window you are working in off this Mac.** Not what you
dictated — the window: its buttons, its labels, the names in the sidebar, the
messages visible in it. That is what the decider needs to pick a target, and
it is a different bargain from every other model in this config.

`--check-config` prints it whenever the block is on:

```
  ✓ actions           Right ⌃ acts in the focused window of the app in front
      ⚠︎ sends the window you are working in to api.typesafe.ai
         its buttons, labels and visible text — not only what you said.
         model jev-latest, key from ~/.typesafe_api_key
      sends messages  no — typed, not sent
```

## Turning it on

```yaml
actions:
  enabled: true
  hotkey:
    key: right_control
  decider:
    api_key: file:~/.typesafe_api_key
```

Every key is in [configuration.md](configuration.md); the whole block with its
defaults is in `config.example.yaml`.

`send:` is the one to think about. Off, a message is typed into the composer
and left there for you to send. On, Return is pressed.

## What happens, in order

1. **The key goes down.** The app in front is noted *now*. The transcript
   arrives about a second after you let go, and by then another app can be in
   front. ParrotFlow itself is never that app.

2. **You speak, you let go, it decodes.** The same recorder, the same model,
   the same vocabulary as a dictation — names matter here more than anywhere.

3. **The runner takes the request.** The app sends what you said to
   `built-in/recipes/runner.py`, one Python process that does all the
   deciding. A recipe runs if one fits. Otherwise the agent runs, in the
   same process (`loop.py`, `agent.py`). The agent needs `actions: planner:`.
   Without it, a request no recipe fits fails with "No planner is set".

4. **The window is read.** The runner asks the app for it. `ScreenTargets`
   walks that app's focused window (`kAXFocusedWindow`) and comes back with
   everything worth naming: buttons, rows, labels, text fields, in reading
   order. About 0.4 s on a Slack window of 224 targets.

5. **The agent decides.** The planner's model gets the request and the
   window as `[ID] Role "name"` lines, and calls tools: `act` with a batch
   of steps, `read`, `look`, `ask`, `done`. See [The agent loop](#the-agent-loop).

6. **It happens.** The runner turns each step into calls the app does: a
   click, a paste, a key. The paste is the app's own, the same one dictation
   uses. Then the window is read again, and the model gets what changed,
   until it calls `done` or a stop rule fires.

Anything that fails — no window to read, no key, the decider times out
— leaves the screen exactly as it was and says why on the pill.

## What a read holds, and what a step changed

**What opened since the first read.** At the run's first read the app's
top-level parts are listed: its windows, and the app element's children
(pop-ups, menus, sheets). Only the list, no walk. Each later read walks the
front window, plus every part that was not on that first list. A window that
was already open is never walked. Items from such a part carry `"in"`:
`pop-up`, `menu`, `dialog`, `sheet` or `window`. Outlook's suggestion list is
one: it is outside the compose window. Its rows (cells, rows, menu items, and
in a pop-up a bare text) take a real click, like a menu item, and are always offered to Jev and to the planner, however late
they come in reading order. All the new parts together get 3,000 elements and 1 s at most.

**Wide elements.** A list, table or outline gives only the rows on screen. Any
other element with more than 20 children (`ScreenTargets.wideChildren`) gives
its visible children if it lists them. Otherwise its first 20 are read, plus 3
each side of the child that holds the caret, or, when the caret is outside
it, its last 7: Slack's newest messages are the last children. The rest becomes one item of kind `more`,
"and 3,140 more". It is never offered and never counts as a change. The log
says each time: `actions: capped 1 wide element(s) at 20 children — AXGroup 23`.

**Values.** Text fields, combo boxes and search fields carry their value, cut
at 100 characters. A text area's value is never read: Outlook's message body
measured 395,489 characters.

**What changed.** `loop.changes(before, after)` returns it as data:

    {"appeared": [{"kind": "pop-up", "near": "To", "rows": ["Peter Holm", "Peter Smith"]}],
     "values": {"To": "Peter"}, "new": ["Send"], "gone": 3, "window": "Untitled"}

`loop.sentence()` says it in one sentence, which goes to the model in each
step's result: `a pop-up opened near "To": "Peter Holm", "Peter Smith"; "To"
now holds "Pe"`. Typing is a change, so a step that only typed is not
"nothing changed".

When the read after the step has seen lines, the change also holds `seen`, text
on screen that the tree lacks, `[{"near": "To", "lines": [{"text", "x", "y",
"w", "h", "p"}]}]`, and `still`, controls that left the tree and are still on
screen. See [The agent loop](#the-agent-loop).

`--act … --app X --look --parts` reads every other window and pop-up of the
app as if it had just opened. It only reads.

## Who decides what

This is the decider, which `--act` and `scripts/check-actions.sh` still
measure. The Jev loop that ran on it, one question per step, was removed on
09-24: runs go to the agent. The split was measured rather than assumed.

| Question | Decided by | Why |
| --- | --- | --- |
| Which action | the model | six choices, one answer, no arguments to get wrong |
| Which target | the model, from the list it was shown | a name in the utterance picks it |
| What to type | the utterance itself | the model is never asked to write anything |
| Where the search field is | code | Slack's is not a text field in the accessibility API, so it can never be offered — `search` is mapped to ⌘G |
| Opening a new message | code | the picker is a shortcut, not a target, so `new_message` is mapped to ⌘N. Who it is to is a second step, over the window the picker draws |

Everything in this table is Python, in `built-in/recipes/`. The app holds
only what talks to the Mac: the accessibility walk and what it concludes about
an item (`lookup`, `in_list`, `clickable`, `refused`), the events, the
spotlight, Escape, and the checks at the moment of acting.

| Python decides | The app does and checks |
| --- | --- |
| which recipe, or the loop | the accessibility walk, and each item's kind |
| the loop's question to Jev, and reading the answer | clicks, presses, keys, paste, wheel, drag |
| the stop rules, what changed, what goes in `done` | `never_press`, refused by name at the moment of acting |
| the per-app notes in `apps/<app>.md` | the front-app check before a key or a click |
| the guards before each step | Return refused in a message box when `send` is off |
| whether a name is on the recipient line | Escape, and the outlines |

## Recipes

A recipe is a fixed sequence for a request the loop gets wrong, such as a
message to two people. It is a Python function. The model picks the recipe from
what you said, or says none, and none goes to the agent.
`actions: recipes: true` turns it on; it is off by default.

One Python process does the deciding: `built-in/recipes/runner.py`. The app
starts it at launch and restarts it if it dies. It imports the recipe files,
asks Jev which recipe fits and what was said, and runs the recipe. It imports
the files again on every request, so an edit counts on the next press. A file
that fails to import is logged and skipped. The app does only the steps that
touch the screen.

The runner needs pydantic, openai, Pydantic AI with its TypeSafe model, and
its harness in the `python3` it runs with: `python3 -m pip install pydantic
openai 'pydantic-ai-slim[openai,typesafe]' pydantic-ai-harness`. Every
question to Jev goes through Pydantic AI's `TypeSafeModel`
(`built-in/recipes/judge.py`): one question per field of the output type. Without one of them, the
runner still starts, and every action ends with that line and the missing
package's name. Importing them costs 330-520 ms, once per runner start. How a
release build ships them is an open question.

Recipes live in two places. A recipe in the second with the same name and app
replaces the first.

- `built-in/recipes/` in the app: the shipped recipes, one folder per app,
  with `runner.py` and `parrotflow.py`, which defines `@recipe` and what a
  recipe gets.
- `recipes/` in the config folder, for your own, for example
  `~/.config/parrotflow-dev/recipes/outlook/message_people.py`.

A recipe is a function declared with `@recipe`. A file can hold several:

```python
from parrotflow import recipe


@recipe(app="com.microsoft.Outlook", says="write an email to one or more people", needs=["who"])
def message_people(app, ask):
    app.key("cmd+n", wait=1200)
    for name in ask.who:
        to = app.lookup_field()
        since = app.mark()
        app.type(name[:ask.letters])
        rows = app.rows(since=since, under=to, outside_window=True)
        row = app.choose(f"Which of these rows is the person called “{name}”?", rows)
        app.click(row)
    app.ready(app.find(kind="text", name="subject")[0])
```

- `app` is the app's bundle ID, or its name as macOS shows it. The bundle ID
  does not change with the system language: `osascript -e 'id of app "Slack"'`.
- `says` is what the model matches the sentence against, by meaning.
- `needs` is `who`, `what`, or both. The model reads them out of the sentence
  only when a recipe needs them.
- `allows` takes words off `never_press` for this recipe's clicks. The Notion
  recipe that deletes a table has `allows=["delete"]`.
- `name` defaults to the function's name. It is what a user recipe replaces.

The recipe never touches the screen. The app sends the runner one line,
`{"run": "<what you said>", "app": …, "bundle": …, "execute": …,
"recipes": …, "read_app": …, "loop": {…}}`. The runner answers with one
`{"do": …}` line per step, the app replies to each, and the runner ends with
`{"end": "planned|ready|done|stopped|failed"}`. When no recipe fits, or
`recipes` is false, the runner runs the agent and the end line also carries
`"loop"`: the report the pill or the alert shows (`said`, `markdown`,
`acted`, `stopped`, `steps`, `shown`). The top of `runner.py` has the details.
The app does the reading, typing and clicking, so Escape still stops the run,
and a click on anything on `never_press` is refused. `ready`, `done` and
`stop` end the run. `choose` asks Jev from the runner and never reaches the
app. `print()` goes to the log as `recipe: py:`. `parrotflow.py` lists every
call.

### The steps the loop asks for

Each is a thin wrapper over existing Swift, with the same checks as the
recipe steps.

| Step | What the app does |
| --- | --- |
| `snapshot {app}` | reads the focused window of `app`, or of the app in front when `app` is null. Items come back in reading order, with ids, `actions` and the app's verdicts |
| `press {id, click}` | the accessibility press, or a real click when `click` is true or the press is refused. Says `pressed` |
| `look {x, y, w, h}` | the text in that part of the screen, from its pixels: `{"lines": [{text, x, y, w, h, p}]}`, frames as for items, or `{"error": …}`. Needs Screen Recording |
| `click_at {x, y, name}` | a real click at a point. `name`, when given, is checked against `never_press` too |
| `scroll {x, y, down, turns}` | wheel turns over a point |
| `select {id}` | drags across the item's text |
| `show_menu {id}` or `{x, y}` | the item's own menu, else a right-click |
| `front` | brings the app forward, for a chord |
| `focus`, `ready_for_words` | where the caret is, its `role`, and whether it waits in an empty box |
| `select_text {id, location, length, text, caret}` | selects `text`, which the focused field holds at `location` (UTF-16, as `field_text` read it), then leaves the caret `before` or `after` it when `caret` says so. AXSelectedTextRange first, read back through AXSelectedText; else keys: ⌘↑ and → from the start, or ⌘↓ and ← from the end, one press per character, then ⇧→ over the text. `method` says which. Refused when the caret is not in that field |
| `field_text {id}` | the whole text of field `id`, or of the focused one: AXValue, else AXStringForRange, else its children joined. `source` says which. The walk never reads a text area's value |
| `observe {at, app, see}` | `snapshot`, plus `focus` (`point`, `role`, `id`, `described`) and `ready_box` from the same read. The loop's step reads use it |
| `spotlight {snapshot, offers, aim, chosen, seconds}`, `spotlight_dismiss` | the outlines |
| `watch` | starts watching for Escape |
| `log {text, plain}` | a log line; `plain` leaves out the `recipe:` prefix |

`--act … --snapshot` sends `{"decide": …, "snapshot": …, "mode": …}` instead:
one decision on a window the app hands over, and no step asked for.

### Send is off: Return is refused in a message box

With `send: false` the app refuses a `key` step for Return, with or without
modifiers, when the caret is in a message box: a text area, or a text field in
the bottom fifth of its window. A field that narrows a list is not one, so the
Slack search recipe's Return still goes through. It asks first. "Yes, go ahead" presses it. "No" fails the step with
`said: true`, and the run stops with "Won't press Return in the message box —
send is off". Other words fail it with `{"error": "redirected", "text": …}`
and the run goes on: see [The question panel](#the-question-panel). This check holds whatever step a run asks for.

`python3 tests/recipe-runner.py` runs the runner against a fake app and a fake
Jev: no screen, no network. It covers the recipes, the agent and its guards.

`type` sends real keystrokes, for a field that filters a list as you type.
`paste` goes through the clipboard, for anything longer. Slack's recipient
field needs the first. Slack's search box needs the second.

Run one without the hotkey. `--execute` brings the app to the front and does
the steps. Without it, the command only says which recipe it would run.

```sh
PARROTFLOW_CONFIG_DIR=<a copy of the config folder> \
  $PF --recipe-probe "write an email to Peter and Antonio" --app "Microsoft Outlook" --execute
```

## Planner

A planner is a remote chat model that knows how apps work. It is off unless
`actions: planner:` is set. When no recipe fits, it runs the request as the
agent: see [The agent loop](#the-agent-loop). Without a planner, that request
fails with "No planner is set".

Two older paths were removed on 09-24: the plan path (`loop: plan`, one plan,
Jev finds each target) and the Jev loop (Jev asks "what now" at every step).
`loop: plan` in an older config runs the agent, and the app log says so.

```yaml
actions:
  planner:
    model: gpt-5.6-luna
    endpoint: https://api.openai.com/v1/chat/completions
    api_key: file:~/.openai_api_key
    reasoning: low           # the reasoning effort; empty leaves it out
    timeout_seconds: 15      # per attempt
    review_reasoning: high   # the review after an agent run; empty leaves it out
```

**The call.** The runner uses the official `openai` package (3.19), one
client per runner, so the connection is kept. The agent loop uses the SDK's
async client, with the same settings, through Pydantic AI, on the Responses
API (`<base>/responses`): every call sends `reasoning: {effort: <reasoning>}`.
On `/v1/chat/completions`, gpt-6-luna answers 400 to any effort but `none`
when tools are sent (09-23); `/v1/responses` takes `low` with strict tools.
Grounding stays on chat completions, with `reasoning_effort`. Both clients ask for gzip
only: httpx2 2.13 cannot read a brotli answer with brotli 1.1, and every call
failed with a `TypeError` (09-23). Its base URL is `endpoint`
without the trailing `/chat/completions`: `https://api.openai.com/v1`. An
endpoint that does not end that way is used as the base as it is. The key
comes from `api_key`, as before.

`timeout_seconds` is per attempt. The SDK gives it to httpx for each phase:
the connection, the upload, and each wait for bytes of the answer. The
answer is not streamed, so in practice it bounds the wait for the whole
answer. A failed attempt is tried twice more (`max_retries=2`): on a
connection error, a timeout, 408, 409, 429 and 5xx. The waits between tries
are about 0.5 s and 1 s, or the server's `Retry-After` when it gives one of
60 s or less. So with the default, an endpoint that never answers fails after about
47 s: 3 × 15 s plus 1.5 s. A refused connection fails in about 1.5 s. A
`Retry-After` of 60 s on each try would make it 165 s; the app's 120 s
silence limit ends the run first. A 401 or 400 is not tried again. The errors read as
before: "The planner answered 500: …", with the key cut out of the body,
and "The planner timed out after 3 tries."

**What leaves the Mac.** The request, the app name and bundle ID, the window
title, and the screen lines the agent reads: names, and
what a text field holds, cut to 60 characters. A row's name can hold the
first words of a message, because Slack names its rows that way. A 512 px
picture of the area being worked in. Per-app notes and memories go too.
`--check-config` prints the host.

**⌘A.** The select-all guard asks the app for the focused element's role
first. In a text field, a combo box or a search field, ⌘A selects only what
the field holds, so it runs without a question. Anywhere else, a text area
included, it asks.

**An open list.** A web pop-up can lie over the target. Seen 09-23 in
Teams: Start time's list lay over End time, the hit test named End time, and
the click picked "18:30" in Start time, which became "18:3018:30". So before
a click or a type, if an item in the newest read is a combo box, a pop-up
button or a text field marked `expanded`, and it is not the target, the loop
presses Return. Return commits the value and closes the list; Escape reverted
the time in that run. The window is read again, and the step's result starts
with `closed the open list of "Start time" first`. Not for a row of that list
or a seen line: that Return would close the list the click is for. The
Return is marked as the app's own. The send guard does not fire on it, since
a combo box is not a message box.

### The agent loop

The agent is the planner's model, calling tools. `loop: agent` is the
default and the only value; `loop: plan` runs the agent too.

The model gets the request, the app, its notes, and the screen as
`[ID] Role "name"` lines: the items Jev would be offered, every item in a
pop-up, and the focused one. A text field, combo box or search field that
holds something shows it: `[20] ComboBox "Start time" = "16:00"`, cut to 60
characters. IDs belong to one read. It has seven tools, and the plan tools:

- `act(why, steps)`: steps `{do, id, value, expect, at}` run in order, `do`
  one of `click`, `pick`, `type`, `write`, `key`, `scroll`, `caret` or
  `select`. `why` is what the
  batch is for, in a few words. It goes in the app
  log line and the trace. A call without it still runs. `expect`, optional,
  is what should be true after the step, such as "To holds Alex Moreau and
  Antonio Ruiz". It is recorded with the step and not checked.
  `at` is where `type` or `write` puts the text in a field that already
  holds some: `start` (⌘↑ first), `end` (⌘↓ first) or `replace` (⌘A first,
  with the ⌘A guard). A field that holds text and a step with no `at` is
  refused before any keystroke, with the start of what the field holds. A
  field that looks names up (To, a search box, a combo box) needs no `at`.
  `write` at the start or end of a text area gets a new line between the
  two. After typing at the start or end, or replacing in a text area, code
  reads the field back (`field_text`): the text must be there, at the start
  or end when asked, and what the field held must still be there, except
  with `replace`. A one-line field is not read back after `replace`: it may
  show the text in its own format, 16:00 for "4 PM".
  `caret` puts the caret in field `id`: `at` is `start` or `end` (⌘↑, ⌘↓),
  or `before` or `after` the words in `value`. `select` selects the words
  in `value`; a `key` (⌘C, ⌘X, backspace) or a `type` or `write` with no
  `at` then acts on them, with no second click. The field is forgotten once
  a step acts on another item, a click, scroll, Tab, Escape or Return moves
  the caret, the field leaves the tree, or another item has the focus. A new
  window title does not count: Gmail renames the window when it saves the
  draft. The model names words and
  never counts characters or aims at pixels. Code finds the words in the
  field's whole text (`field_text`): exactly, else with case and runs of
  spaces not counting. None, or more than one, fails the step and says what
  the field holds, or the words around each match. `select_text` does the
  move and reads the selection back; a mismatch fails the step in one line.
  A skill can hold the same gestures: `caret "<field>" at start|end|before
  "<text>"|after "<text>"` and `select "<field>" "<text>"`.
  Each step goes through `Loop._planned_step` and its guards. The
  batch stops at the first surprise: a step failed, a step changed nothing
  (`type`, `write` and `key` do not count: the tree does not show the caret
  or a selection), a step took a name out of its field,
  or something opened that the next step does not target. The result says which steps
  ran, why it stopped, what changed (as `changes()` gives it), and the new
  screen with new IDs.
- `read()`: the screen again, nothing done.
- `look(id, side)` or `look(x, y, w, h)`: the text in a part of the screen,
  read from its pixels with Vision (fast level, en-US and fr-FR). `side` is
  below, above, right, left or around; below is the item's width plus 40 pt,
  at least 400 pt wide, and 400 pt down. The region is cut to the screen, not
  the window: Outlook draws its suggestions outside the window. Each line
  gets an ID after the screen's (101, 201…). `act` can click one: a real
  click at its centre, checked against `never_press` by its text and by what
  is under the point. A seen line cannot be typed into.
- `ground(description, id, side)` or `ground(description, x, y, w, h)`: a
  point for a target the screen lines have no ID for, found in the pixels.
  See [Finding a target in the pixels](#finding-a-target-in-the-pixels).
  Absent with `actions.ground: off`.
- `ask(question, options)`: a question for the user, with at most 4 options.
  The prompt allows it in three cases: several items could be what the user
  meant, the next step would send, delete, start a call or invite people, or
  the model cannot go on. The result is "The user answered: …". No answer
  ends the run.
- `done(summary)` and `stuck(why)` end the run. They are the run's output
  tools. `done` is refused while a plan step is pending or in progress: the
  model gets "Not done: '<step>' is still open. Finish it, or cancel it with
  a reason." and tries again. `stuck` asks the user once first; an answer
  other than Stop goes back to the model.
  A recipient field (a lookup field named To, Cc, Bcc, recipients,
  attendees, invitees or participants) must end with real recipients. Code
  reads the text typed after the last picked contact in its value: a picked
  contact is U+FFFC or sits between no-break spaces, and Gmail empties the
  value when one is picked. Text there that is not an email address is not a
  recipient. The first `done` is refused once with `"To recipients" still
  holds the text "Sonia Bonnell", which is not a recipient: pick the contact
  from the list or type an email address.` A second `done` goes through. A
  step that moves from that field to another text field gets the same line,
  as a fact. The last value read is kept when the field leaves the tree:
  Gmail folds To away once the caret leaves it.
- `write_plan`, `read_plan`, `add_task`, `update_task_status`,
  `update_task_statuses`, `remove_task`: the task list of `Planning`, from
  pydantic-ai-harness. The prompt asks for `write_plan` on the first call;
  nothing enforces it. The plan is shown at the end of every request after
  it, and is never cut. Each plan call is a model call, and counts toward the
  15.

The loop is Pydantic AI's (`pydantic-ai-slim` 2.48, `pydantic-ai-harness`
0.34): the calls, the tool calls, argument checks, retries and the call
limit. Each tool takes a Pydantic model in `agent.py`. Its docstring is the
tool's description, and its JSON schema, made strict, is what the model gets.
Arguments that do not fit the model run nothing: the tool result is Pydantic
AI's list of wrong fields, and the model tries again. `agent.py` keeps what
is ours: the steps, the reading, the IDs, the history cut, the trace and the
recording.

Every read during a run also reads the window's text from its pixels
(`actions.see`, on in the dev build), from the screenshot's own capture: one
capture, not two. The reply carries the lines as `seen`, and `seen_ms`. The
app log gets a line when that takes over 80 ms. `loop.changes` keeps only
what the tree lacks:

- It drops a line whose text a tree item's name or value holds. Case, spaces,
  accents and punctuation do not count. The line may be part of the tree
  text: Vision cuts long labels. The tree text may be part of the line only
  as whole words and 60% of it, so a row "Peter Holm" is not hidden by a
  field that holds "Peter". At the same place, a looser match also counts:
  70% of the line's characters in order, for lines of six or more. Vision
  reads "23/09/26" as "23109126".
- It drops a line seen at the same place in the read before (12 pt, or half
  the smaller box), 1–2 characters, and lines with no run of two letters or
  digits. After a new window title it reports none: the tree has the page.
- What is left is grouped into blocks: lines stacked less than 40 pt apart,
  with left edges within 40 pt. Each block is `near` the field that changed,
  else the focused field, else the nearest one.
- A line that matches a control of the read before, at its place, and no
  item of this read, is reported apart: the control left the tree and is
  still on screen. Seen 09-23: Teams' date panel hid the rest of the form
  from the tree, and the model said there was no attendee field.

The step's result then says `text appeared near "<field>" (seen, not in the
tree): [101] "…"` and `still on screen, no longer in the tree (a panel may be
hiding them): [105] ComboBox "…"`. The IDs click at the line's centre with
`click_at`, until the next read. Text that appeared ends the batch when the
next step does not click one of its lines, as a pop-up does; a control still
on screen does not. Seen 09-23 in
Teams: the attendee suggestions were on screen and not in the tree, and the
next step clicked the date.

Before a click or a type on a tree item a line high (60 pt or less), the
seen lines over it that are not its own text and not in the tree mean
something covers it. The app's hit test cannot see a web pop-up: it named
End time under Start time's open list. An open list is closed with Return
first, as above. Still covered, the step fails with `"End time" is covered by
text seen on screen: "18:30"`, and the run goes on. An empty field's one line
is taken for its placeholder.

After a `type` into a lookup field, the wait does not end at the field's own
value. It ends when a list shows: a part of the app opened, the field became
expanded, or new items or seen lines appeared below it. It lasts 1.5 s at
most. With `seen` and no list, the step's result starts with `no suggestion
is showing for "Sonia Bonnell": the list can close when a later letter does
not match; clear the field and type only "Sonia"`, and the batch stops there.
Seen 09-25 in Gmail: the list showed Sonia while typing, then closed at
"Bonnell", as the contact is "Bonell-Granda Sonia". The step is not refused.

Without `seen` (the setting off, or no Screen Recording), a `type` into a
lookup field (`lookup`, a combo box, a search field, or a name like To or
attendees) looks below the field before the typing. If the tree then shows
no change, it looks again, and lines that were not there before come back as
`a list opened near "<field>" (seen, not from the tree): [101] "…"`.

`scripts/see-run.py <run folder> <tree> …` runs the reading and the filter on
a recorded run, offline: the blocks, the controls still on screen, and
whether the step taken from that tree was covered. It prints to the terminal
only. Measured 09-23 on two Teams runs: 40–67 ms per window from the JPEG,
warm. On the attendee read it gives the suggestion list and nothing else.

`look` needs **Screen Recording** for ParrotFlow (System Settings → Privacy &
Security → Screen & System Audio Recording). Without it, the first look adds
the app to that list, and `look` answers "screen recording is not granted"
as a tool result. The run goes on without it. Like Accessibility, it cannot
be checked from a terminal: macOS credits the shell.

`--look-image <png> [x y w h] [--scale 2]` runs the same reading on a saved
image, with no capture and no permission. The region is centre and size in
the image's pixels; lines print in points. Measured 09-23 on a 3448×1998
screenshot, warm: 7 ms for the 201×181 pt list under a Teams time field,
15 ms for 400×400 pt, 45 ms for the whole screen.

A guard refusal (never_press, words not said, `cmd+a`) comes back as a tool
result, and so does a covered target. Letters the user spelled count as a
said word: "Harry s'écrit A R I" says "ari", and "B-O-N-E L L" says "bonell". Words the user gave a guard instead of
yes or no come back as the step's result, `Not done — the user said: "…"`,
and the run goes on. Escape, the front-app check and the send rule's no end
the run. Limits: 25 model calls, `max_steps`
steps (30 by default), 120 s, not counting the time the user takes to answer.
Only the newest screen is sent in full; earlier tool results are cut to the
steps that ran. There is no re-plan: the model decides each move from what
came back.

### Surprises

A surprise is a step that failed, the same batch run twice, a refused
`done`, or a step that took a name or words out of its field. The last is
checked after every step that ran, without a model call.

A step's `expect` is not checked. Asking Jev "Is this true now: <expect>?"
cost 0.6-1.0 s a step, and on 09-24 it said no to three steps that had
worked. It was removed on 09-24; the step still records `expect`.

- Loss (`loop.lost`): the text the target field held, split into names, and
  the items drawn inside its frame. A part with two letters or more that is
  gone after the step is reported: `— this step removed "Alex Moreau" from
  "To:"`. Numbers and the field's own name (a placeholder) do not count, nor
  do other fields. Over 72 recorded steps with a target, it fired 3 times,
  and each time a recipient had been removed.

A surprise ends the batch and is a note under the task in progress.

A second surprise on the same task adds to the result: "Two steps surprised
you on this task. Call `ask` now: …". If the model's next tool is not `ask` or
`read`, the runner asks instead: the surprise and "What should I do?", with
Stop. Stop ends the run; other words go back as the tool result. The count
starts again when the task in progress changes, or after a question. With no
plan, nothing is counted.

Each model call writes one JSON line to
`~/Library/Logs/ParrotFlow-Dev-agent.jsonl` (`ParrotFlow-agent.jsonl` for
the release app): the instructions as a system message, then the Responses
`input` as sent, plan reminder included, the tool
calls, the results, ms, tokens and the plan after the call. Never the key. With `actions.record` on, the run is also recorded
for the run viewer: see [Recording a run](#recording-a-run). The app log gets
one line per call:

    agent: call 1 · act (reply in the thread) click [7]; write [7] I'll be there at three · 2578 ms, 1309 tokens in

**Measured 09-22, plan only**, gpt-5.6-luna, `reasoning_effort: none`, strict
tools: 3 of 3 calls came back as valid `act` calls, 1.5-2.6 s, 1,300-1,850
tokens in, 28-44 out. On Notion, "open the page menu" clicked the page title:
the "•••" button was not among the items offered.

**Measured 09-23, through Pydantic AI**, gpt-6-luna, reasoning off, on a
recorded Teams calendar read ("schedule a meeting at 6 pm with Peter"), with
`act` stubbed: call 1 was `write_plan` (2 steps), call 2 a valid `act` with
the plan reminder at the end of the request, call 3 `stuck`, which ended the
run as its output. 2.1-2.5 s per call, 3,400-3,650 tokens in. Plan only, the
plan tools run and the first call that is not one is printed.

### Finding a target in the pixels

`actions.ground` (`tinyclick` in the dev build, `off` in release) gives the
agent a `ground` tool, for a target the screen lines have no ID for: a row of
a list that opened, an icon with no name. The prompt says to call it before
trying another way.

```yaml
actions:
  ground: tinyclick          # tinyclick | luna | off
```

`ground` takes the target's description and a place: next to item `id`
(`side`, around by default, as for `look`), a region x, y, w, h in points, or
nothing, for the list or pop-up that opened last. It crops the newest read's
screenshot there, to 600×400 points at most, and never the whole window. The
answer is a point ID, `[101] point for "Peter Holm" (from pixels)`, that
`act` clicks with `click_at`, as a seen line. Nothing found comes back as
`Not found: …`.

- `tinyclick`: TinyClick (Florence-2-base, 0.27 B, MIT), on MLX, in a helper
  process with its own Python, `built-in/recipes/ground_server.py`. The runner
  starts it on the first `ground` call (1.1-3 s, the model load) and it exits
  after 5 idle minutes. Each call has 3 s. It answers the crop's exact centre,
  `<loc_499><loc_499>`, when it finds nothing: that is taken as not found.
  Without the helper set up, or when it does not answer, the call goes to
  `luna`, and the app log says so once.
- `luna`: the planner's model, with its key and endpoint. The crop goes as a
  JPEG of 512 px on its long side, `detail: low`, and the answer is
  `{found, x, y}` in a strict schema.

Set up TinyClick once:

```sh
scripts/setup-vision.sh     # --release for the release build's folder
```

It makes `~/Library/Application Support/ParrotFlow Dev/vision-venv` (Python
3.11 with mlx 0.32.2, mlx-vlm 0.1.23, transformers 4.49 and pillow; 332 MB)
and puts the model in `models/tinyclick-mlx` next to it (522 MB), with a
README that says where it came from. Nothing goes into any other Python. The
helper takes about 1 GB while it is up.

**Measured 09-23** on 42 targets from recorded Teams, Slack and Outlook runs,
13 of them with no ID in the tree, through `ground.py` and the helper:

| | Hits | No ID in the tree | Time |
| --- | --- | --- | --- |
| TinyClick, 600×400 pt crop | 35/42 | 13/13 | 1.3 s cold, 227 ms warm, 262 ms with the 128 MB buffer cap |
| TinyClick, the whole window | 20/42 | | |
| gpt-6-luna, 512 px, `detail: low` | 39/42 (10/12 through `ground.py`) | 13/13 | 1.1-2.2 s, ~300 tokens in |

Numbered boxes drawn on the picture (set-of-marks) did worse for Luna, 28/42
at 512 px, so it is asked for a point.

**Every request gets a picture** of the area being worked in: the list that
opened, else around the last target, else, on the first call, around the
focused item. 512 px on its long side, `detail: low`, about
300 tokens. A line says what it shows; with `ground` on, it adds that the
model may answer with `ground`, by description, or by `image_x` and `image_y`
in the picture. The system prompt asks the model to check it for what the
screen lines cannot say: which part of a field is selected, highlighted rows,
chips, what covers what. Only the newest request keeps its picture. No
screenshot (no Screen Recording, or none of the above to centre on), no
picture.

No automatic `ground` call. An `act` step names its target by ID only, so a
step aimed at something with no ID carries no words to look for. A step on
an ID that is not on the screen says to call `ground` instead.

With recording on, each grounding is in `grounds/NN.json`: the method, the
crop, the description, the point or not found, ms, and Luna's tokens. The
JPEG Luna got is `grounds/NN.jpg`, and a recorded request names that file
instead of carrying the picture. Without recording, the runner still asks
for each read's screenshot, into one file in the temp folder that each read
overwrites.

### The question panel

A question, from the agent's `ask` or from a guard, is the protocol verb
`ask`. The app shows it in a panel next to `near`: the frame of the item the
last step acted on, plus the pop-up rows that step opened. For the Return
guard it is the focused element; for never_press, the button. The panel goes
below `near`, then above, right or left, whichever fits with a 12 pt gap. It
never covers `near`. With no `near` it is centred on the target window's
screen.

The panel shows the request, the last 4 steps, the question and numbered
options. "Something else…" is always last and opens a text field. Answers:

- click an option, or press its number;
- "Something else…", then type and press Return. Only this takes keyboard
  focus from the target app. Teams may close its suggestion list then;
- hold the action key and speak: the words are the answer, not a new request;
- Escape stops the run. 60 s with no answer is no answer.

A guard asks "Yes, go ahead" or "No". The first, or a plain yes ("yes",
"ok", "sure", "go ahead"…), is yes. "No", a plain no ("nope", "cancel",
"stop"…), Escape or silence is no, as before. Any other words steer: the step
is not done, the run does not stop, and the words go to the model as the
step's result, `Not done — the user said: "move on to the next step"`. The
same rule is in Swift
(`Confirm.verdict`, for the Return and never_press questions) and in Python
(`loop.verdict`, for the runner's own guards).

    ParrotFlow --panels question [seconds] [--at x y w h]
    ParrotFlow --panels question-confirm [seconds] [--at x y w h]
    ParrotFlow --panels question-place

The first two put the panel up next to a dashed box, at `--at` (top-left
corner and size, in screen points from the top-left of the main screen) or
at a made-up field. Each answer is printed and the question comes back.
`question-place` checks the placement rule on a made-up screen.

### The run panel

The question panel is also the run's panel. It comes up when a run starts,
in place of the pill's "Looking…", and shows:

- the request, shortened;
- the agent's plan as a checklist: ✓ completed, ▸ in progress, ☐ pending,
  ✗ cancelled. Under a task, the last one or two things that went wrong
  while it was in progress: a failed step ("is covered by…", "Not done — the
  user said…"), a repeated batch, a refused `done`, why the run stopped.
  These are our own texts; the model writes nothing extra;
- one line for what the run does now: the step, "thinking…" or
  "asking you…". Recipes have no checklist, only this line.

A question appears in the same panel, under the checklist, next to what it is
about. After the answer the panel goes back to its place. That place is
chosen once per run: beside the app's window when there is room, else the
screen corner farthest from the window's centre. It then only grows or shrinks.

During an agent run, a field at the bottom takes words for the agent. Type
and press Return, or hold the action key and speak: a press during a run
never starts a second run. The words are queued in the app. Before each model
call the agent asks for them (`steer`) and adds each to the request as "The
user says, while you work: …". They stay in the history. The prompt says they
come first and may change the plan. Each shows under the plan, with a clock
until the agent takes it, then a tick. The runner logs each, and the run
recording keeps them in `steer` on the call that got them.

While the field has focus or holds unsent text, a step that touches the
screen (a key, typing, a paste, a click at a point, a drag, a menu) waits.
An accessibility press, a scroll, reads and model calls go on. Return gives
focus back to the run's app, then the steps go on. The wait does not count
against the run's time. Escape clears the field; in an empty field it stops
the run. While a question is up, the field is hidden and the question's own
answer field is used.

When the run ends, the line says how ("Done", "Stopped — …"), and the panel
stays until ✕ or Escape. Escape during a run stops it; ✕ stops it and closes.
The runner sends the state with the `progress` verb (see `runner.py`).

    ParrotFlow --panels run [seconds] [--at x y w h]
    ParrotFlow --panels run-ask [seconds] [--at x y w h]

`run` goes through a made-up run: tasks complete, a step fails, a question
comes and is answered, the run ends, a made-up review comes, then again. `run-ask` stops on the
question and asks it again after each answer. `--at` is the question's
anchor; without it the question stays where the panel is. Each placement is
printed.

### The review after a run

After an agent run ends (done, stopped or stuck), one more model call reviews
it and proposes memory files. It needs a planner key and `actions.record`: the
review reads the run's recording. The end of the run is not delayed: the
runner sends `end` first and makes the review in a thread
(`built-in/recipes/review.py`).

**What the model gets.** A digest built by code from the run folder: the
request, the plan, each call's tools in short form, each step's outcome, the
failures with at most five items of screen near each and the call after it,
the user's answers, the timings, and the memory files the agent had for this
app and for the people the request names. No screen beyond that. About
2,000-13,000 characters on four recorded runs.

**The call.** The planner's model, host and key, on the Responses API, with
`review_reasoning` (`high` by default). 120 s per attempt, tried once more.
The answer is strict: `next_time`, `learned`, `went_wrong` and `proposals`,
each `{file, content, why}`. The prompt gives the rules: record the path
that finally worked, never a detour; say where to click and what the screen
shows; update a file rather than add one; people facts only from the user's
answers; `steps:` only for gestures that succeeded in this run, each with a
check; nothing when nothing new was learned; short files.

**What code drops.** A proposal whose file is not `<app folder>/<name>.md` or
`people/<first name>.md`, one without front matter or over 2,500 characters,
a `steps:` block that `skills.problems` rejects, and a step that clicks a
control no step of this run clicked without an error. At most 4 are shown.

**The panel.** Under the run's outcome, "Reviewing the run…", then the
report: next time, what was learned, where the time went (computed from the
recording's `ms`, not by the model), what went wrong. Then each proposal:
its file, `new` or `update`, why, and **Keep** / **Drop**. A click on the
file name shows its content. When each proposal has an answer, the kept files
are written under `<config>/memories/`, folders made as needed. Closed, or no
answer in 5 minutes, and nothing is written. A new request drops a review
that was not answered.

**Between runs.** The review is sent once, and only while no request is
served. The app listens for it until the review comes, 5 minutes pass, or a
new request starts. A review sent just as a request came is dropped on both
sides. `review.json` in the run folder holds the digest, the report, the
proposals shown, those dropped and why, and what was kept.

## Measuring it

`--act` runs the whole path without a microphone. `--execute` runs the
agent, so it needs `actions: planner:`.

```sh
PF=/Applications/ParrotFlow.app/Contents/MacOS/ParrotFlow

# Look, decide, do nothing. --app the app to read; the one in front without it.
$PF --act "click on Antonio" --app Slack

# Read a window and keep it. --look stops before the decision, so it costs
# nothing: this is how a case set is built.
$PF --act "" --app Slack --look --save slack.json

# Decide against a saved window. No screen, same answer.
$PF --act "clique sur Antonio" --snapshot slack.json

# The live path, with the click.
$PF --act "open the thread with Ian" --app Slack --execute

# Outline what the model would be offered, on the window itself, for 6 s.
$PF --act "" --app Slack --look --show 6
```

## Recording a run

With `actions.record: true`, every run is recorded in its own folder under
`~/Library/Logs/ParrotFlow-Dev-runs` (`ParrotFlow-runs` for release). It is on
by default in the dev build and off in release. To step through the runs:

```sh
make trace-viewer                  # the dev runs; VARIANT=release for release
python3 scripts/trace-viewer/serve.py --runs <folder>
```

The server listens on 127.0.0.1 only, on a free port, and opens the browser.
It serves the runs read-only. Pick a run, then a row: a model call or a step.
The picture is the screenshot of that read with the tree drawn over it, in
layers you can switch off: every item, the items shown to the model with
their `[ID]`, the target and the click point, what the hit test found there,
pop-ups, the lines `look` read, the lines seen at the read (the ones the
step reported in full, the rest faint), and what changed since the read before. Up and down
arrows move through the rows. `live` follows a run as it happens; it is on
when the newest run has not ended and its `run.json` moved in the last 2 min.

A run's folder, written by `built-in/recipes/runlog.py`:

| File | What |
| --- | --- |
| `run.json` | The request, the app, the loop (agent, plan, loop or recipe), the model, the settings, start and end, the outcome and the steps shown. Rewritten as the run goes. |
| `calls/NN.json` | One model call: the messages exactly as sent (for the agent, the instructions as a system message, then the Responses `input` items), the tool calls with `why`, the results, ms, tokens, and the agent's plan after the call. `steer` is what the user typed or said to the run that this call got. `ids` maps each `[ID]` the model saw to the item's id in `tree`, as the agent numbered them. They are recorded, not recomputed. A line `look` saw is in `seen`, whole. |
| `steps/NN.json` | One step: what was asked, the target item, the point, an accessibility press or a real click, `under` (what the hit test found at the point before), the trees before and after, the change and its sentence, a guard's question and answer, the verbs sent to the app and their replies, errors and ms. The agent adds `expect` and `lost`, what the step took out of its field. `expect_p` and `expect_ms`, Jev's check of `expect`, are in runs before 09-24 only. |
| `trees/NN.json` | Every read of the window, raw: all items, not only those shown, with the window frame. `shot` is the screenshot's file, its frame in screen points (top left and size), its scale in pixels per point and its size in pixels. `seen` is every line of text read from it, and `seen_ms` the time; a step's `change.seen` and `change.still` are the lines it reported. |
| `shots/NN.jpg` | The screenshot of that read, cut to the window, JPEG at 0.7. Taken right after the walk, without ParrotFlow's own panels. Without Screen Recording there is none: `shot` is null and `shot_error` says why. |
| `looks/NN.json` | A `look`: the region and the lines read. |
| `grounds/NN.json` | A `ground` call or a request's picture: the method (`tinyclick`, `luna`, or `image`), the description, the region in points, the crop in the shot's pixels, the point or null, ms, and Luna's tokens. |
| `grounds/NN.jpg` | The JPEG the model got for it. |
| `review.json` | The review after the run: the digest, the report, the proposals shown and those dropped with why, whether it was shown, what was kept and how it ended (`answered`, `closed`, `timeout`, `superseded`). The review's model call is `calls/NN.json` with `kind: review`. |

The agent records everything. A recipe records the run, the trees and one
step per verb that touches the screen. The one-line trace in
`ParrotFlow-Dev-agent.jsonl` is still written.

**Private.** A recording holds what was on screen: names, messages, mail. It
stays in `~/Library/Logs`, never in the repository. The keys are replaced by
`[key]` before anything is written, the folder name too. The last 50 runs are
kept; older folders are deleted when a run starts. A recording that fails (a
full disk, a folder that cannot be made) is logged once and the run goes on.

**Cost.** Each read is also a screenshot, and a step reads the window one to
five times. The capture time is in each tree, `shot.ms`, and the reading
of its text in `seen_ms`. With recording on,
`press`, `click` and `click_at` also do one hit test before acting, for `under`.

## Seeing what it was offered

`spotlight: 1.5` in the `actions:` block outlines every offered target on the
window it came from, numbered `t0`, `t1`, …, with the last step's aim as a pink
dot — while the model is being asked, then again with its choice filled in
green, held for that many seconds before the step happens. Text fields are
teal: they are always in the list.

That list is the whole answer to "why did it pick that". A target missing from
the outlines could never have been chosen. The log prints three lines of
forty-odd, and `--look` prints twelve.

`0` is off, and off is the default. On, it costs those seconds per step.

A saved snapshot is a window frozen, and it is the only thing that makes this
measurable: the same file and the same utterance have to produce the same
decision after the next change.

**Run from a terminal, `--act` reads the screen with the terminal's
Accessibility grant, not ParrotFlow's** — TCC credits the responsible process.
A shell that has the grant works; one that does not reports nothing while the
app itself is fine. Same wrinkle as `--peek`, same way round it:
`open -na ParrotFlowDev --args --act "…"`, then read the log.

### The port's gate

This began as a prototype outside the repository: `axsnap` printed the window,
`jev_probe.py` asked the questions, `axdo` clicked. All three moved in here.
The gate for that port was: the snapshot the prototype measured on
2026-09-20, the same twelve utterances, the same answers.

Twelve of twelve, on the model's own choice:

| # | utterance | action | target |
| --- | --- | --- | --- |
| 1 | send a message to john | send_message | t25 Button "John Bledsoe", 7.5 cm |
| 2 | click on antonio | click | t40 Group "Antonio Ruiz, …", 12 cm |
| 3 | search for "media" | search | t2 composer — and the target is ignored, ⌘G |
| 4 | reply here: on it, thanks | send_message | t2 composer |
| 5 | open this one | click | t0, by the gaze — the model chose a label. With the gaze gone (09-25) the case expects no target |
| 6 | reply to this message: sounds good | send_message | t2 composer |
| 7 | envoie un message à John | send_message | t25 Button "John Bledsoe" |
| 8 | clique sur Antonio | click | t40 Group "Antonio Ruiz, …" |
| 9 | what time is it | none | — |
| 10 | open the thread with Ian | click | t4 Group "Ian Macomber: …", 2.6 cm |
| 11 | scroll down | scroll | none |
| 12 | go to jira | click | t8 Row "Jira", 4 cm |

610-770 ms per call, 3.1-3.5k input tokens.

One case is unstable and always was. "Open the thread with Ian" scored 0.61 for
his message against 0.39 for his button in the prototype's own run, and it
flips about one run in four. Both answers open something of Ian's. Three runs
in four are 12/12, and no run has ever chosen the wrong *action*.

**The snapshot is not in this repository and will not be.** It is 224 items of
somebody's Slack window: colleagues' names, and the first line of what they
wrote. Take your own with `--look --save` and write the answers down beside
it.

## What is known to be wrong

Measured, or seen once and not yet measured. None of it is fixed. Most of it
is about the decider and the Jev loop, from before the agent.

- **A sequence is one step at a time, and only the first step is decided.**
  "Send a message to Antonio and Peter" from an open DM has no right one-step
  answer: it picks one of the two and drops the other. From the new-message
  picker it is right in one click, because Slack offers the existing "Antonio
  Nava, Peter Holm" conversation as a single target, chosen at 0.91. So the
  two-recipient case mostly collapses rather than needing a sequence.
  `--act --done "<step>"` puts what has already happened into the state and it
  does move the answer on — Peter goes from 0.47 to 0.93 once Antonio is in
  `done` — but nothing in the app passes it, and it will not stop on its own.
- **Only Slack, Ghostty, ChatGPT and TextEdit have been tried.** The action
  list, the composer rule and the ⌘G mapping are all Slack-shaped.
- **A full-window text area** was dropped by the 12 % container rule until
  TextEdit showed it: a text field is now exempt, because it holds no targets
  — it is one.
- **"This one" names nothing.** With no gaze there is nothing to point at, so
  a deictic request with no name in it has no right target.
- **The words to type come from a regex** — quotes, or after
  "saying"/"that"/":". Clicking first and dictating afterwards needs no
  extraction at all, and already works.

## Where the pieces are

| Piece | File |
| --- | --- |
| The accessibility walk | `ScreenTargets.swift` |
| Reading text from the pixels, `--look-image` | `ScreenText.swift` |
| The question to Jev, and what the answers mean | `built-in/recipes/decider.py` |
| Asking Jev: Pydantic AI's TypeSafe model, the connection | `built-in/recipes/judge.py` |
| A step and its guards, what changed | `built-in/recipes/loop.py` |
| The agent: tools, batches, surprises | `built-in/recipes/agent.py` |
| Per-app notes, `apps/<app>.md` in the config folder | `built-in/recipes/decider.py` |
| Clicks, keys and the paste | `ScreenAction.swift` |
| `--act` | `ActCommand.swift` |
| The second hotkey | `HotKeyManager.swift`, `AppDelegate.act(on:for:)` |
| Recipes: loading, picking, running one | `built-in/recipes/runner.py` |
| The process, the steps, Escape, the send check | `RecipeRunner.swift`, `Recipes.swift` |
| What a recipe gets | `built-in/recipes/parrotflow.py` |
| The planner's client | `built-in/recipes/planner.py` |
| Recording a run, the run viewer | `built-in/recipes/runlog.py`, `scripts/trace-viewer/` |
| The review after a run, the proposals | `built-in/recipes/review.py`, `QuestionPanel.swift` |
