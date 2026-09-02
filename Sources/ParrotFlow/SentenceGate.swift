import Foundation

/// The two tests that read the sentence, put together.
///
/// They never speak on the same side. `SlotReference` only refuses: it asks
/// whether the term belongs where the word was heard, and a term is unknown to
/// the tokenizer by construction, so its vector sits further from any centre
/// than a real word's and the comparison cannot be made to write.
/// `TermPortrait` answers about the term alone: whether this sentence looks like
/// the ones it was confirmed in, or more like the ones it was corrected out of.
/// It authorises when it looks like the first, refuses when it looks like the
/// second, and says nothing when the two are too close to call.
///
/// So there are four outcomes and only one of them is a disagreement:
///
///     refuses, authorises   ->  neither wins, the place is left open
///     refuses               ->  keep what was heard
///     authorises            ->  write the term
///     neither               ->  the place is left open
///
/// A place neither test settles keeps whatever is already in the text: the
/// term where a rule wrote one, the word that was heard where nothing did.
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
        var looked = 0
        for (index, change) in changes.enumerated() {
            guard index < out.count, out[index] != false else { continue }
            guard let term = change.terms.first else { continue }
            guard change.range.upperBound <= text.endIndex else { continue }

            // A place an earlier rule already decided to write. The two word
            // lists write a name whenever the heard word is in neither of them,
            // which is right almost always and wrong when the word is simply
            // rare: `on the moon on its superbase` became `its Supabase`. The
            // portrait is the only test that separates that from `we host our
            // databases on superbase` — 0.665 against 0.944 — so it may take
            // such a write back out.
            //
            // It used to hand the place back instead, for a model to arbitrate.
            // There is no model, and handing a place back with nobody to hand
            // it to is a keep: `a much better stack than PHP` shipped as
            // `a much BetterStack than PHP` with the portrait at 0.650 against
            // a floor of 0.795, having said no. So a refusal here reverts.
            //
            // How wide the portrait's licence to overrule a rule should be is a
            // separate question, and not answered here.
            // The words around the span, and the span as it was *heard* — see
            // `TermPortrait.radius`.
            //
            // A rule writes its term into the text before this runs, and the
            // vectors are contextual: the term standing in the span colours
            // every word around it, so the sentence reads like one of the
            // term's own and the gate grades the rule's own homework. Measured
            // on the seeded Vercel portrait, floor 0.898:
            //
            //     "Vercel and its king."      0.941  authorises
            //     "Versailles and its king."  0.712  refuses
            //
            // and the same flip on three more. A sound proposal has written
            // nothing, so for those this is the text it already was.
            let start = text.distance(from: text.startIndex, to: change.range.lowerBound)
            let heard = text.replacingCharacters(in: change.range, with: change.was)
            let from = heard.index(heard.startIndex, offsetBy: start)
            let upto = heard.index(from, offsetBy: change.was.count)
            let near = TermPortrait.window(around: from ..< upto, in: heard)

            if out[index] == true {
                let portrait = await TermPortrait.shared.reads(
                    change.was, in: near, as: term
                )
                looked += 1
                if portrait == .refuses {
                    out[index] = false
                    Log.write(
                        "sentence gate: \"\(change.was)\" -> \(term) taken back out"
                            + " — \(term) does not live in this sentence")
                } else {
                    Log.write(
                        "sentence gate: \"\(change.was)\" -> \(term) already written,"
                            + " and \(term)'s own sentences do not object")
                }
                continue
            }

            let refuses: Bool
            do {
                let gap = try await SlotReference.gap(
                    term: change.now, heard: change.was, at: change.range, in: text
                )
                refuses = gap < -SlotReference.floor
            } catch {
                // A place the slot cannot read is a place this stage has no
                // opinion about, not one to guess at.
                Log.write("sentence gate: \(change.was) — \(error.localizedDescription)")
                continue
            }
            let portrait = await TermPortrait.shared.reads(
                change.was, in: near, as: term
            )

            switch (refuses, portrait) {
            case (true, .authorises):
                Log.write("sentence gate: \"\(change.was)\" -> \(term) — the two disagree")
            case (true, _), (false, .refuses):
                out[index] = false
                let why = refuses ? "it belongs here" : "\(term) does not live in this sentence"
                Log.write("sentence gate: \"\(change.was)\" kept — \(why)")
            case (false, .authorises):
                out[index] = true
                Log.write("sentence gate: \"\(change.was)\" -> \(term) — this is where it lives")
            case (false, .nothing):
                break
            }
            looked += 1
        }
        if looked == 0 {
            Log.write("sentence gate: nothing left to read in \(changes.count) place(s)")
        }
        return out
    }
}
