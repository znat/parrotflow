import Foundation

/// `--learn <heard> <corrected> [kind] [--in "<sentence>"]` — adds a vocabulary
/// pronunciation from the terminal.
///
/// The same code path the correction panel uses, minus the UI. Useful on its
/// own, and it makes the config-rewriting logic testable without a GUI.
///
/// `--in` records the sentence as well, which is what a term's portrait is
/// built from. The panel always has one; this command only has one if it is
/// given, so without it the mapping is saved and nothing else.
enum LearnCommand {
    static func run(
        heard: String, corrected: String, kind: WordKind? = nil, sentence: String? = nil
    ) -> Int32 {
        do {
            try ConfigWriter.addVocabularyPronunciation(
                term: corrected, heard: heard, kind: kind
            )
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
        // The mapping is already saved by here, so a sentence that could not be
        // written is a warning and not a failure. Reporting it as one would say
        // the correction was lost when it was not.
        if let sentence, !sentence.isEmpty {
            do {
                // From the terminal, so it was typed and not lived. A portrait
                // built out of sentences somebody invented behaves differently
                // from one built out of real dictation.
                try TermUses.record(
                    term: corrected, said: sentence, span: corrected, from: .seeded
                )
            } catch {
                print("! the sentence was not recorded in"
                    + " \(TermUses.url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        Trace.correction(heard: heard, corrected: corrected, via: "learn")
        print("✓ \(heard) → \(corrected)")
        return 0
    }

    /// `--tidy-uses` — cuts every stored use down to its own sentence.
    ///
    /// The migration for `TermUses.narrowed`. Rows written before it exist hold
    /// the whole prompt line, and two of Ghostty's three uses were teaching it
    /// that "The night was very ghostly" is where it lives.
    static func tidy() -> Int32 {
        // `read`, not `load`. A file that does not parse reads as no uses, and
        // this writes what it read back over it.
        let all: [String: [TermUses.Use]]
        do { all = try TermUses.read() } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
        var out: [String: [TermUses.Use]] = [:]
        var cut = 0
        for (term, uses) in all {
            var kept: [TermUses.Use] = []
            for use in uses {
                let said = TermUses.narrowed(use.said, to: use.span)
                if said != use.said { cut += 1 }
                let now = TermUses.Use(said: said, span: use.span, from: use.from)
                // The custom `==` is on the sentence and the span, so two rows
                // that narrow to the same sentence collapse into one.
                if !kept.contains(now) { kept.append(now) }
            }
            if !kept.isEmpty { out[term] = kept }
        }
        do {
            try TermUses.write(out)
            let was = all.values.map(\.count).reduce(0, +)
            let now = out.values.map(\.count).reduce(0, +)
            print("✓ \(cut) use(s) cut to their own sentence, \(was - now) duplicate(s) dropped")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }

    /// `--for <term> "<sentence>" [word]` — a sentence the term *does* belong
    /// in, recorded without touching the pronunciations.
    ///
    /// `--learn` also seeds a use, but only alongside a `heard:` rendering, so
    /// there was no way to record a genuine use on its own. Passing the term as
    /// its own rendering is not a workaround: `VocabularyJudge.ruleParts` finds
    /// a rule substitution by searching for the term, so a self-mapping makes
    /// every correctly spelled occurrence look like something a rule wrote.
    ///
    /// `word` is what stands where the term goes, for a sentence that inflects
    /// it — `Praisy's` — and defaults to the term itself.
    static func supporting(term: String, sentence: String, span: String? = nil) -> Int32 {
        let written = span ?? term
        guard sentence.contains(written) else {
            print("✗ \"\(written)\" is not in that sentence")
            return 1
        }
        do {
            try TermUses.record(term: term, said: sentence, span: written, from: .seeded)
            print("✓ \(term) belongs at \"\(written)\"")
            return 0
        } catch {
            print("✗ \(error.localizedDescription)")
            return 1
        }
    }
}
