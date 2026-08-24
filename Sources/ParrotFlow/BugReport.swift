import AppKit
import Foundation

/// The text a bug report needs, assembled from what the app already knows.
///
/// The form asks for the version, the machine, `--check-config` and the tail of
/// the log. Every one of them is here, so nobody has to run four commands and
/// paste the results.
///
/// Two rules shape it. Nothing is copied or opened before the person has read
/// it — this app hears what people say, and the log can carry a transcript. And
/// every absolute home path is written as `~`, in this one place, so no section
/// can carry the account name out.
enum BugReport {

    /// What the form asks for: `tail -50`.
    static let logLines = 50

    /// GitHub answers a longer URL with an error page rather than a truncated
    /// form, so the bulk goes to the clipboard and only the short fields go
    /// here.
    static let urlLimit = 2000

    // MARK: - The machine

    static var macOSVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var described = "\(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { described += ".\(version.patchVersion)" }
        return described
    }

    /// "Apple M2 Pro". `ProcessInfo` has no chip name; this sysctl key holds it
    /// on Apple silicon and on Intel alike.
    static var chip: String {
        var size = 0
        let key = "machdep.cpu.brand_string"
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown chip" }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown chip" }
        let name = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// One line, and the value of the form's `macos` field.
    static var machine: String { "macOS \(macOSVersion), \(chip)" }

    // MARK: - The report

    /// - Parameters:
    ///   - fromTerminal: whether the accessibility answer can be trusted. It
    ///     cannot from a command line, and the report says so instead of
    ///     printing a wrong answer.
    ///   - app: the app the person was dictating into, if it is known.
    static func text(fromTerminal: Bool, app: String? = nil) -> String {
        var sections: [String] = []

        sections.append("ParrotFlow bug report")

        var version = [
            "Version",
            "  app        \(AppVariant.version)",
            "  build      \(AppVariant.buildStamp)",
            "  macOS      \(macOSVersion)",
            "  chip       \(chip)",
        ]
        if let app, !app.isEmpty { version.append("  app in use \(app)") }
        sections.append(version.joined(separator: "\n"))

        sections.append(permissions(fromTerminal: fromTerminal))
        sections.append("--check-config\n\(CheckConfigCommand.report().text)")
        sections.append("Log — last \(logLines) lines of \(Log.fileURL.path)\n\(logTail())")

        return redacted(sections.joined(separator: "\n\n"))
    }

    private static func permissions(fromTerminal: Bool) -> String {
        var lines = ["Permissions", "  microphone     \(Permissions.microphone.label)"]

        if fromTerminal {
            // The same caveat `--check-config` carries: TCC credits a check made
            // from a shell to the shell, so ParrotFlow reads as untrusted even
            // where the grant is in place. Measured — see docs/cli.md.
            lines.append("  accessibility  not checkable from a terminal — macOS credits"
                + " the check to the shell")
            lines.append("                 the app writes the true value to the log at"
                + " each launch (\"launched —\")")
        } else {
            lines.append("  accessibility  \(Permissions.accessibility.label)")
            if let blocker = Permissions.accessibilityBlocker {
                lines.append("                 \(blocker)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func logTail() -> String {
        let url = Log.fileURL
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "  not found — no log file at \(url.path)"
        }
        let lines = contents
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return "  not found — the log file is empty" }
        return lines.suffix(logLines).joined(separator: "\n")
    }

    // MARK: - The account name

    /// Every absolute home path written as `~`.
    ///
    /// A path under another account is an account name too, so it is rewritten
    /// the same way. Which home it was is worth less than the guarantee that
    /// none of them leaves the machine.
    static func redacted(_ text: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var out = text.replacingOccurrences(of: "/private\(home)", with: "~")
        out = out.replacingOccurrences(of: home, with: "~")

        guard let accounts = try? NSRegularExpression(pattern: "/Users/[^/\\s\"']+") else { return out }
        return accounts.stringByReplacingMatches(
            in: out,
            range: NSRange(out.startIndex..., in: out),
            withTemplate: "~"
        )
    }

    // MARK: - The prefilled form

    /// The issue form with the short fields already filled. The `--check-config`
    /// output and the log are not in here — they are on the clipboard.
    ///
    /// The names are the field `id`s in `.github/ISSUE_TEMPLATE/bug.yml`. A name
    /// that is not one is ignored by GitHub, silently.
    static func issueURL(app: String? = nil) -> URL? {
        var query = "template=bug.yml&labels=bug"
        query += "&version=\(encoded(AppVariant.version))"
        query += "&macos=\(encoded(machine))"
        if let app, !app.isEmpty { query += "&app=\(encoded(app))" }

        let base = "\(AppVariant.repository)/issues/new"
        let full = "\(base)?\(query)"
        let within = full.count <= urlLimit ? full : "\(base)?template=bug.yml&labels=bug"
        return URL(string: within)
    }

    /// Alphanumerics only, so a space becomes `%20` rather than `+` and nothing
    /// in a chip name or an app name can end the value early.
    private static func encoded(_ value: String) -> String {
        String(value.prefix(200)).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}

/// The window behind 🦜 → Report a bug…
///
/// It exists to be read. The buttons are underneath the text rather than beside
/// the menu item because a report that is copied before it is seen is a report
/// nobody consented to — and this one carries the last fifty lines of a log that
/// can hold dictated words.
final class BugReportWindow: NSObject {

    private var window: NSWindow?
    private weak var textView: NSTextView?
    private var report = ""
    private var app: String?

    /// - Parameter app: the app that was in front, for the form's `app` field.
    func show(app: String?) {
        self.app = app
        report = BugReport.text(fromTerminal: false, app: app)

        let window = self.window ?? build()
        self.window = window
        textView?.string = report

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func build() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Report a Bug"
        window.isReleasedWhenClosed = false

        let content = NSView()
        window.contentView = content

        let caption = NSTextField(wrappingLabelWithString:
            "This is what will be copied. Read it first — the log can carry what you dictated."
                + " Home paths are already written as ~.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        // The recipe a text view in a scroll view needs: a real starting frame,
        // an unbounded max size and width tracking, or it lays out at zero width
        // and shows nothing.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 688, height: 440))
        text.minSize = NSSize(width: 0, height: 0)
        let unbounded = CGFloat.greatestFiniteMagnitude
        text.maxSize = NSSize(width: unbounded, height: unbounded)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.isEditable = false
        text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = report
        scroll.documentView = text
        textView = text

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let copyOnly = NSButton(title: "Copy only", target: self, action: #selector(copyOnly))
        let copyAndOpen = NSButton(
            title: "Copy and open GitHub", target: self, action: #selector(copyAndOpen)
        )
        copyAndOpen.keyEquivalent = "\r"

        let buttons = NSStackView(views: [cancel, copyOnly, copyAndOpen])
        buttons.orientation = .horizontal
        buttons.spacing = 12

        for view in [caption, scroll, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            caption.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])

        return window
    }

    private func copyReport() {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(report, forType: .string)
        Log.write("bug report: copied, \(report.count) characters")
    }

    @objc private func copyAndOpen() {
        copyReport()
        if let url = BugReport.issueURL(app: app) { NSWorkspace.shared.open(url) }
        window?.close()
    }

    @objc private func copyOnly() {
        copyReport()
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }
}
