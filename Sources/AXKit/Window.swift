import AppKit
import ApplicationServices

/// Where a window is and how big, through accessibility. All of it works with
/// the app in the background.
extension Element {
    public func move(to point: CGPoint) throws {
        var origin = point
        guard let value = AXValueCreate(.cgPoint, &origin) else { return }
        try set(kAXPositionAttribute, to: value)
    }

    public func resize(to size: CGSize) throws {
        var extent = size
        guard let value = AXValueCreate(.cgSize, &extent) else { return }
        try set(kAXSizeAttribute, to: value)
    }

    public var isMinimized: Bool? { bool(kAXMinimizedAttribute) }

    public func minimize(_ minimized: Bool = true) throws {
        try set(kAXMinimizedAttribute, to: minimized as CFBoolean)
    }
}
