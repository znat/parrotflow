import AppKit
import ApplicationServices

/// What the system shows around the apps: the Dock and the menu bar icons.
public enum System {
    public struct DockItem: Sendable {
        public let element: Element
        public let name: String
        /// The badge: unread messages, updates. Nil when there is none.
        public let badge: String?
        public let running: Bool
    }

    /// The Dock's items, with their badges, left to right.
    public static var dock: [DockItem] {
        guard let dock = App.named("com.apple.dock"),
              let list = dock.element.children.first(where: { $0.role == kAXListRole }) else { return [] }
        return list.children.filter { $0.role == "AXDockItem" }.map { item in
            DockItem(element: item, name: item.title ?? "",
                     badge: item.string("AXStatusLabel").flatMap { $0.isEmpty ? nil : $0 },
                     running: item.bool("AXIsApplicationRunning") ?? false)
        }
    }

    public struct MenuExtra: Sendable {
        public let element: Element
        /// Its title, else its description ("Wi-Fi", "Battery").
        public let name: String
        public let app: String
    }

    /// The menu bar icons of every app that has some, Control Center's too.
    public static var menuExtras: [MenuExtra] {
        NSWorkspace.shared.runningApplications.flatMap { running -> [MenuExtra] in
            let app = App(pid: running.processIdentifier)
            guard let bar = app.element.element(kAXExtrasMenuBarAttribute) else { return [] }
            return bar.children.map {
                MenuExtra(element: $0, name: $0.title.flatMap { $0.isEmpty ? nil : $0 } ?? $0.name ?? "",
                          app: running.localizedName ?? "")
            }
        }
    }

    /// Opens a menu bar icon's menu and presses the item whose title matches.
    @discardableResult
    public static func menuExtra(_ extra: MenuExtra, choose item: String) throws -> Outcome {
        // While its menu is open the app tracks it, and the press can come
        // back as "cannot complete" (-25204) with the menu open all the same.
        do { try extra.element.perform(kAXPressAction) } catch AXKitError.ax(.cannotComplete, _) {}
        var menu: Element?
        _ = Controls.wait {
            menu = extra.element.first(budget: 50, where: { $0.role == kAXMenuRole })
            return menu != nil
        }
        guard let menu else { throw AXKitError.ax(.failure, "no menu under \(extra.name)") }
        let items = menu.children.filter { $0.role == kAXMenuItemRole }
        guard let chosen = items.first(where: { Glob.matches(item, $0.title ?? "") }) else {
            try? menu.perform(kAXCancelAction)
            throw AXKitError.ax(.failure, "no \"\(item)\" in \(items.compactMap(\.title))")
        }
        try chosen.perform(kAXPressAction)
        return Outcome(before: nil, after: nil, method: "pressed \(extra.name), then \(chosen.title ?? item)", verified: nil)
    }
}

extension App {
    /// Opens a file or URL with a chosen app, without bringing it in front.
    /// An app that opens a document can come in front on its own whatever
    /// was asked (TextEdit did, 09-29): then the app that was in front is
    /// brought back. Returns whether that was needed.
    @discardableResult
    public static func open(_ url: URL, with bundle: String, background: Bool = true) throws -> Bool {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
            throw AXKitError.appNotFound(bundle)
        }
        let front = App.frontmost
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = !background
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        guard background, let front else { return false }
        Thread.sleep(forTimeInterval: 0.5)
        guard App.frontmost?.bundleIdentifier == bundle else { return false }
        front.activate()
        return true
    }
}

extension Controls {
    /// What an element holds, taken for another app: its selected text, else
    /// its value. No pasteboard: nothing the user copied is touched.
    public static func text(of element: Element) -> String? {
        if let selected = element.string(kAXSelectedTextAttribute), !selected.isEmpty { return selected }
        return element.valueText
    }

    /// Copies what is selected in an element with the app's ⌘C and returns
    /// the pasteboard's items, then puts back what the pasteboard held. For
    /// rich content (styled text, images) that plain text would lose.
    public static func copy(near element: Element) throws -> Clipboard.Saved {
        let saved = Clipboard.save()
        defer { Clipboard.restore(saved) }
        let count = NSPasteboard.general.changeCount
        try shortcut("c", near: element)
        guard wait({ NSPasteboard.general.changeCount != count }) else {
            throw AXKitError.notApplied("⌘C in \(describe(element)): nothing was copied")
        }
        return Clipboard.save()
    }
}
