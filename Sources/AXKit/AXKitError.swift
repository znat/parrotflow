import ApplicationServices

public enum AXKitError: Error, CustomStringConvertible, Equatable {
    /// An accessibility call failed. `what` names the call and its argument.
    case ax(AXError, String)
    /// This process is not in System Settings > Privacy & Security > Accessibility.
    case notTrusted
    case appNotFound(String)
    /// A write returned success but reading back shows another value.
    case notApplied(String)
    /// The state cannot be read, so the operation would be blind: a second
    /// press would undo the first. Material's checkbox and switch.
    case unreadable(String)
    case timedOut(String)

    public var description: String {
        switch self {
        case .ax(let error, let what): return "\(what): \(AXKitError.name(of: error)) (\(error.rawValue))"
        case .notTrusted: return "this process has no Accessibility permission"
        case .appNotFound(let name): return "no running app \"\(name)\""
        case .notApplied(let what): return "\(what): the call succeeded but the value did not change"
        case .unreadable(let what): return "\(what): its state cannot be read, so it was left alone"
        case .timedOut(let what): return "\(what): timed out"
        }
    }

    public static func name(of error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegal argument"
        case .invalidUIElement: return "invalid element"
        case .invalidUIElementObserver: return "invalid observer"
        case .cannotComplete: return "cannot complete"
        case .attributeUnsupported: return "attribute unsupported"
        case .actionUnsupported: return "action unsupported"
        case .notificationUnsupported: return "notification unsupported"
        case .notImplemented: return "not implemented"
        case .notificationAlreadyRegistered: return "notification already registered"
        case .notificationNotRegistered: return "notification not registered"
        case .apiDisabled: return "accessibility disabled"
        case .noValue: return "no value"
        case .parameterizedAttributeUnsupported: return "parameterized attribute unsupported"
        case .notEnoughPrecision: return "not enough precision"
        @unknown default: return "unknown"
        }
    }
}
