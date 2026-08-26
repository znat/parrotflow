import CryptoKit
import Foundation

/// Takes a release and puts it where the running app is.
///
/// Every check `scripts/install.sh` performs is performed here, in the same
/// order and for the same reasons, because this is the other way in and a door
/// that checks less is the door that gets used. Published checksum, signature,
/// the signing Team ID, and Apple's notarization — an update is refused unless
/// every one of them agrees.
///
/// The last step is the awkward one: an app cannot replace the bundle it is
/// running from. So the swap is handed to a detached shell that waits for this
/// process to exit, moves the old bundle aside, moves the new one in, and
/// relaunches. If the move fails the old one goes back, because the worst
/// outcome here is not a failed update — it is a Mac with no ParrotFlow on it
/// and no idea why.
enum UpdateInstaller {

    enum Failure: Error, LocalizedError {
        case download(String)
        case checksum(expected: String, got: String)
        case signature(String)
        case certificate(expected: String)
        case notarization(String)
        case contents(String)
        case cannotInstall(String)

        var errorDescription: String? {
            switch self {
            case .download(let why):
                return "could not download the update: \(why)"
            case .checksum(let expected, let got):
                return "the download does not match its published checksum "
                    + "(expected \(expected.prefix(12))…, got \(got.prefix(12))…)"
            case .signature(let why):
                return "the downloaded app failed signature verification: \(why)"
            case .certificate(let expected):
                return "the downloaded app was not signed by ParrotFlow "
                    + "(expected a Developer ID issued to Team ID \(expected))"
            case .notarization(let why):
                return "the downloaded app is signed but not notarized by Apple: \(why)"
            case .contents(let what):
                return "the download is not what it should be: \(what)"
            case .cannotInstall(let why):
                return why
            }
        }
    }

    /// Where this app is.
    static var destination: URL { Bundle.main.bundleURL }

    /// Why this build cannot take an update in place, or nil when it can.
    ///
    /// A dev build cannot, and not for a reason more code would fix. The
    /// release archive holds ParrotFlow.app signed as com.parrotflow.app; a dev
    /// bundle is ParrotFlowDev.app signed as com.parrotflow.app.dev. Moving one
    /// over the other does not update the dev build, it puts the released app
    /// under the dev build's name — reading the other config directory, writing
    /// the other log, listening to the other key, and asking for the microphone
    /// again. A dev build is built from the source tree, and that is where its
    /// updates come from.
    static var blocker: String? {
        if AppVariant.isDev {
            return "This is a dev build, so a release cannot be installed over it. "
                + "Build it from the source tree instead."
        }
        let parent = destination.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent) else {
            return "\(parent) cannot be written to, so the update has to be installed by hand."
        }
        return nil
    }

    static var canInstallInPlace: Bool { blocker == nil }

    // MARK: - Fetch and verify

    /// Downloads, checks, and unpacks — everything except the part that cannot
    /// be undone. Returns the verified bundle, still in a temporary directory.
    static func prepare(_ release: Updates.Release) async throws -> URL {
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parrotflow-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let zip = scratch.appendingPathComponent("ParrotFlow.zip")
        try await download(release.zip, to: zip)

        let publishedSum = try await string(from: release.checksum)
            .split(separator: " ").first.map(String.init) ?? ""
        let actualSum = try sha256(ofFileAt: zip)
        guard publishedSum == actualSum else {
            throw Failure.checksum(expected: publishedSum, got: actualSum)
        }

        // ditto, not unzip: a .app is a bundle, and unzip drops the metadata
        // the signature covers — which would cost the user their permissions.
        let unpacked = scratch.appendingPathComponent("unpacked")
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]).status == 0 else {
            throw Failure.contents("could not unpack the archive")
        }
        // The name the release ships under, not the name this bundle happens to
        // carry. The two differ on a dev build, and for anyone who renamed the
        // app after installing it.
        let app = unpacked.appendingPathComponent(Updates.releaseAppName)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw Failure.contents("the archive does not contain \(Updates.releaseAppName)")
        }

        try verify(app, expecting: release.version)
        return app
    }

    /// The checks install.sh runs, in the same order and for the same reasons.
    static func verify(_ app: URL, expecting version: String) throws {
        let verified = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard verified.status == 0 else {
            throw Failure.signature(verified.error.isEmpty ? "unknown reason" : verified.error)
        }

        // Signed by whom. The check above proves the signature matches the
        // bundle and says nothing about who produced it. This one says the
        // chain ends at Apple's root and the leaf carries our Team ID.
        let issued = run("/usr/bin/codesign",
                         ["--verify", "--deep", "--strict",
                          "-R", "=\(Updates.signingRequirement)", app.path])
        guard issued.status == 0 else {
            throw Failure.certificate(expected: Updates.expectedTeamID)
        }

        // And notarized, asked the way Gatekeeper asks. A signature can be
        // genuine and the build never submitted to Apple.
        let assessed = run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard assessed.status == 0 else {
            throw Failure.notarization(assessed.error.isEmpty ? "unknown reason" : assessed.error)
        }

        // Identity and version, because a valid archive can still be the wrong
        // one: a release asset built from the wrong tag would pass everything
        // above and then downgrade the user.
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let identifier = plist["CFBundleIdentifier"] as? String,
              let shipped = plist["CFBundleShortVersionString"] as? String else {
            throw Failure.contents("no readable Info.plist")
        }
        guard identifier == Updates.releaseBundleIdentifier else {
            throw Failure.contents("it is \(identifier), not \(Updates.releaseBundleIdentifier)")
        }
        guard shipped == version else {
            throw Failure.contents("the archive says \(shipped), the release says \(version)")
        }
    }

    // MARK: - Swap

    /// Hands the swap to a process that outlives this one, then leaves.
    ///
    /// Paths are passed as arguments rather than pasted into the script text:
    /// they contain the app's name and its parent directory, and a path with a
    /// space in it would otherwise become two words at the worst possible
    /// moment.
    static func swapAndRelaunch(newApp: URL) throws {
        if let blocker { throw Failure.cannotInstall(blocker) }

        // The outcome goes to the log because by then there is nobody left to
        // tell. This process has exited, and the app that comes back up is
        // whichever one won — so an update that failed and one that worked look
        // exactly alike from the outside: the app relaunches either way.
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        backup="$2.replaced-$$"
        if ! mv "$2" "$backup"; then
            echo "updates: could not move the current app aside; nothing changed" >> "$4"
            exit 1
        fi
        if mv "$3" "$2"; then
            rm -rf "$backup"
            echo "updates: replaced with the downloaded version" >> "$4"
        else
            mv "$backup" "$2"
            echo "updates: the swap failed — put the previous version back" >> "$4"
        fi
        open "$2"
        """

        let swap = Process()
        swap.executableURL = URL(fileURLWithPath: "/bin/sh")
        swap.arguments = [
            "-c", script, "swap",
            String(ProcessInfo.processInfo.processIdentifier),
            destination.path,
            newApp.path,
            Log.fileURL.path,
        ]
        try swap.run()
        Log.write("updates: swapping in \(newApp.path), then relaunching")
    }

    // MARK: - Plumbing

    private static func download(_ url: URL, to file: URL) async throws {
        do {
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw Failure.download("GitHub answered \(http.statusCode)")
            }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temporary, to: file)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    private static func string(from url: URL) async throws -> String {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return String(decoding: data, as: UTF8.self)
        } catch {
            throw Failure.download(error.localizedDescription)
        }
    }

    private static func sha256(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ tool: String, _ arguments: [String]) -> (status: Int32, error: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
