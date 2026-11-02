import Foundation

/// The clause decider, on every place the word lists left open — see
/// `ClauseDecider`.
///
/// A place it does not settle keeps whatever is already in the text: the term
/// where a rule wrote one, the word that was heard where nothing did.
enum SentenceGate {

    /// The places, and what each one settled to.
    ///
    /// The changes come back because a group place can change what it is
    /// proposing: `now` is one member when it arrives here and the winning
    /// member when it leaves, and `group` is cut to the members still standing
    /// — which is the list the pill offers when nobody wins. Nothing else in a
    /// change moves.
    typealias Settled = (decided: [Bool?], changes: [VocabularyPass.Change])

    /// Fills in the places the earlier rules left open.
    ///
    /// `settled` carries one entry per change: `true` writes the term, `false`
    /// keeps what was heard, `nil` is still open. A place the word lists
    /// already refused is not read.
    static func settle(
        _ changes: [VocabularyPass.Change], in text: String, given settled: [Bool?],
        clause: ClauseSession
    ) async -> Settled {
        var changes = changes
        var out = settled
        var looked = 0
        for (index, change) in changes.enumerated() {
            guard index < out.count, out[index] != false else { continue }
            guard let term = change.terms.first else { continue }
            guard change.range.upperBound <= text.endIndex else { continue }
            looked += 1

            if change.group.count > 1 {
                let members = change.group.joined(separator: "/")
                switch await clause.readGroup(change, in: text) {
                case .write(let member)?:
                    changes[index] = change.writing(member)
                    out[index] = true
                    Log.write("sentence gate: \"\(change.was)\" -> \(member) — the clause decider picks it")
                case .offer(let top)?:
                    changes[index] = change.offering(top)
                    Log.write("sentence gate: \"\(change.was)\" — the clause decider offers \(top.joined(separator: "/"))")
                case .leave?:
                    out[index] = false
                    Log.write("sentence gate: \"\(change.was)\" kept — no member of \(members) clears the clause decider")
                case nil:
                    Log.write("sentence gate: \"\(change.was)\" — the clause decider cannot read \(members) here")
                }
                continue
            }

            let owner = change.owner ?? term
            if out[index] == true {
                // The clause decider takes a write back only from a term it
                // has sentences for, and only when it would leave the place.
                if let reading = await clause.read(change, term: owner, in: text),
                   !reading.cold, reading.decision == .leave {
                    out[index] = false
                    Log.write("sentence gate: \"\(change.was)\" -> \(owner) taken back out"
                        + " — the clause decider leaves it")
                } else {
                    Log.write("sentence gate: \"\(change.was)\" -> \(owner) already written,"
                        + " and the clause decider does not object")
                }
                continue
            }

            switch await clause.read(change, term: owner, in: text)?.decision {
            case .write?:
                out[index] = true
                Log.write("sentence gate: \"\(change.was)\" -> \(owner) — the clause decider writes it")
            case .leave?:
                out[index] = false
                Log.write("sentence gate: \"\(change.was)\" kept — the clause decider leaves it")
            case .offer?, nil:
                Log.write("sentence gate: \"\(change.was)\" -> \(owner) — the clause decider offers it")
            }
        }
        if looked == 0 {
            Log.write("sentence gate: nothing left to read in \(changes.count) place(s)")
        }
        return (out, changes)
    }
}
