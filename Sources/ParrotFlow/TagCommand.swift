import Foundation

/// `--tag "<text>" [--lang fr]` — the tokens a `returns: json` transform is
/// handed, as JSON on stdout.
///
/// Exists so the tagging can be read by hand and scored by a script. A case set
/// that hard-coded the tags would be scoring a fixture; `scripts/check-join.sh`
/// builds its envelopes from this, so it exercises the tagger the app ships.
enum TagCommand {

    static func run(text: String, language: String?) -> Int32 {
        // NLTagger with no language returns `Other` for everything on a short
        // string — it will not guess from four words. The pipeline always has
        // one in scope; a bare command falls back to the first configured.
        let resolved = language
            ?? (try? ConfigStore.load())?.transcription.languages.first
            ?? "en"
        let tokens = Tagger.tokens(in: ComposeCommand.expanded(text), language: resolved)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(tokens),
              let json = String(bytes: data, encoding: .utf8) else { return 1 }
        print(json)
        return 0
    }
}
