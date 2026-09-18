import Foundation

/// `--tree-test` — scores `TreeContext.assemble` and the label readings under
/// it against labels a real Slack window produced.
///
/// Only the pure half is here. The walk itself depends on a running Slack and
/// on what is on screen, and a fixture that stubbed the tree would be scoring
/// the stub — the same split `--context-test` makes for terminals. The walk is
/// checked with `--peek` against a real window.
///
/// The labels below are shapes, not a transcript: names are the ones already in
/// `SoundCommand`'s table or invented, and no message text from a real
/// conversation is kept in the repository.
enum TreeContextCommand {

    private typealias Node = TreeContext.Node

    /// A channel, its header, its furniture, and two messages.
    private static let channel: [Node] = [
        Node(role: "AXGroup", label: "Channel sws-engineering", frame: nil),
        Node(role: "AXButton", label: "View all 14 members. Includes Mik Okun, Parsa Gouran, and Sa…",
             frame: nil),
        Node(role: "AXList", label: "sws-engineering (private channel)", frame: nil),
        Node(role: "AXGroup", label: "Martin Alix: the deploy hook fired. 4:38 PM. 10 reactions, 9 replies.",
             frame: nil, inMessage: true),
        Node(role: "AXStaticText", label: "the deploy hook fired", frame: nil, inMessage: true),
        Node(role: "AXStaticText", label: "Today at 4:38:29 PM", frame: nil, inMessage: true),
        Node(role: "AXStaticText", label: "React with +1", frame: nil, inMessage: true),
        Node(role: "AXGroup", label: "Mik Okun: I set EDITOR_FRAME_ANCESTORS in my .env file. 12:09 AM. 3 replies, 1 link.",
             frame: nil, inMessage: true),
        Node(role: "AXStaticText", label: "EDITOR_FRAME_ANCESTORS=", frame: nil,
             inMessage: true, code: true),
        Node(role: "AXStaticText", label: "Bold", frame: nil),
        Node(role: "AXStaticText", label: "Schedule for later", frame: nil),
        Node(role: "AXTextArea", label: "what I am dictating right now", frame: nil),
    ]

    /// A group direct message, where the conversation is named after the people
    /// in it and there is no channel anywhere.
    private static let groupDM: [Node] = [
        Node(role: "AXList", label: "Matthieu Joannon, Mik Okun (group direct message)", frame: nil),
        Node(role: "AXGroup", label: "Matthieu Joannon: shipping it after the review. 9:03 PM.",
             frame: nil, inMessage: true),
        Node(role: "AXStaticText", label: "2 days ago", frame: nil, inMessage: true),
        Node(role: "AXGroup", label: "mik: shipping it too. 9:05 PM.", frame: nil, inMessage: true),
    ]

    /// Two people writing the same short word, each announced and then drawn.
    /// The copy inside an announcement's box goes; the other message stays.
    private static let sameWords: [Node] = [
        Node(role: "AXList", label: "Mik Okun, Martin Alix (group direct message)", frame: nil),
        Node(role: "AXGroup", label: "Mik Okun: ok. 9:03 PM.",
             frame: CGRect(x: 0, y: 0, width: 400, height: 40), inMessage: true),
        Node(role: "AXStaticText", label: "ok",
             frame: CGRect(x: 10, y: 10, width: 40, height: 16), inMessage: true),
        Node(role: "AXGroup", label: "Martin Alix: ok. 9:04 PM.",
             frame: CGRect(x: 0, y: 50, width: 400, height: 40), inMessage: true),
        Node(role: "AXStaticText", label: "ok",
             frame: CGRect(x: 10, y: 60, width: 40, height: 16), inMessage: true),
        // A time somebody typed, in a label Slack did not announce.
        Node(role: "AXStaticText", label: "see you at 9:03 PM.",
             frame: CGRect(x: 10, y: 110, width: 200, height: 16), inMessage: true),
    ]

    /// No list label at all: the title is the only thing naming the place, and
    /// it arrives with an unread count and a notification mark on it.
    private static let titleOnly: [Node] = [
        Node(role: "AXGroup", label: "Tasmeen Kathuria: can we talk Monday? 8:11 PM.",
             frame: nil, inMessage: true),
    ]

    private struct Case {
        let name: String
        let nodes: [Node]
        let title: String?
        let place: String
        let people: [String]
        let text: String
        var code: [String] = []
    }

    private static let cases: [Case] = [
        Case(name: "channel", nodes: channel, title: "#sws-engineering - Swoop - 21 new items - Slack",
             place: "#sws-engineering",
             // The header is read before the messages, so its three members
             // land first. Order is what a later stage sees, so it is pinned.
             people: ["Mik Okun", "Parsa Gouran", "Martin Alix"],
             text: "Martin Alix: the deploy hook fired.\n"
                 + "Mik Okun: I set EDITOR_FRAME_ANCESTORS in my .env file.\n"
                 + "EDITOR_FRAME_ANCESTORS=",
             code: ["EDITOR_FRAME_ANCESTORS="]),
        Case(name: "group dm", nodes: groupDM, title: "! Matthieu Joannon (DM) - Swoop - Slack",
             place: "Matthieu Joannon, Mik Okun",
             people: ["Matthieu Joannon"],
             text: "Matthieu Joannon: shipping it after the review.\n"
                 + "mik: shipping it too."),
        Case(name: "same words", nodes: sameWords, title: nil,
             place: "Mik Okun, Martin Alix",
             people: ["Mik Okun", "Martin Alix"],
             text: "Mik Okun: ok.\nMartin Alix: ok.\nsee you at 9:03 PM."),
        Case(name: "title only", nodes: titleOnly, title: "! Tasmeen Kathuria (DM) - Swoop - 21 new items - Slack",
             place: "Tasmeen Kathuria (DM) - Swoop",
             people: ["Tasmeen Kathuria"],
             text: "Tasmeen Kathuria: can we talk Monday?"),
    ]

    /// The readings the cases above depend on, pinned one at a time so a
    /// failure says which one moved rather than "the text differs".
    private static let readings: [(what: String, got: String?, want: String?)] = [
        ("place, channel", TreeContext.place(in: "sws-engineering (private channel)"), "#sws-engineering"),
        ("place, dm", TreeContext.place(in: "Tasmeen Kathuria (direct message, away)"), "Tasmeen Kathuria"),
        ("place, group dm", TreeContext.place(in: "Mik Okun, Mirza Baig (group direct message)"),
         "Mik Okun, Mirza Baig"),
        ("place, not a place", TreeContext.place(in: "Files & links (2)"), nil),
        // A name with brackets of its own: the last "(" opens the kind.
        ("place, bracketed name", TreeContext.place(in: "Nathan (Swoop) (direct message, away)"),
         "Nathan (Swoop)"),
        ("author", TreeContext.author(in: "Martin Alix: the deploy hook fired"), "Martin Alix"),
        // A lowercase display name is still a message, and still not a person:
        // `people` is offered to a dictation as a spelling, and "tip" is a word.
        ("speaker, lowercase", TreeContext.speaker(in: "mik: hello team"), "mik"),
        ("author, lowercase", TreeContext.author(in: "mik: hello team"), nil),
        ("speaker, not a url", TreeContext.speaker(in: "http://localhost:3000"), nil),
        ("author, trailing stop", TreeContext.author(in: "Matthieu Joannon.: it shipped"), "Matthieu Joannon"),
        ("author, not one", TreeContext.author(in: "Note: this is not a name"), "Note"),
        ("author, needs a space", TreeContext.author(in: "http://localhost:3000"), nil),
        ("announcement", TreeContext.trimAnnouncement("it shipped. 4:38 PM. 10 reactions, 9 replies."),
         "it shipped."),
        ("announcement, nothing to cut", TreeContext.trimAnnouncement("it shipped"), "it shipped"),
        ("title", TreeContext.cleanTitle("! Tasmeen Kathuria (DM) - Swoop - 21 new items - Slack"),
         "Tasmeen Kathuria (DM) - Swoop"),
    ]

    static func run() -> Int32 {
        var failed: [String] = []

        for reading in readings where reading.got != reading.want {
            failed.append("  \(reading.what): want \(reading.want ?? "nil"),"
                + " got \(reading.got ?? "nil")")
        }

        for one in cases {
            let got = TreeContext.assemble(one.nodes, title: one.title)
            if got.place != one.place {
                failed.append("  \(one.name) place: want \(one.place), got \(got.place)")
            }
            if got.people != one.people {
                failed.append("  \(one.name) people: want \(one.people), got \(got.people)")
            }
            if got.code != one.code {
                failed.append("  \(one.name) code: want \(one.code), got \(got.code)")
            }
            if got.text != one.text {
                failed.append("  \(one.name) text: want"
                    + " \(one.text.replacingOccurrences(of: "\n", with: " | ")), got"
                    + " \(got.text.replacingOccurrences(of: "\n", with: " | "))")
            }
        }

        let total = readings.count + cases.count * 4
        guard failed.isEmpty else {
            print("✗ tree context: \(failed.count) of \(total)")
            for line in failed { print(line) }
            return 1
        }
        print("✓ tree context: \(total) of \(total)")
        return 0
    }
}
