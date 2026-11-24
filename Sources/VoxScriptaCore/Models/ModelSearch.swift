import Foundation

/// Where a model file is looked for.
///
/// One implementation for every engine, because "where the model lives" is a
/// rule, and two engines resolving it differently would mean a build where
/// transcription finds its model and polishing does not.
///
/// The order matters, and each step is there for a different situation:
///
/// 1. An environment variable, so a benchmark can point at a specific model
///    without editing anything.
/// 2. Beside the executable, which is where a packaged application keeps one.
/// 3. Inside an Apple app bundle's `Resources`, because a `.app`'s executable
///    lives in `Contents/MacOS` and not next to its assets.
/// 4. The host's own data directory, when a host has named one. This is the
///    only location that exists on Android, where the working directory is
///    `/` and the executable is the system's, not ours — the walk in step 5
///    produced `/build/models/ggml-base.bin`, a path no phone can ever have.
/// 5. The development build tree, found by walking up from the working
///    directory rather than assuming how deep it is.
///
/// The first version did step 4 alone, and did it by joining
/// `build/models/<name>` onto the *current directory*. That is right for a
/// command line run from the project root and wrong for every packaged
/// application, whose working directory is not the project — so a shipped
/// Windows or Linux build would have reported "no bundled model" with the file
/// sitting beside the executable, and POLISH would have been quietly absent.
/// Found by running `vs_capabilities` against a real machine.
public enum ModelSearch {

    /// Finds `fileName`, or returns the path it would have used, so that a
    /// failure can name something a person can act on.
    ///
    /// - Parameters:
    ///   - fileName: for example `polish.gguf`.
    ///   - environmentKey: the override variable, e.g. `VOXSCRIPTA_LLAMA_MODEL`.
    public static func locate(_ fileName: String, environmentKey: String) -> URL {
        locate(fileName, environmentKey: environmentKey,
               hostDirectory: DataDirectory.configuredRoot)
    }

    /// The same, with the host directory supplied rather than read.
    ///
    /// Internal so tests can exercise the rule without setting a process-wide
    /// directory. The first version of these tests did set one, and they
    /// raced each other: the data directory is global by design, so a test
    /// that mutates it is testing every other test running beside it.
    static func locate(_ fileName: String, environmentKey: String,
                       hostDirectory: URL?) -> URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey],
           !override.isEmpty {
            // Taken as given, present or not: someone who named a path wants
            // to be told that path is wrong, not quietly handed a different
            // model.
            return URL(filePath: override)
        }
        for candidate in candidates(for: fileName, hostDirectory: hostDirectory)
        where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return fallbackPath(for: fileName, hostDirectory: hostDirectory)
    }

    /// Every place that is looked, in order.
    ///
    /// Public so a diagnostic can print the list: "no model found" is a poor
    /// message when the fix is usually putting the file in one of these.
    public static func candidates(for fileName: String) -> [URL] {
        candidates(for: fileName, hostDirectory: DataDirectory.configuredRoot)
    }

    static func candidates(for fileName: String, hostDirectory: URL?) -> [URL] {
        var places: [URL] = []

        if let argument = CommandLine.arguments.first, !argument.isEmpty {
            let executable = URL(filePath: argument).deletingLastPathComponent()
            places.append(executable.appending(path: "models/\(fileName)"))
            places.append(executable.appending(path: fileName))
            // Contents/MacOS/exe → Contents/Resources/models/<name>
            places.append(executable
                .deletingLastPathComponent()
                .appending(path: "Resources/models/\(fileName)"))
        }

        // Where the host said its data lives. The caller passes
        // `DataDirectory.configuredRoot` and never `root`: reading `root`
        // would fix the data directory for the whole process, and a model
        // lookup has no business deciding that — see its comment.
        if let hostDirectory {
            places.append(hostDirectory.appending(path: "models/\(fileName)"))
        }

        // The development tree, by walking up rather than guessing a depth —
        // the same mistake, one level removed, as hardcoding `../../`.
        var directory = URL(filePath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            places.append(directory.appending(path: "build/models/\(fileName)"))
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return places
    }

    /// What a message should name when nothing was found.
    ///
    /// A failure is read by whoever can fix it, so it names the place that
    /// person would put the file. With a host data directory that is the data
    /// directory; without one it is the development tree. Naming the
    /// development tree unconditionally is what told an Android user to run a
    /// shell script against `/build/models`, which is neither a path on that
    /// device nor something a phone can do.
    static func fallbackPath(for fileName: String, hostDirectory: URL?) -> URL {
        if let hostDirectory {
            return hostDirectory.appending(path: "models/\(fileName)")
        }
        return URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "build/models/\(fileName)")
    }
}
