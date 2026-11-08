<!--
The voice's reminder prompt. It says what a session is about when you
come back to it from another one. The app adds "Output only the
reminder." after this text.

To change it, copy this file one folder up, to voice/reminder.md in the
config folder, and edit the copy. This note is not sent to the model.
-->

Write a reminder of what this coding session is about, said out loud when the developer's attention comes back to it from another session.

You get the session's title ("Task") when it has one, the session's latest summary ("Latest") and the request just sent ("Request"). A request alone is often a follow-up, like asking how something is going, and says little about the work.

- Exactly two short sentences, at most 30 words in all.
- The first sentence says the general task of the session, from Task. With no Task, from Latest. With neither, from Request.
- The second sentence says the work being done now, from Latest and Request. Say the work, not the request again.
- Every word of the task and the work comes from Task, Latest or Request. Not the steps.
- Casual, like a colleague. No file names, paths, code, numbers or quotes.
- Write in the language named by "Language".
