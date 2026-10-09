import AXKit
import ApplicationServices
import Foundation

/// `--tree-test`, second half: `SlackReader` on the fixtures `TreeContext` is
/// scored on, turned into records, then on whole windows built as records.
///
/// The label readings are rules both readers call, so they count for both.
enum SlackReaderTest {

    typealias Node = TreeContext.Node

    /// An element and what is under it, for building a window by hand.
    struct Tree {
        var record: Record
        var children: [Tree] = []

        /// Slack puts a text's words in its value and a group's in its description.
        init(_ role: String, _ label: String? = nil, subrole: String? = nil, named name: String? = nil,
             frame: CGRect? = nil, focused: Bool = false, _ children: [Tree] = []) {
            let valued = [kAXStaticTextRole, kAXTextAreaRole].contains(role)
            record = Record(role: role, subrole: subrole, description: valued ? name : label,
                            value: valued ? label : nil, frame: frame.map(Rect.init), focused: focused)
            self.children = children
        }
    }

    /// In tree order, as `Read.walk` returns them.
    static func records(_ tree: Tree) -> [Record] {
        var out: [Record] = []
        func add(_ tree: Tree, depth: Int, parent: Int?) {
            var record = tree.record
            (record.depth, record.parent) = (depth, parent)
            out.append(record)
            let index = out.count - 1
            for child in tree.children { add(child, depth: depth + 1, parent: index) }
        }
        add(tree, depth: 0, parent: nil)
        return out
    }

    /// The climb from the focused record: the window, then each element down to it.
    static func path(in records: [Record]) -> [Record] {
        guard var at = records.firstIndex(where: \.focused) else { return [] }
        var chain = [records[at]]
        while let up = records[at].parent {
            chain.insert(records[up], at: 0)
            at = up
        }
        return chain
    }

    /// A case's labels as Slack draws them: a message group under the pane,
    /// the words said in it under the group, everything else beside them.
    static func tree(_ nodes: [Node], title: String?) -> Tree {
        var pane: [Tree] = []
        for node in nodes {
            let child = Tree(node.role, node.label, subrole: node.code ? "AXCodeStyleGroup" : nil,
                             frame: node.frame)
            let opens = node.inMessage && TreeContext.speaker(in: node.label) != nil
            if node.inMessage && !opens, !pane.isEmpty {
                pane[pane.count - 1].children.append(child)
            } else {
                pane.append(child)
            }
        }
        var window = Tree(kAXWindowRole, nil, [Tree(kAXGroupRole, nil, pane)])
        window.record.title = title
        return window
    }

    // MARK: - Whole windows

    private static let sidebar = Tree("AXOutline", nil, [
        Tree(kAXRowRole, "Mik Okun (notifications snoozed), status: PTO"),
        Tree(kAXRowRole, "sws-engineering"),
    ])

    /// Two conversations in one window, in identical shells. The composer in
    /// the second one has the caret.
    private static let twoPanes = Tree(kAXWindowRole, nil, [
        sidebar,
        Tree(kAXGroupRole, nil, [
            Tree(kAXGroupRole, nil, [
                Tree("AXList", "Tasmeen Kathuria (direct message)"),
                Tree(kAXGroupRole, "Tasmeen Kathuria: can we talk Monday? 8:11 PM."),
                Tree(kAXTextAreaRole, "Message to Tasmeen Kathuria"),
            ]),
            Tree(kAXGroupRole, nil, [
                Tree("AXList", "sws-engineering (private channel)"),
                Tree(kAXGroupRole, "Martin Alix: the deploy hook fired. 4:38 PM.", [
                    Tree(kAXStaticTextRole, "the deploy hook fired"),
                ]),
                Tree(kAXGroupRole, nil, [
                    Tree(kAXTextAreaRole, "what I am dictating", focused: true),
                ]),
            ]),
        ]),
    ])

    /// Slack's Threads view: one flat list, each thread closed by its reply box.
    private static let threads = Tree(kAXWindowRole, nil, [
        Tree("AXList", "Threads, 4 new replies", [
            Tree(kAXGroupRole, "Mik Okun: the first thread. 9:00 PM."),
            Tree(kAXGroupRole, nil, [
                Tree(kAXGroupRole, nil, [
                    Tree(kAXTextAreaRole, "a reply", named: "Reply to thread in sws-engineering"),
                ]),
            ]),
            Tree(kAXGroupRole, "Martin Alix: the second thread. 9:01 PM."),
            Tree(kAXGroupRole, "Parsa Gouran: still the second. 9:02 PM."),
            Tree(kAXGroupRole, nil, [
                Tree(kAXGroupRole, nil, [
                    Tree(kAXTextAreaRole, "draft", named: "Reply to thread with Tasmeen Kathuria", focused: true),
                ]),
            ]),
        ]),
    ])

    /// A composer and the sidebar, and no conversation.
    private static let noPane = Tree(kAXWindowRole, nil, [
        sidebar,
        Tree(kAXGroupRole, nil, [Tree(kAXTextAreaRole, "draft", focused: true)]),
    ])

    /// A message group over more labels than the walk keeps.
    private static let longPane = Tree(kAXGroupRole, nil, [
        Tree("AXList", "sws-engineering (channel)"),
        Tree(kAXGroupRole, "Mik Okun: a long one. 9:00 PM.",
             (0..<(SlackReader.nodeLimit + 5)).map { Tree(kAXStaticTextRole, "line \($0)") }),
    ])

    /// A label 25 levels under the pane is read, one 26 levels under is not.
    private static let deepPane: Tree = {
        var inner = Tree(kAXGroupRole, "deep enough", [Tree(kAXStaticTextRole, "too deep")])
        for _ in 2..<(SlackReader.paneDepth - 1) { inner = Tree(kAXGroupRole, nil, [inner]) }
        return Tree(kAXGroupRole, nil, [
            Tree("AXList", "sws-engineering (channel)"),
            Tree(kAXGroupRole, "Mik Okun: deep. 9:00 PM.", [inner]),
        ])
    }()

    private static let longSidebar = Tree(kAXWindowRole, nil, [
        Tree("AXOutline", nil, (0..<(TreeContext.maxRoster + 10)).map { Tree(kAXRowRole, "channel-\($0)") }),
    ])

    private static func published(_ tree: Tree, lost: Bool = false, hidden: Bool = false) -> String {
        let window = records(tree)
        var trail = path(in: window)
        let name = trail.last.flatMap { $0.title ?? $0.description }
        if lost { trail[trail.count - 1].description = "Message to nobody" }
        if hidden { trail.insert(Record(role: kAXScrollAreaRole), at: 1) }
        return TreeContextCommand.published(SlackReader.interpret(
            SlackReader.Screen(window: window, path: trail, focusedName: name)))
    }

    private static func labels(under tree: Tree) -> [String] {
        SlackReader.nodes(under: [0], in: records(tree)).map(\.label)
    }

    private static let windows: [(what: String, got: String, want: String)] = [
        ("the pane around the caret",
         published(twoPanes),
         "text=Martin Alix: the deploy hook fired.; place=#sws-engineering; people=Martin Alix; code=;"
            + " roster=Mik Okun,#sws-engineering"),
        ("a thread in the Threads view",
         published(threads),
         "text=Martin Alix: the second thread.\nParsa Gouran: still the second.; place=Tasmeen Kathuria;"
            + " people=Martin Alix,Parsa Gouran; code=; roster="),
        ("a parent the walk never meets",
         published(twoPanes, hidden: true),
         "text=Martin Alix: the deploy hook fired.; place=#sws-engineering; people=Martin Alix; code=;"
            + " roster=Mik Okun,#sws-engineering"),
        ("no conversation, the sidebar still",
         published(noPane),
         "text=; place=; people=; code=; roster=Mik Okun,#sws-engineering"),
        ("a caret the walk cannot find",
         published(twoPanes, lost: true),
         "text=; place=; people=; code=; roster=Mik Okun,#sws-engineering"),
        ("the node limit", "\(labels(under: longPane).count)", "\(SlackReader.nodeLimit)"),
        ("the depth limit",
         labels(under: deepPane).filter { $0.hasPrefix("deep") || $0.hasPrefix("too") }.joined(separator: ","),
         "deep enough"),
        ("the roster limit",
         "\(SlackReader.roster(in: records(longSidebar)).count)", "\(TreeContext.maxRoster)"),
    ]

    static func run() -> Int32 {
        var failed: [String] = []
        for reading in TreeContextCommand.readings where reading.got != reading.want {
            failed.append("  \(reading.what): want \(reading.want ?? "nil"), got \(reading.got ?? "nil")")
        }
        var extra: [String] = []
        for one in TreeContextCommand.cases {
            let window = records(tree(one.nodes, title: one.title))
            let nodes = SlackReader.nodes(under: [1], in: window)
            if nodes != one.nodes { extra.append("  \(one.name) nodes: \(nodes.count) read, \(one.nodes.count) drawn") }
            let got = TreeContext.assemble(nodes, title: window[0].title)
            if got.place != one.place { failed.append("  \(one.name) place: want \(one.place), got \(got.place)") }
            if got.people != one.people { failed.append("  \(one.name) people: want \(one.people), got \(got.people)") }
            if got.code != one.code { failed.append("  \(one.name) code: want \(one.code), got \(got.code)") }
            if got.text != one.text {
                failed.append("  \(one.name) text: want \(one.text.replacingOccurrences(of: "\n", with: " | ")),"
                    + " got \(got.text.replacingOccurrences(of: "\n", with: " | "))")
            }
        }
        for window in windows where window.got != window.want {
            extra.append("  \(window.what): want \(window.want.replacingOccurrences(of: "\n", with: " | ")),"
                + " got \(window.got.replacingOccurrences(of: "\n", with: " | "))")
        }

        let total = TreeContextCommand.readings.count + TreeContextCommand.cases.count * 4
        let extras = TreeContextCommand.cases.count + windows.count
        print(failed.isEmpty ? "✓ slack reader: \(total) of \(total)" : "✗ slack reader: \(failed.count) of \(total)")
        failed.forEach { print($0) }
        print(extra.isEmpty ? "✓ slack reader, records and whole windows: \(extras) of \(extras)"
                            : "✗ slack reader, records and whole windows: \(extra.count) of \(extras)")
        extra.forEach { print($0) }
        return failed.isEmpty && extra.isEmpty ? 0 : 1
    }
}
