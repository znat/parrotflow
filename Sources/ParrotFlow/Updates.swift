import Foundation

/// Whether a newer ParrotFlow exists — and whether it is old enough to take.
///
/// The second half is the unusual one. `updates.after_days` is a waiting period,
/// not a polling interval: a release is ignored until it has existed for that
/// many days. Nothing about this repository is special enough to be attacked,
/// but the shape of it is the shape everyone in this category has — a
/// self-signed binary, downloaded over `curl`, that then asks for the
/// microphone and for permission to type into every window. The delay is what
/// turns "a bad release was published" into "a bad release was published and
/// pulled before anyone's app looked", which is the only realistic defence a
/// one-person project has against its own release pipeline being taken.
///
/// It is a delay, not a proof. What proves the archive is ours is the pinned
/// signing certificate, checked before anything is installed — see
/// `scripts/install.sh`. The two answer different questions and neither
/// replaces the other: the certificate answers "is this from you", the waiting
/// period answers "have you had time to notice it should not have been".
enum Updates {

    static let repo = "znat/parrotflow"

    /// What is published, as the API describes it.
    struct Release: Equatable {
        let version: String
        let publishedAt: Date
        let notes: String
        let zip: URL
        let checksum: URL

        var age: TimeInterval { Date().timeIntervalSince(publishedAt) }
        var ageInDays: Int { Int(age / 86_400) }
    }

    /// Every answer the check can give, including the ones that are not "yes".
    ///
    /// Separate cases rather than an optional Release, because `--update-check`
    /// has to be able to say *why* nothing is being offered. "No update" and
    /// "an update exists but you asked to wait five more days" look identical
    /// from the outside and are entirely different situations to debug.
    enum Decision: Equatable {
        case disabled
        case upToDate(current: String, latest: String)
        case waiting(Release, daysToGo: Int)
        case skipped(Release)
        case snoozed(Release, until: Date)
        case available(Release)
    }

    enum Failure: Error, LocalizedError {
        case offline(String)
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .offline(let why): return why
            case .malformed(let what): return "GitHub answered with something unexpected: \(what)"
            }
        }
    }

    // MARK: - This build

    /// Empty when the binary is run outside its bundle, which is how the test
    /// scripts run it. Reported rather than papered over with a zero: a version
    /// that reads "0.0.0" would make every release look like an upgrade.
    static var current: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    // MARK: - Deciding

    static func decide(
        current: String?,
        latest: Release?,
        afterDays: Int,
        state: State = .standard
    ) -> Decision {
        guard afterDays >= 0 else { return .disabled }
        guard let latest else { return .upToDate(current: current ?? "?", latest: "?") }
        guard let current, isNewer(latest.version, than: current) else {
            return .upToDate(current: current ?? "?", latest: latest.version)
        }
        if state.skipped == latest.version { return .skipped(latest) }

        let ready = latest.publishedAt.addingTimeInterval(Double(afterDays) * 86_400)
        if ready > Date() {
            // Rounded up: with a 7 day wait and a release six and a half days
            // old, "1 day to go" is true and "0 days to go" is a lie that
            // invites the user to wonder why nothing is being offered.
            let remaining = Int(ceil(ready.timeIntervalSinceNow / 86_400))
            return .waiting(latest, daysToGo: max(remaining, 1))
        }
        if let until = state.remindAfter, until > Date() {
            return .snoozed(latest, until: until)
        }
        return .available(latest)
    }

    /// Numeric, field by field. String comparison would put 0.10.0 before
    /// 0.9.0, which is exactly the release where it would first matter.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = fields(candidate), b = fields(current)
        for i in 0..<max(a.count, b.count) {
            let left = i < a.count ? a[i] : 0
            let right = i < b.count ? b[i] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func fields(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "v "))
            .split(separator: "-").first
            .map(String.init)?
            .split(separator: ".")
            .map { Int($0.filter(\.isNumber)) ?? 0 }
            ?? []
    }

    // MARK: - Asking GitHub

    /// One call, no authentication. Unauthenticated GitHub allows 60 an hour
    /// per address, and this runs once a day.
    static func latest(timeout: TimeInterval = 10) async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw Failure.malformed("bad URL")
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects an unidentified caller outright, and the version makes
        // their rate-limit logs useful to us if this ever misbehaves in the wild.
        request.setValue(
            "ParrotFlow/\(current ?? "dev") (+https://github.com/\(repo))",
            forHTTPHeaderField: "User-Agent"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.offline(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure.offline("GitHub answered \(http.statusCode)")
        }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Release {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("not JSON")
        }
        guard let tag = root["tag_name"] as? String else { throw Failure.malformed("no tag_name") }
        guard let published = root["published_at"] as? String,
              let date = ISO8601DateFormatter().date(from: published) else {
            throw Failure.malformed("no published_at")
        }

        let assets = root["assets"] as? [[String: Any]] ?? []
        func asset(named name: String) -> URL? {
            assets
                .first { $0["name"] as? String == name }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        // A release with no archive attached is a build that failed after the
        // tag was cut. Offering it would send someone to a download that is not
        // there, so it does not count as a release at all.
        guard let zip = asset(named: "ParrotFlow.zip"),
              let checksum = asset(named: "ParrotFlow.zip.sha256") else {
            throw Failure.malformed("the release has no ParrotFlow.zip attached")
        }

        return Release(
            version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "v ")),
            publishedAt: date,
            notes: (root["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            zip: zip,
            checksum: checksum
        )
    }

    // MARK: - What the user already answered

    /// Deliberately not in config.yaml. "Skip 0.4.0" and "not now" are answers
    /// to a question the app asked, not settings anybody would go and write by
    /// hand — and putting them in the config file would mean rewriting a file
    /// full of the user's own comments every time they press Later.
    struct State {
        var skipped: String?
        var remindAfter: Date?

        /// Read on every access, not once. As a `static let` this was
        /// resolved at first use and cached for the life of the process, so
        /// pressing Skip changed nothing until the app was restarted — the
        /// decision would keep being made against the state from launch.
        static var standard: State {
            State(
                skipped: UserDefaults.standard.string(forKey: skippedKey),
                remindAfter: UserDefaults.standard.object(forKey: remindKey) as? Date
            )
        }

        static let skippedKey = "updates.skipped"
        static let remindKey = "updates.remindAfter"
    }

    static func skip(_ version: String) {
        UserDefaults.standard.set(version, forKey: State.skippedKey)
        Log.write("updates: skipping \(version)")
    }

    static func remindLater(days: Int = 3) {
        let until = Date().addingTimeInterval(Double(days) * 86_400)
        UserDefaults.standard.set(until, forKey: State.remindKey)
        Log.write("updates: reminding again after \(until)")
    }

    /// The command a user runs to take the update, ready to paste.
    static var installCommand: String {
        "curl -fsSL https://raw.githubusercontent.com/\(repo)/main/scripts/install.sh | sh"
    }
}
