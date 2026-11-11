import Foundation

/// A session's pinned window or pane, kept across launches. Numbers only: no titles.
struct SavedPin: Codable, Equatable {
    /// The agent's process, and the app it runs in.
    var agent: pid_t
    var host: pid_t
    var rect: CGRect
    var at: Date

    static let key = "voice.pins"
    /// Past a long meeting a pin still comes back; left overnight, the next prompt pins it again.
    static let maxAge: TimeInterval = 8 * 3600
    static let limit = 20

    enum Check: Equatable {
        case restore(Int)
        case drop(String)
    }

    /// Whether the pin still names one place. `places`: the frames of the host's
    /// windows and panes, each with the index of its window, nil when the walk
    /// ran out before it saw them all. A pane at its own window's frame is one place.
    static func check(_ pin: SavedPin, agent: pid_t?, host: pid_t, places: [(rect: CGRect, window: Int)]?,
                      now: Date) -> Check {
        if now.timeIntervalSince(pin.at) > maxAge { return .drop("older than \(Int(maxAge / 3600)) h") }
        guard pin.agent == agent else { return .drop("another agent process") }
        guard pin.host == host else { return .drop("another host app") }
        guard let places else { return .drop("too many windows to look through") }
        let found = places.indices.filter { SpeakingFrame.close(places[$0].rect, pin.rect) }
        let windows = Set(found.map { places[$0].window }).count
        switch windows {
        case 1: return .restore(found[0])
        case 0: return .drop("nothing at " + SpeakingFrame.describe(pin.rect))
        default: return .drop("\(windows) windows at " + SpeakingFrame.describe(pin.rect))
        }
    }

    /// The pins worth keeping: fresh, with the agent still running, the newest `limit`.
    static func kept(_ pins: [String: SavedPin], now: Date, running: (pid_t) -> Bool) -> [String: SavedPin] {
        let live = pins.filter { now.timeIntervalSince($0.value.at) <= maxAge && running($0.value.agent) }
        return Dictionary(uniqueKeysWithValues: live.sorted { $0.value.at > $1.value.at }.prefix(limit).map { ($0.key, $0.value) })
    }

    static func running(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    static func load() -> [String: SavedPin] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let pins = try? JSONDecoder().decode([String: SavedPin].self, from: data) else { return [:] }
        return save(pins)
    }

    /// Returns what it kept.
    static func save(_ pins: [String: SavedPin]) -> [String: SavedPin] {
        let kept = kept(pins, now: Date(), running: running)
        if !kept.isEmpty, let data = try? JSONEncoder().encode(kept) {
            UserDefaults.standard.set(data, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return kept
    }
}
