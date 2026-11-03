import Testing
import Foundation
@testable import VoxScriptaCore

/// Where a model is looked for.
///
/// Worth its own suite because getting this wrong is silent: a packaged build
/// that cannot find its model does not crash, it reports "no bundled model"
/// and runs without POLISH. That is a headline feature going missing with no
/// error anywhere, which is how the original bug survived.
@Suite("Model search")
struct ModelSearchTests {

    @Test("A named override is taken as given, present or not")
    func overrideWins() {
        // Someone who named a path wants to be told that path is wrong, not
        // quietly handed a different model from somewhere else.
        let key = "VOXSCRIPTA_TEST_MODEL_\(UUID().uuidString.prefix(8))"
        setenv(key, "/nowhere/special/model.gguf", 1)
        defer { unsetenv(key) }

        let found = ModelSearch.locate("polish.gguf", environmentKey: key)
        #expect(found.path == "/nowhere/special/model.gguf")
    }

    @Test("An empty override is ignored rather than resolving to nothing")
    func emptyOverrideIgnored() {
        let key = "VOXSCRIPTA_TEST_MODEL_\(UUID().uuidString.prefix(8))"
        setenv(key, "", 1)
        defer { unsetenv(key) }

        let found = ModelSearch.locate("polish.gguf", environmentKey: key)
        #expect(!found.path.isEmpty)
        #expect(found.lastPathComponent == "polish.gguf")
    }

    @Test("Beside the executable is searched before the build tree")
    func executableComesFirst() {
        let places = ModelSearch.candidates(for: "polish.gguf")
        let besideExecutable = places.firstIndex { !$0.path.contains("build/models") }
        let inBuildTree = places.firstIndex { $0.path.contains("build/models") }

        // A packaged application's working directory is not the project, so
        // the executable's own folder has to be looked at first or a shipped
        // build never finds the model sitting next to it.
        let beside = try! #require(besideExecutable)
        let built = try! #require(inBuildTree)
        #expect(beside < built)
    }

    @Test("An Apple bundle's Resources folder is one of the places")
    func appleBundleLayoutIsCovered() {
        let places = ModelSearch.candidates(for: "polish.gguf").map(\.path)
        // A .app's executable is in Contents/MacOS and its assets are not.
        #expect(places.contains { $0.contains("Resources/models/polish.gguf") })
    }

    @Test("The build tree is found by walking up, not by a fixed depth")
    func buildTreeIsWalked() {
        let places = ModelSearch.candidates(for: "polish.gguf")
            .filter { $0.path.contains("build/models") }
        // More than one level, because the depth differs per platform and per
        // build mode — the same mistake that made a bundled app look for the
        // library two directories too high.
        #expect(places.count > 1)
    }

    @Test("Nothing found still names a path a person can act on")
    func missingModelNamesSomewhere() {
        let key = "VOXSCRIPTA_TEST_MODEL_\(UUID().uuidString.prefix(8))"
        let found = ModelSearch.locate("definitely-not-here-\(UUID().uuidString).gguf",
                                       environmentKey: key)
        #expect(found.path.contains("build/models"))
    }

    @Test("A model that is really there is found")
    func findsAnActualFile() throws {
        let directory = URL(filePath: NSTemporaryDirectory())
            .appending(path: "models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory.appending(path: "build/models"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let name = "found-\(UUID().uuidString.prefix(8)).gguf"
        let model = directory.appending(path: "build/models/\(name)")
        try Data("not really a model".utf8).write(to: model)

        let previous = FileManager.default.currentDirectoryPath
        defer { FileManager.default.changeCurrentDirectoryPath(previous) }
        FileManager.default.changeCurrentDirectoryPath(directory.path)

        let found = ModelSearch.locate(name, environmentKey: "VOXSCRIPTA_UNSET_\(name)")
        #expect(FileManager.default.fileExists(atPath: found.path))
        #expect(found.lastPathComponent == name)
    }
}
