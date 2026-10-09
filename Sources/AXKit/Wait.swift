import AppKit
import ApplicationServices

/// Waiting on what an app says changed, instead of reading it again every
/// few milliseconds. An AXObserver wakes the wait on each notification; the
/// condition is checked then, and at a slow tick in case an app says nothing.
public enum Wait {
    /// What most changes on screen announce.
    public static let everything = [
        kAXValueChangedNotification, kAXCreatedNotification, kAXUIElementDestroyedNotification,
        kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification, kAXSheetCreatedNotification,
        kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXLayoutChangedNotification,
        kAXSelectedRowsChangedNotification, kAXRowCountChangedNotification, kAXMenuOpenedNotification,
    ]

    /// Until `condition` holds or `timeout` passes, whichever first. Watches
    /// `element` (the app by default). Returns whether the condition held.
    @discardableResult
    public static func until(_ app: App, on element: Element? = nil, notifications: [String] = everything,
                             timeout: Double = 3, tick: Double = 0.25, _ condition: () -> Bool) -> Bool {
        if condition() { return true }
        let watch = Watch(app: app, element: element ?? app.element, notifications: notifications)
        defer { watch.stop() }
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            watch.fired = false
            // Returns on the first notification, or after `tick`.
            let slice = min(tick, end.timeIntervalSinceNow)
            if slice <= 0 { break }
            CFRunLoopRunInMode(.defaultMode, slice, true)
            if condition() { return true }
        }
        return condition()
    }

    /// Until the app has said nothing for `quiet` seconds: a list that stops
    /// being rebuilt, a page that stops loading. Returns false on timeout, and
    /// when no notification could be registered, since silence then proves nothing.
    @discardableResult
    public static func settled(_ app: App, on element: Element? = nil, quiet: Double = 0.3,
                               timeout: Double = 3) -> Bool {
        let watch = Watch(app: app, element: element ?? app.element, notifications: everything)
        defer { watch.stop() }
        guard watch.isWatching else { return false }
        let end = Date().addingTimeInterval(timeout)
        var last = Date()
        while Date() < end {
            watch.fired = false
            CFRunLoopRunInMode(.defaultMode, min(quiet, max(0.01, end.timeIntervalSinceNow)), true)
            if watch.fired { last = Date() } else if Date().timeIntervalSince(last) >= quiet { return true }
        }
        return false
    }

    /// The first element under `root` that matches, as soon as it appears.
    public static func element(in root: Element, app: App, timeout: Double = 3,
                               where match: @escaping (Element) -> Bool) -> Element? {
        var found: Element?
        until(app, timeout: timeout) {
            found = root.first(budget: 5000, where: match)
            return found != nil
        }
        return found
    }
}

/// One observer on one element, its callback setting `fired`.
final class Watch {
    var fired = false
    var isWatching: Bool { observer != nil }
    private var observer: AXObserver?
    private let element: Element
    private var notifications: [String] = []

    init(app: App, element: Element, notifications: [String]) {
        self.element = element
        var created: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            Unmanaged<Watch>.fromOpaque(refcon).takeUnretainedValue().fired = true
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        guard AXObserverCreate(app.pid, callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let added = notifications.filter {
            AXObserverAddNotification(created, element.ref, $0 as CFString, refcon) == .success
        }
        guard !added.isEmpty else { return }
        observer = created
        self.notifications = added
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(created), .defaultMode)
    }

    func stop() {
        guard let observer else { return }
        for name in notifications {
            AXObserverRemoveNotification(observer, element.ref, name as CFString)
        }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        self.observer = nil
    }
}
