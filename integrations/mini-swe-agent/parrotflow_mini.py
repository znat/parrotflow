"""Speaks mini-swe-agent's progress and answers through the ParrotFlow app.

Run mini with `--agent-class parrotflow_mini.ParrotFlowAgent`. Each event goes
to ParrotFlow's socket in the shape of a Claude Code hook event. Written
against mini-swe-agent 2.4.6.
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import socket
import uuid
from typing import Any, Iterator

from minisweagent.agents.interactive import InteractiveAgent

DEFAULT_SOCKET = "~/Library/Application Support/ParrotFlow/claude.sock"
SUBMIT = "COMPLETE_TASK_AND_SUBMIT_FINAL_OUTPUT"
# The text InteractiveAgent puts before a task typed at the end of a run.
NEW_TASK = "The user added a new task: "

logger = logging.getLogger("parrotflow_mini")


@contextlib.contextmanager
def quiet() -> Iterator[None]:
    """mini goes on whatever happens here."""
    try:
        yield
    except Exception as error:
        logger.debug("parrotflow: event not sent: %s", error)


def send(event: dict[str, Any]) -> None:
    """One event to the app's socket, or nothing when the app is not running."""
    path = os.path.expanduser(os.environ.get("PARROTFLOW_SOCKET") or DEFAULT_SOCKET)
    payload = f"pid={os.getpid()}\nagent=mini\n{json.dumps(event)}".encode()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(0.2)
        conn.connect(path)
        conn.sendall(payload)


def text(message: dict[str, Any]) -> str:
    content = message.get("content")
    if isinstance(content, list):
        content = "\n".join(str(part.get("text") or "") for part in content if isinstance(part, dict))
    return content.strip() if isinstance(content, str) else ""


class ParrotFlowAgent(InteractiveAgent):
    """One session per agent, so one per `mini` process."""

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        self.parrotflow_session = str(uuid.uuid4())
        self.parrotflow_answered = False
        # Where this task's messages start, so an answer never comes from the task before.
        self.parrotflow_start = 0

    def _tell(self, name: str, **fields: Any) -> None:
        cwd = getattr(getattr(self.env, "config", None), "cwd", "") or os.getcwd()
        send({"hook_event_name": name, "session_id": self.parrotflow_session, "cwd": cwd, **fields})

    def _prompted(self, task: str, start: int) -> None:
        self.parrotflow_answered = False
        self.parrotflow_start = start
        self._tell("UserPromptSubmit", prompt=task)

    def run(self, task: str = "", **kwargs: Any) -> dict:
        with quiet():
            self._prompted(task, start=0)
        return super().run(task, **kwargs)

    def execute_actions(self, message: dict) -> list[dict]:
        with quiet():
            # In human mode the user's own command comes through here too.
            if message.get("role") == "assistant":
                thought = text(message)
                for action in message.get("extra", {}).get("actions", []):
                    command = action.get("command", "")
                    if SUBMIT not in command:
                        self._tell("PreToolUse", tool_name="Bash",
                                   tool_input={"command": command, "description": thought})
        return super().execute_actions(message)

    def _ask_confirmation_or_interrupt(self, commands: list[str], *args: Any, **kwargs: Any) -> None:
        with quiet():
            asked = [command for command in commands if self._should_ask_confirmation(command)]
            if asked:
                self._tell("PermissionRequest", tool_name="Bash", tool_input={"command": asked[0]})
        return super()._ask_confirmation_or_interrupt(commands, *args, **kwargs)

    def _check_for_new_task_or_submit(self, e: Exception, *args: Any, **kwargs: Any) -> None:
        # Before super(): it waits at the "Type new task" prompt. It calls
        # itself again after a mode switch, hence the flag.
        with quiet():
            if not self.parrotflow_answered:
                self.parrotflow_answered = True
                said = next((text(m) for m in reversed(self.messages[self.parrotflow_start:])
                             if m.get("role") == "assistant" and text(m)), "")
                self._tell("Stop", last_assistant_message=said)
        return super()._check_for_new_task_or_submit(e, *args, **kwargs)

    def _interrupt(self, content: str, *args: Any, **kwargs: Any) -> None:
        with quiet():
            if kwargs.get("itype") == "UserNewTask" and content.startswith(NEW_TASK):
                self._prompted(content[len(NEW_TASK):], start=len(self.messages))
        return super()._interrupt(content, *args, **kwargs)
