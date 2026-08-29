import Foundation

/// The words a language model's tokenizer keeps whole.
///
/// A second opinion on "has anyone ever written this word", next to
/// `Replacements.isRealWord`. The spell checker answers from a dictionary, and
/// a dictionary has no first names in it: `Sarah`, `Nathan`, `Zoe`, `Ahmed`,
/// `Frederick` are all unknown to `NSSpellChecker` in `en` and in `fr`.
/// `Vocabulary.autoApplies` reads "unknown" as "safe to overwrite", so an
/// ordinary name was being replaced by a vocabulary term without anything
/// reading the sentence.
///
/// This list is the whole-word half of `distilbert-base-uncased`'s WordPiece
/// vocabulary. A tokenizer keeps a word whole when it saw it often enough
/// while being trained, and chops the rest into fragments, so membership is a
/// frequency fact rather than a lexicographer's judgement — which is exactly
/// what covers the spell checker's blind spot. Its own blind spot is the
/// mirror image: `subtask`, `webhook`, `changelog`, `worktree`, `monorepo`,
/// `kubernetes` and `dockerfile` are all split, and all known to the spell
/// checker. Requiring both to say "unknown" is what makes the pair work;
/// either one alone is worse than the other.
///
/// **No model runs.** The whole test is a set lookup. The tokenizer normalises
/// by lowercasing and then dropping combining marks, and none of the 23694
/// entries carries one, so folding the query with `.diacriticInsensitive` and
/// `.caseInsensitive` reproduces that normalisation: `Chloé` -> `chloe`,
/// `Créé` -> `cree`. Checked both ways — every entry survives the tokenizer's
/// own normalisation unchanged, and the lookup agrees with "the tokenizer does
/// not split this word" on 43 of 43 sample words.
enum WordPieces {

    /// Whether the list knows this word. `nil` when the list could not be read.
    ///
    /// Three answers, not two, and the third is the point. A missing file that
    /// answered "unknown" would put the gate back exactly where it was — both
    /// lists silent, the proposal written in without asking. `nil` is what
    /// `Vocabulary.autoApplies` turns into "ask the judge".
    static func knows(_ word: String) -> Bool? {
        guard let words else { return nil }
        return words.contains(fold(word))
    }

    /// The tokenizer's normalisation, in Foundation's terms.
    static func fold(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive],
                     locale: Locale(identifier: "en_US"))
    }

    /// Loaded once, on first question. `static let` rather than a lock: the
    /// gate is asked from the transcript pass and from the command line, and
    /// this way neither can see a half-built set.
    static let words: Set<String>? = {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            Log.write("wordpiece.txt could not be read at \(fileURL.path);"
                + " every name will be put to the judge")
            return nil
        }
        let entries = text.split(separator: "\n").map(String.init)
        guard !entries.isEmpty else { return nil }
        return Set(entries)
    }()

    /// Where the list is, by the same rule `Config.configTemplateURL` uses: the
    /// assembled bundle when there is one, the source tree when the binary is
    /// the raw `swift build` product the check scripts run.
    ///
    /// `PARROTFLOW_WORDPIECE` overrides both. `scripts/check-word-gate.sh`
    /// points it at a path that does not exist, which is the only way to score
    /// the missing-resource branch against the shipped code.
    static var fileURL: URL {
        let override = ProcessInfo.processInfo.environment["PARROTFLOW_WORDPIECE"] ?? ""
        if !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        if !Permissions.isRunningFromBuildDirectory,
           let bundled = Bundle.main.resourceURL?.appendingPathComponent("wordpiece.txt"),
           FileManager.default.fileExists(atPath: bundled.path) {
            return bundled
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // WordPieces.swift -> Sources/ParrotFlow/
            .deletingLastPathComponent()  // -> Sources/
            .deletingLastPathComponent()  // -> repo root
            .appendingPathComponent("data/wordpiece.txt")
    }
}
