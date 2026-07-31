import Foundation
import NaturalLanguage

/// Which language a transcript was dictated in, so the correction prompt can
/// be the one written for that language.
///
/// `NLLanguageRecognizer` rather than the LLM or a hand-rolled heuristic: it
/// ships with macOS, needs no download, and measured 52/53 on the source lines
/// of both validation sets at 0.84ms per call — against a model call of 1.5s,
/// it is free.
///
/// Parakeet cannot do this for us. It transcribes multilingually but its
/// `ASRResult` carries no language, and its `ASRConfig` takes no language hint,
/// so the configured list constrains this recogniser rather than the ASR.
///
/// The known miss is code-switching, which is the register this app gets used
/// in: "Tee bo relit la pull request" is French but reads as English, because
/// half its tokens are English technical vocabulary. Nothing here fixes that.
/// What makes it tolerable is the cost of being wrong — the correction falls
/// back to the English prompt, which still scores 87% on tests/french-cases.yaml
/// against the French prompt's 93%. A misdetection loses a few points on one
/// correction, not the feature.
enum DictationLanguage {

    /// The languages the app knows how to prompt in. Anything else falls back
    /// to English, which is why an unrecognised config entry degrades rather
    /// than breaks.
    static let supported = ["en", "fr"]

    private static let byCode: [String: NLLanguage] = [
        "en": .english, "fr": .french,
    ]

    /// Below this, the answer is a coin toss dressed as a result — measured
    /// 98% at four words and above, 94% at three, and confidence does not
    /// warn you: "Locks me a relu" came back English at 1.00. So the guard is
    /// on length, not on the recogniser's own score.
    private static let minimumWords = 4

    /// The language of `text`, restricted to `allowed`.
    ///
    /// Returns `fallback` when there is nothing to decide (one language
    /// configured) or not enough text to decide it on. `allowed` is the
    /// configured list, which is what makes this accurate: constrained to two
    /// candidates it is a near-binary decision, where an open-ended guess over
    /// every language the recogniser knows is a much harder one.
    static func detect(_ text: String, allowed: [String], fallback: String) -> String {
        let candidates = allowed.filter { byCode[$0] != nil }
        guard candidates.count > 1 else { return candidates.first ?? fallback }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard words.count >= minimumWords else { return fallback }

        let recogniser = NLLanguageRecognizer()
        recogniser.languageConstraints = candidates.compactMap { byCode[$0] }
        recogniser.processString(text)

        let hypotheses = recogniser.languageHypotheses(withMaximum: candidates.count)
        let best = candidates.max { a, b in
            (hypotheses[byCode[a]!] ?? 0) < (hypotheses[byCode[b]!] ?? 0)
        }
        return best ?? fallback
    }

    /// The language to prompt in, given what the config allows.
    ///
    /// Detection runs on the transcript, never on the spoken command: the
    /// command is short, and its trigger word ("spells") plus a run of loose
    /// capitals reads as English whatever the speaker said — 72% on the
    /// correction lines, confidently wrong.
    static func forCorrection(
        transcript: String?, allowed: [String]
    ) -> String {
        let fallback = allowed.first(where: { byCode[$0] != nil }) ?? "en"
        guard let transcript, !transcript.isEmpty else { return fallback }
        return detect(transcript, allowed: allowed, fallback: fallback)
    }
}
