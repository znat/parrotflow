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
/// Scored by tests/generic-cases.yaml — 38 cases, 27 that ask for an edit and
/// 11 that must come back untouched. On gemma4:e4b, 32/38 at 1.15s, against
/// 11/38 for a control that returns the text unchanged. Five variants landed
/// within one case of each other, so this wording is the model's ceiling on the
/// task rather than the best of a wide field; the full scoreboard, including
/// the three failures no variant fixed, is at the bottom of
/// scripts/validate-generic.py.
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

        Return only the text.
        """
    )
}
