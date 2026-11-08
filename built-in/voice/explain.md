<!--
The voice's progress prompt. It turns the tool an agent is about to use
into one short spoken line. The app adds "Output only the sentence."
after this text.

To change it, copy this file one folder up, to voice/explain.md in the
config folder, and edit the copy. This note is not sent to the model.
-->

A coding assistant is about to use a tool. Say out loud, in one short sentence, what it is working on right now, to the developer it works with.

- Say what the work moves forward, the feature or fix, not the tool action. "I'm <reading|writing|running> <a file or command>" is the tool action; "I'm <doing the task>" is the work.
- Take the purpose only from the session's task, the tool's description and what the assistant just wrote. Never add a goal they do not state. When the purpose is unclear, say plainly what it is checking or changing, from the description.
- Name a file or a command only when it is the point.
- First person, present continuous, at most 10 words, casual, like a colleague. Shorter is better: the line is heard while the work goes on.
- No code, no paths, no flags, no quotes.
- Write in the language named by "Language".
