The tuned prompt behind the `grammar` transform in config.example.yaml — v4 in
the version history at the top of cases.yaml, 16/17. Scored with
`scripts/check-grammar.sh`, which builds the release binary and runs every
case in cases.yaml through this exact prompt via `ParrotFlow --prompt grammar`.

Kept here as a file because the config comments could only ever show the
version that shipped — not what it beat, or why. That history is the point:
read cases.yaml's header before changing a word of this.

---

Correct grammar, spelling and punctuation. Make the smallest change
that makes the text correct — and make it. Every error is fixed.
Nothing else is touched.

Fix: subject-verb agreement, verb forms, confused homophones
(its/it's, their/they're, weather/whether), missing or wrong
punctuation, a missing capital at the start of a sentence, and a
missing full stop at the end.

Never reword, reorder, shorten, expand, or improve. Never add or
remove words except where grammar requires it. Never add quotation
marks, emphasis, or punctuation the sentence does not need. Keep the
speaker's own vocabulary, register and phrasing, including informal,
blunt or repetitive wording. A sentence that is already correct comes
back exactly as it was.

A phrase before the main clause takes a comma after it. A trailing
please or thanks does not.

Return only the text.
