import AXKit
import ApplicationServices
import Foundation
import Yams

/// `--tree-test`, third part: `GenericReader` on windows built as records.
enum GenericReaderTest {

    /// An element and what is under it. Text roles carry their words in the value.
    struct Tree {
        var record: Record
        var children: [Tree] = []

        init(_ role: String, _ text: String? = nil, subrole: String? = nil, title: String? = nil,
             url: String? = nil, frame: CGRect? = nil, focused: Bool = false, _ children: [Tree] = []) {
            let valued = [kAXStaticTextRole, kAXTextAreaRole, kAXTextFieldRole, "AXSecureTextField"].contains(role)
            record = Record(role: role, subrole: subrole, title: title, description: valued ? nil : text,
                            value: valued ? text : nil, url: url, frame: frame.map(Rect.init), focused: focused)
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

    /// The climb ends at the focused record, or at the window when nothing is focused.
    static func screen(_ tree: Tree, app: String = "Mail", document: String? = nil,
                       browser: Bool = false, chromium: Bool = false) -> GenericReader.Screen {
        let records = records(tree)
        let path = SlackReaderTest.path(in: records)
        return GenericReader.Screen(records: records, path: path.isEmpty ? [records[0]] : path, app: app,
                                    document: document, browser: browser, chromium: chromium)
    }

    static func published(_ screen: GenericReader.Screen) -> String {
        switch GenericReader.interpret(screen) {
        case .failure(let why): return "declined: \(why.rawValue)"
        case .success(let got):
            return "text=\(got.text); place=\(got.place); code=\(got.code.joined(separator: ","));"
                + " pane=\(got.walked?.branch ?? "")"
        }
    }

    private static let long = String(repeating: "word ", count: 50).trimmingCharacters(in: .whitespaces)

    /// A sidebar beside a message pane, a toolbar, a scrolled-out line, and
    /// the field with the caret.
    private static let mail = Tree(kAXWindowRole, title: "Inbox (1,234) — name@mail", frame: box(0, 0, 1000, 800), [
        Tree(kAXToolbarRole, nil, frame: box(0, 0, 1000, 40), [Tree(kAXStaticTextRole, "Get Mail")]),
        Tree(kAXGroupRole, nil, subrole: "AXLandmarkNavigation", frame: box(0, 40, 200, 760), [
            Tree(kAXStaticTextRole, "Inbox", frame: box(0, 40, 200, 20)),
        ]),
        Tree(kAXScrollAreaRole, nil, frame: box(200, 40, 800, 700), [
            Tree(kAXGroupRole, nil, frame: box(200, 40, 800, 1400), [
                Tree(kAXStaticTextRole, long, frame: box(200, 40, 800, 100)),
                Tree(kAXGroupRole, nil, frame: box(200, 140, 800, 20), [
                    Tree(kAXStaticTextRole, "Lunch at noon?", frame: box(200, 140, 800, 20)),
                ]),
                Tree(kAXStaticTextRole, "Lunch at noon?", frame: box(200, 140, 800, 20)),
                Tree(kAXButtonRole, "Reply", frame: box(200, 160, 80, 20), [Tree(kAXStaticTextRole, "Reply")]),
                Tree(kAXGroupRole, nil, subrole: "AXCodeStyleGroup", frame: box(200, 180, 800, 20), [
                    Tree(kAXStaticTextRole, "make test", frame: box(200, 180, 800, 20)),
                ]),
                Tree(kAXTextFieldRole, "a draft somewhere else", frame: box(200, 200, 800, 20)),
                Tree("AXSecureTextField", "hunter2", frame: box(200, 220, 800, 20)),
                Tree(kAXStaticTextRole, "scrolled away", frame: box(200, 1200, 800, 20)),
                Tree(kAXTextAreaRole, "what I am dictating", frame: box(200, 600, 800, 100), focused: true),
            ]),
        ]),
    ])

    /// A field with little around it: the pane falls back to the web area.
    private static let page = Tree(kAXWindowRole, title: "Docs - Google Chrome - Nathan (Work)", [
        Tree("AXWebArea", nil, title: "Pull requests · parrotflow", url: "https://www.github.com/znat", [
            Tree(kAXStaticTextRole, "Open"),
            Tree(kAXGroupRole, nil, [Tree(kAXTextAreaRole, "a comment", focused: true)]),
        ]),
    ])

    /// A chat in a Chromium page: a banner, a channel list, a side panel,
    /// and the message log inside main. The composer sits outside the log.
    private static func chat(focusInLog: Bool = false, main: Bool = true, focusPage: Bool = false) -> Tree {
        let log = Tree(kAXGroupRole, nil, subrole: "AXApplicationLog", [
            Tree(kAXStaticTextRole, "Ana: lunch at noon?"),
            Tree(kAXStaticTextRole, "Ben: sure", focused: focusInLog),
        ])
        let content = [
            Tree(kAXHeadingRole, nil, [Tree(kAXStaticTextRole, "general")]),
            log,
            Tree(kAXGroupRole, nil, subrole: "AXApplicationLog", [Tree(kAXStaticTextRole, "a second log")]),
            Tree(kAXTextAreaRole, "my draft", focused: !focusInLog && !focusPage),
        ]
        return Tree(kAXWindowRole, title: "general (3) - Slack-like", [
            Tree("AXWebArea", nil, title: "general", focused: focusPage, [
                Tree(kAXGroupRole, nil, subrole: "AXLandmarkBanner", [Tree(kAXStaticTextRole, "Search")]),
                Tree(kAXGroupRole, nil, subrole: "AXLandmarkNavigation", [Tree(kAXStaticTextRole, "random")]),
                Tree(kAXGroupRole, nil, subrole: "AXLandmarkComplementary", [Tree(kAXStaticTextRole, "Details")]),
                main ? Tree(kAXGroupRole, nil, subrole: "AXLandmarkMain", content) : Tree(kAXGroupRole, nil, content),
            ]),
        ])
    }

    private static let editor = Tree(kAXWindowRole, title: "Report.pages — Edited", [
        Tree(kAXTextAreaRole, "the whole document", focused: true),
    ])

    private static func box(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> CGRect {
        CGRect(x: x, y: y, width: w, height: h)
    }

    private static func chosen(_ bundleID: String, everyApp: Bool = true) -> String {
        switch ContextReader.choose(for: Pipeline.App(name: "", bundleID: bundleID), everyApp: everyApp) {
        case .success(let reader): return reader.rawValue
        case .failure(let why): return "declined: \(why.rawValue)"
        }
    }

    private static func screenRead(_ yaml: String) -> String {
        let config = yaml.isEmpty ? Config() : try? YAMLDecoder().decode(Config.self, from: yaml)
        guard let config else { return "did not parse" }
        return config.transcription.context.everyApp ? "every app" : "terminals and Slack"
    }

    private static func owned(_ app: String, by owner: String?) -> String {
        ContextReader.check(owner: owner, of: Pipeline.App(name: "", bundleID: app))
            .map { "declined: \($0.rawValue)" } ?? "read"
    }

    static let checks: [(what: String, got: String, want: String)] = [
        ("denied: 1Password", chosen("com.1password.1password"), "declined: \(Context.Declined.denied.rawValue)"),
        ("denied: Bitwarden", chosen("com.bitwarden.desktop"), "declined: \(Context.Declined.denied.rawValue)"),
        ("denied: Keychain Access", chosen("com.apple.keychainaccess"),
         "declined: \(Context.Declined.denied.rawValue)"),
        ("denied: System Settings", chosen("com.apple.systempreferences"),
         "declined: \(Context.Declined.denied.rawValue)"),
        ("switch off: declined as before", chosen("com.apple.systempreferences", everyApp: false),
         "declined: \(Context.Declined.notReadable.rawValue)"),
        ("switch off: a terminal", chosen("com.mitchellh.ghostty", everyApp: false), "terminal"),
        ("switch off: Slack", chosen("com.tinyspeck.slackmacgap", everyApp: false), "slack"),
        ("switch on: any other app", chosen("com.google.Chrome"), "generic"),
        ("config: an empty file reads every app", screenRead(""), "every app"),
        ("config: no context block reads every app",
         screenRead("transcription:\n  context_spelling:\n    enabled: true\n"), "every app"),
        ("config: a context block without the switch reads every app",
         screenRead("transcription:\n  context:\n    after_release_seconds: 0.2\n"), "every app"),
        ("config: every_app false keeps it to terminals and Slack",
         screenRead("transcription:\n  context:\n    every_app: false\n"), "terminals and Slack"),
        ("denied: Apple Passwords", chosen("com.apple.Passwords"), "declined: \(Context.Declined.denied.rawValue)"),
        ("owner: the app itself", owned("com.google.chrome", by: "com.google.Chrome"), "read"),
        ("owner: a password manager's panel over a browser",
         owned("com.google.Chrome", by: "com.1password.1password"), "declined: \(Context.Declined.denied.rawValue)"),
        ("owner: an auth prompt over a terminal",
         owned("com.mitchellh.ghostty", by: "com.apple.SecurityAgent"), "declined: \(Context.Declined.denied.rawValue)"),
        ("owner: another app", owned("com.google.Chrome", by: "notion.id"),
         "declined: \(Context.Declined.appChanged.rawValue)"),
        ("owner: unknown", owned("com.google.Chrome", by: nil), "declined: \(Context.Declined.appChanged.rawValue)"),
        ("scrub: counts and an email", GenericReader.scrub("Inbox (1,234) — name@mail", app: "Mail"), "Inbox"),
        ("scrub: marks, unread count, app name",
         GenericReader.scrub("! Tasmeen Kathuria (DM) - Swoop - 21 new items - Slack", app: "Slack"),
         "Tasmeen Kathuria (DM) - Swoop"),
        ("scrub: the app name and the profile after it",
         GenericReader.scrub("(3) Feed | LinkedIn - Google Chrome - Nathan (Work)", app: "Google Chrome"),
         "Feed - LinkedIn"),
        ("scrub: nothing to take", GenericReader.scrub("Report Q3.pages", app: "Pages"), "Report Q3.pages"),
        ("scrub: only an address", GenericReader.scrub("nathan@example.com", app: "Mail"), ""),
        ("scrub: a 100k title of one token, in under 50 ms", {
            let started = Date()
            let got = GenericReader.scrub(String(repeating: "a", count: 100_000), app: "Chrome")
            return Date().timeIntervalSince(started) < 0.05 && got.count == GenericReader.scrubLimit ? "fast" : "slow"
        }(), "fast"),
        ("scrub: a 100k title of digits in brackets", {
            let started = Date()
            _ = GenericReader.scrub("(" + String(repeating: "1 ", count: 50_000), app: "Chrome")
            return Date().timeIntervalSince(started) < 0.05 ? "fast" : "slow"
        }(), "fast"),
        ("place: at most 80 chars, cut on a word",
         "\(GenericReader.place(screen(Tree(kAXWindowRole, title: long))).count)", "79"),
        ("the pane around the caret",
         published(screen(mail)),
         "text=\(long)\nLunch at noon?\nmake test; place=Inbox; code=make test; pane=pane"),
        ("the web area when the pane is thin, with the host in a browser",
         published(screen(page, app: "Google Chrome", browser: true)),
         "text=Open; place=Pull requests · parrotflow — github.com; code=; pane=web area"),
        ("no host outside a browser",
         published(screen(page, app: "Notion")),
         "text=Open; place=Pull requests · parrotflow; code=; pane=web area"),
        ("a document editor gives only the place",
         published(screen(editor, app: "Pages", document: "file:///Users/someone/Report%20Q3.pages")),
         "text=; place=Report Q3.pages; code=; pane=window"),
        ("chromium: the first log in main, the composer outside it",
         published(screen(chat(), app: "Chat", chromium: true)),
         "text=Ana: lunch at noon?\nBen: sure; place=general; code=; pane=log"),
        ("chromium: the log holding the focus",
         published(screen(chat(focusInLog: true), app: "Chat", chromium: true)),
         "text=Ana: lunch at noon?; place=general; code=; pane=log"),
        ("chromium: no main, so the climb, without banner, navigation or side panel",
         published(screen(chat(main: false), app: "Chat", chromium: true)),
         "text=general\nAna: lunch at noon?\nBen: sure\na second log; place=general; code=; pane=web area"),
        ("not chromium: the side panel is read",
         published(screen(chat(main: false), app: "Chat")),
         "text=Details\ngeneral\nAna: lunch at noon?\nBen: sure\na second log; place=general; code=; pane=web area"),
        ("a row repeated inside one value is kept",
         published(screen(Tree(kAXWindowRole, nil, [
            Tree(kAXStaticTextRole, "yes\nyes"),
            Tree(kAXTextAreaRole, "draft", focused: true),
         ]))),
         "text=yes\nyes; place=; code=; pane=window"),
        ("nothing focused: the page the walk found names the place",
         published(screen(Tree(kAXWindowRole, title: "Docs - Google Chrome", [
            Tree("AXWebArea", nil, title: "Pull requests", url: "https://github.com/znat", [
                Tree(kAXStaticTextRole, "Open"),
            ]),
         ]), app: "Google Chrome", browser: true, chromium: true)),
         "text=Open; place=Pull requests — github.com; code=; pane=window"),
        ("a focused page is not a field",
         published(screen(chat(focusPage: true), app: "Chat", chromium: true)),
         "text=Ana: lunch at noon?\nBen: sure; place=general; code=; pane=log"),
        ("a button with a sentence in it is read, a label is not",
         published(screen(Tree(kAXWindowRole, nil, [
            Tree(kAXButtonRole, "Send", [Tree(kAXStaticTextRole, "Send")]),
            Tree(kAXButtonRole, nil, [Tree(kAXStaticTextRole, "Ana: the deploy is done")]),
            Tree(kAXTextAreaRole, "draft", focused: true),
         ]))),
         "text=Ana: the deploy is done; place=; code=; pane=window"),
        ("nothing at all",
         published(screen(Tree(kAXWindowRole, nil, [Tree(kAXTextAreaRole, "draft", focused: true)]))),
         "declined: \(Context.Declined.blank.rawValue)"),
    ]

    static func run() -> Int32 { report("generic reader", checks) }

    static func report(_ name: String, _ checks: [(what: String, got: String, want: String)]) -> Int32 {
        let failed = checks.filter { $0.got != $0.want }
        print(failed.isEmpty ? "✓ \(name): \(checks.count) of \(checks.count)"
                             : "✗ \(name): \(failed.count) of \(checks.count)")
        for check in failed {
            print("  \(check.what): want \(check.want.replacingOccurrences(of: "\n", with: " | ")),"
                + " got \(check.got.replacingOccurrences(of: "\n", with: " | "))")
        }
        return failed.isEmpty ? 0 : 1
    }
}
