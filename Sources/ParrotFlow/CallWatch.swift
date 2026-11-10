import AppKit
import CoreAudio

/// A process with the microphone open.
struct MicUser: Equatable {
    var pid: pid_t
    var bundle: String
    /// The app it belongs to: "Zoom is using the mic". Nil for a system service.
    var name: String?
}

/// Whether another app is on a call, from the processes with the microphone open.
enum CallState: Equatable {
    case idle
    /// Another app opened the mic at `since`.
    case rising(app: String, since: Date)
    case on(app: String)
    /// The mic closed at `since`.
    case falling(app: String, since: Date)

    enum Event: Equatable {
        case started(app: String)
        case ended(app: String)
    }

    static let rise: TimeInterval = 2
    static let fall: TimeInterval = 5

    /// When to look again with nothing changed, to end a wait.
    var deadline: Date? {
        switch self {
        case .rising(_, let since): since + Self.rise
        case .falling(_, let since): since + Self.fall
        case .idle, .on: nil
        }
    }

    /// Services with no app that carry calls.
    static let callServices = ["com.apple.avconferenced": "FaceTime"]

    /// Another copy of ParrotFlow dictating is not a call. Nor is a system service, like Siri
    /// or dictation listening in com.apple.CoreSpeech.
    static func caller(_ users: [MicUser], ourPid: pid_t) -> String? {
        users.lazy.filter { $0.pid != ourPid && !$0.bundle.hasPrefix("com.parrotflow.") }
            .compactMap { $0.name ?? callServices[$0.bundle] }.first
    }

    func step(_ users: [MicUser], ourPid: pid_t, now: Date) -> (CallState, Event?) {
        switch (self, Self.caller(users, ourPid: ourPid)) {
        case (.idle, nil), (.on, _?): return (self, nil)
        case (.idle, let app?): return (.rising(app: app, since: now), nil)
        case (.rising, nil): return (.idle, nil)
        case (.rising(let app, let since), _?):
            return now >= since + Self.rise ? (.on(app: app), .started(app: app)) : (self, nil)
        case (.on(let app), nil): return (.falling(app: app, since: now), nil)
        case (.falling(let app, _), _?): return (.on(app: app), nil)
        case (.falling(let app, let since), nil):
            return now >= since + Self.fall ? (.idle, .ended(app: app)) : (self, nil)
        }
    }
}

/// Feeds `CallState` from Core Audio's process objects.
///
/// `kAudioProcessPropertyIsRunningInput` sends no notice when it changes, but the
/// process's `kAudioProcessPropertyDevices` does, on start and on stop (measured on
/// macOS 27). So every property of every process object is watched, and any notice
/// reads the list again.
final class CallWatch {
    var onEvent: (CallState.Event) -> Void = { _ in }
    private(set) var state = CallState.idle
    private var timer: Timer?
    private let queue = DispatchQueue(label: "parrotflow.call-watch")
    /// Touched on `queue` only.
    private var watched: Set<AudioObjectID> = []
    private var looking = false
    private lazy var changed: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.look() }
    private lazy var listChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.watchProcesses()
        self?.look()
    }

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static var listAddress = address(kAudioHardwarePropertyProcessObjectList)
    private static var anyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioObjectPropertySelectorWildcard, mScope: kAudioObjectPropertyScopeWildcard,
        mElement: kAudioObjectPropertyElementWildcard)

    init() {
        queue.async { [self] in
            AudioObjectAddPropertyListenerBlock(Self.system, &Self.listAddress, queue, listChanged)
            watchProcesses()
            look()
        }
    }

    func stop() {
        onEvent = { _ in }
        timer?.invalidate()
        timer = nil
        queue.sync {
            AudioObjectRemovePropertyListenerBlock(Self.system, &Self.listAddress, queue, listChanged)
            for id in watched { AudioObjectRemovePropertyListenerBlock(id, &Self.anyAddress, queue, changed) }
            watched = []
        }
    }

    private func watchProcesses() {
        let current = Set(Self.processes())
        for id in current.subtracting(watched)
        where AudioObjectAddPropertyListenerBlock(id, &Self.anyAddress, queue, changed) == noErr {
            watched.insert(id)
        }
        watched.formIntersection(current)
    }

    /// Several notices come at once: one read after the last.
    private func look() {
        guard !looking else { return }
        looking = true
        queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            looking = false
            let open = Self.processes().filter { Self.read(UInt32(0), $0, kAudioProcessPropertyIsRunningInput) == 1 }
            let found = open.map { id in
                (Self.read(pid_t(0), id, kAudioProcessPropertyPID),
                 Self.read("" as CFString, id, kAudioProcessPropertyBundleID) as String)
            }
            DispatchQueue.main.async {
                self.decide(found.map { MicUser(pid: $0, bundle: $1, name: Self.name(pid: $0)) })
            }
        }
    }

    private func decide(_ users: [MicUser]) {
        let (next, event) = state.step(users, ourPid: getpid(), now: Date())
        state = next
        timer?.invalidate()
        timer = nil
        if let deadline = state.deadline {
            let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                self?.queue.async { self?.look() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if let event { onEvent(event) }
    }

    /// The app a process belongs to: the first ancestor with a Dock icon. Chrome and
    /// Teams take the mic in a helper. WebKit's GPU process, Safari's, is a child of
    /// launchd and calls itself "Safari Graphics and Media". Nil for a daemon, or a
    /// background-only app like SiriNCService.
    static func name(pid: pid_t) -> String? {
        var ancestor = pid
        for _ in 0..<8 where ancestor > 1 {
            if let app = NSRunningApplication(processIdentifier: ancestor), app.activationPolicy == .regular,
               let name = app.localizedName { return name }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            ancestor = pid_t(info.pbi_ppid)
        }
        guard let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy != .prohibited,
              let name = app.localizedName else { return nil }
        return name.replacingOccurrences(of: " Graphics and Media", with: "")
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processes() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func read<T>(_ fallback: T, _ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T {
        var address = address(selector)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0) }
        return status == noErr ? value : fallback
    }
}
