import AXKit

/// Pure helpers over the records of one `Read.walk`, which come in tree order:
/// a parent before its children, and a subtree in one run.
enum RecordTree {

    /// The focused element's index: the end of a chain of records that match
    /// `path` one level at a time from the window down. Records hold no live
    /// reference, so this is how the climb and the walk meet.
    ///
    /// A step no child matches is skipped. Slack's web area has an
    /// AXScrollArea for a parent, and that scroll area is nobody's child (10-09).
    /// Twins that match the whole path are told apart by the focus flag. A
    /// focused element whose frame or label changed between the two reads is
    /// found by its role and that flag, even when an unfocused twin still matches.
    static func locate(_ path: [Record], in records: [Record]) -> Int? {
        guard let window = path.first, let root = records.first, same(root, window) else { return nil }
        var children: [Int: [Int]] = [:]
        for (index, record) in records.enumerated() {
            if let parent = record.parent { children[parent, default: []].append(index) }
        }
        var frontier = [0]
        for (step, record) in path.enumerated().dropFirst() {
            let below = frontier.flatMap { children[$0] ?? [] }
            let next = below.filter { same(records[$0], record) }
            if step == path.count - 1 {
                let moved = below.first { records[$0].focused && records[$0].role == record.role }
                return next.first { records[$0].focused } ?? moved ?? next.first
            }
            if !next.isEmpty { frontier = next }
        }
        return frontier.first { records[$0].focused } ?? frontier.first
    }

    /// A draft or a focus flag can change between the climb and the walk, so
    /// neither is compared.
    private static func same(_ a: Record, _ b: Record) -> Bool {
        a.role == b.role && a.subrole == b.subrole && a.title == b.title
            && a.description == b.description && a.identifier == b.identifier && a.frame == b.frame
    }

    /// The record and the ones under it, less than `depth` levels down.
    static func below(_ index: Int, in records: [Record], depth: Int) -> [Int] {
        let base = records[index].depth
        let end = records[(index + 1)...].firstIndex { $0.depth <= base } ?? records.count
        return (index..<end).filter { records[$0].depth - base < depth }
    }

    /// The ancestors of a record, nearest first, the root last.
    static func ancestors(of index: Int, in records: [Record]) -> [Int] {
        var found: [Int] = []
        var current = records[index].parent
        while let up = current {
            found.append(up)
            current = records[up].parent
        }
        return found
    }
}
