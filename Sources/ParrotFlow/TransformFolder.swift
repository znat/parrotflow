import Foundation

/// Where a transform's files live, and where its command runs.
///
/// A transform named `X` owns `<config>/transforms/X/`. Everything belonging to
/// it — the prompt or the script, its case set, the roster it looks names up in
/// — goes in there, so it can be written, scored and handed to someone else as
/// one thing rather than as a paragraph of config plus four files you have to
/// remember to bring.
///
/// The half that pays for the extra directory is that the folder is also the
/// **working directory** the command runs in. A script can then open
/// `roster.json` as a bare relative path and the folder is self-contained: copy
/// it to another machine, or paste it into a gist, and it works.
///
/// The config directory itself is searched second, because that is where every
/// script written before folders existed still sits and nobody's setup is
/// allowed to stop working because they upgraded.
struct TransformFolder: Equatable {
    /// The directory of the file that declared the transform — where
    /// `config.yaml` is, or where a `--pipeline` fixture is.
    var configDirectory: URL
    /// The transform's name, verbatim as the config spells it.
    var name: String

    init(configDirectory: URL, name: String) {
        self.configDirectory = configDirectory
        self.name = name
    }

    /// `<config>/transforms/<name>`, or nil for a name that cannot be one.
    ///
    /// A name with a slash in it would reach outside the transforms directory,
    /// and an empty one names the directory itself. Neither is a folder, and
    /// both would otherwise resolve to something — silently, and to the wrong
    /// place.
    var url: URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        return configDirectory
            .appendingPathComponent("transforms", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .standardizedFileURL
    }

    /// The directories a relative path is tried against, in order: the folder,
    /// then the old location beside `config.yaml`.
    var searchPath: [URL] {
        [url, configDirectory.standardizedFileURL].compactMap { $0 }
    }

    /// Where a command with no file of its own runs — a bare `sed` the shell
    /// finds on PATH.
    ///
    /// Only that case. A command that resolved to a file runs in **that file's**
    /// directory, decided by `CommandRunner.run`, because a script's neighbours
    /// are the files beside the script and not the files beside a folder it was
    /// never in.
    ///
    /// The folder when it is there, and the config directory when it is not — a
    /// working directory that does not exist is not a slower process, it is a
    /// process that cannot start at all, and a config whose folders have not
    /// been created yet is an ordinary state to be in.
    var workingDirectory: URL {
        var isDirectory: ObjCBool = false
        if let url, FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return url
        }
        return configDirectory
    }

    /// A file the transform declared, found.
    struct Resolved: Equatable {
        var url: URL
        /// True when it was found beside `config.yaml` rather than in the
        /// folder. A notice and never a fault: it runs, and `--check-config`
        /// says where it should move to.
        var atOldLocation: Bool

        var path: String { url.path }
    }

    /// The first directory in the search path that has `path`, or nil.
    ///
    /// An absolute path — or one starting `~` — is its own answer and skips the
    /// search entirely.
    func resolve(_ path: String) -> Resolved? {
        // Expanded only when there is a tilde, because the expansion also
        // standardises — and a trailing slash is the shell's business, not
        // this one's. See `CommandRunner.parts`.
        let expanded = path.hasPrefix("~") ? (path as NSString).expandingTildeInPath : path
        guard !expanded.isEmpty else { return nil }
        let fm = FileManager.default

        if expanded.hasPrefix("/") {
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            guard fm.fileExists(atPath: url.path) else { return nil }
            // Deliberate, wherever it points. Nothing to move.
            return Resolved(url: url, atOldLocation: false)
        }

        for base in searchPath {
            let candidate = base.appendingPathComponent(expanded).standardizedFileURL
            guard fm.fileExists(atPath: candidate.path) else { continue }
            return Resolved(url: candidate, atOldLocation: !contains(candidate))
        }
        return nil
    }

    /// Whether a resolved file is inside the folder.
    ///
    /// Compared as resolved absolute paths rather than by looking at what was
    /// written, because both of these name the same file and neither is at the
    /// old location:
    ///
    ///     command: slack_mentions.py
    ///     command: transforms/slack_mentions/slack_mentions.py
    ///
    /// The first is found by the folder. The second is relative to the config
    /// directory and spells out what the first does — string-matching the
    /// prefix would report it as needing to move to where it already is.
    private func contains(_ candidate: URL) -> Bool {
        guard let url else { return false }
        let folder = url.path.hasSuffix("/") ? url.path : url.path + "/"
        return candidate.path.hasPrefix(folder)
    }

    /// What `--check-config` prints for a file found beside `config.yaml`.
    ///
    /// A notice and not a fault. The distinction matters at the other end: the
    /// app puts `problems()` behind "⚠︎ your config does nothing", and a
    /// working script in the place it has always been is not that.
    func moveNotice(for file: URL) -> String? {
        guard url != nil else { return nil }
        return "transforms: \"\(name)\" found at the old location — move it to"
            + " transforms/\(name)/\(file.lastPathComponent)"
    }
}
