import Foundation

/// `--suggest "<sentence>"` — the rows the correction panel would propose.
///
/// One `heard<tab>kind` per line, nothing when it proposes nothing. Tab
/// separated so a check script can cut it without quoting rules.
enum SuggestCommand {
    static func run(text: String, language: String?) -> Int32 {
        for row in VocabularySuggest.rows(in: text, language: language) {
            print("\(row.heard)\t\(row.kind.rawValue)")
        }
        return 0
    }
}
