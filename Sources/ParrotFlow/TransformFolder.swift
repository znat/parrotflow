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
/// **One layout, and nothing to fall back to.** An earlier draft searched the
/// config directory too, so that a script written before folders existed kept
/// running where it was. Two directories that can disagree turned out to be a
/// steady source of defects rather than a kindness: which one a command runs
/// in stopped being answerable without knowing where every file it names
/// happens to sit, and every answer was wrong for some other config. It was
/// paid for a population of nobody — the layout arrived before anyone had
/// installed the app. A config that still points outside its folder is now
/// told so once, by `--check-config`, and moving the file is the whole fix.
///
/// What that invariant is really about is the *bare name*: `punctuation.py`
/// resolves in the folder or nowhere, so the spelling written every day cannot
/// mean two files. A path with a directory in it —
/// `examples/punctuation/punctuation.py` — may name a file elsewhere under
/// `transforms/`, which is how the shipped examples are read from one copy
/// rather than copied per transform. It is still one answer per spelling, and
/// the working directory does not move: a shared script runs in the folder of
/// whichever transform called it, so it locates its own data from `__file__`.
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

    /// Where a `command:` runs — the folder, always.
    ///
    /// The config directory only when the folder is not there at all, because a
    /// working directory that does not exist is not a slower process, it is a
    /// process that cannot start. A transform whose folder is missing has
    /// nothing to run anyway; this just decides where it fails.
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

        var path: String { url.path }
    }

    /// The file at `path` inside the folder, or nil.
    ///
    /// An absolute path — or one starting `~` — is its own answer and skips the
    /// folder entirely.
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
            return Resolved(url: url)
        }

        guard let url else { return nil }
        let inFolder = url.appendingPathComponent(expanded).standardizedFileURL
        if fm.fileExists(atPath: inFolder.path) { return Resolved(url: inFolder) }

        // A folder shared between transforms, resolved against `transforms/`
        // rather than against any one transform's own folder —
        // `examples/punctuation/punctuation.py`. The shipped examples are the
        // case that wants it: one copy of a script, read by whoever names it,
        // instead of a copy per transform that names it.
        //
        // **Only for a path with a slash in it.** A bare `punctuation.py` still
        // means your own folder and nothing else, which is the invariant the
        // note above is defending: the common spelling can never resolve in two
        // places, so the two can never disagree. A path that reaches sideways
        // says so by having a directory in it.
        if expanded.contains("/") {
            let shared = transformsDirectory
                .appendingPathComponent(expanded).standardizedFileURL
            if fm.fileExists(atPath: shared.path), shared.isInside(transformsDirectory) {
                return Resolved(url: shared)
            }
        }

        // `transforms/slack_mentions/slack_mentions.py` spells out what
        // `slack_mentions.py` does, and people write both, so both name the
        // same file. Resolved against the config directory and then **required
        // to land inside the folder**, so this is not a second place to look:
        // the only paths it adds are longer spellings of the folder above.
        let spelledOut = configDirectory.appendingPathComponent(expanded).standardizedFileURL
        guard fm.fileExists(atPath: spelledOut.path), spelledOut.isInside(url) else { return nil }
        return Resolved(url: spelledOut)
    }

    /// `<config>/transforms` — where every transform's folder sits.
    private var transformsDirectory: URL {
        configDirectory
            .appendingPathComponent("transforms", isDirectory: true)
            .standardizedFileURL
    }
}

private extension URL {
    /// Whether this path sits inside `directory`, compared as resolved
    /// absolute paths rather than by matching what was written.
    func isInside(_ directory: URL) -> Bool {
        let folder = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return path.hasPrefix(folder)
    }
}
