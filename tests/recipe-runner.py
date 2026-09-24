"""The recipe runner against a fake app and a fake Jev. No screen, no network.

    python3 tests/recipe-runner.py

Starts built-in/recipes/runner.py as the app does, answers its steps from a
script, and checks the steps it asked for, the lines it said and how it ended.
"""

import http.server
import json
import os
import re
import subprocess
import sys
import tempfile
import threading

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RUNNER = os.path.join(ROOT, "built-in", "recipes", "runner.py")

RECIPES = {"write an email to Peter and Antonio": "message_people"}
NAMES = {"Peter", "Antonio"}
jev_calls = []
# The loop's answers, one per call: action, target, and the noul questions.
loop_answers = []
loop_bodies = []
# The planner path: Jev's answer to "is <expect> on screen", and the pick's p.
visible_answers = []
visible_bodies = []
pick_p = {"p": 0.97}
PLANNER_KEY = "sk-test-planner-key-1234"
planner_plans = []
planner_bodies = []
# The agent path: one turn per call, a list of (tool, arguments).
agent_turns = []
# `ground` through the planner's model: its answers, and what it was sent.
luna_points = []
luna_bodies = []
# The review after a run: the model's answers, and what it was sent.
review_turns = []
review_bodies = []
PLAN_TOOLS = {"write_plan", "read_plan", "add_task", "update_task_status", "update_task_statuses",
              "remove_task"}


def loop_answer(action, target="none", finished=0.0, has_text=0.0, deictic=0.0):
    return {"action": action, "target": target, "finished": finished, "has_text": has_text,
            "deictic": deictic}


def plain(body):
    """A TypeSafe-model request as the questions were written: the state as a
    dict, each question under its own name, its instructions the question.
    One question alone goes out as `response`."""
    questions = {}
    for key, question in body["questions"].items():
        instructions = question.get("instructions")
        if isinstance(instructions, dict):
            instructions = instructions["question"]
        if key == "response":
            key = ("visible" if question["type"] == "noul" else
                   "recipe" if instructions == "Which of these is the user asking for?" else "pick")
        questions[key] = dict(question, instructions=instructions)
    return {"state": json.loads(body["state"]), "model": body["model"], "questions": questions}


class FakeJev(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        sent = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.headers["Authorization"] == "Bearer test-key"
        body = plain(sent)
        questions = body["questions"]
        jev_calls.append(sorted(questions))
        answers = {}
        if "action" in questions:
            loop_bodies.append(body)
            want = loop_answers.pop(0)
            for key in ("action", "target"):
                offered = questions[key]["criteria"]
                if want[key] not in offered:
                    print(f"fake Jev: {want[key]!r} is not offered: {list(offered)}", file=sys.stderr)
                answers[key] = choice(want[key], {want[key]: 0.9})
            for key in ("has_text", "deictic", "finished"):
                answers[key] = {"type": "noul", "noul": float(want[key])}
            answers["word"] = choice("none", {"none": 0.9})
            questions = {}
        for key, question in questions.items():
            if key == "recipe":
                chosen = RECIPES.get(body["state"]["utterance"], "none")
            elif key == "pick":
                wanted = question["instructions"].split("“")[1].split("”")[0]
                matches = [k for k, v in question["criteria"].items()
                           if k != "none" and wanted in v]
                chosen = matches[0] if matches else "none"
                if len(matches) > 1:
                    answers[key] = choice(chosen, {k: pick_p["p"] for k in matches})
                    continue
            elif key == "visible":
                visible_bodies.append(body)
                answers[key] = {"type": "noul",
                                "noul": visible_answers.pop(0) if visible_answers else 0.9}
                continue
            else:
                word = body["state"]["words"][key]
                chosen = "who" if word in NAMES else "none"
            p = 1.0 if key == "recipe" else pick_p["p"] if key == "pick" else 0.97
            answers[key] = choice(chosen, {chosen: p})
        if "response" in sent["questions"]:
            answers = {"response": next(iter(answers.values()))}
        data = json.dumps({"answers": answers, "model": sent["model"],
                           "usage": {"input_tokens": 100, "output_tokens": 1}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


def choice(chosen, probabilities):
    return {"type": "choice", "choice": chosen, "confidence": 0.5,
            "probabilities": {k: float(v) for k, v in probabilities.items()}}


class FakePlanner(http.server.BaseHTTPRequestHandler):
    """Chat completions: the next plan in `planner_plans`, a list of steps.
    A string is sent back as a 401 body, a number as that status. Responses:
    the agent's next turn in `agent_turns`, as function calls."""

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        assert self.headers["Authorization"] == f"Bearer {PLANNER_KEY}"
        if ((body.get("response_format") or {}).get("json_schema") or {}).get("name") == "point":
            luna_bodies.append(body)
            content = json.dumps(luna_points.pop(0) if luna_points else
                                 {"found": False, "x": 0, "y": 0})
            data = json.dumps({"choices": [{"message": {"content": content}}],
                               "usage": {"prompt_tokens": 300, "completion_tokens": 12}}).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        reviewing = any(t.get("name") == "review" for t in body.get("tools") or ())
        if reviewing:
            review_bodies.append(body)
        else:
            planner_bodies.append(body)
        if self.path.endswith("/responses"):
            if reviewing:
                turn = [("review", review_turns.pop(0))]
            else:
                turn = agent_turns.pop(0) if agent_turns else [("stuck", {"why": "no turn left"})]
            k = len(planner_bodies)
            output = [{"type": "function_call", "id": f"fc_{k}_{n}", "call_id": f"call_{k}_{n}",
                       "name": name, "arguments": json.dumps(args), "status": "completed"}
                      for n, (name, args) in enumerate(turn)]
            data = json.dumps({"id": f"resp_{k}", "object": "response", "created_at": 1,
                               "model": body["model"], "status": "completed", "output": output,
                               "parallel_tool_calls": False, "tool_choice": "required",
                               "tools": [],
                               "usage": {"input_tokens": 100, "output_tokens": 20,
                                         "total_tokens": 120,
                                         "input_tokens_details": {"cached_tokens": 0},
                                         "output_tokens_details": {"reasoning_tokens": 0}}}
                              ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        plan = planner_plans.pop(0) if planner_plans else []
        status = 200
        if isinstance(plan, str):
            status, data = 401, plan.encode()
        elif isinstance(plan, int):
            status, data = plan, f"fake {plan} for {PLANNER_KEY}".encode()
        else:
            steps = [dict({"target": "", "value": "", "expect": ""}, **step) for step in plan]
            content = json.dumps({"steps": steps, "unsure": ""})
            data = json.dumps({"choices": [{"message": {"content": content}}],
                               "usage": {"prompt_tokens": 100}}).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args):
        pass


class Outlook:
    """Replies to steps the way the app does on a new Outlook draft."""

    def __init__(self, override=None):
        self.override = override or {}
        self.steps = []
        self.lines = []
        self.marks = 0

    def reply(self, step):
        do = step["do"]
        self.steps.append(step)
        count = sum(1 for s in self.steps if s["do"] == do)
        if (do, count) in self.override:
            return self.override[(do, count)]
        if do == "say":
            self.lines.append(step["text"])
        if do == "lookup_field":
            return {"item": {"id": 1, "role": "AXTextField", "name": "To", "value": "",
                             "kind": "text", "x": 400, "y": 200, "w": 300, "h": 20}}
        if do == "mark":
            self.marks += 1
            return {"mark": self.marks}
        if do == "rows":
            return {"waited": 750, "items": [
                {"id": 10, "role": "AXButton", "name": "Pete Other", "value": "",
                 "kind": "click", "x": 400, "y": 230, "w": 300, "h": 20},
                {"id": 11, "role": "AXButton", "name": "Peter Smith", "value": "",
                 "kind": "click", "x": 400, "y": 250, "w": 300, "h": 20},
                {"id": 12, "role": "AXButton", "name": "Antonio Ruiz", "value": "",
                 "kind": "click", "x": 400, "y": 270, "w": 300, "h": 20}]}
        if do == "snapshot":
            return {"snapshot": {"id": 30, "app": "Microsoft Outlook", "window": "Draft",
                                 "frame": {"x": 0, "y": 0, "w": 1000, "h": 800},
                                 "pointer": {"x": 0, "y": 0}, "pxPerCm": 47, "items": [
                {"id": 31, "role": "AXButton", "name": "Peter Smith", "value": "", "kind": "click",
                 "x": 300, "y": 205, "w": 80, "h": 20, "cm": 0, "actions": [], "lookup": False,
                 "in_list": False, "clickable": True, "refused": None},
                {"id": 32, "role": "AXButton", "name": "Antonio Ruiz", "value": "", "kind": "click",
                 "x": 390, "y": 205, "w": 80, "h": 20, "cm": 0, "actions": [], "lookup": False,
                 "in_list": False, "clickable": True, "refused": None}]}}
        if do == "find":
            return {"items": [{"id": 20, "role": "AXTextField", "name": "Subject", "value": "",
                               "kind": "text", "x": 400, "y": 300, "w": 300, "h": 20}]}
        return {"ok": True}


class Runner:
    def __init__(self, jev_url, user_dir, extra=None, stderr=subprocess.DEVNULL):
        env = dict(os.environ, PARROTFLOW_JEV_KEY="test-key", PARROTFLOW_JEV_URL=jev_url,
                   PARROTFLOW_JEV_KEY_SOURCE="test", PARROTFLOW_RECIPES_USER=user_dir,
                   PYTHONIOENCODING="utf-8", **(extra or {}))
        self.process = subprocess.Popen(
            [sys.executable, "-u", RUNNER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=stderr, env=env, text=True, encoding="utf-8")
        assert "up" in self.read()

    def read(self):
        line = self.process.stdout.readline()
        assert line, "the runner closed its output"
        return json.loads(line)

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def run(self, utterance, app, fake=None, execute=True, bundle=None, **extra):
        """The run's end message and the fake. The run panel's states are in
        `self.progress`, and where each came among the steps in `self.order`."""
        fake = fake or Outlook()
        self.progress, self.order = [], []
        if bundle is None:
            bundle = {"Microsoft Outlook": "com.microsoft.Outlook"}.get(app, "")
        self.send(dict({"run": utterance, "app": app, "bundle": bundle, "gaze": None, "letters": 2,
                        "screen": {"w": 1512, "h": 982}, "execute": execute}, **extra))
        while True:
            message = self.read()
            if "end" in message:
                return message, fake
            if message.get("do") == "progress":
                self.progress.append(message)
                self.order.append(message)
                self.send({"ok": True})
                continue
            self.order.append(message)
            self.send(fake.reply(message))


def window(n, refused=None):
    """An invented window. Its row is named after `n`, so two windows with
    different numbers differ by one item."""
    def item(name, kind, role, x, y):
        return {"role": role, "name": name, "value": "", "kind": kind, "x": x, "y": y,
                "w": 80, "h": 20, "cm": 1.0, "actions": ["AXPress"], "lookup": False,
                "in_list": False, "clickable": kind in ("click", "text"),
                "refused": refused if name == "Checkout" else None}
    return {"app": "Test", "window": "Shop", "pointer": {"x": 500, "y": 300}, "pxPerCm": 47,
            "frame": {"x": 0, "y": 0, "w": 1000, "h": 800},
            "items": [item("Checkout", "click", "AXButton", 500, 300),
                      item(f"Row {n}", "click", "AXRow", 600, 400),
                      item("12:04", "label", "AXStaticText", 610, 410),
                      item("Message to Ann", "text", "AXTextArea", 500, 750)]}


READS = {"snapshot"}
GESTURES = {"press", "click", "click_at", "right_click", "hover", "drag", "ready", "key", "type",
            "paste", "scroll", "select", "show_menu"}


class Screen:
    """Replies to the loop's steps. `windows` come in turn, one per gesture
    (one per read with `per_read`); the last one stays on screen."""

    def __init__(self, windows, override=None, per_read=False):
        self.windows = list(windows)
        self.override = override or {}
        self.per_read = per_read
        self.steps = []
        self.lines = []
        self.logs = []
        self.reads = 0
        self.by_id = {}
        self.next = 100
        self.moved = False

    def reply(self, step):
        do = step["do"]
        self.steps.append(step)
        count = sum(1 for s in self.steps if s["do"] == do)
        if (do, count) in self.override:
            return self.override[(do, count)]
        if do == "say":
            self.lines.append(step["text"])
        if do == "log":
            self.logs.append(step["text"])
        if do in GESTURES:
            self.moved = True
        if do in READS:
            # The window moves on after a gesture, not because it was read
            # again: `settle` reads until something changed.
            if self.moved or self.per_read or not self.reads:
                self.reads += 1
                self.moved = False
            shown = json.loads(json.dumps(self.windows[min(self.reads - 1, len(self.windows) - 1)]))
            # The app reads the text from the pixels when asked and allowed.
            seen = shown.pop("seen", None)
            shown["id"] = self.next
            for item in shown["items"]:
                self.next += 1
                item["id"] = self.next
                self.by_id[self.next] = item
            self.next += 1
            reply = {"snapshot": shown}
            if seen is not None and step.get("see"):
                reply.update(seen=seen, seen_ms=40)
            return reply
        if do == "press":
            # The app's never_press asks, and a fake has nobody to say yes.
            if (self.by_id.get(step["id"]) or {}).get("refused"):
                return {"error": "refused", "said": True, "text": "Won't press"}
            return {"ok": True, "pressed": not step["click"]}
        if do == "focus":
            return {"point": None, "described": "", "role": None}
        if do == "ready_for_words":
            return {"box": None}
        if do == "ask":
            return {"answer": None, "via": "timeout"}
        if do == "look":
            return {"lines": []}
        if do == "steer":
            return {"messages": []}
        return {"ok": True}

    def did(self):
        return [s["do"] for s in self.steps
                if s["do"] not in ("say", "log", "watch", "wait", "steer")]


LOOP = {"max_steps": 15, "send": False, "spotlight": 0, "lookup_letters": 2}
UNCHANGED = ("nothing in the accessibility tree changed — not verified: it may still have "
             "worked (a part of a field selected, a field already focused); check the picture")


def loop_checks(runner):
    def run(utterance, windows, answers, override=None, execute=True, **loop):
        loop_answers[:] = answers
        del loop_bodies[:]
        fake = Screen(windows, override, per_read=True)
        end, fake = runner.run(utterance, "Test", fake=fake, execute=execute,
                               loop=dict(LOOP, **loop), recipes=False)
        return end, fake, end.get("loop") or {}

    end, fake, report = run("click on Checkout", [window(1), window(2)],
                            [loop_answer("click", "t0"), loop_answer("none", finished=0.9)])
    check("loop: finished over 0.5 ends it, done",
          end["end"] == "done" and report["stopped"] == "Done" and report["acted"]
          and report["said"] == "Picked Checkout", (end, fake.did()))
    check("loop: the second question carries done and finished",
          loop_bodies[1]["state"]["done"] == ['picked "Checkout" from the list; that is one recipient in']
          and "finished" in loop_bodies[1]["questions"] and "finished" not in loop_bodies[0]["questions"],
          [sorted(b["questions"]) for b in loop_bodies])
    check("loop: an ignored press never touches the screen twice",
          [s["click"] for s in fake.steps if s["do"] == "press"] == [False], fake.did())

    end, fake, report = run("what time is it", [window(1)], [loop_answer("none")])
    check("loop: action none on the first step does nothing",
          end["end"] == "done" and report["stopped"] == "Nothing to do on screen"
          and not report["acted"] and fake.did() == ["snapshot"], (report, fake.did()))

    end, fake, report = run("click on Checkout", [window(1), window(2), window(3)],
                            [loop_answer("click", "t0")] * 3)
    check("loop: the same step three times stops it, pressed once",
          report["stopped"] == "Asked for the same step three times — stopping"
          and fake.did().count("press") == 1 and end["end"] == "stopped", (report, fake.did()))

    end, fake, report = run("scroll down", [window(1)] * 3,
                            [loop_answer("scroll"), loop_answer("show_menu", "t0")])
    check("loop: nothing changed twice stops it",
          report["stopped"] == "Nothing changed twice over — stopping"
          and [d for d in fake.did() if d not in ("ready_for_words", "focus")]
          == ["snapshot", "scroll", "snapshot", "front", "show_menu", "snapshot"],
          (report, fake.did()))
    check("loop: a step that changed nothing is said to the model",
          loop_bodies[1]["state"].get("changed") == UNCHANGED, loop_bodies[1]["state"].get("changed"))

    end, fake, report = run("open a new message and scroll", [window(1), window(2)],
                            [loop_answer("new_message"), loop_answer("scroll")], max_steps=2)
    check("loop: max_steps stops it",
          report["stopped"] == "Stopped after 2 steps" and len(report["steps"]) == 2, report)
    check("loop: a shortcut taken is not offered again",
          "new_message" in loop_bodies[0]["questions"]["action"]["criteria"]
          and "new_message" not in loop_bodies[1]["questions"]["action"]["criteria"],
          [list(b["questions"]["action"]["criteria"]) for b in loop_bodies])
    check("loop: scrolling is offered only while another step can follow",
          "scrolling brings more" in loop_bodies[0]["state"]["note"]
          and "scrolling brings more" not in loop_bodies[1]["state"]["note"])
    check("loop: new_message brings the app forward, then ⌘N",
          [s for s in fake.steps if s["do"] == "key"] == [{"do": "key", "keys": "cmd+n"}]
          and fake.did()[:3] == ["snapshot", "front", "key"], fake.did())

    escape = {("snapshot", 2): {"error": "escape", "said": True}}
    end, fake, report = run("scroll down", [window(1), window(2)], [loop_answer("scroll")], escape)
    check("loop: Escape mid-loop stops it before the next step",
          end["end"] == "stopped" and report["stopped"] == "Stopped — you pressed escape"
          and fake.steps[-1]["do"] == "snapshot" and report["steps"] == ["scrolled down where you were looking"],
          (report, fake.steps[-3:]))

    end, fake, report = run("click on Checkout", [window(1), window(1), window(2)],
                            [loop_answer("click", "t0"), loop_answer("click", "t0"), loop_answer("none")])
    check("loop: a press that changed nothing is clicked for real next",
          [s["click"] for s in fake.steps if s["do"] == "press"] == [False, True]
          and "action loop: the press did nothing; using the pointer next" in fake.logs,
          ([s for s in fake.steps if s["do"] == "press"], report))

    refused = {("key", 1): {"error": "send is off", "said": True,
                            "text": "Won't press Return in the message box — send is off"}}
    end, fake, report = run("reply here: on it", [window(1)],
                            [loop_answer("send_message", "t2", has_text=0.9)], refused, send=True)
    check("loop: Return refused in a message box ends it, said",
          end["end"] == "stopped"
          and report["stopped"] == "Won't press Return in the message box — send is off"
          and fake.did()[-2:] == ["paste", "key"] and fake.steps[-1]["do"] != "key"
          and [s["text"] for s in fake.steps if s["do"] == "paste"] == ["on it"],
          (report, fake.did()))
    end, fake, report = run("reply here: on it", [window(1), window(2)],
                            [loop_answer("send_message", "t2", has_text=0.9), loop_answer("none")])
    check("loop: with send off it never asks for Return",
          "key" not in fake.did() and report["said"] == "Typed “on it” into Message to Ann",
          (report, fake.did()))

    end, fake, report = run("click on Checkout", [window(1, refused="send")],
                            [loop_answer("click", "t0")])
    check("loop: a target on never_press is not pressed",
          "press" not in fake.did() and report["stopped"] == 'Won\'t press "Checkout" — that is yours to do',
          (report, fake.did()))

    end, fake, report = run("click on Checkout", [window(1)], [loop_answer("click", "t0")],
                            execute=False)
    check("loop: plan only reads and decides, and does nothing",
          end == {"end": "planned", "ok": True, "loop": report} and fake.did() == ["snapshot"]
          and fake.lines[-1] == "(planned only)" and fake.lines[0].startswith("loop       step 1 · click 0.90"),
          (end, fake.did(), fake.lines))

    snapshot = dict(window(1), id=0)
    runner.send({"decide": "click on Checkout", "snapshot": snapshot, "mode": "request"})
    answer = runner.read()
    body = plain(json.loads(answer.get("body", "{}")))
    check("decide: the request for a handed-over window",
          answer["end"] == "decided" and list(body["state"]["targets"]) == ["t0", "t1", "t2"]
          and [o["index"] for o in answer["offers"]] == [0, 1, 3], answer)
    loop_answers[:] = [loop_answer("click", "t0")]
    runner.send({"decide": "click on Checkout", "snapshot": snapshot, "mode": "decide"})
    answer = runner.read()
    check("decide: one decision, no step asked for",
          answer["end"] == "decided" and answer["decision"]["line"].startswith("click 0.90 · target t0 0.90")
          and answer["decision"]["target"]["x"] == 500, answer)


def panel(title, names, refused=None):
    """A window of buttons, nearest first."""
    items = []
    for i, name in enumerate(names):
        kind, role = ("text", "AXTextArea") if name.startswith("Message") else ("click", "AXButton")
        items.append({"role": role, "name": name, "value": "", "kind": kind, "x": 500,
                      "y": 100 + 30 * i, "w": 80, "h": 20, "cm": 0.1 * i,
                      "actions": ["AXPress"], "lookup": False, "in_list": False,
                      "clickable": True, "refused": refused if name == "Leave" else None})
    return {"app": "Test", "window": title, "pointer": {"x": 500, "y": 100}, "pxPerCm": 47,
            "frame": {"x": 0, "y": 0, "w": 1000, "h": 800}, "items": items}


def draft(to="", popup=False, filler=0, more=None):
    """An invented compose window: a To field, a body, `filler` buttons, and
    with `popup` a suggestion list outside the window, as Outlook draws it."""
    def item(name, kind, role, x, y, value="", origin=None, cm=1.0):
        return {"role": role, "name": name, "value": value, "kind": kind, "x": x, "y": y,
                "w": 200, "h": 20, "cm": cm, "actions": [], "lookup": name == "To",
                "in_list": origin is not None, "clickable": kind in ("click", "text"),
                "refused": None, "in": origin}
    items = [item("To", "text", "AXTextField", 400, 100, to, cm=0.0),
             item("", "text", "AXTextArea", 700, 500)]
    items += [item(f"Tool {n}", "click", "AXButton", 800, 40 + n, cm=1.0 + n / 10)
              for n in range(filler)]
    if more is not None:
        items.append(dict(item(f"and {more:,} more", "more", "AXGroup", 400, 300), clickable=False))
    if popup:
        items += [item("Peter Holm", "click", "AXCell", 400, 130, origin="pop-up", cm=20.0),
                  item("Peter Smith", "click", "AXCell", 400, 150, origin="pop-up", cm=20.1),
                  item("peter@example.com", "label", "AXStaticText", 400, 131, origin="pop-up", cm=20.0)]
    return {"app": "Test", "window": "Untitled", "pointer": {"x": 400, "y": 100}, "pxPerCm": 47,
            "frame": {"x": 0, "y": 0, "w": 1000, "h": 800}, "items": items}


def change_checks():
    """`loop.changes`, read directly: no runner, no screen."""
    sys.path.insert(0, os.path.join(ROOT, "built-in", "recipes"))
    import decider
    import loop

    import planner
    check("line: an unnamed field shows its state, as a named one does",
          planner._line({"role": "AXTextArea", "name": "", "kind": "text", "value": "",
                         "state": ["focused"]}) == "TextArea (no name) (focused)")
    with tempfile.TemporaryDirectory() as config:
        for path, text in (("memories/test-app/one.md", "Click New first."),
                           ("memories/com.test.app/two.md", "Type the day first."),
                           ("memories/people/alex.md", "Alex is Alex Moreau."),
                           ("memories/people/sam.md", "Sam is Sam Lee.")):
            os.makedirs(os.path.dirname(os.path.join(config, path)), exist_ok=True)
            with open(os.path.join(config, path), "w") as handle:
                handle.write(text)
        was = os.environ.get("PARROTFLOW_APP_NOTES")
        os.environ["PARROTFLOW_APP_NOTES"] = os.path.join(config, "apps")
        try:
            import agent
            got = agent.memories("Test App", "write to Alex", lambda line: None)
            by_bundle = agent.memories("com.test.app", "nothing", lambda line: None)
        finally:
            if was is None:
                del os.environ["PARROTFLOW_APP_NOTES"]
            else:
                os.environ["PARROTFLOW_APP_NOTES"] = was
    import skills
    with tempfile.TemporaryDirectory() as folder:
        os.makedirs(os.path.join(folder, "com.test.app"))
        with open(os.path.join(folder, "com.test.app", "set-time.md"), "w") as handle:
            handle.write('---\ngoal: set the time\nparams: [hour, minute]\nsteps:\n'
                         '  - click DateTimeArea "Start time" at left | focus "Start time"\n'
                         '  - type {hour} | value "Start time" ~ "*, {hour}:*"\n'
                         '  - key right\n---\nProse.\n')
        with open(os.path.join(folder, "com.test.app", "notes.md"), "w") as handle:
            handle.write("---\ngoal: no steps\n---\nProse only.\n")
        found = skills.of_app(folder, "com.test.app")
    check("skills: a memory with steps is a skill, one without is not",
          list(found) == ["set-time"] and found["set-time"].params == ["hour", "minute"]
          and found["set-time"].steps[2] == ("key right", ""), {k: v.steps for k, v in found.items()})
    check("skills: a skill sets the controls its clicks name, and says so",
          found["set-time"].covers == {("DateTimeArea", "Start time")}
          and 'Sets "Start time"; never set it with `act`.' in found["set-time"].line()
          and skills.covering(found, {"role": "AXDateTimeArea", "name": "Start time"})
          is found["set-time"]
          and skills.covering(found, {"role": "AXPopUpButton", "name": "Start time"}) is None)
    field = {"name": "Start time", "role": "AXDateTimeArea", "value": "25/09/2026, 11:30",
             "state": ["focused"], "x": 1, "y": 1, "in": None}
    button = {"name": "Start time", "role": "AXPopUpButton", "value": "", "state": [],
              "x": 2, "y": 1, "in": None}
    shown = {"window": "New Event", "items": [button, field]}
    check("skills: checks read values, focus and the window from the tree",
          skills.check('value "Start time" ~ "*, 11:*"', shown)[0]
          and not skills.check('value "Start time" ~ "*, 16:*"', shown)[0]
          and skills.check('focus "Start time"', shown)[0]
          and skills.check('window ~ "New*"', shown)[0]
          and skills.check('value "Start time" ~ "*, 16:*"', shown)[1]
          == "'Start time' = '25/09/2026, 11:30'")
    behind = {"y": 517, "x": 1451, "in": "window", "state": []}
    front = {"y": 546, "x": 1480, "in": None, "state": ["focused"]}
    check("twins: the focused one wins over the one first in reading order",
          min([behind, front], key=agent.twin_rank) is front)
    check("twins: the focused window's wins over another window's",
          min([dict(behind), dict(front, state=[])], key=agent.twin_rank)["in"] is None)
    check("memories: the app's files, and a person's only when the request names them",
          got == "Click New first.\n\nAlex is Alex Moreau.", got)
    check("memories: a bundle ID names its own folder", by_bundle == "Type the day first.", by_bundle)
    check("loop: max_steps is 30 when the app does not say",
          loop.Loop({"run": ""}, object(), None).max_steps == 30)
    change = loop.changes(draft("Pe"), draft("Pe", popup=True))
    check("change: a pop-up's rows are named, with the field they hang from",
          change == {"appeared": [{"kind": "pop-up", "rows": ["Peter Holm", "Peter Smith"],
                                   "near": "To"}]}
          and loop.difference(draft("Pe"), draft("Pe", popup=True))
          == 'a pop-up opened near "To": "Peter Holm", "Peter Smith"', change)
    change = loop.changes(draft(""), draft("Peter"))
    check("change: typing into a field is a change, not nothing",
          change == {"values": {"To": "Peter"}}
          and loop.difference(draft(""), draft("Peter")) == '"To" now holds "Peter"', change)
    check("change: a field emptied is said so",
          loop.difference(draft("Peter"), draft("")) == '"To" is now empty')
    import copy
    focused = copy.deepcopy(draft("Peter"))
    focused["items"][0]["state"] = ["focused"]
    check("change: focus moving into a field is said",
          loop.difference(draft("Peter"), focused) == 'the caret is now in "To"',
          loop.difference(draft("Peter"), focused))
    renamed = copy.deepcopy(draft())
    renamed["items"][0]["name"] = "Look for people"
    change = loop.changes(draft(), renamed)
    check("change: a field renamed in place is one rename, not new and gone",
          change == {"renamed": {"To": "Look for people"}}, change)
    tabbed = copy.deepcopy(draft(filler=1))
    tabbed["items"][2]["state"] = ["selected"]
    check("change: an item becoming selected is said",
          loop.difference(draft(filler=1), tabbed) == '"Tool 0" is now selected',
          loop.difference(draft(filler=1), tabbed))
    check("change: a wide element's count moving is not a change",
          loop.difference(draft(more=3140), draft(more=3141)) == "")
    slack = "\u00a0 Alex Moreau \u00a0 \u00a0"
    check("lost: a field that held Alex Moreau and now holds Antonio lost him",
          loop.lost(draft(slack)["items"][0], draft(slack), draft("\u00a0 Antonio \u00a0"))
          == ["Alex Moreau"])
    check("lost: appending a name loses nothing, nor does a placeholder or a time replaced",
          loop.lost(draft("Alex")["items"][0], draft("Alex"), draft("Alex, Antonio")) == []
          and loop.lost(draft("To")["items"][0], draft("To"), draft("Peter")) == []
          and loop.lost(draft("17:00")["items"][0], draft("17:00"), draft("18:00")) == [])
    chip = draft("")
    chip["items"].append(dict(chip["items"][0], name="Peter Smith", kind="click",
                              role="AXButton", w=60))
    check("lost: a chip drawn inside the field that is gone after the step is lost",
          loop.lost(chip["items"][0], chip, draft("Antonio")) == ["Peter Smith"]
          and loop.lost(chip["items"][0], chip, chip) == [])
    wide = draft(more=3140)
    offered = decider.candidates(wide, "write to Peter")
    lines = []

    class Jev:
        def ask(self, state, questions):
            lines.extend(state["on_screen"])
            return {}
    decider.visible(Jev(), "a list", wide)
    check("change: the summary line is read, never offered",
          "and 3,140 more" in [i["name"] for i in wide["items"]]
          and all(i["kind"] != "more" for i in offered)
          and "Group “and 3,140 more”" in lines, (offered, lines))
    far = draft(popup=True, filler=45)
    offered = decider.candidates(far, "write to Tool")
    check("change: a pop-up's rows are offered however far they are",
          [i["name"] for i in offered if i.get("in")] == ["Peter Holm", "Peter Smith"]
          and len(offered) > decider.OFFERED, len(offered))
    check("change: a pop-up's row says where it is",
          decider.describe(offered[-1], far).endswith("in the pop-up that opened during this request"),
          decider.describe(offered[-1], far))

    def line(text, x, y, w=120, h=14):
        return {"text": text, "x": x, "y": y, "w": w, "h": h, "p": 0.5}
    before = dict(draft("Pe"), seen=[line("To", 310, 100, 20), line("Subject", 330, 300, 50)])
    after = dict(draft("Pe"), seen=[
        line("To", 310, 100, 20), line("pe", 400, 100, 20), line("Subject", 334, 305, 50),
        line("Peter Quill", 330, 130), line("PQ", 280, 138, 16), line("peter.quill@example.com", 340, 146),
        line("Peter Parker", 330, 180), line("•", 200, 200, 8)])
    change = loop.changes(before, after)
    check("seen: lines the tree holds, noise, and lines seen there before are dropped",
          [[l["text"] for l in b["lines"]] for b in change.get("seen", ())]
          == [["Peter Quill", "peter.quill@example.com", "Peter Parker"]], change)
    check("seen: new lines stacked below a field are one block, near that field",
          len(change.get("seen", ())) == 1 and change["seen"][0].get("near") == "To"
          and 'text appeared near "To" (seen, not in the tree): "Peter Quill", '
          '"peter.quill@example.com", "Peter Parker"' in loop.sentence(change),
          loop.sentence(change))
    check("seen: a tree name inside a longer line does not hide it, a cut label does",
          loop.same_text("Invite required", "Invite required attendees")
          and loop.same_text("Q Search (% E)", "Search (⌘ E)")
          and not loop.same_text("Peter Quill", "Peter")
          and loop.alike("23109126", "23/09/26") and not loop.alike("18:30", "17:30"))
    check("seen: no seen lines, no seen change",
          "seen" not in loop.changes(draft("Pe"), draft("Pe", popup=True))
          and loop.changes(before, dict(draft("Pe"), seen=[])) == {})
    import copy
    formed = copy.deepcopy(draft("Pe", filler=1))
    formed["seen"] = [line("Tool 0", 800, 41, 50)]
    hidden = dict(draft("Pe"), seen=[line("Tool 0", 801, 42, 50), line("Peter Quill", 330, 130)])
    change = loop.changes(formed, hidden)
    check("seen: a control that left the tree and is still on screen is its own group",
          [(l["role"], l["name"]) for l in change.get("still", ())] == [("Button", "Tool 0")]
          and [l["text"] for b in change["seen"] for l in b["lines"]] == ["Peter Quill"]
          and 'still on screen, no longer in the tree (a panel may be hiding them): Button "Tool 0"'
          in loop.sentence(change), change)
    end = {"role": "AXComboBox", "name": "End time", "value": "17:30", "kind": "text",
           "x": 400, "y": 200, "w": 90, "h": 32}
    over = dict(draft("Pe"), items=draft("Pe")["items"] + [end],
                seen=[line("17:30", 390, 200, 40), line("18:30", 392, 204, 40)])
    check("seen: a line over a target that is not its own text covers it",
          [l["text"] for l in loop.covering(end, over)] == ["18:30"]
          and loop.covering(end, dict(over, seen=[line("17:30", 390, 200, 40)])) == [])
    lp = loop.Loop({"run": ""}, object(), None)
    lp.change = {"seen": [{"near": "To", "lines": [line("Peter Quill", 330, 130)]}]}
    typed = {"do": "type", "target": "To", "value": "Pe", "expect": ""}
    check("seen: on the plan path, text that appeared and the next step skips is a surprise",
          (lp._surprise(typed, {"do": "click", "target": "Date", "value": "", "expect": ""}) or "")
          .startswith('text appeared near “To” (seen, not in the tree): “Peter Quill”, and the next')
          and lp._surprise(typed, {"do": "click", "target": "Peter Quill", "value": "", "expect": ""})
          is None)


def settle_checks():
    """`Loop.settle` against a window whose To field fills `at` seconds in."""
    import time
    import loop

    class Channel:
        def __init__(self, at):
            self.began, self.at, self.reads = time.monotonic(), at, 0

        def ask(self, do, **args):
            self.reads += 1
            filled = self.at is not None and time.monotonic() - self.began >= self.at
            return {"snapshot": draft("Pe" if filled else "")}

    def settled(at, policy, until=None):
        channel = Channel(at)
        now = loop.Loop({"run": ""}, channel, None).settle(draft(""), [0, 0], policy, until)
        return now["items"][0]["value"], channel.reads, time.monotonic() - channel.began

    value, reads, took = settled(0.1, "after_press")
    check("settle: a window that changed is taken at the first read after it",
          value == "Pe" and reads == 1 and took < 0.3, (value, reads, took))
    value, reads, took = settled(None, "after_press")
    check("settle: a window that never changes is read until the policy's time, not less",
          value == "" and reads == 4 and 0.49 <= took < 0.7, (value, reads, took))
    value, reads, took = settled(0.35, "after_type")
    check("settle: a late change is still caught",
          value == "Pe" and reads == 3 and took < 0.6, (value, reads, took))
    value, reads, took = settled(0.1, "skill_check", until=lambda now: False)
    check("settle: `until` decides when it is done, not the change",
          reads == 6 and took >= 0.89, (value, reads, took))


def seeing_checks(runner):
    """The loop is told what opened and what was typed."""
    def run(utterance, windows, answers):
        loop_answers[:] = answers
        del loop_bodies[:]
        fake = Screen(windows)
        end, fake = runner.run(utterance, "Test", fake=fake, loop=LOOP, recipes=False)
        return end, fake, end.get("loop") or {}

    end, fake, report = run("write to Peter", [draft("Pe", filler=45), draft("Pe", popup=True, filler=45)],
                            [loop_answer("scroll"), loop_answer("none")])
    state = loop_bodies[1]["state"]
    check("loop: a pop-up that opened is in `changed`, and its rows are targets",
          state["changed"] == 'a pop-up opened near "To": "Peter Holm", "Peter Smith"'
          and any(v.startswith("Cell “Peter Smith”") and "in the pop-up" in v
                  for v in state["targets"].values()), state)

    end, fake, report = run("write to Peter", [draft(""), draft("Pe"), draft("Pe")],
                            [loop_answer("scroll"), loop_answer("click", "t0"), loop_answer("none")])
    check("loop: typing into a field counts as a change",
          loop_bodies[1]["state"]["changed"] == '"To" now holds "Pe"'
          and loop_bodies[2]["state"]["changed"] == UNCHANGED, [b["state"].get("changed") for b in loop_bodies])


def planner_checks(runner, stderr_path):
    def run(utterance, windows, plans, override=None, execute=True, visible=(), p=0.97):
        planner_plans[:] = plans
        del planner_bodies[:]
        visible_answers[:] = list(visible)
        pick_p["p"] = p
        calls = len(jev_calls)
        fake = Screen(windows, override)
        end, fake = runner.run(utterance, "Test", fake=fake, execute=execute, loop=LOOP,
                               recipes=False)
        return end, fake, end.get("loop") or {}, [c[0] for c in jev_calls[calls:]]

    def pressed(fake):
        return [s["id"] for s in fake.steps if s["do"] == "press"]

    home = panel("Home", ["General", "Settings", "Leave"])
    menu = panel("Home", ["General", "Settings", "Leave", "Mute channel"])
    muted = panel("Home — muted", ["General", "Settings", "Leave", "Unmute channel"])

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[{"do": "click", "target": "Settings", "expect": "a Mute channel item"},
          {"do": "pick", "target": "Mute channel"}]])
    check("planner: a plan is followed step by step",
          end["end"] == "done" and report["stopped"] == "Done" and len(planner_bodies) == 1
          and asked == ["pick", "visible", "pick"] and len(pressed(fake)) == 2
          and report["shown"] == ["Clicked Settings", "Clicked Mute channel"],
          (report, asked, fake.did()))
    check("planner: the request carries the window and names, not values",
          'Window: "Home"' in planner_bodies[0]["messages"][1]["content"]
          and '- Button "Settings"' in planner_bodies[0]["messages"][1]["content"]
          and planner_bodies[0].get("reasoning_effort") == "none",
          planner_bodies[0]["messages"][1]["content"])
    check("planner: no loop question to Jev", "action" not in asked, asked)

    compose = panel("New message", ["General", "Message to Ann"])
    end, fake, report, asked = run(
        "write to Ann saying hello", [home, compose, compose],
        [[{"do": "key", "value": "⌘N", "expect": "a message box"},
          {"do": "write", "target": "Message to Ann", "value": "hello"}]])
    check("planner: a key step, then write pastes into the box, and no Return",
          [s.get("keys") for s in fake.steps if s["do"] == "key"] == ["cmd+n"]
          and [s["text"] for s in fake.steps if s["do"] == "paste"] == ["hello"]
          and end["end"] == "done", (report, fake.did()))

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[{"do": "click", "target": "Settings menu"}],
         [{"do": "click", "target": "Settings"}]])
    check("planner: Jev's none, when the words are on screen, asks again",
          len(planner_bodies) == 2 and "Stalled: none of the" in planner_bodies[1]["messages"][1]["content"]
          and end["end"] == "done" and len(pressed(fake)) == 1, (report, asked))

    end, fake, report, asked = run(
        "mute this channel", [home, home, home, home, home],
        [[{"do": "click", "target": "General"}, {"do": "click", "target": "Settings"}],
         [{"do": "click", "target": "Leave"}]])
    check("planner: nothing changed twice asks again",
          "Stalled: nothing changed twice" in planner_bodies[1]["messages"][1]["content"],
          (report, [b["messages"][1]["content"][-80:] for b in planner_bodies]))
    check("planner: a press that did nothing is clicked for real",
          [s["click"] for s in fake.steps if s["do"] == "press"][:2] == [False, True], fake.steps)

    end, fake, report, asked = run(
        "mute this channel", [panel("Home", ["General", "Settings", f"Row {n}"]) for n in range(6)],
        [[{"do": "click", "target": "Settings"}] * 3, []])
    check("planner: the same step three times asks again",
          len(planner_bodies) == 2
          and "Stalled: the same step three times" in planner_bodies[1]["messages"][1]["content"]
          and report["stopped"].startswith("Stopped at “click Settings”"), report)

    end, fake, report, asked = run(
        "mute this channel", [home, menu], [[{"do": "click", "target": "Setting"}], []],
        p=0.6)
    check("planner: a pick below 0.8 asks again, and nothing is pressed",
          "at only 0.60" in planner_bodies[1]["messages"][1]["content"] and pressed(fake) == [],
          (report, fake.did()))

    twins = panel("Calendar", ["Today", "Create a new event.", "Week", "Create a new event."])
    end, fake, report, asked = run(
        "new meeting", [twins, twins], [[{"do": "click", "target": "Create a new event."}]],
        p=0.45)
    check("planner: two items with one name add their scores and the first is pressed",
          len(planner_bodies) == 1 and len(set(pressed(fake))) == 1
          and any("0.90" in line and "Create a new event." in line for line in fake.logs),
          (report, fake.logs[-4:]))

    end, fake, report, asked = run(
        "leave this channel", [panel("Home", ["General", "Settings", "Leave"], refused="leave")],
        [[{"do": "click", "target": "Leave"}], []])
    check("planner: a target on never_press is asked about, and no answer asks the planner again",
          len(planner_bodies) == 2
          and "the app refused to press it" in planner_bodies[1]["messages"][1]["content"],
          (report, fake.did()))

    refusal = {("press", 1): {"error": "refused", "said": True, "text": "Won't press"}}
    end, fake, report, asked = run(
        "mute this channel", [home, menu], [[{"do": "click", "target": "Settings"}], []], refusal)
    check("planner: a click the app refused asks again",
          "the app refused to press it" in planner_bodies[1]["messages"][1]["content"], report)

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[{"do": "click", "target": "Settings", "expect": "a Mute channel item"}],
         [{"do": "pick", "target": "Mute channel"}]], visible=[0.1])
    check("planner: an expect answered no asks again, then carries on",
          "and it is not on screen (0.10)" in planner_bodies[1]["messages"][1]["content"]
          and end["end"] == "done" and len(pressed(fake)) == 2, (report, asked))

    end, fake, report, asked = run(
        "mute this channel", [home, home, home, home],
        [[{"do": "click", "target": "Settings", "expect": "a menu"}],
         [{"do": "click", "target": "General", "expect": "a menu"},
          {"do": "click", "target": "Settings"}]], visible=[0.1, 0.1])
    check("planner: the same reason twice stops it and names the failed step",
          len(planner_bodies) == 2 and end["end"] == "stopped"
          and report["stopped"] == "Stopped at “click General” — expected “a menu” and it is not "
                                   "on screen (0.10)", report)

    del visible_bodies[:]
    end, fake, report, asked = run(
        "write to Peter", [draft(""), draft("Pe", popup=True)],
        [[{"do": "type", "target": "To", "value": "Peter", "expect": "a list of people"}], []],
        visible=[0.1])
    replan = planner_bodies[1]["messages"][1]["content"] if len(planner_bodies) > 1 else ""
    check("planner: the re-plan is told what opened and what the field holds",
          'Just opened: a pop-up near "To" with "Peter Holm", "Peter Smith"' in replan
          and 'Now in "To": "Pe"' in replan and '- Cell "Peter Smith" (in the pop-up)' in replan,
          replan)
    check("planner: the expect check sees the pop-up and what changed",
          'a pop-up opened near "To"' in visible_bodies[0]["state"]["changed_by_the_last_step"]
          and "Cell “Peter Smith”" in visible_bodies[0]["state"]["on_screen"],
          visible_bodies[:1])

    end, fake, report, asked = run(
        "write to Peter", [draft(""), draft("Pe", popup=True), draft("Pe", popup=True)],
        [[{"do": "type", "target": "To", "value": "Peter"}, {"do": "click", "target": "Subject"}],
         [{"do": "pick", "target": "Peter Smith"}]])
    advice = planner_bodies[1]["messages"][1]["content"] if len(planner_bodies) > 1 else ""
    check("planner: a pop-up the next step does not use asks again before the step",
          'a pop-up opened near “To” with “Peter Holm”, “Peter Smith”, and the next step, '
          '“click Subject”, does not use it' in advice and "Subject" not in str(pressed(fake)),
          (advice[-400:], fake.did()))

    end, fake, report, asked = run(
        "write to Peter", [draft(""), draft("Pe", popup=True), draft("Pe", popup=True)],
        [[{"do": "type", "target": "To", "value": "Peter"},
          {"do": "pick", "target": "Peter Smith"}]])
    check("planner: a pop-up the next step picks from is not a surprise",
          len(planner_bodies) == 1, planner_bodies[1:])

    end, fake, report, asked = run(
        "write to Peter", [draft(""), draft("Pe", popup=True)],
        [[{"do": "type", "target": "To", "value": "Peter"}], []])
    check("planner: a plan that ends on a typed field with a pop-up open asks again",
          len(planner_bodies) == 2 and "the plan ends with it open" in
          planner_bodies[1]["messages"][1]["content"], report)

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[{"do": "click", "target": "Settings"}, {"do": "pick", "target": "Mute channel"}]])
    clicks = [s["click"] for s in fake.steps if s["do"] == "press"]
    check("planner: an item the last step brought up is clicked, not pressed",
          clicks == [False, True], clicks)

    end, fake, report, asked = run(
        "make this a checklist", [home, home],
        [[{"do": "key", "value": "cmd+a"}, {"do": "type", "value": "☐ one"}], []])
    check("planner: select all is refused and asks again",
          "select all would put" in planner_bodies[1]["messages"][1]["content"]
          and "key" not in fake.did(), (report, fake.did()))
    focused = {("focus", 1): {"point": None, "described": "", "role": "AXComboBox"}}
    end, fake, report, asked = run(
        "set the end time to five", [home, menu], [[{"do": "key", "value": "cmd+a"}]], focused)
    check("planner: ⌘A in a combo box runs without asking",
          "ask" not in fake.did() and [s.get("keys") for s in fake.steps if s["do"] == "key"]
          == ["cmd+a"] and end["end"] == "done", (report, fake.did()))
    focused = {("focus", 1): {"point": None, "described": "", "role": "AXTextArea"}}
    end, fake, report, asked = run(
        "make this a checklist", [home, home], [[{"do": "key", "value": "cmd+a"}], []], focused)
    check("planner: ⌘A in a text area still asks",
          "ask" in fake.did() and "key" not in fake.did(), (report, fake.did()))

    end, fake, report, asked = run(
        "make this a checklist", [home, menu],
        [[{"do": "key", "value": "cmd+a"}], [{"do": "click", "target": "Settings"}]],
        {("ask", 1): {"answer": "move on to the next step", "via": "voice"}})
    replan = planner_bodies[1]["messages"][1]["content"] if len(planner_bodies) > 1 else ""
    check("planner: other words to a guard ask again, with the words in the reason",
          'Stalled: Not done — the user said: "move on to the next step"' in replan
          and "key" not in fake.did() and end["end"] == "done" and len(pressed(fake)) == 1,
          (replan[-200:], report, fake.did()))

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [500, [{"do": "click", "target": "Settings"}, {"do": "pick", "target": "Mute channel"}]])
    check("planner: a 500 is tried again by the SDK, and the second answer is used",
          len(planner_bodies) == 2 and end["end"] == "done" and len(pressed(fake)) == 2,
          (report, len(planner_bodies)))
    end, fake, report, asked = run(
        "search for invoices", [home, home],
        [[{"do": "type", "target": "Settings", "value": "invoices from March"}], []])
    check("planner: type refuses words that were not said",
          "not said: from, march" in planner_bodies[1]["messages"][1]["content"]
          and "type" not in fake.did() and "press" not in fake.did(), (report, fake.did()))

    end, fake, report, asked = run(
        "open the zebra panel", [home], [[{"do": "click", "target": "Zebra panel"}], []])
    check("planner: a target not in the tree stops it, and is not re-planned",
          len(planner_bodies) == 1 and end["end"] == "stopped"
          and report["stopped"] == "Could not find “Zebra panel” on screen"
          and any(line.startswith('planner: target not in the tree: "Zebra panel" — Test “Home”')
                  for line in fake.logs), (report, fake.logs[-3:]))

    end, fake, report, asked = run(
        "reply in the zebra thread", [panel("Home", ["Sign in", "General"])],
        [[{"do": "click", "target": "Reply in zebra thread"}], []])
    check("planner: a function word on screen does not hide a target not in the tree",
          len(planner_bodies) == 1 and report["stopped"].startswith("Could not find")
          and any("target not in the tree" in line for line in fake.logs), (report, fake.logs[-2:]))

    end, fake, report, asked = run(
        "mute this channel", [home], [[{"do": "click", "target": "Settings"}]], execute=False)
    check("planner: plan only says the plan and does nothing",
          end["end"] == "planned" and fake.did() == ["snapshot"]
          and "           1. click “Settings”" in fake.lines, (fake.lines, fake.did()))

    end, fake, report, asked = run(
        "mute this channel", [home], [f"invalid key {PLANNER_KEY}"])
    check("planner: an error that echoes the key does not repeat it",
          end["end"] == "failed" and PLANNER_KEY not in json.dumps(end)
          and "invalid key …" in report["stopped"], report)

    runner.process.stdin.close()
    runner.process.wait(timeout=5)
    with open(stderr_path, encoding="utf-8") as handle:
        printed = handle.read()
    check("planner: the key never appears in what the runner printed or sent",
          PLANNER_KEY not in printed and "jev pick" in printed,
          printed[-300:])


def messages(body):
    """What a request sent, as chat messages: the plan path's own, or the
    agent's Responses instructions and input items."""
    if "messages" in body:
        return body["messages"]
    out = [{"role": "system", "content": body.get("instructions") or ""}]
    for item in body.get("input") or ():
        if item.get("type") == "function_call_output":
            out.append({"role": "tool", "content": item["output"]})
        elif item.get("type") == "function_call":
            out.append({"role": "assistant", "content": None, "tool_calls": [item]})
        else:
            out.append(item)
    return out


def text(message):
    """A message's content as text: Pydantic AI sends some as a list of parts."""
    content = message.get("content")
    if isinstance(content, list):
        return "".join(part.get("text", "") for part in content)
    return content or ""


def act(*steps):
    return ("act", {"steps": [dict({"id": None, "value": None}, **step) for step in steps]})


def agent_checks(runner, stderr_path, trace_path):
    def run(utterance, windows, turns, override=None, execute=True, **loop):
        agent_turns[:] = turns
        del planner_bodies[:]
        calls = len(jev_calls)
        fake = Screen(windows, override, per_read=True)
        end, fake = runner.run(utterance, "Test", fake=fake, execute=execute,
                               loop=dict(LOOP, **loop), recipes=False)
        return end, fake, end.get("loop") or {}, [c[0] for c in jev_calls[calls:]]

    def results(n):
        """The tool messages of the nth call to the model."""
        return [m["content"] for m in messages(planner_bodies[n]) if m["role"] == "tool"]

    home = panel("Home", ["General", "Settings", "Leave"])
    menu = panel("Home", ["General", "Settings", "Leave", "Mute channel"])
    muted = panel("Home — muted", ["General", "Settings", "Leave", "Unmute channel"])

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[act({"do": "click", "id": 2}, {"do": "click", "id": 1})], [("done", {"summary": "ok"})]])
    check("agent: one act batch runs and done ends the run",
          end["end"] == "done" and report["stopped"] == "Done" and len(planner_bodies) == 2
          and report["shown"] == ["Clicked Settings", "Clicked General"] and report["acted"],
          (report, fake.did()))
    check("agent: a model ID maps to the runner's item, found again in the next read",
          [s["id"] for s in fake.steps if s["do"] == "press"] == [102, 105], fake.steps)
    body = planner_bodies[0]
    names = [t["name"] for t in body["tools"]]
    check("agent: tools, strict, required, parallel calls, reasoning none, on /v1/responses",
          names[:4] == ["act", "read", "look", "ask"] and names[-2:] == ["done", "stuck"]
          and set(names[4:-2]) == {"write_plan"}
          and all(t["strict"] for t in body["tools"] if t["name"] not in PLAN_TOOLS)
          and body["tool_choice"] == "required" and body["parallel_tool_calls"] is True
          and body["reasoning"] == {"effort": "none"} and "input" in body, names)
    schema_checks(body["tools"])
    check("agent: the screen is sent as numbered lines",
          '[2] Button "Settings"' in messages(body)[1]["content"]
          and "Request: mute this channel" in messages(body)[1]["content"],
          messages(body)[1]["content"])
    check("agent: Jev is never asked", asked == [], asked)
    check("agent: the first message says today's date",
          "\nNow: " in messages(body)[1]["content"], messages(body)[1]["content"][:200])

    end, fake, report, asked = run(
        "write to Peter", [draft(""), draft("Pe", popup=True), draft("Pe", popup=True)],
        [[act({"do": "type", "id": 1, "value": "Peter"}, {"do": "click", "id": 2})],
         [("done", {"summary": "typed"})]])
    got = results(1)[0] if len(planner_bodies) > 1 else ""
    check("agent: a pop-up opening mid-batch stops it, and its rows come back",
          "Ran 1 of 2:" in got and "Stopped: something opened after step 1, and step 2 does not "
          "use it" in got and 'Cell "Peter Smith" (in the pop-up)' in got
          and '"appeared": [{"kind": "pop-up"' in got
          and [s["do"] for s in fake.steps if s["do"] in ("press", "type")] == ["press", "type"],
          (got, fake.did()))

    end, fake, report, asked = run(
        "leave this channel", [panel("Home", ["General", "Settings", "Leave"], refused="leave")] * 3,
        [[act({"do": "click", "id": 3})], [act({"do": "type", "value": "goodbye from March"})],
         [act({"do": "click", "id": 2})], [("stuck", {"why": "refused"})]],
        {("press", 2): {"error": "refused", "said": True, "text": "Won't press"}})
    got = [r for n in range(1, 4) for r in results(n)[-1:]] if len(planner_bodies) == 4 else []
    check("agent: guard refusals come back as tool results, not a crash",
          len(got) == 3 and "the app refused to press it" in got[0]
          and "not said: goodbye, from, march" in got[1]
          and "the app refused to press it" in got[2] and end["end"] == "stopped"
          and report["stopped"] == "Stuck — refused"
          and [s["do"] for s in fake.steps].count("ask") == 2
          and "type" not in fake.did(), (got, report, fake.did()))

    end, fake, report, asked = run(
        "mute this channel", [home] * 3,
        [[act({"do": "click", "id": 2}), ("done", {"summary": "ok"})],
         [("done", {"summary": "ok"})]])
    got = results(1)
    check("agent: done in the same turn as an act is refused until the result is read",
          any("Not done: this turn acted" in r for r in got) and end["end"] == "done"
          and len(planner_bodies) == 2, (got, report))

    end, fake, report, asked = run(
        "leave this channel", [home] * 3,
        [[("stuck", {"why": "The form is gone."})], [("done", {"summary": "ok"})]],
        {("ask", 1): {"answer": "go back to the form", "via": "text"}})
    check("agent: stuck asks the user once, and an answer carries the run on",
          len(planner_bodies) == 2 and end["end"] == "done"
          and "The user answered: go back to the form" in results(1)[-1]
          and "The form is gone. What should I do?" in str(fake.steps), (report, fake.did()))

    which = ("ask", {"question": "Two people match. Which one?",
                      "options": ["Peter Holm", "Peter Smith"]})
    typed = [draft(""), draft("Peter", popup=True)]
    end, fake, report, asked = run(
        "write to Peter", typed,
        [[act({"do": "type", "id": 1, "value": "Peter"})], [which], [("done", {"summary": "ok"})]],
        {("ask", 1): {"answer": "Peter Smith", "via": "option"}})
    sent = next((s for s in fake.steps if s["do"] == "ask"), {})
    near = sent.get("near") or {}
    check("agent: ask reaches the app with the question, the options and the frame of the "
          "field and its list",
          sent.get("question") == "Two people match. Which one?"
          and sent.get("options") == ["Peter Holm", "Peter Smith"]
          and near.get("x") == 400 and near.get("y") - near.get("h") / 2 == 90
          and near.get("y") + near.get("h") / 2 == 160 and near.get("w") == 200
          and sent.get("shown") == report["shown"][:1], sent)
    got = results(2)[-1] if len(planner_bodies) == 3 else ""
    check("agent: an option answer comes back to the model",
          got == "The user answered: Peter Smith" and end["end"] == "done", (got, report))

    end, fake, report, asked = run(
        "write to Peter", typed,
        [[act({"do": "type", "id": 1, "value": "Peter"})], [which], [("done", {"summary": "ok"})]],
        {("ask", 1): {"answer": "the one in Paris", "via": "text"}})
    got = results(2)[-1] if len(planner_bodies) == 3 else ""
    check("agent: a typed answer comes back to the model",
          got == "The user answered: the one in Paris", got)

    end, fake, report, asked = run(
        "write to Peter", typed,
        [[act({"do": "type", "id": 1, "value": "Peter"})], [which], [("done", {"summary": "ok"})]])
    got = results(2)[-1] if len(planner_bodies) == 3 else ""
    check("agent: no answer goes back to the model, which must not commit",
          got.startswith("No answer. Do not commit anything") and end["end"] == "done",
          (got, report, len(planner_bodies)))

    end, fake, report, asked = run(
        "write to Peter", typed,
        [[act({"do": "type", "id": 1, "value": "Peter"})], [which], [("done", {"summary": "ok"})]],
        {("ask", 1): {"answer": None, "via": "escape"}})
    check("agent: Escape on the question stops the run",
          report["stopped"] == "Stopped — you pressed escape" and len(planner_bodies) == 2,
          (report, len(planner_bodies)))

    end, fake, report, asked = run(
        "mute this channel", [home], [[which], [("done", {"summary": "ok"})]],
        {("ask", 1): {"answer": "Settings", "via": "voice"}})
    sent = next((s for s in fake.steps if s["do"] == "ask"), {})
    check("agent: a question before any step has no frame and no steps",
          "near" in sent and sent["near"] is None and "shown" not in sent, sent)

    def guarded(answer):
        return run("leave this channel", [home] * 3,
                   [[act({"do": "type", "value": "goodbye from March"})],
                    [("done", {"summary": "ok"})]],
                   {("ask", 1): {"answer": answer, "via": "option"}})

    end, fake, report, asked = guarded("No")
    sent = next((s for s in fake.steps if s["do"] == "ask"), {})
    check("guard: words not said ask Yes or No, and No refuses",
          sent.get("options") == ["Yes, go ahead", "No"]
          and sent.get("question", "").startswith("Type “goodbye from March”?")
          and "type" not in fake.did() and "paste" not in fake.did(), (sent, fake.did()))
    end, fake, report, asked = guarded("Yes, go ahead")
    check("guard: Yes, go ahead lets the step run", "type" in fake.did(), fake.did())
    end, fake, report, asked = guarded("yes")
    check("guard: a plain yes is a yes", "type" in fake.did(), fake.did())
    end, fake, report, asked = guarded("no")
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("guard: a plain no still refuses",
          "type" not in fake.did() and "failed: would type words that were not said" in got,
          (got, fake.did()))
    end, fake, report, asked = guarded("move on to the next step")
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("guard: other words are the step's result, and the run goes on",
          'Not done — the user said: "move on to the next step"' in got
          and "failed:" not in got.split("Change:")[0] and "type" not in fake.did()
          and len(planner_bodies) == 2 and end["end"] == "done", (got, report))

    redirect = {("press", 1): {"error": "redirected", "text": "click General instead"}}
    end, fake, report, asked = run(
        "leave this channel", [home] * 3,
        [[act({"do": "click", "id": 3})], [("done", {"summary": "ok"})]], redirect)
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("guard: the app's own guard answered with other words is a tool result",
          'Not done — the user said: "click General instead"' in got
          and len(planner_bodies) == 2 and end["end"] == "done", (got, report))

    def times(expanded):
        form = panel("New event", ["Start time", "End time", "Save"])
        for item in form["items"][:2]:
            item.update(kind="text", role="AXComboBox", value="18:00")
        if expanded:
            form["items"][0]["state"] = ["expanded"]
            form["items"].append(dict(form["items"][2], name="18:30", role="AXCell", y=160,
                                      kind="click", **{"in": "pop-up"}))
        return form

    end, fake, report, asked = run(
        "end at seven", [times(True), times(False), times(False)],
        [[act({"do": "type", "id": 2, "value": "19:00"})], [("done", {"summary": "ok"})]])
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    acted = [(s["do"], s.get("keys") or s.get("id")) for s in fake.steps
             if s["do"] in ("key", "press", "type", "paste")]
    check("agent: an open list that is not the target's gets Return before the click",
          acted[:2] == [("key", "return"), ("press", 102)]
          and 'closed the open list of "Start time" first' in got
          and 'planner: closed the open list of "Start time" first' in fake.logs,
          (acted, got))
    end, fake, report, asked = run(
        "pick 18:30", [times(True), times(False)],
        [[act({"do": "click", "id": 4})], [("done", {"summary": "ok"})]])
    check("agent: a row of the open list is clicked with no Return first",
          "key" not in fake.did() and "press" in fake.did(), fake.did())

    slack = times(True)
    slack["items"].append(dict(slack["items"][2], name="Tess Exshaw (active)", role="AXButton",
                               y=190, kind="click"))
    end, fake, report, asked = run(
        "message Tess", [slack, times(False)],
        [[act({"do": "click", "id": 5})], [("done", {"summary": "ok"})]])
    check("agent: a suggestion row outside any pop-up is clicked with no Return first",
          "key" not in fake.did() and "press" in fake.did(), fake.did())

    end, fake, report, asked = run(
        "mute this channel", [home] * 6,
        [[act({"do": "click", "id": 1})], [act({"do": "click", "id": 1})],
         [("done", {"summary": "ok"})]])
    got = results(2)[-1] if len(planner_bodies) > 2 else ""
    check("agent: a batch that repeats with the same result is flagged",
          "This exact batch already ran and did the same thing" in got
          and "already ran" not in (results(1)[-1] if len(planner_bodies) > 1 else "x"), got[:300])

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[act({"do": "click", "id": 2}, {"do": "key", "value": "return"})],
         [("done", {"summary": "ok"})]])
    key = next((s for s in fake.steps if s["do"] == "key"), {})
    check("guard: a key after a step carries the steps, for the app's own question",
          key.get("shown") == ["Clicked Settings"], key)

    end, fake, report, asked = run("mute this channel", [home], [[("read", {})]] * 51)
    check("agent: the call limit stops the run",
          len(planner_bodies) == 50 and report["stopped"] == "Stopped after 50 model calls"
          and end["end"] == "stopped", (report, len(planner_bodies)))
    last = [m.get("content") or "" for m in messages(planner_bodies[-1])]
    check("agent: only the newest screen goes in full",
          sum("earlier ones no longer work" in c for c in last) == 1
          and "earlier ones no longer work" in last[-1]
          and last[1].endswith("(the screen is in the newest tool result)")
          and last.count("Read the screen.") == 48, last)

    end, fake, report, asked = run(
        "mute this channel", [home, menu], [[act({"do": "click", "id": 2})]] * 3, max_steps=2)
    check("agent: max_steps stops the run",
          report["stopped"] == "Stopped after 2 steps" and len(planner_bodies) == 2, report)

    escape = {("press", 1): {"error": "escape", "said": True}}
    end, fake, report, asked = run(
        "mute this channel", [home, menu], [[act({"do": "click", "id": 2}, {"do": "click", "id": 1})]],
        escape)
    check("agent: Escape mid-batch stops the run at once",
          report["stopped"] == "Stopped — you pressed escape" and fake.did().count("press") == 1
          and len(planner_bodies) == 1, (report, fake.did()))

    end, fake, report, asked = run(
        "mute this channel", [home], [[act({"do": "click", "id": 2})]], execute=False)
    check("agent: plan only asks once, says the call and does nothing",
          end["end"] == "planned" and fake.did() == ["snapshot"] and len(planner_bodies) == 1
          and "           click  → Button “Settings”" in " ".join(fake.lines)
          and fake.lines[-1] == "(planned only)", (fake.lines, fake.did()))

    end, fake, report, asked = run(
        "write to Peter", [draft("Peter"), draft("Peter")], [[("done", {"summary": "ok"})]])
    first = messages(planner_bodies[0])[1]["content"]
    check("agent: a field's value is on its line, and an empty one is not",
          'TextField "To" = "Peter"' in first and "TextArea (no name)\n" in first + "\n"
          and "= \"\"" not in first, first)

    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[("act", {"why": "open the channel settings", "steps": [
            {"do": "click", "id": 2, "value": None}]})], [("done", {"summary": "ok"})]])
    check("agent: act takes a why, and the app log line says it",
          any("act (open the channel settings) click [2]" in line for line in fake.logs)
          and end["end"] == "done", fake.logs)

    seen = {"text": "Matthieu Laurent · cAI", "x": 420, "y": 140, "w": 180, "h": 14, "p": 0.5}
    subject = {"text": "Subject", "x": 330, "y": 300, "w": 50, "h": 12, "p": 1.0}
    look = ("look", {"id": 1, "side": "below", "x": None, "y": None, "w": None, "h": None})
    end, fake, report, asked = run(
        "invite Matthieu", [draft("Matthieu")] * 3,
        [[look], [act({"do": "type", "id": 101, "value": "x"})],
         [look], [act({"do": "click", "id": 101})], [("done", {"summary": "ok"})]],
        {("look", 1): {"lines": [seen]}, ("look", 2): {"lines": [seen]}})
    sent = next((s for s in fake.steps if s["do"] == "look"), {})
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("agent: look with an id sends the region below that item, and lines come back with IDs",
          {k: sent.get(k) for k in ("x", "y", "w", "h")} == {"x": 460, "y": 310, "w": 400, "h": 400}
          and got.startswith('Looked below [1] TextField "To" = "Matthieu"')
          and '[101] "Matthieu Laurent · cAI"' in got and "may misread" in got, (sent, got))
    got = results(2)[-1] if len(planner_bodies) > 2 else ""
    check("agent: a seen line cannot be typed into",
          got.startswith("Nothing ran: step 1 would type into a seen line"), got)
    click = next((s for s in fake.steps if s["do"] == "click_at"), {})
    check("agent: clicking a seen line clicks at its centre, with its text for never_press",
          (click.get("x"), click.get("y"), click.get("name")) == (420, 140, "Matthieu Laurent · cAI")
          and "press" not in fake.did() and report["shown"] == ["Clicked Matthieu Laurent · cAI"],
          (click, fake.did(), report))

    end, fake, report, asked = run(
        "invite Matthieu", [draft("")] * 12,
        [[act({"do": "type", "id": 1, "value": "Matthieu"}, {"do": "click", "id": 2})],
         [act({"do": "click", "id": 101})], [("done", {"summary": "ok"})]],
        {("look", 1): {"lines": [subject]}, ("look", 2): {"lines": [subject, seen]}})
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("agent: a lookup type that changed nothing looks below the field, before and after",
          [s["do"] for s in fake.steps if s["do"] in ("look", "type")] == ["look", "type", "look"]
          and 'a list opened near "To" (seen, not from the tree): [101] "Matthieu Laurent · cAI"'
          in got and '"Subject"' not in got.split("Change:")[0]
          and "Stopped: a list opened after step 1, seen on screen only" in got
          and fake.did().count("press") == 1, (got, fake.did()))
    click = next((s for s in fake.steps if s["do"] == "click_at"), {})
    check("agent: a line the automatic look found can be clicked next",
          (click.get("x"), click.get("y")) == (420, 140), fake.steps)

    end, fake, report, asked = run(
        "invite Matthieu", [draft("")] * 12,
        [[look], [act({"do": "type", "id": 1, "value": "Matthieu"})], [("done", {"summary": "ok"})]],
        {("look", n): {"error": "screen recording is not granted"} for n in (1, 2, 3)})
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    after = results(2)[-1] if len(planner_bodies) > 2 else ""
    check("agent: a look without the permission is a tool result, and the type still runs",
          got == "Could not look: screen recording is not granted" and end["end"] == "done"
          and "Ran 1 of 1" in after and UNCHANGED in after
          and sum("could not look" in line for line in fake.logs) == 1, (got, after, fake.logs))

    end, fake, report, asked = run(
        "mute this channel", [home] * 3,
        [[act({"do": "click", "id": "Settings"})], [act({"do": "delete", "id": 2})],
         [("done", {"summary": "ok"})]])
    got = [results(n)[-1] for n in (1, 2)] if len(planner_bodies) == 3 else []
    def wrong(text):
        """The field of Pydantic AI's retry prompt that names the wrong argument."""
        try:
            return json.loads(text.split("```json\n")[1].split("\n```")[0])[0]["loc"]
        except (IndexError, ValueError, KeyError):
            return None
    check("agent: a wrong type or an unknown do comes back as a validation message, "
          "and nothing runs",
          len(got) == 2 and wrong(got[0]) == ["steps", 0, "id"]
          and wrong(got[1]) == ["steps", 0, "do"] and got[0].endswith("Fix the errors and try again.")
          and "'click'" in got[1] and "press" not in fake.did() and end["end"] == "done"
          and any("act (arguments not valid)" in line for line in fake.logs), (got, fake.did()))

    def seen(text, x, y, w=120, h=14):
        return {"text": text, "x": x, "y": y, "w": w, "h": h, "p": 0.5}
    listed = [seen("Peter Quill", 330, 130), seen("peter.quill@example.com", 340, 146)]
    end, fake, report, asked = run(
        "invite Peter", [dict(draft(""), seen=[]), dict(draft("Pe"), seen=listed),
                         dict(draft("Pe"), seen=listed)],
        [[act({"do": "type", "id": 1, "value": "Peter"}, {"do": "click", "id": 2})],
         [act({"do": "click", "id": 101})], [("done", {"summary": "ok"})]])
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("agent: text that appeared after a type stops the batch before a click elsewhere",
          "Ran 1 of 2" in got and "Stopped: text appeared after step 1, and step 2 does not use it"
          in got and 'text appeared near "To" (seen, not in the tree): [101] "Peter Quill", '
          '[102] "peter.quill@example.com"' in got
          and '"seen"' not in got.split("Change:")[1].split("\n")[0]
          and fake.did().count("press") == 1 and "look" not in fake.did(), (got, fake.did()))
    click = next((s for s in fake.steps if s["do"] == "click_at"), {})
    check("agent: a seen line from a step's result is clicked at its centre",
          (click.get("x"), click.get("y"), click.get("name")) == (330, 130, "Peter Quill"), fake.steps)
    check("agent: every read during a run asks for the text on screen",
          all(s.get("see") is True for s in fake.steps if s["do"] == "snapshot"), fake.steps)
    end, fake, report, asked = run(
        "invite Peter", [draft(""), draft("Pe"), draft("Pe")],
        [[act({"do": "type", "id": 1, "value": "Peter"}, {"do": "click", "id": 2})],
         [("done", {"summary": "ok"})]])
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("agent: without seen lines in the reply (no permission) the batch runs as before",
          "Ran 2 of 2" in got and "seen" not in got and "look" in fake.did()
          and end["end"] == "done", (got, fake.did()))

    tool = [seen("Tool 0", 801, 42, 50)]
    end, fake, report, asked = run(
        "save it", [dict(draft("", filler=1), seen=tool), dict(draft(""), seen=tool),
                    dict(draft(""), seen=tool)],
        [[act({"do": "click", "id": 1}, {"do": "click", "id": 2})],
         [act({"do": "click", "id": 101})], [("done", {"summary": "ok"})]])
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    click = next((s for s in fake.steps if s["do"] == "click_at"), {})
    check("agent: a control still on screen does not stop the batch, and keeps a clickable ID",
          "Ran 2 of 2" in got and 'still on screen, no longer in the tree (a panel may be hiding '
          'them): [101] Button "Tool 0"' in got
          and (click.get("x"), click.get("y"), click.get("name")) == (801, 42, "Tool 0"),
          (got, click))

    def timed(expanded, over):
        form = panel("New event", ["Start time", "End time", "Save"])
        for item in form["items"][:2]:
            item.update(kind="text", role="AXComboBox", value="17:30", h=32)
        if expanded:
            form["items"][0]["state"] = ["expanded"]
        form["seen"] = [seen("18:30", 490, 132, 40)] if over else []
        return form
    end, fake, report, asked = run(
        "end at 18:30", [timed(True, True)] * 4,
        [[act({"do": "type", "id": 2, "value": "18:30"})], [("done", {"summary": "ok"})]])
    got = results(1)[-1] if len(planner_bodies) > 1 else ""
    check("agent: a seen line over the target, a list still open, is a failed step; the run goes on",
          'failed: "End time" is covered by text seen on screen: "18:30"' in got
          and not {"press", "type", "paste"} & set(fake.did()) and end["end"] == "done",
          (got, fake.did()))
    end, fake, report, asked = run(
        "end at 18:30", [timed(False, True)] * 4,
        [[act({"do": "type", "id": 2, "value": "18:30"})], [("done", {"summary": "ok"})]])
    check("agent: text inside a field with no list open is not a cover (Slack's To placeholder)",
          "press" in fake.did(), fake.did())
    end, fake, report, asked = run(
        "end at 18:30", [timed(True, True), timed(False, False), timed(False, False)],
        [[act({"do": "type", "id": 2, "value": "18:30"})], [("done", {"summary": "ok"})]])
    acted = [(s["do"], s.get("keys") or s.get("id")) for s in fake.steps
             if s["do"] in ("key", "press", "type")]
    check("agent: covered with a list open: Return first, then read again and act",
          acted == [("key", "return"), ("press", 102), ("type", None)], acted)

    focused_to = draft("Alex Moreau")
    focused_to["items"][0]["state"] = ["focused"]
    end, fake, report, asked = run(
        "write to Alex and Antonio", [focused_to] * 4,
        [[act({"do": "type", "id": 1, "value": "Antonio"})], [("done", {"summary": "ok"})]])
    check("agent: typing into the field that holds the caret does not click it first",
          "press" not in fake.did() and "click_at" not in fake.did() and "type" in fake.did(),
          fake.did())

    def plan(*tasks):
        return ("write_plan", {"items": [{"content": content, "status": status}
                                         for content, status in tasks]})
    end, fake, report, asked = run(
        "mute this channel", [home, menu, muted],
        [[plan(("Open the settings", "in_progress"), ("Mute the channel", "pending"))],
         [act({"do": "click", "id": 2}, {"do": "click", "id": 1})], [("done", {"summary": "ok"})],
         [plan(("Open the settings", "completed"), ("Mute the channel", "completed"))],
         [("done", {"summary": "ok"})]])
    first, second = (planner_bodies + [{"input": []}] * 2)[:2]
    reminder = text(messages(second)[-1]) if messages(second) else ""
    check("agent: a plan written on the first call is shown at the end of the next request",
          "<plan-reminder>" not in json.dumps(first) and messages(second)[-1]["role"] == "user"
          and re.search(r"1\. \[~\] \[\w+\] Open the settings\n2\. \[ \] \[\w+\] Mute the channel", reminder), reminder)
    refused = results(3)[-1] if len(planner_bodies) > 3 else ""
    check("agent: done with a task open is refused, the model is asked again, and done then passes",
          refused.startswith("Not done: 'Open the settings' is still open. Finish it, or cancel it "
                             "with a reason.")
          and len(planner_bodies) == 5 and end["end"] == "done" and report["stopped"] == "Done"
          and report["shown"] == ["Clicked Settings", "Clicked General"], (refused, report))

    covered = "the app refused to press it"
    end, fake, report, asked = run(
        "mute this channel", [home, home, menu, muted],
        [[("write_plan", {"items": [
            {"id": "a", "content": "Open the settings", "status": "in_progress"},
            {"id": "b", "content": "Mute the channel", "status": "pending"}]})],
         [act({"do": "click", "id": 2})],
         [act({"do": "click", "id": 2}, {"do": "click", "id": 1})],
         [("act", {"plan": {"now_done": ["a"], "dropped": [], "working_on": "b"},
                   "steps": [{"do": "click", "id": 2}]})],
         [("done", {"plan": {"now_done": ["b"], "dropped": [], "working_on": None},
                    "summary": "ok"})]],
        {("press", 1): {"error": "refused"}})
    shown = runner.progress
    statuses = [[t["status"] for t in p["plan"]] for p in shown if p.get("plan")]
    first_press = next((n for n, m in enumerate(runner.order) if m.get("do") == "press"), 0)
    check("progress: the run's title comes first, with no plan yet",
          shown and shown[0]["title"] == "mute this channel" and shown[0]["plan"] is None
          and runner.order[0].get("do") == "progress", shown[:1])
    check("progress: the plan with its statuses after write_plan and each call's plan field",
          ["in_progress", "pending"] in statuses and ["completed", "in_progress"] in statuses
          and statuses[-1] == ["completed", "completed"]
          and shown[-1]["plan"][0]["content"] == "Open the settings", statuses)
    check("progress: thinking while the model is asked, and the step before it runs",
          any(p.get("activity") == "thinking…" for p in shown)
          and any(m.get("do") == "progress" and m.get("activity") == "clicking “Settings”…"
                  for m in runner.order[:first_press]),
          [p.get("activity") for p in shown])
    notes = next((p["plan"][0]["notes"] for p in shown if p.get("plan") and p["plan"][0]["notes"]),
                 [])
    check("progress: a failed step is a note on the task in progress",
          notes == [covered], (notes, shown[-1]))
    check("progress: the end says how it ended, after the last step",
          shown[-1]["outcome"] == "Done" and shown[-1]["activity"] is None
          and runner.order[-1] is shown[-1] and end["end"] == "done", (shown[-1:], end))

    end, fake, report, asked = run(
        "mute this channel", [home] * 3,
        [[plan(("Mute the channel", "in_progress"))], [("read", {})], [("read", {})],
         [("stuck", {"why": "no mute here"})]])
    last = [text(m) for m in messages(planner_bodies[-1])]
    check("agent: with a plan, only the newest screen goes in full and the plan is never cut",
          sum("earlier ones no longer work" in c for c in last) == 1
          and "earlier ones no longer work" in last[-2] and "<plan-reminder>" in last[-1]
          and re.search(r"\[~\] \[\w+\] Mute the channel", last[-1])
          and last[1].endswith("(the screen is in the newest tool result)")
          and last.count("Read the screen.") == 1 and report["stopped"] == "Stuck — no mute here",
          last)

    runner.process.stdin.close()
    runner.process.wait(timeout=5)
    with open(trace_path, encoding="utf-8") as handle:
        traced = handle.read()
    with open(stderr_path, encoding="utf-8") as handle:
        printed = handle.read()
    lines = [json.loads(line) for line in traced.splitlines()]
    check("agent: one trace line per call, and the key is not in it",
          len(lines) == 149 and PLANNER_KEY not in traced and PLANNER_KEY not in printed
          and lines[0]["tokens"] == {"in": 100, "out": 20} and lines[0]["messages"]
          and lines[0]["tool_calls"] and lines[0]["results"], (len(lines), lines[:1]))
    check("agent: the why is in the trace",
          '"why\\": \\"open the channel settings\\"' in traced, traced[-400:])


STRICT_KEYS = {"type", "properties", "required", "additionalProperties", "items", "enum",
               "anyOf", "description", "const"}


def steer_checks(url, user, plans_url):
    """What the user types or says during an agent run: the app queues it,
    the agent takes it with `steer` before each model call."""
    root = tempfile.mkdtemp()
    runner = Runner(url, user, extra=planner_env(
        plans_url, PARROTFLOW_PLANNER_LOOP="agent", PARROTFLOW_RUNS=root))
    said = "The user says, while you work: "

    def run(turns, override=None, windows=None):
        agent_turns[:] = turns
        del planner_bodies[:]
        home = panel("Home", ["General", "Settings", "Leave"])
        fake = Screen(windows or [home] * 4, override)
        end, fake = runner.run("mute this channel", "Test", fake=fake, loop=LOOP, recipes=False)
        return end, fake, os.path.join(root, recorded(root)[-1])

    def users(n):
        """The user messages of the nth request that the user said during the run."""
        return [text(m)[len(said):] for m in messages(planner_bodies[n])
                if m.get("role") == "user" and text(m).startswith(said)]

    three = [[act({"do": "click", "id": 2})], [act({"do": "click", "id": 1})],
             [("done", {"summary": "ok"})]]
    end, fake, folder = run(three, {("steer", 2): {"messages": ["mute General instead"]}})
    check("steer: a queued message reaches the next request as a user message, and not before",
          len(planner_bodies) == 3 and users(0) == [] and users(1) == ["mute General instead"]
          and end["end"] == "done", [users(n) for n in range(len(planner_bodies))])
    last = [text(m) for m in messages(planner_bodies[2])] if len(planner_bodies) == 3 else []
    check("steer: the message survives the history cut: two calls later it is still sent",
          users(2) == ["mute General instead"]
          and any(t.endswith("(the screen is in the newest tool result)") for t in last), last)
    check("steer: the agent asks before each model call, and the panel shows the field",
          [s["do"] for s in fake.steps].count("steer") == 3
          and any(p.get("steers") is True for p in runner.progress), fake.steps)
    check("steer: the runner logs each message",
          "agent: the user says — mute General instead" in fake.logs, fake.logs)
    check("steer: the prompt says the user's words come first",
          "Their words come first, and may change the plan." in messages(planner_bodies[0])[0]["content"])
    calls = [read_json(folder, "calls", f"0{n}.json") for n in (1, 2, 3)]
    check("steer: the recording keeps each message on the call that received it",
          [c["steer"] for c in calls] == [[], ["mute General instead"], []],
          [c.get("steer") for c in calls])

    end, fake, folder = run(three, {("steer", 1): {"messages": ["first", " second  one "]},
                                    ("steer", 2): {"messages": ["third"]}})
    check("steer: several messages keep their order, across calls",
          users(0) == ["first", "second one"] and users(2) == ["first", "second one", "third"],
          [users(n) for n in range(len(planner_bodies))])

    end, fake, folder = run(three)
    check("steer: no message changes nothing in the requests",
          all(users(n) == [] for n in range(len(planner_bodies))) and len(planner_bodies) == 3
          and not any(said in json.dumps(b["input"]) for b in planner_bodies)
          and end["end"] == "done",
          len(planner_bodies))

    end, fake, folder = run(
        [[act({"do": "type", "value": "channel"})], [("done", {"summary": "ok"})]],
        {("type", 1): {"ok": True, "paused_ms": 2500}})
    check("steer: a screen step that waited for the user goes on, and the wait is logged",
          end["end"] == "done" and "type" in fake.did()
          and any(line.startswith("agent: 2.5 s waiting for the user") for line in fake.logs),
          (end, fake.logs))

    runner.process.stdin.close()
    runner.process.wait(timeout=5)


def strict_errors(node, path="$"):
    """What OpenAI's strict mode would refuse in a JSON schema."""
    if isinstance(node, list):
        return [e for n, item in enumerate(node) for e in strict_errors(item, f"{path}[{n}]")]
    if not isinstance(node, dict):
        return []
    errors = [f"{path}: {key}" for key in node if key not in STRICT_KEYS]
    if node.get("type") == "object" or "properties" in node:
        if node.get("additionalProperties") is not False:
            errors.append(f"{path}: additionalProperties is not false")
        if sorted(node.get("required", [None])) != sorted(node.get("properties", {})):
            errors.append(f"{path}: not every property is required")
    for key, value in node.items():
        if key == "properties":
            errors += [e for name, v in value.items() for e in strict_errors(v, f"{path}.{name}")]
        elif key != "enum":
            errors += strict_errors(value, f"{path}.{key}")
    return errors


def inline(node, defs=None):
    """The schema with each `$ref` written out in place: strict mode takes
    `$defs`, and the rules below then apply to what they point at."""
    if isinstance(node, list):
        return [inline(n, defs) for n in node]
    if not isinstance(node, dict):
        return node
    defs = dict(defs or {}, **node.get("$defs", {}))
    if "$ref" in node:
        return inline(defs[node["$ref"].rsplit("/", 1)[-1]], defs)
    return {k: inline(v, defs) for k, v in node.items() if k != "$defs"}


def schema_checks(tools):
    """The agent's tools as the fake planner received them, and the plan's
    schema read directly."""
    sys.path.insert(0, os.path.join(ROOT, "built-in", "recipes"))
    import planner

    ours = {t["name"]: t for t in tools
            if t["name"] in ("act", "read", "look", "ask", "done", "stuck")}
    errors = {name: strict_errors(inline(f["parameters"])) for name, f in ours.items()}
    errors["plan"] = strict_errors(planner.SCHEMA)
    check("schema: every tool and the plan pass strict mode's rules",
          len(ours) == 6 and not any(errors.values())
          and all(f.get("strict") for f in ours.values()), errors)
    step = inline(ours["act"]["parameters"])["properties"]["steps"]["items"]
    check("schema: act's steps take do from the list, and a nullable id, value and expect",
          step["properties"]["do"]["enum"] == ["click", "pick", "type", "write", "key", "scroll"]
          and step["properties"]["id"] == {"anyOf": [{"type": "integer"}, {"type": "null"}]}
          and step["properties"]["expect"] == {"anyOf": [{"type": "string"}, {"type": "null"}]}
          and step["required"] == ["do", "id", "value", "expect"], step)
    check("schema: a tool's description is its docstring on one line",
          ours["read"]["description"] == "Read the screen again without acting. Returns it with new IDs."
          and "\n" not in ours["act"]["description"]
          and ours["done"]["description"] == "The task is done, or done up to where the user takes over.",
          (ours["read"], ours["done"]["description"]))


def planner_env(plans_url, **more):
    return dict({"PARROTFLOW_PLANNER_MODEL": "test-model", "PARROTFLOW_PLANNER_KEY": PLANNER_KEY,
                 "PARROTFLOW_PLANNER_URL": f"{plans_url}/v1/chat/completions",
                 "PARROTFLOW_PLANNER_REASONING": "none"}, **more)


def recorded(root):
    """The run folders under `root`, oldest first, and their files as text."""
    names = sorted(n for n in os.listdir(root) if n[:4].isdigit())
    return names


def read_json(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as handle:
        return json.load(handle)


class Vanishing(Screen):
    """Deletes the run's folder at the first press: every write after fails."""

    def __init__(self, windows, folder_of):
        super().__init__(windows)
        self.folder_of = folder_of

    def reply(self, step):
        if step["do"] == "press" and not any(s["do"] == "press" for s in self.steps):
            import shutil
            shutil.rmtree(self.folder_of(), ignore_errors=True)
        return super().reply(step)


def recorder_checks(url, user, plans_url):
    """The run recorder, `runlog.py`, writing into a temp folder."""
    root = tempfile.mkdtemp()
    for n in range(55):
        os.makedirs(os.path.join(root, f"2020-01-01T00-00-{n:02d}.000-old"))
    os.makedirs(os.path.join(root, "not-a-run"))
    trace = os.path.join(tempfile.mkdtemp(), "agent.jsonl")
    runner = Runner(url, user, extra=planner_env(
        plans_url, PARROTFLOW_PLANNER_LOOP="agent", PARROTFLOW_PLANNER_TRACE=trace,
        PARROTFLOW_RUNS=root))

    def run(utterance, windows, turns, fake=None):
        agent_turns[:] = turns
        del planner_bodies[:]
        fake = fake or Screen(windows)
        end, fake = runner.run(utterance, "Test", fake=fake, loop=LOOP, recipes=False)
        return end, fake, os.path.join(root, recorded(root)[-1])

    home = panel("Home", ["General", "Settings", "Leave"])
    menu = panel("Home", ["General", "Settings", "Leave", "Mute channel"])
    muted = panel("Home — muted", ["General", "Settings", "Leave", "Unmute channel"])
    end, fake, folder = run(
        "mute this channel", [home, menu, muted],
        [[("act", {"why": "open the settings", "steps": [
            {"do": "click", "id": 2, "value": None}, {"do": "click", "id": 1, "value": None}]})],
         [("done", {"summary": "ok"})]])
    names = recorded(root)
    check("recorder: 50 runs are kept, the oldest go, and other folders stay",
          len(names) == 50 and names[0] == "2020-01-01T00-00-06.000-old"
          and os.path.isdir(os.path.join(root, "not-a-run")), (len(names), names[:2]))
    info = read_json(folder, "run.json")
    check("recorder: run.json holds the request, the settings and how it ended",
          info["request"] == "mute this channel" and info["app"] == "Test"
          and info["kind"] == "agent" and info["model"] == "test-model"
          and info["settings"]["max_steps"] == 15 and info["end"] == "done"
          and info["outcome"] == "Done" and info["ended"]
          and info["shown"] == ["Clicked Settings", "Clicked General"]
          and (info["calls"], info["steps"], info["trees"]) == (2, 2, 3), info)
    call = read_json(folder, "calls", "01.json")
    tree = read_json(folder, "trees", "01.json")
    settings = next(i for i in tree["snapshot"]["items"] if i["name"] == "Settings")
    check("recorder: a call holds the messages sent, the tool call and why, results, ms, tokens",
          call["messages"][0]["role"] == "system" and "Request: mute this channel"
          in call["messages"][1]["content"] and call["tools"][0]["name"] == "act"
          and call["tools"][0]["args"]["why"] == "open the settings"
          and call["results"][0]["tool"] == "act" and isinstance(call["ms"], int)
          and call["tokens"] == {"in": 100, "out": 20} and call["steps"] == [1, 2],
          {k: call[k] for k in ("tools", "tokens", "steps")})
    check("recorder: a call maps the model's IDs to the items of the tree it saw",
          call["tree"] == 1 and call["ids"]["2"] == settings["id"], (call["tree"], call["ids"]))
    step = read_json(folder, "steps", "01.json")
    check("recorder: a step holds the target, the point, press or click, and the change",
          step["do"] == "click" and step["target"]["name"] == "Settings"
          and step["point"] == [500, 130] and step["pressed"] is True and step["call"] == 1
          and step["tree_before"] == 1 and step["tree_after"] == 2
          and step["change"].get("new") == ["Mute channel"] and "Mute channel" in step["sentence"]
          and [a["do"] for a in step["actions"]] == ["press"] and not step["error"], step)
    keys = read_json(ROOT, "tests", "fixtures", "run-keys.json")
    sys.path.insert(0, os.path.join(ROOT, "built-in", "recipes"))
    import runlog
    written = {"run": list(info), "calls": list(call), "steps": list(step), "trees": list(tree)}
    fields = {kind: list(model.model_fields) for kind, model in (
        ("run", runlog.Run), ("calls", runlog.Call), ("steps", runlog.Step),
        ("trees", runlog.Tree), ("looks", runlog.Look), ("grounds", runlog.Ground))}
    check("recorder: the files keep the keys, in order, that the viewer reads",
          all(written[k] == keys[k] for k in written) and fields == keys, (written, fields))
    snapshots = [s for s in fake.steps if s["do"] == "snapshot"]
    check("recorder: a tree holds every item, and the app is asked for the screenshot",
          len(tree["snapshot"]["items"]) == 3 and tree["snapshot"]["frame"]["w"] == 1000
          and tree["shot"] is None
          and snapshots[0].get("shot") == os.path.join(folder, "shots", "01.jpg"),
          (tree.get("shot"), snapshots[0].get("shot")))

    lines = [{"text": "Mute channel", "x": 500, "y": 190, "w": 80, "h": 14, "p": 1.0},
             {"text": "Muted until tomorrow", "x": 500, "y": 220, "w": 120, "h": 14, "p": 1.0}]
    end, fake, folder = run(
        "mute this channel", [dict(home, seen=[]), dict(menu, seen=lines), dict(muted, seen=lines)],
        [[act({"do": "click", "id": 2})], [("done", {"summary": "ok"})]])
    kept = read_json(folder, "trees", "02.json")
    step = read_json(folder, "steps", "01.json")
    check("recorder: a tree stores every seen line and the time to read them, a step its blocks",
          kept["seen"] == lines and kept["seen_ms"] == 40
          and read_json(folder, "trees", "01.json")["seen"] == []
          and [l["text"] for b in step["change"]["seen"] for l in b["lines"]]
          == ["Muted until tomorrow"], (kept, step["change"]))

    end, fake, folder = run(
        "mute this channel", [home, menu, muted],
        [[("write_plan", {"items": [{"content": f"Mute with {PLANNER_KEY}",
                                     "status": "in_progress"}]})],
         [act({"do": "click", "id": 2})],
         [("write_plan", {"items": [{"content": "Mute", "status": "completed"}]})],
         [("done", {"summary": "ok"})]])
    calls = [read_json(folder, "calls", f"{n:02d}.json") for n in (1, 2, 3)]
    check("recorder: each agent call holds the plan as it stood after the call",
          calls[0]["plan"] == [{"content": "Mute with [key]", "status": "in_progress"}]
          and calls[1]["plan"] == calls[0]["plan"]
          and calls[2]["plan"] == [{"content": "Mute", "status": "completed"}]
          and "<plan-reminder>" in json.dumps(calls[1]["messages"]), [c["plan"] for c in calls])

    end, fake, folder = run(
        f"mute {PLANNER_KEY} channel", [home, menu, muted],
        [[act({"do": "click", "id": 2})], [("done", {"summary": PLANNER_KEY})]])
    leaked = [os.path.join(dirpath, name) for dirpath, _, files in os.walk(root) for name in files
              if PLANNER_KEY in name or PLANNER_KEY in open(os.path.join(dirpath, name),
                                                            encoding="utf-8").read()]
    check("recorder: the key is in no recorded file and no folder name",
          end["end"] == "done" and not leaked and PLANNER_KEY not in folder
          and "[key]" in read_json(folder, "run.json")["request"], (leaked, folder))

    end, fake, folder = run(
        "write to Peter", [draft("")] * 4,
        [[act({"do": "type", "id": 1, "value": "Peter Zarkovic"})], [("done", {"summary": "no"})]])
    step = read_json(folder, "steps", "01.json")
    check("recorder: a guard's question and its answer are in the step",
          step["asked"] and step["asked"][0]["question"].startswith("Type “Peter Zarkovic”")
          and step["asked"][0]["via"] == "timeout" and "not said" in step["error"]
          and step["actions"] == [], step)

    end, fake, folder = run(
        "mute this channel", [home, menu, muted],
        [[act({"do": "click", "id": 2}, {"do": "click", "id": 1})], [("done", {"summary": "ok"})]],
        fake=Vanishing([home, menu, muted], lambda: os.path.join(root, recorded(root)[-1])))
    said = [line for line in fake.logs if line.startswith("recorder:")]
    check("recorder: a write that fails is logged once, and the run goes on",
          end["end"] == "done" and end["loop"]["shown"] == ["Clicked Settings", "Clicked General"]
          and len(said) == 1, (end, said))
    runner.process.stdin.close()
    runner.process.wait(timeout=5)

    blocked = os.path.join(tempfile.mkdtemp(), "a-file")
    open(blocked, "w").close()
    runner = Runner(url, user, extra=planner_env(
        plans_url, PARROTFLOW_PLANNER_LOOP="agent", PARROTFLOW_PLANNER_TRACE=trace,
        PARROTFLOW_RUNS=blocked))
    agent_turns[:] = [[act({"do": "click", "id": 2})], [("done", {"summary": "ok"})]]
    end, fake = runner.run("mute this channel", "Test", fake=Screen([home, menu, muted]),
                           loop=LOOP, recipes=False)
    said = [line for line in fake.logs if line.startswith("recorder:")]
    check("recorder: a folder that cannot be made is logged once, and the run goes on",
          end["end"] == "done" and len(said) == 1
          and not any(s.get("shot", "").startswith(blocked) for s in fake.steps
                      if s["do"] == "snapshot"), (end, said))
    runner.process.stdin.close()
    runner.process.wait(timeout=5)

    root = tempfile.mkdtemp()
    runner = Runner(url, user, extra=planner_env(plans_url, PARROTFLOW_RUNS=root))
    planner_plans[:] = [[{"do": "click", "target": "Settings"}, {"do": "pick", "target": "Mute channel"}]]
    end, fake = runner.run("mute this channel", "Test", fake=Screen([home, menu, muted]),
                           loop=LOOP, recipes=False)
    folder = os.path.join(root, recorded(root)[-1])
    info = read_json(folder, "run.json")
    call = read_json(folder, "calls", "01.json")
    step = read_json(folder, "steps", "02.json")
    check("recorder: the plan path records its call, its steps and its trees",
          end["end"] == "done" and info["kind"] == "plan" and call["kind"] == "plan"
          and '"Settings"' in call["reply"] and step["target"]["name"] == "Mute channel"
          and (info["calls"], info["steps"], info["trees"]) == (1, 2, 3), (info, step))
    runner.process.stdin.close()
    runner.process.wait(timeout=5)


INSTALL = "pydantic openai 'pydantic-ai-slim[openai,typesafe]' pydantic-ai-harness"


def missing_checks(url, user):
    """A runner whose python3 has no pydantic, no openai, or no Pydantic AI."""
    stub = tempfile.mkdtemp()
    with open(os.path.join(stub, "pydantic.py"), "w", encoding="utf-8") as handle:
        handle.write("raise ModuleNotFoundError(\"No module named 'pydantic'\", name='pydantic')\n")
    runner = Runner(url, user, extra={"PYTHONPATH": stub})
    end, fake = runner.run("mute this channel", "Test", fake=Screen([window(1)]), recipes=False)
    needs = ("the action runner needs pydantic: python3 -m pip install " + INSTALL)
    check("no pydantic: the runner still starts, and each action ends with how to install it",
          end == {"end": "failed", "ok": False} and fake.lines == [f"✗ {needs}"]
          and runner.process.poll() is None, (end, fake.lines))
    runner.process.stdin.close()
    runner.process.wait(timeout=5)

    stub = tempfile.mkdtemp()
    with open(os.path.join(stub, "openai.py"), "w", encoding="utf-8") as handle:
        handle.write("raise ModuleNotFoundError(\"No module named 'openai'\", name='openai')\n")
    runner = Runner(url, user, extra={"PYTHONPATH": stub})
    end, fake = runner.run("mute this channel", "Test", fake=Screen([window(1)]), recipes=False)
    needs = ("the action runner needs openai: python3 -m pip install " + INSTALL)
    check("no openai: the runner still starts, and each action ends with how to install it",
          end == {"end": "failed", "ok": False} and fake.lines == [f"✗ {needs}"]
          and runner.process.poll() is None, (end, fake.lines))
    runner.process.stdin.close()
    runner.process.wait(timeout=5)

    stub = tempfile.mkdtemp()
    os.makedirs(os.path.join(stub, "pydantic_ai_harness"))
    with open(os.path.join(stub, "pydantic_ai_harness", "__init__.py"), "w",
              encoding="utf-8") as handle:
        handle.write("raise ModuleNotFoundError(\"No module named 'pydantic_ai_harness'\", "
                     "name='pydantic_ai_harness')\n")
    runner = Runner(url, user, extra={"PYTHONPATH": stub})
    end, fake = runner.run("mute this channel", "Test", fake=Screen([window(1)]), recipes=False)
    needs = "the action runner needs pydantic-ai-harness: python3 -m pip install " + INSTALL
    check("no pydantic-ai-harness: the runner still starts, and each action ends with how to "
          "install it",
          end == {"end": "failed", "ok": False} and fake.lines == [f"✗ {needs}"]
          and runner.process.poll() is None, (end, fake.lines))
    runner.process.stdin.close()
    runner.process.wait(timeout=5)


class SlowPlanner(http.server.BaseHTTPRequestHandler):
    """Answers every call too late, and counts them."""
    calls = 0

    def do_POST(self):
        SlowPlanner.calls += 1
        self.rfile.read(int(self.headers["Content-Length"]))
        import time
        time.sleep(1.0)
        try:
            self.send_response(500)
            self.end_headers()
        except OSError:
            pass

    def log_message(self, *args):
        pass


def client_checks(plans_url):
    """`planner.Planner` in this process, against the fake planner."""
    sys.path.insert(0, os.path.join(ROOT, "built-in", "recipes"))
    import planner
    check("client: the base URL is the endpoint without /chat/completions",
          planner.base_url("https://api.openai.com/v1/chat/completions") == "https://api.openai.com/v1"
          and planner.base_url("http://127.0.0.1:9/v1/") == "http://127.0.0.1:9/v1",
          planner.base_url("https://api.openai.com/v1/chat/completions"))

    planner_plans[:] = [500, 500, 500]
    del planner_bodies[:]
    client = planner.Planner(f"{plans_url}/v1/chat/completions", PLANNER_KEY, "test-model")
    try:
        client.chat([{"role": "user", "content": "hi"}])
        said = ""
    except planner.Failure as failure:
        said = str(failure)
    check("client: a 500 on every try fails after three, and the body does not leak the key",
          len(planner_bodies) == 3 and said.startswith("The planner answered 500: fake 500 for …")
          and PLANNER_KEY not in said, (len(planner_bodies), said))

    slow = http.server.ThreadingHTTPServer(("127.0.0.1", 0), SlowPlanner)
    threading.Thread(target=slow.serve_forever, daemon=True).start()
    client = planner.Planner(f"http://127.0.0.1:{slow.server_address[1]}/v1/chat/completions",
                             PLANNER_KEY, "test-model", timeout=0.3)
    try:
        client.chat([{"role": "user", "content": "hi"}])
        said = ""
    except planner.Failure as failure:
        said = str(failure)
    slow.shutdown()
    check("client: a timeout on every try says how many tries",
          said == "The planner timed out after 3 tries." and SlowPlanner.calls == 3,
          (said, SlowPlanner.calls))


failures = []


FAKE_HELPER = r"""
import json, os, sys
print(json.dumps({"up": os.getpid(), "load_ms": 5}), flush=True)
for line in sys.stdin:
    asked = json.loads(line)
    with open(os.environ["FAKE_GROUND_LOG"], "a") as handle:
        handle.write(line)
    crop = asked["crop"]
    if "Nobody" in asked["text"]:
        print(json.dumps({"abstain": True, "ms": 1}), flush=True)
    else:
        print(json.dumps({"x": crop["w"] / 2 + 10, "y": crop["h"] / 2, "ms": 1}), flush=True)
"""


class Pictured(Screen):
    """Writes a white picture of the window where the runner asks for one."""

    def reply(self, step):
        reply = super().reply(step)
        if step["do"] == "snapshot" and step.get("shot") and "snapshot" in reply:
            from PIL import Image
            Image.new("RGB", (1000, 800), "white").save(step["shot"], "JPEG")
            reply["shot"] = {"file": step["shot"], "frame": {"x": 0, "y": 0, "w": 1000, "h": 800},
                             "scale": 1, "w": 1000, "h": 800}
        return reply


def pictures(body):
    """The image parts of a request, as (detail, message index). The agent
    sends Responses parts; grounding sends chat completions parts."""
    return [(part.get("detail") or part["image_url"].get("detail"), n)
            for n, m in enumerate(messages(body)) if isinstance(m.get("content"), list)
            for part in m["content"] if part.get("type") in ("input_image", "image_url")]


def grounding_checks(url, user, plans_url):
    """`ground` and the stuck turn's picture, with a fake TinyClick helper."""
    folder = tempfile.mkdtemp()
    helper = os.path.join(folder, "fake_ground.py")
    with open(helper, "w") as handle:
        handle.write(FAKE_HELPER)
    asked = os.path.join(folder, "asked.jsonl")
    root = tempfile.mkdtemp()

    def start(method, python=sys.executable, runs=""):
        return Runner(url, user, extra=planner_env(
            plans_url, PARROTFLOW_PLANNER_LOOP="agent",
            PARROTFLOW_PLANNER_TRACE=os.path.join(folder, "agent.jsonl"),
            PARROTFLOW_GROUND=method, PARROTFLOW_GROUND_PYTHON=python,
            PARROTFLOW_GROUND_SERVER=helper, PARROTFLOW_GROUND_MODEL=folder,
            FAKE_GROUND_LOG=asked, PARROTFLOW_RUNS=runs))

    def run(runner, windows, turns, override=None):
        agent_turns[:] = turns
        del planner_bodies[:]
        del luna_bodies[:]
        fake = Pictured(windows, override)
        end, fake = runner.run("write to Peter", "Test", fake=fake, loop=LOOP, recipes=False)
        return end, fake, end.get("loop") or {}

    def results(n):
        return [m["content"] for m in messages(planner_bodies[n]) if m["role"] == "tool"] \
            if len(planner_bodies) > n else []

    def names(n):
        return [t["name"] for t in planner_bodies[n]["tools"]]

    tiny = start("tinyclick", runs=root)
    end, fake, report = run(tiny, [draft("")] * 4, [
        [("ground", {"description": "Peter Holm", "id": 1, "side": "below"})],
        [act({"do": "click", "id": 101})], [("done", {"summary": "ok"})]])
    schema_checks(planner_bodies[0]["tools"])
    got = results(1)[-1:]
    clicked = [s for s in fake.steps if s["do"] == "click_at"]
    with open(asked) as handle:
        crops = [json.loads(line)["crop"] for line in handle]
    check("ground: the tool is offered, and says how to use it, when the setting is on",
          "ground" in names(0) and "call `ground`" in json.dumps(messages(planner_bodies[0])),
          [(m["role"], text(m)[-120:]) for m in messages(planner_bodies[0])])
    check("ground: a point comes back as an ID, and clicking it sends click_at at that point",
          got == ['[101] point for "Peter Holm" (from pixels)']
          and [(s["x"], s["y"], s["name"]) for s in clicked] == [(470, 310, "Peter Holm")]
          and end["end"] == "done", (got, clicked, fake.did()))
    check("ground: the crop is below the field, 600×400 at most, in the picture's pixels",
          crops == [{"x": 160, "y": 110, "w": 600, "h": 400}], crops)
    folder_of_run = os.path.join(root, recorded(root)[-1])
    grounded = read_json(folder_of_run, "grounds", "01.json")
    check("ground: the call is recorded with its method, crop, description and point",
          grounded["method"] == "tinyclick" and grounded["point"] == [470, 310]
          and grounded["crop"] == crops[0] and grounded["description"] == "Peter Holm"
          and grounded["call"] == 1, grounded)

    end, fake, report = run(tiny, [draft("")] * 4, [
        [("ground", {"description": "Peter Holm", "id": 1, "side": "below"})],
        [("ground", {"description": "the name Peter Holm", "id": 1, "side": "below"})],
        [("done", {"summary": "ok"})]])
    got = results(2)[-1] if len(results(2)) else ""
    check("ground: the same point asked for again comes back as the ID it has",
          got.startswith("[101] already points there."), got)

    end, fake, report = run(tiny, [draft("")] * 3, [
        [("ground", {"description": "Nobody Here", "id": 1, "side": "below"})],
        [("done", {"summary": "ok"})]])
    got = results(1)[-1] if results(1) else ""
    check("ground: an abstain comes back as not found",
          got.startswith('Not found: no "Nobody Here" below [1].'), got)

    home = panel("Home", ["General", "Settings", "Leave"])
    end, fake, report = run(tiny, [home] * 6, [
        [act({"do": "click", "id": 2})], [act({"do": "click", "id": 2})], [("read", {})],
        [("done", {"summary": "ok"})]])
    counts = [len(pictures(body)) for body in planner_bodies]
    detail = [d for body in planner_bodies for d, _ in pictures(body)]
    check("picture: every request after the first step has one, of the last target, at low",
          counts == [0, 1, 1, 1] and set(detail) == {"low"}
          and 'The picture: the screen around "Settings"' in text(messages(planner_bodies[2])[-1])
          and "call `ground`" in text(messages(planner_bodies[2])[-1]), (counts, detail))
    call = read_json(os.path.join(root, recorded(root)[-1]), "calls", "03.json")
    kept = json.dumps(call["messages"])
    check("picture: the recorded request names the picture's file, not its bytes, and only "
          "the newest",
          "base64" not in kept and "[picture: grounds/02.jpg]" in kept
          and kept.count("[picture:") == 1
          and os.path.exists(os.path.join(root, recorded(root)[-1], "grounds", "02.jpg")),
          kept[-300:])

    end, fake, report = run(tiny, [home] * 4, [
        [act({"do": "click", "id": 2})], [("stuck", {"why": "no idea"})]])
    check("stuck: the first `stuck` asks the user",
          len(planner_bodies) == 2 and [s["do"] for s in fake.steps].count("ask") == 1
          and report["stopped"] == "Stuck — no idea", report)

    focused = draft("")
    focused["items"][0]["state"] = ["focused"]
    end, fake, report = run(tiny, [focused] * 2, [[("done", {"summary": "ok"})]])
    first = text(messages(planner_bodies[0])[-1]) if planner_bodies else ""
    check("picture: the first request shows the area around the focused field",
          len(pictures(planner_bodies[0])) == 1 and 'the screen around "To"' in first, first)
    tiny.process.stdin.close()
    tiny.process.wait(timeout=10)

    missing = start("tinyclick", python=os.path.join(folder, "no-such-python"))
    luna_points[:] = [{"found": True, "x": 256, "y": 170}]
    end, fake, report = run(missing, [draft("")] * 3, [
        [("ground", {"description": "Peter Holm", "id": 1, "side": "below"})],
        [act({"do": "click", "id": 101})], [("done", {"summary": "ok"})]])
    sent = pictures(luna_bodies[0]) if luna_bodies else []
    clicked = [(s["x"], s["y"]) for s in fake.steps if s["do"] == "click_at"]
    check("ground: without TinyClick set up it asks the planner's model, and says so once",
          results(1)[-1:] == ['[101] point for "Peter Holm" (from pixels)']
          and sent == [("low", 0)] and clicked == [(460.0, 309.4)]
          and sum("TinyClick is not set up" in line for line in fake.logs) == 1,
          (results(1), sent, clicked, fake.logs))
    missing.process.stdin.close()
    missing.process.wait(timeout=10)

    off = start("off")
    end, fake, report = run(off, [home] * 6, [
        [act({"do": "click", "id": 2})], [act({"do": "click", "id": 2})], [("read", {})],
        [("done", {"summary": "ok"})]])
    check("ground off: no `ground` tool and no word of it, and the picture still goes",
          "ground" not in names(0) and "ground" not in json.dumps(planner_bodies[2])
          and len(pictures(planner_bodies[2])) == 1 and len(planner_bodies) == 4,
          (names(0), len(planner_bodies)))
    off.process.stdin.close()
    off.process.wait(timeout=10)


def surprise_checks(url, user, plans_url):
    """`expect`, the loss check, the picture after a surprise and the ask after
    a second surprise, with a picture helper and a recording."""
    folder = tempfile.mkdtemp()
    helper = os.path.join(folder, "fake_ground.py")
    with open(helper, "w") as handle:
        handle.write(FAKE_HELPER)
    root, trace = tempfile.mkdtemp(), os.path.join(folder, "agent.jsonl")
    runner = Runner(url, user, extra=planner_env(
        plans_url, PARROTFLOW_PLANNER_LOOP="agent", PARROTFLOW_PLANNER_TRACE=trace,
        PARROTFLOW_PLANNER_REASONING="low", PARROTFLOW_GROUND="tinyclick", PARROTFLOW_GROUND_PYTHON=sys.executable,
        PARROTFLOW_GROUND_SERVER=helper, PARROTFLOW_GROUND_MODEL=folder,
        FAKE_GROUND_LOG=os.path.join(folder, "asked.jsonl"), PARROTFLOW_RUNS=root))

    def run(windows, turns, verdicts=(), override=None):
        agent_turns[:] = turns
        visible_answers[:] = verdicts
        del planner_bodies[:]
        del visible_bodies[:]
        fake = Pictured(windows, override)
        end, fake = runner.run("write to Alex and Antonio", "Test", fake=fake, loop=LOOP,
                               recipes=False)
        return end, fake, end.get("loop") or {}

    def result(n):
        tools = [m["content"] for m in messages(planner_bodies[n]) if m["role"] == "tool"] \
            if len(planner_bodies) > n else []
        return tools[-1] if tools else ""

    def efforts():
        return [((b.get("reasoning") or {}).get("effort"), len(pictures(b)))
                for b in planner_bodies]

    def plan(*tasks):
        return ("write_plan", {"items": [{"id": str(n), "content": content, "status": status}
                                         for n, (content, status) in enumerate(tasks)]})
    finish = [[plan(("Add Alex", "completed"))], [("done", {"summary": "ok"})]]
    expect = "To holds Alex"
    typed = act({"do": "type", "id": 1, "value": "Alex", "expect": expect})

    end, fake, report = run([draft(""), draft(""), draft("Alex")],
                            [[plan(("Add Alex", "in_progress"))], [typed], [("read", {})]] + finish,
                            [0.9])
    step = read_json(root, recorded(root)[-1], "steps", "01.json")
    sent = visible_bodies[0] if visible_bodies else {}
    check("expect: a true expect says nothing",
          "not what happened" not in result(2)
          and end["end"] == "done", (result(2), efforts()))
    check("expect: Jev is asked about it with the fields' values, and the step records it",
          sent.get("questions", {}).get("visible", {}).get("instructions")
          == f"Is this true now: {expect}?"
          and sent["state"]["fields"] == {"To": "Alex"}
          and "changed_by_the_last_step" in sent["state"]
          and step["expect"] == expect and step["expect_p"] == 0.9
          and step["ms"] >= step["expect_ms"] >= 0, (sent, step))

    end, fake, report = run([draft(""), draft(""), draft("Alex")],
                            [[plan(("Add Alex", "in_progress"))], [typed], [("read", {})]] + finish,
                            [0.2])
    got = result(2)
    step = read_json(root, recorded(root)[-1], "steps", "01.json")
    check("expect: a false expect is recorded and says nothing to the model",
          "not what happened" not in got and "Stopped" not in got
          and step["expect_p"] == 0.2, (got, step))
    check("reasoning: every request reasons at low; each after the typing has one picture",
          efforts() == [("low", 0), ("low", 0)] + [("low", 1)] * (len(efforts()) - 2), efforts())

    slack = "\u00a0 Alex Moreau \u00a0 \u00a0"
    end, fake, report = run([draft(slack), draft(slack), draft("\u00a0 Antonio \u00a0")],
                            [[plan(("Add Antonio", "in_progress"))],
                             [act({"do": "type", "id": 1, "value": "Antonio"})], [("read", {})],
                             [plan(("Add Antonio", "completed"))], [("done", {"summary": "ok"})]])
    got = result(2)
    step = read_json(root, recorded(root)[-1], "steps", "01.json")
    check("lost: a step that took a name out of its field says so",
          'this step removed "Alex Moreau" from "To"' in got
          and step["lost"] == '"Alex Moreau"', (got, efforts(), step.get("lost")))
    end, fake, report = run([draft("Alex"), draft("Alex"), draft("Alex, Antonio")],
                            [[plan(("Add Antonio", "in_progress"))],
                             [act({"do": "type", "id": 1, "value": "Antonio"})], [("read", {})],
                             [plan(("Add Antonio", "completed"))], [("done", {"summary": "ok"})]])
    check("lost: a name added after another loses nothing",
          "removed" not in result(2), result(2))

    both = "To holds Alex Moreau and Antonio"
    end, fake, report = run(
        [draft(slack), draft("\u00a0 Antonio \u00a0"), draft("\u00a0 Antonio \u00a0"),
         draft("\u00a0 Antonio Alex \u00a0")] + [draft("\u00a0 Antonio Alex \u00a0")] * 4,
        [[plan(("Add both", "in_progress"))],
         [act({"do": "type", "id": 1, "value": "Antonio"})],
         [act({"do": "type", "id": 1, "value": "Alex", "expect": both})],
         [plan(("Add both", "completed"))], [("done", {"summary": "ok"})]],
        [0.1])
    check("surprises: two on one task do not make anyone ask the user",
          not [s for s in fake.steps if s["do"] == "ask"] and "Call `ask`" not in result(3)
          and end["end"] == "done", (result(3), fake.did()))

    runner.process.stdin.close()
    runner.process.wait(timeout=10)
    kept = ""
    for base, _, files in os.walk(root):
        for name in files:
            if name.endswith(".json"):
                with open(os.path.join(base, name), encoding="utf-8") as handle:
                    kept += handle.read()
    with open(trace, encoding="utf-8") as handle:
        kept += handle.read()
    check("surprise: neither key is in the trace or the recordings",
          kept and PLANNER_KEY not in kept and "test-key" not in kept)


def within(runner, seconds=10):
    """The runner's next line, or None after `seconds`. A reader left waiting
    takes the next line, so only a last read may time out; it ends when the
    runner does."""
    got = []
    reader = threading.Thread(target=lambda: got.append(runner.process.stdout.readline()),
                              daemon=True)
    reader.start()
    reader.join(seconds)
    return json.loads(got[0]) if got and got[0] else None


def waited(test, seconds=5):
    import time
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if test():
            return True
        time.sleep(0.05)
    return test()


def review_checks(url, user, plans_url):
    """The review after a run, `review.py`: the digest, the rules, the
    proposals, and nothing written without Keep."""
    root = tempfile.mkdtemp()
    config = tempfile.mkdtemp()
    memories = os.path.join(config, "memories")
    os.makedirs(os.path.join(memories, "test"))
    existing = os.path.join(memories, "test", "open-settings.md")
    before = "---\napp: Test\ngoal: open the settings\nwhen: Test is open\n---\nClick Settings.\n"
    with open(existing, "w", encoding="utf-8") as handle:
        handle.write(before)
    trace = os.path.join(tempfile.mkdtemp(), "agent.jsonl")
    runner = Runner(url, user, extra=planner_env(
        plans_url, PARROTFLOW_PLANNER_LOOP="agent", PARROTFLOW_PLANNER_TRACE=trace,
        PARROTFLOW_RUNS=root, PARROTFLOW_APP_NOTES=os.path.join(config, "apps")))

    home = panel("Home", ["General", "Settings", "Leave"])
    menu = panel("Home", ["General", "Settings", "Leave", "Mute channel"])
    muted = panel("Home — muted", ["General", "Settings", "Leave", "Unmute channel"])
    updated = ("---\napp: Test\ngoal: open the settings\nwhen: Test is open\n"
               "seen: 2026-09-24 (worked)\n---\nClick Settings. The menu shows Mute channel.\n")
    alex = "---\nkind: person\nseen: 2026-09-24 (the user chose)\n---\nAlex is Alex Moreau.\n"
    answer = {
        "next_time": "Click Settings first, then Mute channel.",
        "learned": ["Settings opens a menu with Mute channel."],
        "went_wrong": ["General failed; Settings worked."],
        "proposals": [
            {"file": "test/open-settings.md", "content": updated, "why": "says what the menu shows"},
            {"file": "people/alex.md", "content": alex, "why": "which Alex"},
            {"file": "test/mute.md", "why": "a skill",
             "content": "---\ngoal: mute\nparams: []\nsteps:\n  - click the settings | looks muted\n"
                        "---\nMute.\n"},
            {"file": "test/leave.md", "why": "a skill",
             "content": "---\ngoal: leave\nparams: []\nsteps:\n  - click Button \"Leave\" | "
                        "appears \"Rejoin\"\n---\nLeave.\n"},
            {"file": "../evil.md", "content": "---\ngoal: x\n---\nx\n", "why": "outside"}]}

    def run(fake=None):
        agent_turns[:] = [
            [act({"do": "click", "id": 2}, {"do": "click", "id": 1})],
            [("ask", {"question": "Which Alex?", "options": ["Alex Moreau", "Alex Other"]})],
            [("done", {"summary": "ok"})]]
        review_turns[:] = [answer]
        del review_bodies[:]
        fake = fake or Screen([home, menu, muted], {
            ("press", 2): {"error": "no such element"},
            ("ask", 1): {"answer": "Alex Moreau", "via": "option"}})
        end, fake = runner.run("mute this channel for alex", "Test", fake=fake, loop=LOOP,
                               recipes=False, review=True)
        return end, os.path.join(root, recorded(root)[-1])

    end, folder = run()
    line = within(runner)
    check("review: the end names the review, and the review comes after it",
          end.get("review") == os.path.basename(folder) and line is not None
          and line.get("do") == "review" and line.get("id") == end["review"], (end, line))
    line = line or {}
    body = review_bodies[0] if review_bodies else {}
    sent = "".join(text(m) for m in messages(body)[1:]) if body else ""
    rules = ["Never record a detour", "Be specific and actionable",
             "Prefer updating an existing file", "Facts about people come only from the user's answers",
             "Add a `steps:` block only when those exact gestures succeeded in this run",
             "No proposal only when the run taught nothing", "Keep files short"]
    check("review: the prompt says the rules for proposals",
          all(rule in (body.get("instructions") or "") for rule in rules),
          [r for r in rules if r not in (body.get("instructions") or "")])
    check("review: one call, with high reasoning by default",
          len(review_bodies) == 1 and (body.get("reasoning") or {}).get("effort") == "high",
          body.get("reasoning"))
    want = ["Request: mute this channel for alex", "App folder: test",
            "act click Button \"Settings\"; click Button \"General\"", "step 1: click “Settings”",
            "Failures:", "no such element", "then: ask", "The user's answers:",
            "Which Alex? — The user answered: Alex Moreau", "Time:", "model calls",
            "=== test/open-settings.md", "Click Settings."]
    check("review: the digest holds the calls, the steps, the failure, the answers, the time "
          "and the memory files", all(w in sent for w in want),
          ([w for w in want if w not in sent], sent[:3000]))
    check("review: the digest has no screen beyond a few lines",
          sent.count("Button \"Leave\"") <= 1 and len(sent) < 4000, len(sent))
    report = line.get("report") or {}
    check("review: the report has the model's three parts and the timings from code",
          report.get("next_time") == answer["next_time"]
          and report.get("learned") == answer["learned"]
          and report.get("went_wrong") == answer["went_wrong"]
          and any("model calls" in t for t in report.get("time") or ())
          and any("steps" in t and "slowest" in t for t in report.get("time") or ()), report)
    proposals = line.get("proposals") or []
    check("review: proposals parsed; a new file and an update say which",
          [(p["file"], p["exists"]) for p in proposals]
          == [("test/open-settings.md", True), ("people/alex.md", False)]
          and proposals[0]["content"] == updated and proposals[1]["why"] == "which Alex",
          proposals)
    record = read_json(folder, "review.json") if os.path.exists(os.path.join(folder, "review.json")) else {}
    dropped = {d["file"]: d["why"] for d in record.get("dropped") or ()}
    check("review: steps that skills.parse cannot read, a click that did not succeed, and a "
          "file outside the memories are dropped",
          dropped.get("test/mute.md", "").startswith("steps: cannot do")
          and "Leave" in dropped.get("test/leave.md", "") and "../evil.md" in dropped
          and record.get("shown") is True and record.get("kept") is None, record)
    calls = sorted(os.listdir(os.path.join(folder, "calls")))
    call = read_json(folder, "calls", calls[-1])
    check("review: the call is recorded with the run's calls",
          call["kind"] == "review" and call["tools"][0]["name"] == "review"
          and call["tools"][0]["args"]["next_time"] == answer["next_time"]
          and read_json(folder, "run.json")["calls"] == len(calls) == 4,
          (calls, call.get("kind"), call.get("tools")))

    runner.send({"review": line.get("id"), "kept": [], "via": "closed"})
    check("review: closed without Keep, nothing is written",
          waited(lambda: read_json(folder, "review.json").get("via") == "closed")
          and open(existing, encoding="utf-8").read() == before
          and not os.path.exists(os.path.join(memories, "people", "alex.md")),
          read_json(folder, "review.json").get("via"))

    end, folder = run()
    line = within(runner) or {}
    runner.send({"review": line.get("id"), "kept": ["people/alex.md", "test/mute.md"],
                 "via": "answered"})
    written = os.path.join(memories, "people", "alex.md")
    check("review: Keep writes that file, and a folder is made for it",
          waited(lambda: os.path.exists(written))
          and open(written, encoding="utf-8").read() == alex
          and open(existing, encoding="utf-8").read() == before
          and not os.path.exists(os.path.join(memories, "test", "mute.md"))
          and read_json(folder, "review.json").get("kept") == ["people/alex.md"],
          read_json(folder, "review.json").get("kept"))

    end, folder = run()
    line = within(runner) or {}
    agent_turns[:] = [[("done", {"summary": "ok"})]]
    runner.run("mute this channel", "Test", fake=Screen([home]), loop=LOOP, recipes=False)
    check("review: the next request drops a review nobody answered",
          line.get("do") == "review"
          and read_json(folder, "review.json").get("via") == "superseded"
          and read_json(folder, "review.json").get("kept") == [],
          read_json(folder, "review.json").get("via"))

    agent_turns[:] = [[("done", {"summary": "ok"})]]
    end, _ = runner.run("mute this channel", "Test", fake=Screen([home]), loop=LOOP,
                        recipes=False)
    check("review: none unless the app asks for it", "review" not in end
          and within(runner, 1) is None, end)
    runner.process.stdin.close()
    runner.process.wait(timeout=5)


def check(name, condition, detail=""):
    print(("ok    " if condition else "FAIL  ") + name + ("" if condition else f"  {detail}"))
    if not condition:
        failures.append(name)


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeJev)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/v1/systemone"
    user = tempfile.mkdtemp()
    os.makedirs(os.path.join(user, "test"))
    with open(os.path.join(user, "test", "message_people.py"), "w") as handle:
        handle.write("from parrotflow import recipe\n\n\n"
                     "@recipe(app='Test', says='write an email to one or more people')\n"
                     "def message_people(app, ask):\n"
                     "    try:\n        app.stop('first')\n    except Exception:\n        pass\n")
    # A file that fails to import must not take the others down.
    with open(os.path.join(user, "test", "broken.py"), "w") as handle:
        handle.write("from parrotflow import recipe\nraise RuntimeError('broken on purpose')\n")
    runner = Runner(url, user)

    runner.send({"decide": "open Antonio", "snapshot": dict(window(1), id=0, app="Slack"),
                 "mode": "look"})
    said = []
    while True:
        message = runner.read()
        said.append(message.get("do") or message.get("end"))
        if "end" in message:
            break
        runner.send({"ok": True})
    check("progress: a decision sends none, even as the runner's first request",
          said[-1] == "decided" and "progress" not in said, said)

    end, fake = runner.run("write an email to Peter and Antonio", "Microsoft Outlook")
    verbs = [s["do"] for s in fake.steps if s["do"] not in ("say", "log")]
    want = (["begin", "key"]
            + ["lookup_field", "mark", "type", "rows", "click", "wait", "snapshot"] * 2
            + ["find", "ready"])
    check("outlook: the steps asked for", verbs == want, verbs)
    check("outlook: ended ready", end == {"end": "ready", "ok": True}, end)
    shown = runner.progress
    check("progress: a recipe has a title, what it says, no plan, and how it ended",
          shown[0]["title"] == "write an email to Peter and Antonio"
          and all(p["plan"] is None for p in shown)
          and any(p["activity"] == "step ⌘N" for p in shown)
          and shown[-1]["outcome"] == "Ready — dictate", [p["activity"] for p in shown])
    typed = [s["text"] for s in fake.steps if s["do"] == "type"]
    check("outlook: typed two letters of each name", typed == ["Pe", "An"], typed)
    clicked = [s["id"] for s in fake.steps if s["do"] == "click"]
    check("outlook: clicked Peter Smith, then Antonio Ruiz", clicked == [11, 12], clicked)
    begin = next(s for s in fake.steps if s["do"] == "begin")
    check("outlook: begin carries the recipe's allows", begin.get("allows") == [], begin)
    want_lines = [
        "recipe     message_people in Microsoft Outlook (1.00)",
        "who        “Peter”, “Antonio”",
        "step       ⌘N",
        "step       Pe → “Peter Smith” of 3 rows (Button), 0.97, after 750 ms",
        "           Peter is in",
        "step       An → “Antonio Ruiz” of 3 rows (Button), 0.97, after 750 ms",
        "           Antonio is in",
        "done       2 of 2 recipients",
    ]
    check("outlook: the lines", fake.lines == want_lines, fake.lines)
    check("outlook: two Jev calls before any step, then one per row list",
          [c[0] for c in jev_calls] == ["recipe", "w0", "pick", "pick"], jev_calls)

    end, fake = runner.run("write an email to Peter and Antonio", "Microsoft Outlook", execute=False)
    check("plan only: no step taken", [s["do"] for s in fake.steps if s["do"] not in ("say", "log")] == [])
    check("plan only: says so", fake.lines[-1] == "(planned only)", fake.lines)
    check("plan only: ended planned", end == {"end": "planned", "ok": True}, end)

    escape = Outlook({("type", 1): {"error": "escape", "said": True}})
    end, fake = runner.run("write an email to Peter and Antonio", "Microsoft Outlook", escape)
    check("escape: ended stopped", end == {"end": "stopped", "ok": False}, end)
    check("escape: no step after it", fake.steps[-1]["do"] == "type", fake.steps[-3:])

    refused = Outlook({("click", 1): {"error": "refused", "said": True}})
    end, fake = runner.run("write an email to Peter and Antonio", "Microsoft Outlook", refused)
    check("refused: ended stopped, nothing more said",
          end["end"] == "stopped" and fake.steps[-1]["do"] == "click", (end, fake.steps[-2:]))

    broken = Outlook({("click", 1): {"error": "no such element"}})
    end, fake = runner.run("write an email to Peter and Antonio", "Microsoft Outlook", broken)
    check("unsaid error: the recipe failed",
          end["end"] == "failed"
          and fake.lines[-1] == "✗ the recipe failed: RuntimeError: no such element",
          (end, fake.lines[-1:]))

    calls = len(jev_calls)
    loop_answers[:] = [loop_answer("none")]
    end, fake = runner.run("click on the Checkout tab", "Microsoft Outlook", fake=Screen([window(1)]))
    check("no fit: the loop takes it",
          end["end"] == "done" and end["loop"]["stopped"] == "Nothing to do on screen"
          and [c[0] for c in jev_calls[calls:]] == ["recipe", "action"], (end, jev_calls[calls:]))
    calls = len(jev_calls)
    loop_answers[:] = [loop_answer("none")]
    end, fake = runner.run("write an email to Peter", "Finder", fake=Screen([window(1)]))
    check("no recipes for the app: the loop, and no recipe question",
          end["end"] == "done" and [c[0] for c in jev_calls[calls:]] == ["action"],
          (end, jev_calls[calls:]))

    calls = len(jev_calls)
    loop_answers[:] = [loop_answer("none")]
    end, fake = runner.run("write an email to Peter", "Microsoft Outlook", bundle="com.other.App",
                           fake=Screen([window(1)]))
    check("a recipe declared by bundle ID is matched by the ID, not the name",
          [c[0] for c in jev_calls[calls:]] == ["action"], (end, jev_calls[calls:]))

    loop_checks(runner)
    seeing_checks(runner)
    change_checks()
    settle_checks()

    end, fake = runner.run("write an email to Peter and Antonio", "Test")
    check("a recipe declared by name, next to a file that fails to import, still runs",
          end["end"] == "stopped", (end, fake.lines))
    check("a user recipe cannot swallow stop", end["end"] == "stopped" and fake.lines[-1] == "✗ first",
          (end, fake.lines))

    end, fake = runner.run("write an email to Peter and Antonio", "Microsoft Outlook")
    check("still serving after all that", end == {"end": "ready", "ok": True}, end)

    runner.process.stdin.close()
    check("exits when the app closes its input", runner.process.wait(timeout=5) == 0)
    check("no planner configured: the planner was never called", planner_bodies == [],
          planner_bodies[:1])

    plans = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakePlanner)
    threading.Thread(target=plans.serve_forever, daemon=True).start()
    printed = os.path.join(tempfile.mkdtemp(), "stderr.txt")
    with open(printed, "w") as stderr:
        planned = Runner(url, user, extra={
            "PARROTFLOW_PLANNER_MODEL": "test-model", "PARROTFLOW_PLANNER_KEY": PLANNER_KEY,
            "PARROTFLOW_PLANNER_URL": f"http://127.0.0.1:{plans.server_address[1]}/v1/chat/completions",
            "PARROTFLOW_PLANNER_REASONING": "none"}, stderr=stderr)
        planner_checks(planned, printed)
    trace = os.path.join(tempfile.mkdtemp(), "agent.jsonl")
    printed = os.path.join(tempfile.mkdtemp(), "stderr.txt")
    with open(printed, "w") as stderr:
        agent = Runner(url, user, extra={
            "PARROTFLOW_PLANNER_MODEL": "test-model", "PARROTFLOW_PLANNER_KEY": PLANNER_KEY,
            "PARROTFLOW_PLANNER_URL": f"http://127.0.0.1:{plans.server_address[1]}/v1/chat/completions",
            "PARROTFLOW_PLANNER_REASONING": "none", "PARROTFLOW_PLANNER_LOOP": "agent",
            "PARROTFLOW_PLANNER_TRACE": trace}, stderr=stderr)
        agent_checks(agent, printed, trace)
    recorder_checks(url, user, f"http://127.0.0.1:{plans.server_address[1]}")
    steer_checks(url, user, f"http://127.0.0.1:{plans.server_address[1]}")
    grounding_checks(url, user, f"http://127.0.0.1:{plans.server_address[1]}")
    surprise_checks(url, user, f"http://127.0.0.1:{plans.server_address[1]}")
    review_checks(url, user, f"http://127.0.0.1:{plans.server_address[1]}")
    client_checks(f"http://127.0.0.1:{plans.server_address[1]}")
    missing_checks(url, user)
    plans.shutdown()
    server.shutdown()
    print(f"\n{'all passed' if not failures else f'{len(failures)} failed'}")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
