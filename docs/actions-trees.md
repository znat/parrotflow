# The agent's rules, as trees

Every rule the "act where you look" agent applies, as the code does it today. Diamonds are the questions, boxes are what happens. A dashed box is a rule in the prompt only; a thick box is what the user sees. Each node's italic id is in the [node index](#node-index) with its file and line.

## 0. A request arrives

The runner tries a recipe first. The agent runs when no recipe fits. `loop: plan` from an older config runs the agent too.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  R([Request arrives]) --> Q1{"Recipes for app?<br/><i>recipes-on</i>"}
  Q1 -->|yes| Q2{"Jev picks one?<br/><i>recipe-pick</i>"}
  Q1 -->|no| LP
  Q2 -->|yes| RC["Run the recipe<br/><i>recipe-run</i>"]
  Q2 -->|none| LP["Start the loop<br/><i>to-loop</i>"]
  LP --> Q3{"Planner set?<br/><i>agent-branch</i>"}
  Q3 -->|no| OT["Run fails: no planner<br/><i>no-planner</i>"]:::user
  Q3 -->|yes| Q4{"Planner key set?<br/><i>no-key</i>"}
  Q4 -->|no| F1["Run fails"]:::user
  Q4 -->|yes| AG["Watch, read, first prompt<br/><i>agent-start</i>"]
  AG --> S1["1 Reading the screen"]
  AG --> S2["2 Choosing the target"]
  AG --> S3["3 Acting"]
  AG --> S4["4 After a step"]
  AG --> S5["5 Between model calls"]
  AG --> S6["6 Ending"]
```

## 1. Reading the screen

The app walks the accessibility tree of the run's app. The agent turns the result into numbered lines, and adds text read from pixels and one picture.

### 1a. The walk (Swift)

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  W0["Front window of app<br/><i>walk-window</i>"] --> W1["8000 elements, 3 s<br/><i>walk-budget</i>"]
  W1 --> W2["Depth under 40<br/><i>walk-depth</i>"]
  W2 --> Q1{"List, table or outline?<br/><i>walk-rows</i>"}
  Q1 -->|yes| W3["Visible rows only"]
  Q1 -->|no| Q2{"Over 20 children?<br/><i>walk-wide</i>"}
  Q2 -->|yes| W4["First 20, near, last 7<br/><i>walk-more</i>"]
  Q2 -->|no| W5["All children"]
  W3 --> W6["Kind, name, value, states<br/><i>walk-item</i>"]
  W4 --> W6
  W5 --> W6
  W6 --> Q3{"Part opened since start?<br/><i>walk-opened</i>"}
  Q3 -->|yes| W7["Walk it, 3000, 1 s"]
  Q3 -->|no| W8
  W7 --> W8["Drop big and blank<br/><i>walk-drop</i>"]
  W8 --> W9["Sort in reading order<br/><i>walk-sort</i>"]
  W9 --> W10["Merge same name, 20 pt<br/><i>walk-dedup</i>"]
```

### 1b. The lines the model reads

A read's lines hold the tree only. Text read from pixels shows up in step results and `look` results, never here.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  R0["Read with pixels<br/><i>read-see</i>"] --> Q1{"More, or nameless?<br/><i>line-drop</i>"}
  Q1 -->|yes| X1["Not shown"]
  Q1 -->|no| L3["Top to bottom<br/><i>line-order</i>"]
  L3 --> L4["Keep first 250, and the focused one<br/><i>line-cap</i>"]
  L4 --> Q3{"Same kind and words?<br/><i>twin-line</i>"}
  Q3 -->|yes| L5["One line, ×N, topmost"]
  Q3 -->|no| L6
  L5 --> L6["IDs 1, 2, 3<br/><i>line-ids</i>"]
  L6 --> L7["Role 'name' = value (states)<br/><i>line-format</i>"]
  L7 --> L8["Only newest read whole<br/><i>cut-history</i>"]
  P1["IDs of newest read only<br/>(prompt) <i>p-ids</i>"]:::prompt
  L6 -.- P1
```

### 1c. Text read from pixels

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  Q0{"See on, permission?<br/><i>see-gate</i>"} -->|no| N0["No seen lines"]
  Q0 -->|yes| S0["OCR the window<br/><i>seen-into</i>"]
  S0 --> Q1{"Noise, or in tree?<br/><i>seen-noise</i>"}
  Q1 -->|yes| X1["Dropped"]
  Q1 -->|no| Q2{"Old control's text?<br/><i>seen-still</i>"}
  Q2 -->|yes| S1["Still on screen"]
  Q2 -->|no| Q3{"New window, or seen before?<br/><i>seen-old</i>"}
  Q3 -->|yes| X1
  Q3 -->|no| S2["Group into blocks<br/><i>seen-block</i>"]
  S1 --> S3["12 each, with IDs<br/><i>seen-ids</i>"]
  S2 --> S3
  P1["Seen lines: click only<br/>(prompt) <i>p-seen</i>"]:::prompt
  S3 -.- P1
```

### 1d. The picture

One picture per request, 512 px on the long side, `detail: low`. The one before is dropped. There is no aim on the first call; after each step it is the focus or the last target.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  Q0{"Read has a screenshot?<br/><i>pic-shot</i>"} -->|no| N0["No picture"]
  Q0 -->|yes| Q1{"A list opened?<br/><i>pic-list</i>"}
  Q1 -->|yes| C1["Around the list"]
  Q1 -->|no| Q2{"A last target?<br/><i>pic-target</i>"}
  Q2 -->|yes| C2["Around the target"]
  Q2 -->|no| Q3{"A focused item?<br/><i>pic-focus</i>"}
  Q3 -->|yes| C3["Around the focus"]
  Q3 -->|no| Q4{"An aim point?<br/><i>pic-aim</i>"}
  Q4 -->|yes| C4["Around the aim"]
  Q4 -->|no| N0
  C1 --> CR["Crop 600×400, JPEG<br/><i>pic-crop</i>"]
  C2 --> CR
  C3 --> CR
  C4 --> CR
  CR --> SD["On this request only<br/><i>pic-send</i>"]
  P1["Check picture for selection<br/>(prompt) <i>p-picture</i>"]:::prompt
  SD -.- P1
```

## 2. Choosing the target

A step names its target by ID. An ID is an element of the newest read, a line seen in pixels, or a point from `ground`.

### 2a. From step ID to element

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  A0([act step]) --> Q1{"ID given?"}
  Q1 -->|no, type/write| N1["Where the caret is<br/><i>null-caret</i>"]
  Q1 -->|no, scroll| N2["At the last aim, else the window's centre<br/><i>null-scroll</i>"]
  Q1 -->|no, click/pick| N3["Jev picks, empty words<br/><i>null-click</i>"]
  Q1 -->|yes| Q2{"On newest read?<br/><i>act-id-known</i>"}
  Q2 -->|no| X1["Nothing runs, hint ground"]
  Q2 -->|yes| Q3{"Seen, but not click?<br/><i>act-seen-verb</i>"}
  Q3 -->|yes| X2["Nothing runs"]
  Q3 -->|no| Q4{"Step 2 or later?"}
  Q4 -->|no| T1["Use the element"]
  Q4 -->|yes| Q5{"Seen line?<br/><i>later-seen</i>"}
  Q5 -->|yes| X3["Batch stops"]
  Q5 -->|no| Q6{"Same kind, role, name?<br/><i>refind</i>"}
  Q6 -->|none| X3
  Q6 -->|nearest| T1
```

### 2b. `ground`: a point from pixels

The tool and its prompt line exist only when `actions.ground` is on.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  G0{"Description given?<br/><i>ground-desc</i>"} -->|no| X1["Not run"]
  G0 -->|yes| Q1{"image_x, image_y?<br/><i>ground-image</i>"}
  Q1 -->|yes| Q2{"Picture shown, inside it?<br/><i>pic-inside</i>"}
  Q2 -->|no| X1
  Q2 -->|yes| PT
  Q1 -->|no| Q3{"id, box, or list?<br/><i>ground-area</i>"}
  Q3 -->|none| X1
  Q3 -->|yes| Q4{"Crop in window picture?<br/><i>ground-crop</i>"}
  Q4 -->|no| X2["Could not ground"]
  Q4 -->|yes| M1["TinyClick or Luna<br/><i>ground-model</i>"]
  M1 --> Q5{"Found?<br/><i>ground-miss</i>"}
  Q5 -->|no| X3["Not found, try another"]
  Q5 -->|yes| PT{"ID within 20 pt?<br/><i>same-point</i>"}
  PT -->|yes| X4["Same ID, already points"]
  PT -->|no| P2["New point ID<br/><i>new-point</i>"]
  P1["No ID: call ground<br/>(prompt) <i>p-ground</i>"]:::prompt
  G0 -.- P1
```

### 2c. `look`: text lines from pixels

```mermaid
flowchart LR
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  L0{"id, or a box?<br/><i>look-where</i>"} -->|neither| X1["Not run"]
  L0 -->|id| L1["Side of it, below default"]
  L0 -->|box| L2["That box"]
  L1 --> L3["OCR, 40 lines max<br/><i>look-ocr</i>"]
  L2 --> L3
  L3 --> L4["Seen IDs, next hundred<br/><i>look-ids</i>"]
  P1["Missing list: look<br/>(prompt) <i>p-look</i>"]:::prompt
  L0 -.- P1
```

## 3. Acting

Each step runs through `Loop._step`. The app posts the events and applies the last guards.

### 3a. click and pick

The open-list check runs only for a field or a control that opens a list. The cover check runs only for a target 60 pt high or less, while another control is expanded. A seen line's real click stops the run when another app is in front. A press has no front check.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  C0([click or pick]) --> Q1{"Other field's list open?<br/><i>close-list</i>"}
  Q1 -->|yes| C1["Press Return first"]
  Q1 -->|no| Q2
  C1 --> Q2{"Seen text over it?<br/><i>covered</i>"}
  Q2 -->|yes| X1["Step fails"]
  Q2 -->|no| Q3{"Seen line or point?<br/><i>seen-click</i>"}
  Q3 -->|yes| Q4{"Text on never_press?<br/><i>np-flat</i>"}
  Q4 -->|yes| X1
  Q4 -->|no| RC["Real click at centre"]
  Q3 -->|no| M1["Press or click?<br/><i>press-mode</i>"]
  M1 --> Q5{"Name on never_press?<br/><i>np-ask</i>"}
  Q5 -->|asked, no| X1
  Q5 -->|clear or yes| Q6{"AX press allowed?<br/><i>can-press</i>"}
  Q6 -->|no| RC
  Q6 -->|yes| Q7{"Press at point works?<br/><i>ax-press</i>"}
  Q7 -->|no| RC
  Q7 -->|yes| OK["Pressed, pointer still"]
  Q5 -.- U1["Yes / No question"]:::user
```

### 3b. type and write

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  T0([type or write]) --> Q1{"type: unsaid, unseen words?<br/><i>unsaid</i>"}
  Q1 -->|yes| U1["Ask Yes / No"]:::user
  U1 -->|no| X1["Step fails"]
  U1 -->|other words| X2["Redirected, batch stops"]
  U1 -->|yes| Q2
  Q1 -->|no| Q2{"ID given?<br/><i>null-caret</i>"}
  Q2 -->|no, the focused field| A1
  Q2 -->|yes| A1{"Field holds text, no at?<br/><i>needs-at</i>"}
  A1 -->|yes| X1
  A1 -->|no, ID given| Q3
  A1 -->|no, no ID| K1
  Q3{"Caret already in it?<br/><i>caret-in</i>"}
  Q3 -->|yes| K1
  Q3 -->|no| C1["Close list, cover, press<br/><i>field-press</i>"]
  C1 --> K1{"Value empty?<br/><i>nothing-to-type</i>"}
  K1 -->|yes| X1
  K1 -->|no| FR["Bring app to front<br/><i>front</i>"]
  FR --> Q4{"Run's app in front?<br/><i>front-check</i>"}
  Q4 -->|no| X3["Run stops"]:::user
  Q4 -->|yes| K2{"type?<br/><i>type-keys</i>"}
  K2 -->|yes| AT
  K2 -->|write| AT["at: ⌘↑, ⌘↓, or ⌘A with its guard<br/><i>place-at</i>"]
  AT -->|type| K3["Keystrokes"]
  AT -->|write| K4["Paste"]
  K3 --> CK{"Read back: text where at said,<br/>old text kept?<br/><i>typed-check</i>"}
  K4 --> CK
  CK -->|no| X1
  P1["Only words the user said<br/>(prompt) <i>p-said</i>"]:::prompt
  P2["Never select all; change words only when asked<br/>(prompt) <i>p-noselect</i>"]:::prompt
  T0 -.- P1
  T0 -.- P2
```

### 3c. key, scroll, and the app's guards

The Return rule applies only when `send` is off. A "no" to it ends the run, not only the step.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  K0([key]) --> Q1{"cmd+a?<br/><i>sel-all</i>"}
  Q1 -->|yes| Q2{"One-line field?<br/><i>one-line</i>"}
  Q2 -->|no| U1["Ask: Select all?"]:::user
  U1 -->|not yes| X1["Step fails"]
  Q1 -->|no| FR
  Q2 -->|yes| FR
  U1 -->|yes| FR["Bring app to front<br/><i>front</i>"]
  FR --> Q3{"Run's app in front?<br/><i>front-check</i>"}
  Q3 -->|no| X2["Run stops"]:::user
  Q3 -->|yes| Q4{"Return in message box?<br/><i>send-rule</i>"}
  Q4 -->|yes| U2["Ask: it may send"]:::user
  U2 -->|no| X2
  U2 -->|yes| KP
  Q4 -->|no| KP["Post key, wait 400 ms<br/><i>key-post</i>"]
  S0([scroll]) --> S1["6 turns at point<br/><i>scroll</i>"]
  P1["Ask before send or invite<br/>(prompt) <i>p-ask-send</i>"]:::prompt
  P2["Never archive, leave, pay<br/>(prompt) <i>p-never</i>"]:::prompt
  Q4 -.- P1
  K0 -.- P2
```

### 3d. caret and select

The model names words the field holds. Code finds them and the app moves the caret.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  E0([caret or select]) --> Q0{"at and value fit?<br/><i>edit-args</i>"}
  Q0 -->|no| X1["Step fails"]
  Q0 -->|yes| Q1{"Caret in the field, or placed there?<br/><i>caret-in</i>"}
  Q1 -->|no| C1["Press the field"]
  Q1 -->|yes| Q2
  C1 --> Q2{"caret at start or end?"}
  Q2 -->|yes| K1["⌘↑ or ⌘↓"]
  Q2 -->|no| R1["Read the whole text<br/><i>field_text</i>"]
  R1 --> Q3{"Words found once?<br/><i>find-words</i>"}
  Q3 -->|none or several| X1
  Q3 -->|once| Q4{"AXSelectedTextRange takes it,<br/>selection reads back?<br/><i>ax-select</i>"}
  Q4 -->|yes| OK["Selected, or caret before/after"]
  Q4 -->|no| K2["Keys: ⌘↑ →×n or ⌘↓ ←×n, then ⇧→<br/><i>key-select</i>"]
  K2 --> Q5{"Selection reads back?"}
  Q5 -->|no| X1
  Q5 -->|yes| OK
  P1["Use caret/select, never ground a caret<br/>(prompt) <i>p-caret</i>"]:::prompt
  E0 -.- P1
```

## 4. After a step

The runner reads the window again and compares. Then the agent decides whether the batch goes on.

### 4a. Reading what changed

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  A0["Wait 0.5 s, read<br/><i>settle</i>"] --> A1["Compare with before<br/><i>diff</i>"]
  A1 --> Q1{"type/write, no change?<br/><i>reread</i>"}
  Q1 -->|yes| A2["Up to 3 reads, 0.4 s"]
  Q1 -->|no| Q2
  A2 --> Q2{"click/pick, no change?<br/><i>fallback-click</i>"}
  Q2 -->|"yes, not row or seen"| A3["Real click, no pixel check"]
  A3 --> A4["Wait 0.5 s, read"]
  Q2 -->|no| Q3
  A4 --> Q3{"Anything changed?"}
  Q3 -->|no| A5["Not verified<br/><i>unchanged</i>"]
  Q3 -->|yes| A6["Change as a sentence"]
  A5 --> A7["Aim at focus or target<br/><i>aim-move</i>"]
  A6 --> A7
  P1["Check picture, do not repeat<br/>(prompt) <i>p-unverified</i>"]:::prompt
  A5 -.- P1
```

### 4b. Does the batch go on?

A "surprise" counts toward the forced question (see 5).

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  B0{"Steps and time left?<br/><i>limits-step</i>"} -->|no| ST["Batch stops"]
  B0 -->|yes| B1([run the step])
  B1 --> Q1{"User redirected it?<br/><i>redirect-stop</i>"}
  Q1 -->|yes| ST
  Q1 -->|no| Q2{"Step failed?<br/><i>fail-stop</i>"}
  Q2 -->|yes| SU["Surprise, batch stops"]
  Q2 -->|no| Q3{"Words gone from field?<br/><i>lost</i>"}
  Q3 -->|yes| SU
  Q3 -->|no| Q6{"Lookup list seen below?<br/><i>lookup-below</i>"}
  Q6 -->|yes| ST
  Q6 -->|no| Q7{"Unchanged, not type/write/key?<br/><i>unchanged-stop</i>"}
  Q7 -->|yes| ST
  Q7 -->|no| Q8{"New part, next elsewhere?<br/><i>opened-stop</i>"}
  Q8 -->|yes| ST
  Q8 -->|no| B0
  ST --> R["Steps, change, new read<br/><i>result</i>"]
  SU --> R
  P1["Opening step ends batch<br/>(prompt) <i>p-batch</i>"]:::prompt
  Q8 -.- P1
```

## 5. Between model calls

The runner watches for loops and for a model that will not ask.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  M0([screen tool call]) --> Q1{"Tool already ran this turn?<br/><i>one-tool</i>"}
  Q1 -->|yes| X1["Not run"]
  Q1 -->|no| Q2{"Ask ordered, same task?<br/><i>forced-ask</i>"}
  Q2 -->|"yes, not ask/read"| U1["Runner asks, Stop option"]:::user
  U1 -->|Stop| X3["Run stops"]:::user
  Q2 -->|no| M1["Run the tool"]
  M1 --> Q3{"Same batch, same result?<br/><i>repeat-batch</i>"}
  Q3 -->|yes| SU(["Any surprise"])
  SU --> Q4{"Task in progress?<br/><i>surprise-task</i>"}
  Q4 -->|no| X2["Not counted"]
  Q4 -->|yes| Q5{"Second on this task?<br/><i>surprise-two</i>"}
  Q5 -->|yes| A1["Tell model: ask now"]
  A1 --> Q2
  M2["ask resets the count<br/><i>ask-reset</i>"]
  M3["Plan appended, with IDs<br/><i>plan-reminder</i>"]
  P1["Never ask twice<br/>(prompt) <i>p-no-repeat</i>"]:::prompt
  P2["First call: write_plan<br/>(prompt) <i>p-plan-first</i>"]:::prompt
  M3 -.- P2
  M2 -.- P1
```

## 6. Ending

### 6a. Limits and Escape

The 240 s clock stops while a question waits for the user. `max_steps` is 30 by default.

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  E0([before each model call]) --> Q1{"A tool ended the run?<br/><i>over-flag</i>"}
  Q1 -->|yes| X0["Run ends"]:::user
  Q1 -->|no| Q2{"Steps at max_steps?<br/><i>max-steps</i>"}
  Q2 -->|yes| X0
  Q2 -->|no| Q3{"Over 240 s?<br/><i>max-seconds</i>"}
  Q3 -->|yes| X0
  Q3 -->|no| Q4{"50 calls made?<br/><i>max-calls</i>"}
  Q4 -->|yes| X0
  Q4 -->|no| C1["Call the model"]
  Q5{"Question unanswered?<br/><i>no-answer</i>"} -->|yes| X0
  Q6{"Escape pressed?<br/><i>escape-watch</i>"} -->|yes| E1["At next step request<br/><i>escape-check</i>"]
  E1 --> X0
  Q7{"Runner silent 120 s?<br/><i>silence</i>"} -->|yes| X1["Runner stopped"]:::user
  Q8{"Plan only?<br/><i>plan-only</i>"} -->|yes| X2["First action shown, ends"]:::user
```

### 6b. `done` and `stuck`

```mermaid
flowchart TD
  classDef prompt stroke-dasharray: 5 5
  classDef user stroke-width:3px
  D0([done]) --> Q1{"Plan task still open?<br/><i>done-open</i>"}
  Q1 -->|yes| D1["Refused, surprise<br/><i>done-refused</i>"]
  D1 --> BK["Back to the model"]
  Q1 -->|no| Q2{"Caret in empty box?<br/><i>ready-box</i>"}
  Q2 -->|yes| O1["Box is ready, dictate"]:::user
  Q2 -->|no| O2["Done"]:::user
  S0([stuck]) --> Q3{"Asked once already?<br/><i>stuck-once</i>"}
  Q3 -->|no| U1["Ask: what should I do?<br/><i>stuck-ask</i>"]:::user
  U1 -->|other words| BK
  U1 -->|"Stop, no answer"| O3["Stuck"]:::user
  Q3 -->|yes| O3
  P1["Ask, not stuck, when blocked<br/>(prompt) <i>p-ask-not-stuck</i>"]:::prompt
  P2["done refused while open<br/>(prompt) <i>p-done</i>"]:::prompt
  S0 -.- P1
  D0 -.- P2
```

## Node index

Python files are in `built-in/recipes/`. Swift files are in `Sources/ParrotFlow/`.

| node id | file:line |
|---|---|
| recipes-on | runner.py:429 |
| recipe-pick | runner.py:439 |
| recipe-run | runner.py:468 |
| to-loop | runner.py:400 |
| agent-branch | loop.py:575 |
| no-planner | loop.py:576 |
| no-key | agent.py:306 |
| agent-start | agent.py:290 |
| walk-window | ScreenTargets.swift:218 |
| walk-budget | ScreenTargets.swift:837 |
| walk-depth | ScreenTargets.swift:1033 |
| walk-rows | ScreenTargets.swift:979 |
| walk-wide | ScreenTargets.swift:989 |
| walk-more | ScreenTargets.swift:1000 |
| walk-item | ScreenTargets.swift:1057 |
| walk-opened | ScreenTargets.swift:236 |
| walk-drop | ScreenTargets.swift:878, 887 |
| walk-sort | ScreenTargets.swift:899 |
| walk-dedup | ScreenTargets.swift:905 |
| read-see | loop.py:970 |
| line-drop | agent.py:1027 |
| line-order | agent.py:1029 |
| line-cap | agent.py:1031 |
| twin-line | agent.py:1034 |
| line-ids | agent.py:1046 |
| line-format | planner.py:195 |
| cut-history | agent.py:1076 |
| p-ids | agent.py:101 |
| see-gate | RecipeRunner.swift:646 |
| seen-into | loop.py:974 |
| seen-noise | loop.py:390 |
| seen-still | loop.py:392 |
| seen-old | loop.py:400 |
| seen-block | loop.py:404 |
| seen-ids | agent.py:645 |
| p-seen | agent.py:104 |
| pic-shot | agent.py:944 |
| pic-list | agent.py:946 |
| pic-target | agent.py:948 |
| pic-focus | agent.py:949 |
| pic-aim | agent.py:953 |
| pic-crop | agent.py:959 |
| pic-send | agent.py:1113 |
| p-picture | agent.py:121 |
| null-caret | loop.py:1140 |
| null-scroll | loop.py:1138 |
| null-click | loop.py:1147 |
| act-id-known | agent.py:556 |
| act-seen-verb | agent.py:562 |
| later-seen | agent.py:578 |
| refind | agent.py:1014 |
| ground-desc | agent.py:833 |
| ground-image | agent.py:836 |
| pic-inside | agent.py:890 |
| ground-area | agent.py:859 |
| ground-crop | agent.py:843 |
| ground-model | agent.py:848 |
| ground-miss | agent.py:853 |
| same-point | agent.py:917 |
| new-point | agent.py:921 |
| p-ground | agent.py:122 |
| look-where | agent.py:734 |
| look-ocr | agent.py:761 |
| look-ids | agent.py:775 |
| p-look | agent.py:103 |
| close-list | loop.py:1227 |
| covered | loop.py:1257 |
| seen-click | loop.py:1166 |
| np-flat | RecipeRunner.swift:800 |
| press-mode | loop.py:1174 |
| np-ask | RecipeRunner.swift:886 |
| can-press | ScreenAction.swift:56 |
| ax-press | ScreenTargets.swift:303 |
| unsaid | loop.py:1105 |
| caret-in | loop.py:1056 |
| field-press | loop.py:1151 |
| nothing-to-type | loop.py:1179 |
| type-keys | loop.py:1185 |
| needs-at | loop.py `_where` |
| place-at | loop.py `_place` |
| typed-check | loop.py `_typed` |
| edit-args | loop.py `_edit_problem` |
| find-words | loop.py `find_words`, `_edit` |
| ax-select | TextCaret.swift `select` |
| key-select | TextCaret.swift `byKeys` |
| p-caret | agent.py `SYSTEM`, `GROUNDING` |
| p-said | agent.py:108 |
| p-noselect | agent.py:109 |
| sel-all | loop.py:1115 |
| one-line | loop.py:1117 |
| front | RecipeRunner.swift:716 |
| front-check | RecipeRunner.swift:466 |
| send-rule | RecipeRunner.swift:510 |
| key-post | RecipeRunner.swift:523 |
| scroll | ScreenAction.swift:204 |
| p-ask-send | agent.py:113 |
| p-never | agent.py:110 |
| settle | loop.py:1187 |
| diff | loop.py:166 |
| reread | loop.py:1192 |
| fallback-click | loop.py:1202 |
| unchanged | loop.py:1213 |
| aim-move | loop.py:1220 |
| p-unverified | agent.py:118 |
| limits-step | agent.py:573 |
| redirect-stop | agent.py:602 |
| fail-stop | agent.py:607 |
| lost | loop.py:527 |
| lookup-below | agent.py:594 |
| unchanged-stop | agent.py:765 |
| opened-stop | agent.py:636, 640 |
| result | agent.py:668 |
| p-batch | agent.py:106 |
| one-tool | agent.py:466 |
| forced-ask | agent.py:470 |
| repeat-batch | agent.py:536 |
| surprise-task | agent.py:710 |
| surprise-two | agent.py:715 |
| ask-reset | agent.py:995 |
| plan-reminder | agent.py:1198 |
| p-no-repeat | agent.py:115 |
| p-plan-first | agent.py:119 |
| over-flag | agent.py:361 |
| max-steps | agent.py:363 |
| max-seconds | agent.py:365 |
| max-calls | agent.py:351 |
| no-answer | agent.py:1001 |
| escape-watch | RecipeRunner.swift:13 |
| escape-check | RecipeRunner.swift:183 |
| silence | RecipeRunner.swift:147 |
| plan-only | agent.py:416 |
| done-open | agent.py:1152 |
| done-refused | agent.py:1154 |
| ready-box | agent.py:408 |
| stuck-once | agent.py:1158 |
| stuck-ask | agent.py:1163 |
| p-ask-not-stuck | agent.py:114 |
| p-done | agent.py:120 |
