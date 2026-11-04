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
/// 4. The development build tree, found by walking up from the working
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
        if let override = ProcessInfo.processInfo.environment[environmentKey],
           !override.isEmpty {
            // Taken as given, present or not: someone who named a path wants
            // to be told that path is wrong, not quietly handed a different
            // model.
            return URL(filePath: override)
        }
        for candidate in candidates(for: fileName)
        where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return developmentPath(for: fileName)
    }

    /// Every place that is looked, in order.
    ///
    /// Public so a diagnostic can print the list: "no model found" is a poor
    /// message when the fix is usually putting the file in one of these.
    public static func candidates(for fileName: String) -> [URL] {
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

    /// What a message should name when nothing was found: the development
    /// location, which is the one a developer can do something about.
    private static func developmentPath(for fileName: String) -> URL {
        URL(filePath: FileManager.default.currentDirectoryPath)
            .appending(path: "build/models/\(fileName)")
    }
}
