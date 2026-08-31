import Foundation

/// The two tests that read the sentence, put together.
///
/// They never speak on the same side. `SlotReference` only refuses: it asks
/// whether the term belongs where the word was heard, and a term is unknown to
/// the tokenizer by construction, so its vector sits further from any centre
/// than a real word's and the comparison cannot be made to write.
/// `TermPortrait` only authorises: it asks whether this sentence looks like the
/// ones the term was confirmed in, and says nothing about the alternative.
///
/// So there are four outcomes and only one of them is a disagreement:
///
///     refuses, authorises   ->  neither wins, the reading is offered
///     refuses               ->  keep what was heard
///     authorises            ->  write the term
///     neither               ->  the stage decides as it did before
///
/// The last line is what makes this safe to turn on: a place neither test
/// settles behaves exactly as it does today.
///
/// Measured on 24 sentences dictated for the purpose, none of them in any
/// portrait: no correct rewrite refused, one ordinary word overwritten, 10 of
/// 13 names written, 10 places handed back. The shipped stack on the same
/// sentences wrote 9 names and overwrote 2 ordinary words.
@available(macOS 14, *)
enum SentenceGate {

    /// Fills in the places the earlier rules left open.
    ///
    /// `settled` carries one entry per change: `true` writes the term, `false`
    /// keeps what was heard, `nil` is still open. Only the open ones are asked
    /// about, so a place the word lists already settled costs nothing.
    static func settle(
        _ changes: [VocabularyJudge.Change], in text: String, given settled: [Bool?]
    ) async -> [Bool?] {
        // Never on the dictation's time. The word vectors are 400 MB and the
        // first MLX call warms Metal; waiting for that with the pill on screen
        // reads as the app having hung, which is what it did.
        guard await WordVectors.shared.isLoaded else {
            await WordVectors.shared.warm()
            Log.write("sentence gate: the word vectors are not loaded yet; skipped")
            return settled
        }
        guard SentenceModel.isCached else {
            Log.write("sentence gate: the sentence model is not cached yet; skipped")
            return settled
        }

        var out = settled
        for (index, change) in changes.enumerated() {
            guard index < out.count, out[index] == nil else { continue }
            guard let term = change.terms.first else { continue }
            guard text.contains(change.was) else { continue }

            let refuses: Bool
            do {
                let gap = try await SlotReference.gap(
                    term: change.now, heard: change.was, in: text
                )
                refuses = gap < -SlotReference.floor
            } catch {
                // A place the slot cannot read is a place this stage has no
                // opinion about, not one to guess at.
                Log.write("sentence gate: \(change.was) — \(error.localizedDescription)")
                continue
            }
            let authorises = await TermPortrait.shared.authorises(
                change.was, in: text, as: term
            )

            switch (refuses, authorises) {
            case (true, true):
                Log.write("sentence gate: \"\(change.was)\" -> \(term) — the two disagree")
            case (true, false):
                out[index] = false
                Log.write("sentence gate: \"\(change.was)\" kept — it belongs here")
            case (false, true):
                out[index] = true
                Log.write("sentence gate: \"\(change.was)\" -> \(term) — this is where it lives")
            case (false, false):
                break
            }
        }
        return out
    }
}
