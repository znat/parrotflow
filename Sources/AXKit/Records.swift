import ApplicationServices

public struct Heading: Equatable, Sendable {
    /// Where the heading sits in the records.
    public var index: Int
    /// 1 to 6 on a web page. Nil when the app gives none.
    public var level: Int?
    public var text: String
}

public struct Landmark: Equatable, Sendable {
    /// The subroles WebKit and Chromium give ARIA landmarks and logs. Chromium
    /// gives `feed` no subrole, so it cannot be told from a group.
    public enum Kind: String, Sendable {
        case main = "AXLandmarkMain"
        case navigation = "AXLandmarkNavigation"
        case banner = "AXLandmarkBanner"
        case complementary = "AXLandmarkComplementary"
        case contentinfo = "AXLandmarkContentInfo"
        case search = "AXLandmarkSearch"
        case region = "AXLandmarkRegion"
        case log = "AXApplicationLog"
    }

    public var index: Int
    public var kind: Kind
    /// Its title or description, such as "Messages in #general".
    public var label: String?
}

/// Pure functions over the records of one read. They take records in tree
/// order, as `Read.walk` returns them.
extension Read {
    /// The indices of the records drawn inside every scroll area and window
    /// above them. A record with no frame, or an empty one, follows its parent.
    public static func visible(_ records: [Record]) -> [Int] {
        var clip = [CGRect](repeating: .infinite, count: records.count)
        var shown = [Bool](repeating: true, count: records.count)
        for (index, record) in records.enumerated() {
            let above = record.parent.map { clip[$0] } ?? .infinite
            let box = record.frame.map { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }
            guard let box, box.width > 0, box.height > 0 else {
                clip[index] = above
                shown[index] = record.parent.map { shown[$0] } ?? true
                continue
            }
            shown[index] = box.intersects(above)
            clip[index] = [kAXScrollAreaRole, kAXWindowRole].contains(record.role) ? above.intersection(box) : above
        }
        return records.indices.filter { shown[$0] }
    }

    /// What the visible records say, one line each, in tree order. A value is
    /// always read; a title or description only on a record with no children,
    /// since a container's label repeats or sums up the text inside it.
    public static func visibleText(_ records: [Record]) -> [String] {
        var parents = Set<Int>()
        for record in records { if let parent = record.parent { parents.insert(parent) } }
        return visible(records).compactMap { index in
            let record = records[index]
            return record.value ?? (parents.contains(index) ? nil : record.title ?? record.description)
        }
    }

    /// Each AXHeading with its level and its text: its title, else its
    /// description, else the values below it joined.
    public static func headings(_ records: [Record]) -> [Heading] {
        records.indices.compactMap { index in
            let record = records[index]
            guard record.role == "AXHeading" else { return nil }
            let text = record.title ?? record.description
                ?? descendants(of: index, in: records).compactMap { records[$0].value }.joined(separator: " ")
            return Heading(index: index, level: record.number.flatMap { Int(exactly: $0) }, text: text)
        }
    }

    public static func landmarks(_ records: [Record]) -> [Landmark] {
        records.indices.compactMap { index in
            let record = records[index]
            guard let kind = record.subrole.flatMap(Landmark.Kind.init(rawValue:)) else { return nil }
            return Landmark(index: index, kind: kind, label: record.title ?? record.description)
        }
    }

    /// In tree order the records below one follow it, deeper than it.
    static func descendants(of index: Int, in records: [Record]) -> Range<Int> {
        let depth = records[index].depth
        let end = records[(index + 1)...].firstIndex { $0.depth <= depth } ?? records.count
        return (index + 1)..<end
    }
}
