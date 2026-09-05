import Foundation

/// `--microphones` — every microphone attached to this Mac, with the exact
/// names `audio.microphones` matches on.
///
/// The list in the config is written by hand as often as it is written by the
/// menu, and a name typed from memory is a name that matches nothing. This is
/// where the strings come from.
enum MicrophonesCommand {

    /// `--microphones --set "a, b"` — writes the priority list, best first.
    /// `--microphones --set ""` clears it, which is what the menu's "Follow the
    /// System Setting" does.
    ///
    /// The menu bar is where this is normally done. This is the door a script
    /// can use, and the one `scripts/check-microphones.sh` writes through.
    static func set(_ list: String) -> Int32 {
        let names = list
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try ConfigWriter.setMicrophones(names)
        } catch {
            print("✗ could not write config.yaml: \(error.localizedDescription)")
            return 1
        }
        print(names.isEmpty
              ? "✓ audio.microphones cleared — following the system's input device"
              : "✓ audio.microphones: \(names.joined(separator: ", "))")
        return 0
    }

    static func run() -> Int32 {
        let devices = Recorder.inputDevices()
        guard !devices.isEmpty else {
            print("no microphone is attached")
            return 1
        }

        let entries = (try? ConfigStore.load())?.audio.microphones ?? []
        let winner = Recorder.preferredDevice(from: entries)
        let system = Recorder.defaultInputDeviceID

        let width = devices.map(\.name.count).max() ?? 0
        for device in devices {
            var notes: [String] = []
            if let rank = entries.firstIndex(where: {
                Recorder.device(named: $0, among: [device]) != nil
            }) {
                notes.append("listed #\(rank + 1)")
            }
            if device.id == winner?.id { notes.append("recording through this one") }
            if device.id == system { notes.append("the system's input device") }
            if device.isBluetooth { notes.append("bluetooth") }
            let name = device.name.padding(toLength: width, withPad: " ", startingAt: 0)
            print("  \(name)  \(device.uid)"
                  + (notes.isEmpty ? "" : "  — \(notes.joined(separator: ", "))"))
        }

        if winner == nil, !entries.isEmpty {
            print("")
            print("none of the \(entries.count) microphones in audio.microphones is attached")
        }
        return 0
    }
}
