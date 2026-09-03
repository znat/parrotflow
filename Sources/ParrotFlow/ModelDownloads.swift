import FluidAudio
import Foundation

/// One model the app fetches at launch, and how far it has got.
///
/// The description of a model lives beside the code that fetches it — see
/// `Transcriber.speechDownload`, `Transcriber.voiceDownload`,
/// `SentenceModel.download`, `WordVectors.download` and
/// `NeuralPhonemes.soundDownload`. No screen keeps a list of models. A model
/// added later declares itself next to its own fetch and every surface that
/// draws rows draws it.
struct ModelDownload: Identifiable, Equatable {

    /// What the model does, which is how the setup screen groups the rows.
    enum Group: Equatable {
        case sound
        case language
    }

    /// The five ways a fetch ends badly. Each says something different about
    /// what to do next, which is why they are five sentences and not one.
    enum Failure: Equatable {
        case unreachable
        case stopped
        case busy
        case damaged
        /// The free space the install wanted, as words: "600 MB".
        case noSpace(String)

        var message: String {
            switch self {
            case .unreachable: return "Could not reach the server."
            case .stopped: return "Download stopped."
            case .busy: return "Already downloading in another window."
            case .damaged: return "The installed copy is damaged."
            case .noSpace(let needs): return "Needs about \(needs) free."
            }
        }

        /// What the button offering the repair says, or nil when no button can
        /// help. The other build holds the lock and lets go on its own.
        var retryTitle: String? {
            switch self {
            case .busy: return nil
            case .damaged: return "Download again"
            case .unreachable, .stopped, .noSpace: return "Try again"
            }
        }
    }

    enum State: Equatable {
        case waiting
        /// Nil percent for a fetch that reports no fraction.
        case downloading(percent: Int?)
        case installed
        case failed(Failure)
        /// A setting turned it off. The string is what the row says instead of
        /// a state — "gate is off".
        case off(String)

        var hasFailed: Bool {
            if case .failed = self { return true }
            return false
        }

        var failure: Failure? {
            if case .failed(let why) = self { return why }
            return nil
        }

        /// Still to come. A row that failed is not pending: it has stopped,
        /// and the screen says so in its own sentence.
        var isPending: Bool {
            switch self {
            case .waiting, .downloading: return true
            case .installed, .off, .failed: return false
            }
        }
    }

    /// What a row says when a setting means it is never fetched. Not a failure
    /// and not a warning: nobody asked for it.
    static let gateOff = "gate is off"

    let id: String
    let name: String
    /// What it takes on disk once installed.
    let megabytes: Int
    /// Free space the install needs at its worst moment. The same as
    /// `megabytes` except for a model that is compiled from a package it then
    /// deletes, where both exist at once.
    let peak: Int
    let group: Group
    /// True when a dictation waits on it. Carried by
    /// `Transcriber.Status.downloading(_, blocking:)` for the two that have it.
    let blocking: Bool
    /// What is lost while it is not here, as the second half of "X could not be
    /// downloaded, and …". Only a blocking row's is read, because only a
    /// blocking row's failure reaches the title.
    let costOfFailure: String
    var state: State = .waiting

    var sizeLabel: String { "\(megabytes) MB" }

    var peakLabel: String { ModelDownloads.size(megabytes: peak) }
}

/// Every model this launch is fetching, in the order the launch asks for them.
///
/// Not owned by the setup window. The fetches start at launch and outlive any
/// window, the same rows are drawn by the Downloads step and by the last
/// screen, and a window that owned a download would take it down with it.
///
/// Read and written on the main queue, like `PermissionsModel`. `report` is the
/// door for the actors that do the fetching.
final class ModelDownloads: ObservableObject {

    static let shared = ModelDownloads()

    @Published private(set) var rows: [ModelDownload] = []

    /// Declares a model the launch is about to fetch. `off` is the reason a
    /// setting means it never will be.
    ///
    /// Idempotent, and it keeps the order of first registration. A second call
    /// leaves the state alone: that belongs to the fetch, and a retry that put
    /// an installed row back to "waiting" would report work nobody is doing.
    ///
    /// The one state a second call does write is `.off`, both ways. `update`
    /// drops every report for a row a setting switched off, so a row left off
    /// after the setting came back would never move again.
    func expect(_ model: ModelDownload, off reason: String? = nil) {
        if let at = rows.firstIndex(where: { $0.id == model.id }) {
            if let reason {
                rows[at].state = .off(reason)
            } else if case .off = rows[at].state {
                rows[at].state = model.state
            }
            return
        }
        var row = model
        if let reason { row.state = .off(reason) }
        rows.append(row)
    }

    /// Puts every failed row back to waiting, for a retry that is about to
    /// start the fetches again.
    func retrying() {
        for at in rows.indices where rows[at].state.hasFailed {
            rows[at].state = .waiting
        }
    }

    func update(_ id: String, to state: ModelDownload.State) {
        guard let at = rows.firstIndex(where: { $0.id == id }) else { return }
        // A row a setting switched off is not fetching, so nothing should be
        // reporting on it. If something does, the setting is still the truth.
        if case .off = rows[at].state { return }
        guard rows[at].state != state else { return }
        rows[at].state = state
    }

    /// Called from whichever thread the fetch is on.
    static func report(_ id: String, _ state: ModelDownload.State) {
        DispatchQueue.main.async { shared.update(id, to: state) }
    }

    // MARK: - What the screens ask

    func rows(in group: ModelDownload.Group) -> [ModelDownload] {
        rows.filter { $0.group == group }
    }

    /// The row a dictation is waiting on that failed, if one did. It is the
    /// only kind of failure that reaches the title and the foot, and the screen
    /// names this row rather than the first blocking one — a failed voice
    /// detector must not be reported as a failed speech model.
    var blockingFailure: ModelDownload? {
        rows.first { $0.blocking && $0.state.hasFailed }
    }

    /// The rows whose bytes are on disk and will not load. Their repair is to
    /// throw the cache away, which the retry does before it fetches again.
    var damaged: Set<String> {
        Set(rows.filter { $0.state.failure == .damaged }.map(\.id))
    }

    /// True when nothing a dictation waits on is still coming. A row a setting
    /// switched off is not coming and nothing waits for it either.
    ///
    /// False when there is nothing to wait for at all: `allSatisfy` over no
    /// rows is true, and that would read as ready to dictate on a launch that
    /// registered no speech model because it will never transcribe.
    var speechIsIn: Bool {
        let blocking = rows.filter(\.blocking)
        guard !blocking.isEmpty else { return false }
        return blocking.allSatisfy {
            switch $0.state {
            case .installed, .off: return true
            case .waiting, .downloading, .failed: return false
            }
        }
    }

    /// A failure turned into the one sentence that says what happened.
    ///
    /// `needs` is the free space to name when the disk is full.
    @available(macOS 14, *)
    static func failure(_ error: Error, needs: String) -> ModelDownload.Failure {
        if error is CancellationError { return .stopped }
        if let failure = error as? SentenceModel.Failure, case .busy = failure { return .busy }
        if let failure = error as? WordVectors.Failure, case .busy = failure { return .busy }
        // The weights loaded as something that is not Qwen3: the copy on disk
        // is not the model it is named after.
        if let failure = error as? WordVectors.Failure, case .notQwen = failure { return .damaged }

        // Parakeet's downloader collapses every reason a transfer failed into
        // one case with a string, so a dropped connection and a full disk are
        // the same error here. Only its load and compile failures are told
        // apart, and those mean the bytes on disk will not open.
        if let asr = error as? AsrModelsError {
            switch asr {
            case .downloadFailed: return .unreachable
            case .loadingFailed, .modelCompilationFailed, .modelNotFound: return .damaged
            }
        }

        if let hub = error as? HubDownload.Failure {
            switch hub {
            case .truncated: return .stopped
            case .http, .unlisted: return .unreachable
            }
        }

        let wrapped = error as NSError
        if wrapped.domain == NSCocoaErrorDomain, wrapped.code == NSFileWriteOutOfSpaceError {
            return .noSpace(needs)
        }
        if wrapped.domain == NSPOSIXErrorDomain, wrapped.code == Int(ENOSPC) {
            return .noSpace(needs)
        }
        // What Core ML throws for a compiled model it will not open. The bytes
        // are there and re-fetching them is the only repair.
        if wrapped.domain == "com.apple.CoreML" { return .damaged }

        if let url = error as? URLError {
            switch url.code {
            case .cancelled, .networkConnectionLost, .timedOut: return .stopped
            default: return .unreachable
            }
        }
        return .unreachable
    }

    /// "1.2 GB", or "461 MB" under a gigabyte.
    static func size(megabytes: Int) -> String {
        guard megabytes >= 1000 else { return "\(megabytes) MB" }
        return String(format: "%.1f GB", Double(megabytes) / 1000)
    }
}
