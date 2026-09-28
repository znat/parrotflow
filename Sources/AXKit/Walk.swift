import AppKit
import ApplicationServices

public struct Rect: Codable, Equatable, Sendable {
    public var x: Int, y: Int, w: Int, h: Int

    public init(_ frame: CGRect) {
        (x, y, w, h) = (Int(frame.minX.rounded()), Int(frame.minY.rounded()),
                        Int(frame.width.rounded()), Int(frame.height.rounded()))
    }
}

/// One element of a walk. `parent` is the index of its parent in the walk.
public struct Node: Codable, Equatable, Sendable {
    public var role: String
    public var subrole: String?
    public var name: String?
    public var value: String?
    public var identifier: String?
    public var dom: String?
    public var frame: Rect?
    public var actions: [String]
    public var states: [String]
    public var depth: Int
    public var parent: Int?
    /// Stable across walks: role, name and the path of roles above it.
    public var key: String
}

public struct WalkOptions: Sendable {
    /// Teams trees reach 42 levels.
    public var depth = 64
    public var budget = 8000
    /// Finder's Downloads list once took 27 s to walk.
    public var seconds: Double = 3
    /// Values longer than this are cut. Outlook's message body is an
    /// AXTextArea of 395,489 characters.
    public var valueLimit = 200

    public init(depth: Int = 64, budget: Int = 8000, seconds: Double = 3, valueLimit: Int = 200) {
        (self.depth, self.budget, self.seconds, self.valueLimit) = (depth, budget, seconds, valueLimit)
    }
}

public struct WalkResult: Codable, Sendable {
    public var nodes: [Node]
    /// "depth", "budget" or "deadline" when the walk did not reach the end.
    public var stopped: String?
    public var milliseconds: Int
}

public enum Walk {
    /// Roles that wrap everything in web apps, left out of a key's path so
    /// that a wrapper added or removed does not change it.
    public static let plainRoles: Set<String> = [kAXGroupRole, "AXGenericElement", kAXUnknownRole]

    public static func run(from root: Element, options: WalkOptions = WalkOptions()) -> WalkResult {
        var walker = Walker(options: options, focused: root.pid.flatMap { App(pid: $0).focusedElement })
        let started = Date()
        walker.visit(root, depth: 0, parent: nil, path: "")
        return WalkResult(nodes: walker.nodes.map(\.1), stopped: walker.stopped,
                          milliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// Elements whose role, name (a glob) and DOM id match, in reading order.
    public static func find(in root: Element, role: String? = nil, name: String? = nil,
                            dom: String? = nil, options: WalkOptions = WalkOptions()) -> [(Element, Node)] {
        var walker = Walker(options: options, focused: nil)
        walker.visit(root, depth: 0, parent: nil, path: "")
        return walker.nodes.filter { _, node in
            (role == nil || node.role == role)
                && (name == nil || Glob.matches(name!, node.name ?? ""))
                && (dom == nil || node.dom == dom)
        }
    }

    public static func key(role: String, name: String, path: String) -> String {
        shortHash("\(role)\u{1}\(name)\u{1}\(path)")
    }

    /// The path the children of an element get: its own role appended, unless
    /// it is a plain wrapper or repeats the last role.
    public static func path(below path: String, role: String) -> String {
        plainRoles.contains(role) || path.hasSuffix("/\(role)") ? path : "\(path)/\(role)"
    }

    /// FNV-1a, 32 bits.
    public static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return String(format: "%08x", hash)
    }
}

private struct Walker {
    let options: WalkOptions
    let focused: Element?
    let deadline: Date
    var budget: Int
    var nodes: [(Element, Node)] = []
    var stopped: String?
    var twins: [String: Int] = [:]

    init(options: WalkOptions, focused: Element?) {
        self.options = options
        self.focused = focused
        self.deadline = Date().addingTimeInterval(options.seconds)
        self.budget = options.budget
    }

    mutating func visit(_ element: Element, depth: Int, parent: Int?, path: String) {
        guard depth < options.depth else { stopped = stopped ?? "depth"; return }
        guard budget > 0 else { stopped = "budget"; return }
        guard Date() < deadline else { stopped = "deadline"; return }
        budget -= 1
        let role = element.role ?? "?"
        let name = element.name
        var key = Walk.key(role: role, name: name ?? "", path: path)
        twins[key, default: 0] += 1
        if twins[key]! > 1 { key += ".\(twins[key]!)" }
        let node = Node(
            role: role, subrole: element.subrole, name: name, value: value(of: element, role: role),
            identifier: element.identifier, dom: element.domIdentifier,
            frame: element.frame.map(Rect.init), actions: element.actions,
            states: states(of: element, role: role), depth: depth, parent: parent, key: key)
        nodes.append((element, node))
        let index = nodes.count - 1
        let inner = Walk.path(below: path, role: role)
        for child in element.children {
            visit(child, depth: depth + 1, parent: index, path: inner)
        }
    }

    private func value(of element: Element, role: String) -> String? {
        guard element.subrole != kAXSecureTextFieldSubrole, let text = element.valueText,
              !text.isEmpty else { return nil }
        return text.count > options.valueLimit ? String(text.prefix(options.valueLimit)) + "…" : text
    }

    private func states(of element: Element, role: String) -> [String] {
        var out: [String] = []
        if let focused, focused == element { out.append("focused") }
        if element.isSelected == true { out.append("selected") }
        if element.isExpanded == true { out.append("expanded") }
        if element.isEnabled == false { out.append("disabled") }
        if role == kAXCheckBoxRole || role == kAXRadioButtonRole,
           (element.value as? NSNumber)?.intValue == 1 {
            out.append("checked")
        }
        return out
    }
}

public enum Glob {
    /// `*` any run, `?` one character, `[...]` a set. Case is ignored.
    public static func matches(_ pattern: String, _ text: String) -> Bool {
        fnmatch(pattern, text, FNM_CASEFOLD) == 0
    }
}
