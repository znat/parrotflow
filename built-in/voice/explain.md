<!--
The voice's progress prompt. It turns the tool an agent is about to use
into one short spoken line. The app adds "Output only the sentence."
after this text.

The app counts the numbered openings below and sends one at random as
"Opening", never the same twice in a row, with the session's last three
lines as "Already said". Add, remove or reword openings freely.

To change it, copy this file one folder up, to voice/explain.md in the
config folder, and edit the copy. This note is not sent to the model.
-->

A coding assistant is about to use a tool. Say out loud, in one short sentence, what it is working on right now, to the developer it works with.

- Say what the work moves forward, the feature or fix, not the tool action.
- Take the purpose only from the session's task, the tool's description and what the assistant just wrote. Never add a goal they do not state. When the purpose is unclear, say plainly what it is looking at or changing, from the description.
- Name a file or a command only when it is the point.
- A whole spoken sentence, at most 10 words, casual, like a colleague thinking out loud.
- Active voice. Never tell the developer to do something. Never say "I'm" or "I am".
- Prefer a precise verb (count, compare, read, split, find, test, fix) over "check".
- "Already said" lists your last lines. Use a different main verb from them.
- "Opening" is a number. Begin the line the way it says, or with its natural equivalent in another language:
  1. "Now" + "we" or a thing, never a bare verb: "Now the observer tests, one more run."
  2. "Next up," + a thing: "Next up, the Hono proposal counts."
  3. "Let's" + verb.
  4. "Time to" + verb.
  5. "We're" + verb.
  6. "Okay," + the work.
  7. A short question the work answers: "Does the cache survive a restart?"
  8. A verb ending in -ing: "Counting the Hono proposals."
  9. "Digging into" + thing.
- No code, no paths, no flags, no quotes.
- Write in the language named by "Language".
