import Foundation

/// The transform for everything nobody wrote a prompt for.
///
/// "make sure fifty dollars is formatted as money", "use the 24 hour clock",
/// "sort the list alphabetically" — instructions that are perfectly clear and
/// that no catalogue will ever finish enumerating. The router sends them here
/// by answering ANY, and the whole sentence comes with them, because there is
/// nothing to extract when the instruction *is* the specification.
///
/// Built in rather than a default entry in `prompts:`, for the reason the
/// measurement found: an abstract description cannot compete in the catalogue
/// listing. Added as `anything — any other change to the text`, gemma picked
/// it zero times out of ten, sending free-form edits to NONE and two of them to
/// the wrong narrow tool. The router needs a separate answer, not another line
/// in the list. See `Router.prompt(for:freeForm:)`.
///
/// Scored by tests/generic-cases.yaml — 44 cases, 31 that ask for an edit and
/// 13 that must come back untouched. On gemma4:e4b-mlx, 39/44, against 11/38
/// for a control that returns the text unchanged. The full scoreboard is at the
/// bottom of scripts/validate-generic.py.
///
/// The last two examples are a *correction* — an instruction with the
/// imperative taken out. "make it Tuesday" and "I meant Tuesday" ask for the
/// same edit, and the second is what people say to a machine that has just
/// written their own sentence down. Without them this scored 3/6 on those, and
/// it failed in one particular way: handed "no I meant three of them" it edited
/// the *instruction* and returned that, having read the corrective phrasing as
/// prose and therefore as the subject. The pair is one of each, because the
/// phrase is not a marker — it introduces an edit only when it names the
/// replacement, and bare it is a complaint with nothing to act on.
///
/// "no I meant three of them" still fails, and is left standing rather than
/// argued with: fixing one case with a third example is tuning on the set. It
/// wants fresh cases before anyone tries again.
///
/// Two findings from that set shaped what shipped. The prompt beats the narrow
/// prompts on their own ground — 14/16 against 12/16 on the cases `dates` and
/// `digits` cover — which is why config.example.yaml no longer ships those two.
/// And an `UNCHANGED` sentinel, the trick that won on the spelling extractor,
/// was measured here and lost: it fixed the copy-back failures and cost two
/// grammar cases, because a prompt whose examples end in a bare token stops
/// returning terminal punctuation.
enum FreeForm {

    /// The name it reports as. Not in the catalogue, so this is only ever seen
    /// in the log, in `--check-config`, and as the argument to `--prompt`.
    static let name = "anything"

    /// `confirm` is left at its default, which is on, and this is the prompt
    /// that most wants it. Everything else is aimed at a subject the speaker
    /// named; this one runs on instructions the app has never been told
    /// anything about, so the preview is the only thing between a
    /// misunderstanding and your selection.
    static let prompt = Config.Prompt(
        name: name,
        description: "any change to the text that no other prompt covers",
        // Wrapped exactly as tests/generic-cases.yaml measured it. The line
        // breaks are part of the string the model sees, so rewrapping this —
        // or joining it with backslash continuations — is an unmeasured change
        // to a scored prompt, not a tidy-up.
        content: """
        Apply the instruction to the text.

        Make exactly the change the instruction asks for, and no other. Every word
        the instruction does not mention comes back as it was — same wording, same
        order, same capitalisation, same punctuation.

        The instruction is an edit to make, never a question to answer and never a
        remark to reply to. Return the text unchanged when the instruction asks for
        something the text does not contain, when the text is already in the form it
        asks for, and when it is not an instruction at all.

        instruction: write the numbers as digits
        text:
        we saw about forty of them
        we saw about 40 of them

        instruction: make the dates ISO
        text:
        the release is 2026-02-01
        the release is 2026-02-01

        instruction: how long is that going to take
        text:
        the migration runs on friday
        the migration runs on friday

        instruction: I meant Tuesday
        text:
        the meeting is on Monday
        the meeting is on Tuesday

        instruction: this is not what I had in mind
        text:
        the migration runs on friday
        the migration runs on friday

        Return only the text.
        """
    )

    /// The catch-all, carrying a display made from what was actually asked.
    ///
    /// Every other transform can name what it is doing before it runs, because
    /// every other transform does one thing. This one does whatever you just
    /// said, so there is no fixed label to write — and the two it could fall
    /// back to are both wrong. Its name yields "anything…", which is the least
    /// informative word in the app to be watching during a wait; "Thinking…"
    /// is what the path said before and describes the model rather than the
    /// request.
    ///
    /// So the label is generated: your own instruction, handed back. It is the
    /// one string guaranteed to describe this particular second, and reading it
    /// mid-wait is also how you find out the router heard you wrong — the
    /// preview then confirms it, but the preview comes after the second you
    /// spent wondering.
    static func prompt(for instruction: String) -> Config.Prompt {
        var made = prompt
        made.display = display(for: instruction)
        return made
    }

    /// The instruction as a status line: first letter raised, cut to something
    /// a menu bar can hold, and never cut mid-word.
    ///
    /// Empty when there is nothing to show, which leaves `progressLabel` to
    /// fall back to the name — the caller does not get to end up with a label
    /// that is just an ellipsis.
    static func display(for instruction: String) -> String {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var shown = String(trimmed.prefix(maximumDisplay))
        if shown.count < trimmed.count, let lastSpace = shown.lastIndex(of: " ") {
            shown = String(shown[..<lastSpace])
        }
        return shown.prefix(1).uppercased() + shown.dropFirst()
    }

    /// Long enough for the instructions people actually say — "sort that list
    /// alphabetically" is 29 — and short enough that the menu bar does not
    /// take the whole width of the screen for one dictation.
    private static let maximumDisplay = 48
}
