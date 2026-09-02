import Foundation
import SwiftUI

/// One thing the panel taught: what was heard, what it should be, and what kind
/// of thing it names.
///
/// `kind` is optional because most callers have no opinion. Only the panel
/// fills it in, and only a filled-in one is written to `vocabulary.yaml` — a
/// default written as if it were a decision is worse than no line at all.
struct TaughtRule: Equatable {
    var heard: String
    var corrected: String
    var kind: WordKind?
}

/// One row of the panel.
struct CorrectionRow: Identifiable, Equatable {
    let id = UUID()
    /// The words as the decoder wrote them. Editable, so a name the decoder
    /// split in two can be widened by typing — "red" into "red crawl". That is
    /// the whole reason it is a field and not a label.
    var heard: String
    var corrected: String = ""
    var kind: WordKind = .word
    /// Proposed by the spell check rather than typed. Only used to decide
    /// where the caret starts.
    var suggested: Bool = false
}

final class CorrectionModel: ObservableObject {
    @Published var rows: [CorrectionRow] = []

    /// The sentence the panel opened on, kept so the corrected text can be
    /// built by applying the rules to it. The rows are not the sentence — they
    /// are the words that looked wrong — so nothing can be reassembled from
    /// them.
    private(set) var sentence = ""

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The rows that would be written. A row is a rule when both halves are
    /// filled in and they differ.
    func rules() -> [TaughtRule] {
        rows.compactMap { row in
            let heard = row.heard.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = row.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !corrected.isEmpty, heard != corrected else { return nil }
            return TaughtRule(heard: heard, corrected: corrected, kind: row.kind)
        }
    }

    /// The sentence with what the panel taught applied to it.
    ///
    /// `applyExact` rather than a string replace, so the panel and the pipeline
    /// agree on what a rule does to a sentence — word boundaries and case
    /// included. See `Replacements.exact`.
    func correctedText() -> String {
        let taught = rules()
        guard !taught.isEmpty else { return sentence }
        return Replacements.applyExact(
            to: sentence,
            rules: taught.map {
                Config.Transcription.Rule(source: $0.heard, replacement: $0.corrected)
            }
        )
    }

    // MARK: - Loading

    /// Open on a sentence: a row per word the dictionary does not know.
    ///
    /// A sentence with nothing suspect in it gets one blank row rather than no
    /// rows. You came here to teach a word; the panel has to have somewhere to
    /// type it. That is 33 of the 56 sentences measured — see
    /// `VocabularySuggest`.
    func load(sentence: String, language: String? = nil) {
        self.sentence = sentence
        rows = VocabularySuggest.rows(in: sentence, language: language).map {
            CorrectionRow(heard: $0.heard, kind: $0.kind, suggested: true)
        }
        if rows.isEmpty { rows = [CorrectionRow(heard: "")] }
        focusFirstRow()
    }

    /// Open with the rules already filled in — a model proposed them, you
    /// confirm them.
    ///
    /// More than one row when the utterance carried more than one correction:
    /// "Tasmeen spells T A S M E E N and Mick spells M I K" is two rules, and
    /// splitting them across two panels would mean saying it twice.
    ///
    /// The kind is still proposed from the tag, because a rule that arrived
    /// this way has a heard word like any other.
    func load(rules proposed: [(heard: String, corrected: String)], over sentence: String = "") {
        self.sentence = sentence
        // What the vocabulary already says about this term beats what a tagger
        // guesses about the word. A term you have already labelled is labelled,
        // and offering a different answer for it invites you to disagree with
        // yourself one row at a time.
        let known = ((try? ConfigStore.load())?.vocabulary.terms ?? [:])
            .reduce(into: [String: WordKind]()) { out, entry in
                if let kind = entry.value.kind { out[entry.key.lowercased()] = kind }
            }
        rows = proposed.map { proposal in
            // The possessive belongs to the sentence, not to the name. Saved as
            // it stands, `Precey's -> Praizy's` teaches a term called `Praizy's`
            // beside the one called `Praizy`, and a vocabulary that holds both
            // is worse than one that holds neither.
            var rule = proposal
            if let mine = Vocabulary.possessive(in: rule.corrected),
               let theirs = Vocabulary.possessive(in: rule.heard) {
                rule.corrected = String(rule.corrected.dropLast(mine.suffix.count))
                rule.heard = String(rule.heard.dropLast(theirs.suffix.count))
            }
            let word = rule.corrected.trimmingCharacters(in: .punctuationCharacters)
            if let already = known[word.lowercased()] {
                return CorrectionRow(heard: rule.heard, corrected: rule.corrected, kind: already)
            }
            let tag = Tagger.tokens(in: rule.corrected, language: nil).first?.tag
            return CorrectionRow(
                heard: rule.heard, corrected: rule.corrected, kind: .from(tag: tag)
            )
        }
        if rows.isEmpty { rows = [CorrectionRow(heard: "")] }
        focusFirstRow()
    }

    // MARK: - Editing

    /// Drop a row. The last one is emptied rather than removed, so the panel is
    /// never a window with no fields in it.
    func remove(_ id: UUID) {
        guard rows.count > 1 else {
            rows = [CorrectionRow(heard: "")]
            focusFirstRow()
            return
        }
        rows.removeAll { $0.id == id }
        if focus?.row == id { focusFirstRow() }
    }

    /// A row to type a pair into that the spell check did not propose. The
    /// caret goes to it — you pressed the button because you have a word.
    func addRow() {
        let row = CorrectionRow(heard: "")
        rows.append(row)
        focus = Cell(row: row.id, column: .heard)
    }

    // MARK: - Focus

    enum Column: Hashable { case heard, corrected, kind }

    /// One editable thing on the panel. The type menu is one of them: it is a
    /// third of what a row says, so Tab has to reach it.
    struct Cell: Hashable {
        let row: UUID
        let column: Column
    }

    /// Where the caret is. Published rather than owned by the view, because Tab
    /// is caught on the panel — a text field swallows it before SwiftUI sees
    /// it — and the panel can only move focus by writing it here.
    @Published var focus: Cell?

    /// The cells Tab walks, in the order it walks them: across a row, then down
    /// to the next.
    private var ring: [Cell] {
        rows.flatMap { row in
            [Cell(row: row.id, column: .heard),
             Cell(row: row.id, column: .corrected),
             Cell(row: row.id, column: .kind)]
        }
    }

    /// One cell on, or back with Shift. Wraps, so Tab off the end of the last
    /// row returns to the first rather than dropping focus out of the panel.
    func moveFocus(by step: Int) {
        let ring = self.ring
        guard !ring.isEmpty else { return }
        guard let focus, let index = ring.firstIndex(of: focus) else {
            self.focus = ring.first
            return
        }
        self.focus = ring[(index + step + ring.count) % ring.count]
    }

    /// Where the caret starts: the right-hand side of the first proposed row,
    /// because the left-hand side is already right. With nothing proposed there
    /// is one blank row and the left side is the only thing to fill in.
    private func focusFirstRow() {
        guard let first = rows.first else { return focus = nil }
        focus = Cell(row: first.id, column: first.suggested ? .corrected : .heard)
    }
}
