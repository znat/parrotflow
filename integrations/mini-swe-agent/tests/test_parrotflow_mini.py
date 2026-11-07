"""The events the plugin sends, through a whole mini run.

Runs on the real mini-swe-agent when it is installed, and else on a stub of
its 2.4.6 control flow. The same expectations pass on both.
"""

from __future__ import annotations

import atexit
import json
import os
import re
import shutil
import socket
import sys
import tempfile
import time
import types
import unittest
from pathlib import Path
from types import SimpleNamespace

SCRATCH = tempfile.mkdtemp()
atexit.register(shutil.rmtree, SCRATCH, True)
# Importing mini creates its config folder and loads the .env there.
os.environ["MSWEA_GLOBAL_CONFIG_DIR"] = os.path.join(SCRATCH, "mini")
os.environ["MSWEA_SILENT_STARTUP"] = "1"
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


def install_stub() -> None:
    class InterruptAgentFlow(Exception):
        def __init__(self, *messages):
            super().__init__()
            self.messages = messages

    class Submitted(InterruptAgentFlow):
        pass

    class UserInterruption(InterruptAgentFlow):
        pass

    class InteractiveAgent:
        def __init__(self, model, env, *, mode="confirm", whitelist_actions=(), confirm_exit=True, **_):
            self.model, self.env, self.messages = model, env, []
            self.config = SimpleNamespace(mode=mode, whitelist_actions=list(whitelist_actions),
                                          confirm_exit=confirm_exit)

        def run(self, task="", **kwargs):
            self.messages = [{"role": "user", "content": task}]
            while self.messages[-1].get("role") != "exit":
                try:
                    message = self.model.query(self.messages)
                    self.messages.append(message)
                    self.execute_actions(message)
                except InterruptAgentFlow as e:
                    self.messages.extend(e.messages)
            return self.messages[-1].get("extra", {})

        def execute_actions(self, message):
            actions = message.get("extra", {}).get("actions", [])
            outputs = []
            try:
                self._ask_confirmation_or_interrupt([a["command"] for a in actions])
                for action in actions:
                    outputs.append(self.env.execute(action))
            except Submitted as e:
                self._check_for_new_task_or_submit(e)
            finally:
                result = self.model.format_observation_messages(message, outputs, {})
                self.messages.extend(result)
            return result

        def _interrupt(self, content, *, itype="UserInterruption"):
            raise UserInterruption({"role": "user", "content": content, "extra": {"interrupt_type": itype}})

        def _check_for_new_task_or_submit(self, e):
            if self.config.confirm_exit:
                typed = self._prompt_and_handle_slash_commands("> ").strip()
                if typed == "/u":
                    self._interrupt("Switched to human mode.")
                elif typed in ("/c", "/y"):
                    return self._check_for_new_task_or_submit(e)
                elif typed:
                    self._interrupt(f"The user added a new task: {typed}", itype="UserNewTask")
            raise e

        def _should_ask_confirmation(self, action):
            return self.config.mode == "confirm" and not any(re.match(r, action)
                                                             for r in self.config.whitelist_actions)

        def _ask_confirmation_or_interrupt(self, commands):
            if not any(self._should_ask_confirmation(c) for c in commands):
                return
            typed = self._prompt_and_handle_slash_commands("> ").strip()
            if typed not in ("", "/y"):
                self._interrupt(f"Commands not executed: {typed}", itype="UserRejection")

    package = types.ModuleType("minisweagent")
    agents = types.ModuleType("minisweagent.agents")
    interactive = types.ModuleType("minisweagent.agents.interactive")
    exceptions = types.ModuleType("minisweagent.exceptions")
    interactive.InteractiveAgent = InteractiveAgent
    exceptions.Submitted = Submitted
    for module in (package, agents, interactive, exceptions):
        sys.modules[module.__name__] = module


try:
    import minisweagent  # noqa: F401
    REAL = True
except ImportError:
    install_stub()
    REAL = False

import parrotflow_mini  # noqa: E402
from minisweagent.exceptions import Submitted  # noqa: E402

SUBMIT = "echo COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"


def said(content: str, *commands: str) -> dict:
    return {"role": "assistant", "content": content, "extra": {"actions": [{"command": c} for c in commands]}}


class Model:
    def __init__(self, *outputs: dict):
        self.outputs = list(outputs)

    def query(self, messages, **kwargs):
        return self.outputs.pop(0)

    def format_message(self, **kwargs):
        return kwargs

    def format_observation_messages(self, message, outputs, template_vars=None):
        return [{"role": "user", "content": json.dumps(output)} for output in outputs]

    def get_template_vars(self, **kwargs):
        return {}

    def serialize(self):
        return {}


class Env:
    config = SimpleNamespace(cwd="/work/shop")

    def __init__(self):
        self.ran: list[str] = []

    def execute(self, action, **kwargs):
        self.ran.append(action["command"])
        if "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT" in action["command"]:
            raise Submitted({"role": "exit", "content": "", "extra": {"exit_status": "Submitted", "submission": ""}})
        return {"returncode": 0, "output": ""}

    def get_template_vars(self, **kwargs):
        return {}

    def serialize(self):
        return {}


class App:
    """ParrotFlow's socket. Sends complete before accept, so it is read in step."""

    def __init__(self):
        self.path = tempfile.mktemp(prefix="pf", dir=SCRATCH)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(self.path)
        self.server.listen(64)
        self.server.setblocking(False)
        self.raw: list[bytes] = []

    def received(self) -> list[bytes]:
        while True:
            try:
                conn, _ = self.server.accept()
            except BlockingIOError:
                return self.raw
            conn.settimeout(1)
            data = b""
            while chunk := conn.recv(65536):
                data += chunk
            conn.close()
            self.raw.append(data)

    def events(self) -> list[tuple]:
        """Each event as (name, the field that matters)."""
        out = []
        for data in self.received():
            event = json.loads(data.split(b"\n", 2)[2])
            name = event["hook_event_name"]
            if name == "UserPromptSubmit":
                out.append((name, event["prompt"]))
            elif name == "PreToolUse":
                out.append((name, event["tool_input"]["command"], event["tool_input"]["description"]))
            elif name == "PermissionRequest":
                out.append((name, event["tool_input"]["command"]))
            else:
                out.append((name, event["last_assistant_message"]))
        return out

    def close(self):
        self.server.close()
        os.unlink(self.path)


class PluginTest(unittest.TestCase):
    def setUp(self):
        self.app = App()
        os.environ["PARROTFLOW_SOCKET"] = self.app.path
        self.addCleanup(self.app.close)

    def agent(self, *outputs: dict, typed=(), **config):
        agent = parrotflow_mini.ParrotFlowAgent(Model(*outputs), Env(), system_template="You help.",
                                                instance_template="Please solve this issue: {{task}}", **config)
        answers = list(typed)
        self.prompts: list[int] = []

        def prompt(text, **kwargs):
            self.prompts.append(len(self.app.events()))
            return answers.pop(0) if answers else ""

        agent._prompt_and_handle_slash_commands = prompt
        return agent

    def test_yolo_run_says_the_prompt_each_command_and_the_answer(self):
        agent = self.agent(said("I list the files.", "ls", "swift test"), said("Fixed the cart total.", "git diff"),
                           said("", SUBMIT), mode="yolo", confirm_exit=False)
        result = agent.run("fix the cart")
        self.assertEqual(result["exit_status"], "Submitted")
        self.assertEqual(agent.env.ran, ["ls", "swift test", "git diff", SUBMIT])
        self.assertEqual(self.app.events(), [
            ("UserPromptSubmit", "fix the cart"),
            ("PreToolUse", "ls", "I list the files."),
            ("PreToolUse", "swift test", "I list the files."),
            ("PreToolUse", "git diff", "Fixed the cart total."),
            ("Stop", "Fixed the cart total."),
        ])

    def test_confirm_mode_says_the_wait_before_it_waits(self):
        agent = self.agent(said("Look first.", "ls"), said("Done.", SUBMIT), whitelist_actions=["^echo "])
        agent.run("fix the cart")
        self.assertEqual(self.app.events(), [
            ("UserPromptSubmit", "fix the cart"),
            ("PreToolUse", "ls", "Look first."),
            ("PermissionRequest", "ls"),
            ("Stop", "Done."),
        ])
        self.assertEqual(self.prompts, [3, 4])

    def test_a_task_typed_at_the_end_is_a_new_prompt_in_the_same_session(self):
        agent = self.agent(said("Done.", SUBMIT), said("", "pytest"), said("", SUBMIT),
                           typed=["/c", "add a test", ""], mode="yolo")
        agent.run("fix the cart")
        self.assertEqual(self.app.events(), [
            ("UserPromptSubmit", "fix the cart"),
            ("Stop", "Done."),
            ("UserPromptSubmit", "add a test"),
            ("PreToolUse", "pytest", ""),
            ("Stop", ""),
        ])
        events = [json.loads(raw.split(b"\n", 2)[2]) for raw in self.app.raw]
        self.assertEqual({e["session_id"] for e in events}, {agent.parrotflow_session})
        self.assertEqual({e["cwd"] for e in events}, {"/work/shop"})

    def test_going_on_after_the_answer_says_the_next_answer(self):
        agent = self.agent(said("Done.", SUBMIT), said("", SUBMIT), said("Now really done.", SUBMIT),
                           typed=["/u", "/u", ""], mode="yolo")
        agent.run("fix the cart")
        self.assertEqual(self.app.events(), [
            ("UserPromptSubmit", "fix the cart"),
            ("Stop", "Done."),
            ("Stop", ""),
            ("Stop", "Now really done."),
        ])

    def test_a_command_the_user_typed_is_not_said(self):
        agent = self.agent(mode="yolo")
        agent.execute_actions({"role": "user", "content": "User command", "extra": {"actions": [{"command": "ls"}]}})
        self.assertEqual(agent.env.ran, ["ls"])
        self.assertEqual(self.app.events(), [])

    def test_the_payload_is_what_the_app_reads(self):
        parrotflow_mini.send({"hook_event_name": "Stop", "session_id": "s1", "cwd": "/w"})
        self.assertEqual(self.app.received(), [
            f"pid={os.getpid()}\nagent=mini\n".encode()
            + b'{"hook_event_name": "Stop", "session_id": "s1", "cwd": "/w"}'
        ])

    def test_no_app_running_changes_nothing_for_mini(self):
        os.environ["PARROTFLOW_SOCKET"] = os.path.join(SCRATCH, "missing.sock")
        agent = self.agent(said("Look.", "ls"), said("Done.", SUBMIT), mode="yolo", confirm_exit=False)
        started = time.monotonic()
        self.assertEqual(agent.run("fix the cart")["exit_status"], "Submitted")
        self.assertLess(time.monotonic() - started, 1)
        self.assertEqual(agent.env.ran, ["ls", SUBMIT])


if __name__ == "__main__":
    print("against", "mini-swe-agent " + sys.modules["minisweagent"].__version__ if REAL else "the stub")
    unittest.main(verbosity=2)
