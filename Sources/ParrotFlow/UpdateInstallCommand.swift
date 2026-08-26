import Foundation

/// Downloads and checks a release without installing it.
///
///     ParrotFlow --update-install --dry-run     # everything but the swap
///     ParrotFlow --update-install               # and the swap
///
/// The dry run exists because every interesting failure happens before the
/// swap — a checksum that does not match, an archive signed by someone else, a
/// release whose asset was built from the wrong tag. Those are the paths worth
/// exercising, and none of them should require replacing the app on the
/// machine doing the exercising.
enum UpdateInstallCommand {

    static func run(dryRun: Bool) -> Int32 {
        guard let current = Updates.current else {
            print("✗ this binary is running outside its app bundle, so there is nothing to replace")
            return 1
        }

        var code: Int32 = 0
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            do {
                let release = try await Updates.latest()
                print("current            \(current)")
                print("latest             \(release.version)")

                guard Updates.isNewer(release.version, than: current) else {
                    print("decision           nothing to install")
                    done.signal()
                    return
                }

                print("downloading        \(release.zip.lastPathComponent)")
                let app = try await UpdateInstaller.prepare(release)
                print("checksum           matches the published one")
                print("signature          valid")
                print("team id            \(Updates.expectedTeamID)")
                print("notarized          yes")
                print("identity           \(Updates.releaseBundleIdentifier)")
                print("verified           \(app.path)")

                guard !dryRun else {
                    print("dry run            not installing")
                    done.signal()
                    return
                }
                if let blocker = UpdateInstaller.blocker {
                    print("✗ \(blocker)")
                    code = 1
                    done.signal()
                    return
                }
                try UpdateInstaller.swapAndRelaunch(newApp: app)
                print("installing         after this process exits")
            } catch {
                print("✗ \(error.localizedDescription)")
                code = 1
            }
            done.signal()
        }
        done.wait()
        return code
    }
}
