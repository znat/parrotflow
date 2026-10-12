import AXKit
import ApplicationServices
import Foundation

/// `--tree-test`, last parts: the Teams and Outlook readers on windows built as records.
enum TeamsReaderTest {
    typealias Tree = GenericReaderTest.Tree

    /// A summary drawn 0×1 for screen readers, as Teams draws it.
    private static func summary(_ text: String) -> Tree {
        Tree(kAXHeadingRole, nil, title: text, frame: CGRect(x: 700, y: 500, width: 1, height: 2), [
            Tree(kAXStaticTextRole, text, frame: CGRect(x: 700, y: 500, width: 0, height: 1)),
        ])
    }

    private static func name(_ text: String) -> Tree {
        Tree(kAXPopUpButtonRole, nil, title: text, [Tree(kAXPopUpButtonRole, nil, title: text)])
    }

    private static let first = [
        summary("Ana Lima, Can you ask Ben Okoro to look at the layout?, 10:02"),
        Tree(kAXGroupRole, nil, subrole: "AXApplicationGroup", title: "Ana Lima, Can you ask Ben Okoro…", [
            Tree(kAXGroupRole, nil, [
                name("Ana Lima"), Tree(kAXStaticTextRole, "10:02"), Tree(kAXStaticTextRole, "Can you ask "),
                name("Ben Okoro"), Tree(kAXStaticTextRole, " to look at the layout?"),
                Tree(kAXButtonRole, "Like", [Tree(kAXStaticTextRole, "Like")]),
            ]),
        ]),
    ]

    private static let second = [
        Tree(kAXHeadingRole, nil, title: "1 October", [Tree(kAXGroupRole, nil, [Tree(kAXStaticTextRole, "1 October")])]),
        summary("Ben Okoro, run make test first, 10:05"),
        Tree(kAXGroupRole, nil, subrole: "AXApplicationGroup", title: "Ben Okoro, run make test first, 10:05", [
            Tree(kAXGroupRole, nil, [
                name("Ben Okoro"), Tree(kAXStaticTextRole, "10:05"), Tree(kAXStaticTextRole, "run"),
                Tree(kAXGroupRole, nil, subrole: "AXCodeStyleGroup", [Tree(kAXStaticTextRole, "make test")]),
                Tree(kAXStaticTextRole, "first"),
            ]),
        ]),
    ]

    /// The chat view as measured: a sidebar list beside the chat, a header
    /// heading, the message list, the composer below it. No main landmark.
    private static func chat(_ messages: [Tree], focus: Bool = true, focusSidebar: Bool = false) -> Tree {
        Tree(kAXWindowRole, title: "Chat | Design review | Microsoft Teams", [
            Tree("AXWebArea", nil, title: "Chat | Design review | Microsoft Teams", [
                Tree(kAXGroupRole, nil, subrole: "AXLandmarkNavigation", [Tree(kAXCheckBoxRole, "Chat")]),
                Tree(kAXGroupRole, nil, [
                    Tree(kAXHeadingRole, nil, title: "Chat", [Tree(kAXStaticTextRole, "Chat")]),
                    Tree(kAXOutlineRole, nil, [
                        Tree(kAXRowRole, nil, [Tree(kAXStaticTextRole, "Ops weekly: the build is green again")]),
                        Tree(kAXRowRole, nil, focused: focusSidebar, [Tree(kAXStaticTextRole, "Ana Lima")]),
                    ]),
                ]),
                Tree(kAXGroupRole, nil, [Tree(kAXHeadingRole, nil, title: "Design review (2)")]),
                Tree(kAXGroupRole, nil, [
                    Tree(kAXGroupRole, nil, title: "Message List", messages),
                    Tree(kAXGroupRole, nil, [Tree(kAXTextAreaRole, "my draft", focused: focus)]),
                ]),
            ]),
        ])
    }

    static func published(_ tree: Tree, generic: Bool = false) -> String {
        let screen = GenericReaderTest.screen(tree, app: "Microsoft Teams", chromium: true)
        switch generic ? GenericReader.interpret(screen) : TeamsReader.interpret(screen) {
        case .failure(let why): return "declined: \(why.rawValue)"
        case .success(let got):
            return "text=\(got.text); place=\(got.place); people=\(got.people.joined(separator: ","));"
                + " code=\(got.code.joined(separator: ",")); pane=\(got.walked?.branch ?? "")"
        }
    }

    private static func chosen(_ bundleID: String, everyApp: Bool = true) -> String {
        switch ContextReader.choose(for: Pipeline.App(name: "", bundleID: bundleID), everyApp: everyApp) {
        case .success(let reader): return reader.rawValue
        case .failure(let why): return "declined: \(why.rawValue)"
        }
    }

    private static let read = "text=Ana Lima 10:02 Can you ask Ben Okoro to look at the layout?\n"
        + "Ben Okoro 10:05 run make test first; place=Design review; people=Ana Lima,Ben Okoro;"
        + " code=make test; pane=messages"

    static let checks: [(what: String, got: String, want: String)] = [
        ("dispatch: new Teams", chosen("com.microsoft.teams2"), "teams"),
        ("dispatch: Outlook", chosen("com.microsoft.Outlook"), "outlook"),
        ("dispatch: classic Teams stays generic", chosen("com.microsoft.teams"), "generic"),
        ("switch off: Teams declined as before", chosen("com.microsoft.teams2", everyApp: false),
         "declined: \(Context.Declined.notReadable.rawValue)"),
        ("switch off: Outlook declined as before", chosen("com.microsoft.Outlook", everyApp: false),
         "declined: \(Context.Declined.notReadable.rawValue)"),
        ("one line per message, no summary twice, names from the name buttons, the sidebar left out",
         published(chat(first + second)), read),
        ("nothing focused: the list with the most messages",
         published(chat(first + second, focus: false)), read),
        ("a chat with no message: the place, not the sidebar",
         published(chat([])), "text=; place=Design review; people=; code=; pane=empty chat"),
        ("the focus outside any chat: the generic reader",
         published(chat([], focus: false, focusSidebar: true)), published(chat([], focus: false, focusSidebar: true), generic: true)),
        ("the focus in the sidebar beside a chat: the generic reader",
         published(chat(first + second, focus: false, focusSidebar: true)),
         published(chat(first + second, focus: false, focusSidebar: true), generic: true)),
        ("a message with no visible part: its title",
         published(chat([summary("Meeting started"),
                          Tree(kAXGroupRole, nil, subrole: "AXApplicationGroup", title: "Meeting started")])),
         "text=Meeting started; place=Design review; people=; code=; pane=messages"),
    ]

    static func run() -> Int32 { GenericReaderTest.report("teams reader", checks) }
}

enum OutlookReaderTest {
    typealias Tree = GenericReaderTest.Tree

    private static func id(_ identifier: String, _ tree: Tree) -> Tree {
        var tree = tree
        tree.record.identifier = identifier
        return tree
    }

    /// Outlook marks cells focused whatever has the focus.
    private static let header = id(OutlookReader.headerID, Tree(kAXGroupRole, nil, title: "Message header", [
        Tree(kAXStaticTextRole, "Q3 numbers (2) — ana@example.com"),
        Tree(kAXButtonRole, "Reply"),
        Tree(kAXCellRole, nil, focused: true, [Tree(kAXStaticTextRole, "From: Ana Lima <ana@example.com>")]),
    ]))

    private static let body = Tree(kAXGroupRole, nil, [
        Tree(kAXScrollAreaRole, nil, [
            Tree("AXWebArea", nil, [
                Tree(kAXHeadingRole, nil, [Tree(kAXStaticTextRole, "Q3 numbers")]),
                Tree(kAXGroupRole, nil, [Tree(kAXStaticTextRole, "The totals are in.", focused: true)]),
                Tree(kAXGroupRole, nil, subrole: "AXCodeStyleGroup", [Tree(kAXStaticTextRole, "SUM(B2:B9)")]),
                Tree("AXSecureTextField", "hunter2"),
                Tree(kAXTextFieldRole, "a field"),
            ]),
        ]),
    ])

    private static func draft(subject: String, withPage: Bool = false, body: String? = nil) -> [Tree] {
        let page = body.map { body in
            [Tree(kAXScrollAreaRole, nil, [Tree("AXWebArea", nil, [Tree(kAXTextAreaRole, body, focused: true, [
                Tree(kAXGroupRole, nil, [Tree(kAXStaticTextRole, "the body's paragraphs, never read")]),
            ])])])]
        } ?? (withPage ? [Tree("AXWebArea", nil, [Tree(kAXStaticTextRole, "quoted text")])] : [])
        return [
            Tree(kAXGroupRole, "Reply", page),
            Tree(kAXScrollAreaRole, nil, [id("toTextField", Tree(kAXTextFieldRole, "ben@example.com"))]),
            id(OutlookReader.subjectFieldID, Tree(kAXTextFieldRole, subject)),
        ]
    }

    private static let quotedHeader = "From: Ana Lima <ana@example.com>\nSent: Monday, 6 October 2026 09:12\n"
        + "To: Ben Okoro <ben@example.com>\nSubject: Lunch plans"
    private static let older = "From: Ben Okoro\nSent: Friday, 3 October 2026 17:40\nTo: Ana Lima\nSubject: Lunch plans"
    private static let thread = quotedHeader + "\n\nShall we try the new place on Friday?\n\n" + older
        + "\n\nAny ideas for lunch next week?\n  \nBen"
    private static let threadRead = quotedHeader + "\nShall we try the new place on Friday?\n" + older
        + "\nAny ideas for lunch next week?\nBen"
    private static let french = "De\u{a0}: Ana Lima\nEnvoyé\u{a0}: lundi 6 octobre 2026 09:12\nÀ\u{a0}: Ben Okoro\n"
        + "Objet\u{a0}: Déjeuner\n\nVendredi ?"

    private static func published(_ parts: [Tree], title: String? = "Inbox • nathan@example.com",
                                  focusedIdentifier: String? = nil, branch: String = "reading pane") -> String {
        let screen = OutlookReader.Screen(
            records: GenericReaderTest.records(Tree(kAXGroupRole, nil, parts)), app: "Microsoft Outlook",
            title: title, focusedIdentifier: focusedIdentifier, branch: branch)
        switch OutlookReader.interpret(screen) {
        case .failure(let why): return "declined: \(why.rawValue)"
        case .success(let got):
            return "text=\(got.text); place=\(got.place); code=\(got.code.joined(separator: ","));"
                + " pane=\(got.walked?.branch ?? "")"
        }
    }

    private static func longThread() -> String {
        let body = "Ok.\n" + quotedHeader + "\n" + String(repeating: "lunch ", count: 400)
        let screen = OutlookReader.Screen(
            records: GenericReaderTest.records(Tree(kAXGroupRole, nil, draft(subject: "Re: Lunch plans", body: body))),
            app: "Microsoft Outlook", title: nil)
        guard case .success(let got) = OutlookReader.interpret(screen) else { return "declined" }
        return "\(got.text.count) chars, \(got.text.hasPrefix(quotedHeader) ? "from the header" : "elsewhere")"
            + (got.truncated ? ", truncated" : "")
    }

    private static let split = OutlookReader.Peek(role: kAXSplitterRole, childRoles: [])

    static let checks: [(what: String, got: String, want: String)] = [
        ("the content area, never the toolbar holding the search field",
         "\(OutlookReader.content(among: [kAXGroupRole, kAXStaticTextRole, kAXButtonRole, kAXSplitGroupRole]) ?? -1)",
         "3"),
        ("no content area outside the main window",
         "\(OutlookReader.content(among: [kAXGroupRole, kAXTextFieldRole]) ?? -1)", "-1"),
        ("the message list and the splitter are never read",
         OutlookReader.parts([
            OutlookReader.Peek(role: kAXGroupRole, childRoles: [kAXGroupRole, kAXTableRole]), split,
            OutlookReader.Peek(role: kAXGroupRole, childRoles: [kAXStaticTextRole, kAXButtonRole]),
            OutlookReader.Peek(role: kAXScrollAreaRole, childRoles: []),
            OutlookReader.Peek(role: kAXGroupRole, childRoles: [kAXGroupRole]),
            OutlookReader.Peek(role: kAXOutlineRole, childRoles: [kAXRowRole]),
         ]).map(String.init).joined(separator: ","),
         "2,3,4"),
        ("the body, and the subject without its address and count, focus flags ignored",
         published([header, body]),
         "text=Q3 numbers\nThe totals are in.\nSUM(B2:B9); place=Q3 numbers; code=SUM(B2:B9); pane=reading pane"),
        ("a draft: the subject only",
         published(draft(subject: "Lunch plans")), "text=; place=Lunch plans; code=; pane=compose"),
        ("a draft with its page: still only the subject",
         published(draft(subject: "Lunch plans", withPage: true)), "text=; place=Lunch plans; code=; pane=compose"),
        ("a reply: the quoted thread, newest first, without the draft above it",
         published(draft(subject: "Re: Lunch plans", body: "Friday works for me.\n\n" + thread)),
         "text=\(threadRead); place=Re: Lunch plans; code=; pane=reply"),
        ("a reply with nothing typed yet: the whole thread",
         published(draft(subject: "Re: Lunch plans", body: "\n" + thread)),
         "text=\(threadRead); place=Re: Lunch plans; code=; pane=reply"),
        ("a French header, a space before each colon",
         published(draft(subject: "RE: Déjeuner", body: "Oui.\n\n" + french)),
         "text=\(french.replacingOccurrences(of: "\n\n", with: "\n")); place=RE: Déjeuner; code=; pane=reply"),
        ("a new mail whose draft has lines like a header: the subject only",
         published(draft(subject: "Notes", body: "Agenda: the budget\nOwner: Ana\nNotes: none\n\nSee you there.")),
         "text=; place=Notes; code=; pane=compose"),
        ("draft labels whose last value ends the subject: still the subject only",
         published(draft(subject: "Lunch with Ana", body: "Where: the canteen\nWhen: noon\nWith: Ana\n\nOk?")),
         "text=; place=Lunch with Ana; code=; pane=compose"),
        ("a reply whose subject was changed: the subject only",
         published(draft(subject: "Friday", body: "Fine.\n\n" + thread)), "text=; place=Friday; code=; pane=compose"),
        ("Windows line ends",
         published(draft(subject: "Re: Lunch plans",
                         body: ("Ok.\n\n" + thread).replacingOccurrences(of: "\n", with: "\r\n"))),
         "text=\(threadRead); place=Re: Lunch plans; code=; pane=reply"),
        ("a long thread: its first 2000 characters, the mail replied to",
         longThread(), "2000 chars, from the header, truncated"),
        ("the caret in the subject: the window title instead",
         published(draft(subject: "Lunch plans"), focusedIdentifier: OutlookReader.subjectFieldID),
         "text=; place=Inbox; code=; pane=compose"),
        ("no reading pane: the window title only",
         published([], title: "Q3 numbers — ana@example.com", branch: "window"),
         "text=; place=Q3 numbers; code=; pane=window"),
        ("no mail and no title", published([], title: nil), "declined: \(Context.Declined.blank.rawValue)"),
    ]

    static func run() -> Int32 { GenericReaderTest.report("outlook reader", checks) }
}
