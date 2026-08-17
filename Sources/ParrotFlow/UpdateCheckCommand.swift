import Foundation

/// Asks the same question the app asks hourly, and shows its working.
///
///     ParrotFlow --update-check
///     ParrotFlow --update-check --after-days 0
///
/// The `--after-days` override is what makes the waiting period testable at
/// all: the alternative is publishing a release and coming back in a week.
enum UpdateCheckCommand {

    static func run(afterDays override: Int?) -> Int32 {
        let config = (try? ConfigStore.load()) ?? Config()
        let afterDays = override ?? config.updates.afterDays

        let current = Updates.current
        print("current            \(current ?? "unknown (running outside the app bundle)")")
        print("waiting period     \(describe(afterDays))")

        if afterDays < 0 {
            print("decision           no check — updates.after_days is negative")
            return 0
        }

        var latest: Updates.Release?
        let done = DispatchSemaphore(value: 0)
        Task<Void, Never> {
            do {
                latest = try await Updates.latest()
            } catch {
                // Being offline is a normal state, not a failed command: a
                // non-zero exit here would make a laptop on a train look like
                // a broken build.
                print("decision           could not ask GitHub: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()

        guard let latest else { return 0 }

        print("latest             \(latest.version)")
        print("published          \(latest.publishedAt) (\(latest.ageInDays) days ago)")

        let state = Updates.State.standard
        if let skipped = state.skipped { print("skipped            \(skipped)") }
        if let remind = state.remindAfter { print("remind after       \(remind)") }

        switch Updates.decide(current: current, latest: latest, afterDays: afterDays, state: state) {
        case .disabled:
            print("decision           no check — updates.after_days is negative")
        case .upToDate(let running, let published):
            print("decision           up to date (\(running), latest is \(published))")
        case .waiting(let release, let days):
            print("decision           holding \(release.version) for \(days) more day(s)")
        case .skipped(let release):
            print("decision           \(release.version) was skipped")
        case .snoozed(let release, let until):
            print("decision           \(release.version) postponed until \(until)")
        case .available(let release):
            print("decision           offer \(release.version)")
            print()
            print(release.notes.isEmpty ? "(no release notes)" : release.notes)
        }
        return 0
    }

    private static func describe(_ days: Int) -> String {
        switch days {
        case ..<0: return "never check (\(days))"
        case 0: return "none — take a release the day it is published"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }
}
