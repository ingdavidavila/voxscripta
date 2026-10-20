import Foundation
import VoxScriptaCore

/// Whether an imported recording is copied into the project or referenced in place.
public enum ImportPolicy: String, Sendable, Codable, CaseIterable {
    /// Point at the user's file where it already lives. No duplication, but the
    /// project breaks if they move it. The default: recordings are large, and
    /// silently doubling a 4 GB file is a surprise.
    case reference
    /// Copy the audio into the package, making the project self-contained.
    case copy

    public static let `default` = ImportPolicy.reference
}

/// Creates, opens and maintains project packages.
///
/// A package is a plain directory rather than an opaque database, so a user can
/// inspect it, back it up, and recover from it by hand if this app ever fails.
public struct ProjectStore: Sendable {
    public init() {}

    /// Imports `audio` into a new project at `url`.
    ///
    /// The original is read, hashed, and either copied or bookmarked. It is never
    /// opened for writing, moved, or modified.
    public func create(
        from audio: URL,
        at url: URL,
        policy: ImportPolicy = .default,
        silence: SilenceParameters = .default,
        chunking: ChunkParameters = .default,
        engine: EngineID = .appleSpeech,
        locale: String = "en-US",
        concurrency: Int = 4,
        probe: @Sendable (URL) async throws -> (AudioFormatDescription, MediaTime)
    ) async throws -> Project {
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw VoxScriptaError.sourceUnavailable(path: audio.path)
        }
        let package = ProjectPackage(root: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package.originalDirectory,
                                                withIntermediateDirectories: true)

        let hash = try ContentHash.file(at: audio)
        let size = (try? FileManager.default
            .attributesOfItem(atPath: audio.path)[.size] as? Int64) ?? 0
        let (format, duration) = try await probe(audio)

        let reference: SourceReference
        switch policy {
        case .copy:
            let destination = package.originalDirectory.appending(path: audio.lastPathComponent)
            if !FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.copyItem(at: audio, to: destination)
            }
            reference = .insidePackage(filename: audio.lastPathComponent)
        case .reference:
            reference = .bookmark(try Self.makeBookmark(for: audio))
        }

        let manifest = ProjectManifest(
            source: AudioSource(
                reference: reference, displayName: audio.lastPathComponent,
                contentHash: hash, format: format, duration: duration, byteSize: size),
            silenceParameters: silence,
            chunkParameters: chunking,
            engineID: engine,
            locale: locale,
            concurrency: concurrency)

        try AtomicFile.writeJSON(manifest, to: package.manifestURL)
        let store = try JobStore(url: package.jobStoreURL)
        try await store.setState(.imported)

        return Project(package: package, manifest: manifest, store: store)
    }

    /// Opens an existing project, recovering any work interrupted by a crash.
    public func open(at url: URL) async throws -> Project {
        let package = ProjectPackage(root: url)
        guard FileManager.default.fileExists(atPath: package.manifestURL.path) else {
            throw VoxScriptaError.projectCorrupt(reason: "no manifest at \(url.lastPathComponent)")
        }
        let manifest = try AtomicFile.readJSON(ProjectManifest.self, from: package.manifestURL)

        guard manifest.schemaVersion <= VoxScripta.projectSchemaVersion else {
            throw VoxScriptaError.schemaTooNew(found: manifest.schemaVersion,
                                             supported: VoxScripta.projectSchemaVersion)
        }

        let store = try JobStore(url: package.jobStoreURL)
        // A chunk still marked in-flight means the process died mid-transcription.
        _ = try await store.recoverInterruptedChunks()
        try Self.removeOrphanedTemporaries(in: package)

        return Project(package: package, manifest: manifest, store: store)
    }

    /// What deleting a project would actually remove.
    ///
    /// Presented before the fact, because "delete" means different things
    /// depending on how the recording was imported, and the difference is the
    /// whole §5 guarantee. A referenced recording lives in the user's own folder
    /// and is never touched; a copied one exists twice, and only the copy inside
    /// the project goes.
    public struct DeletionPlan: Sendable {
        public let projectName: String
        /// Bytes freed by removing the package.
        public let bytesFreed: Int64
        /// The user's own recording, which is not deleted.
        public let originalKept: URL?
        /// True when the only copy of the audio is inside the package.
        public let removesAudioCopy: Bool

        public init(projectName: String, bytesFreed: Int64,
                    originalKept: URL?, removesAudioCopy: Bool) {
            self.projectName = projectName
            self.bytesFreed = bytesFreed
            self.originalKept = originalKept
            self.removesAudioCopy = removesAudioCopy
        }
    }

    /// Describes what deleting `url` would remove, without removing anything.
    public func deletionPlan(for url: URL) async throws -> DeletionPlan {
        let package = ProjectPackage(root: url)
        let manifest = try AtomicFile.readJSON(ProjectManifest.self, from: package.manifestURL)

        let bytes = Self.sizeOnDisk(of: url)
        let copied = manifest.source.reference.isCopy
        var kept: URL?
        if !copied {
            let project = Project(package: package, manifest: manifest,
                                  store: try JobStore(url: package.jobStoreURL))
            if let (resolved, release) = try? project.resolveSource() {
                release()
                kept = resolved
            }
        }

        return DeletionPlan(projectName: manifest.source.displayName,
                            bytesFreed: bytes, originalKept: kept,
                            removesAudioCopy: copied)
    }

    /// Total bytes a directory occupies. Synchronous: directory enumeration is
    /// unavailable from an async context.
    nonisolated static func sizeOnDisk(of url: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var bytes: Int64 = 0
        for case let entry as URL in walker {
            bytes += Int64((try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes
    }

    /// Deletes a project package.
    ///
    /// Moves it to the Trash rather than unlinking, so a mistaken delete is
    /// recoverable — this is the only destructive action in the app, and an
    /// undoable one costs nothing.
    ///
    /// - Important: Only the package is removed. A recording the user imported by
    ///   reference stays exactly where they put it; nothing here can reach
    ///   outside `url`.
    @discardableResult
    public func delete(at url: URL) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Only ever removes something that is demonstrably a VoxScripta project.
        // The UI hands this a URL; a bug there must not be able to trash an
        // arbitrary folder of the user's.
        guard FileManager.default.fileExists(
            atPath: ProjectPackage(root: url).manifestURL.path) else {
            throw VoxScriptaError.projectCorrupt(
                reason: "\(url.lastPathComponent) is not a VoxScripta project")
        }
        var trashed: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        } catch {
            throw VoxScriptaError.ioFailure(path: url.path, reason: error.localizedDescription)
        }
        return trashed as URL?
    }

    /// Deletes leftover `.tmp` files from an interrupted atomic write.
    ///
    /// These are always safe to remove: an atomic write only renames into place
    /// once the data is durable, so anything still carrying the temporary suffix
    /// never became a committed artifact.
    private static func removeOrphanedTemporaries(in package: ProjectPackage) throws {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: package.root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker where url.lastPathComponent.hasSuffix(".tmp") {
            try? fm.removeItem(at: url)
        }
    }

    private static func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(options: [.withSecurityScope],
                                        includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            // Security scope needs an entitlement the CLI does not carry. A plain
            // bookmark still resolves and still tracks the file if it moves.
            return try url.bookmarkData(includingResourceValuesForKeys: nil, relativeTo: nil)
        }
    }
}

/// An open project: its layout, its manifest, and its durable job state.
public struct Project: Sendable {
    public let package: ProjectPackage
    public let manifest: ProjectManifest
    public let store: JobStore

    public init(package: ProjectPackage, manifest: ProjectManifest, store: JobStore) {
        self.package = package
        self.manifest = manifest
        self.store = store
    }

    /// Records the locale the language probe settled on.
    ///
    /// Written to the manifest so a reopened project does not detect again:
    /// the locale feeds the content hash, and a second detection that
    /// disagreed would invalidate work that is already finished and correct.
    public func recordDetectedLocale(_ locale: String) throws {
        var updated = manifest
        updated.detectedLocale = locale
        updated.locale = locale
        try AtomicFile.writeJSON(updated, to: package.manifestURL)
    }

    /// Resolves the original audio to a readable URL.
    ///
    /// - Returns: The URL, plus a closure to call when finished, which releases
    ///   security-scoped access if resolution started any.
    public func resolveSource() throws -> (url: URL, release: @Sendable () -> Void) {
        switch manifest.source.reference {
        case .insidePackage(let filename):
            let url = package.originalDirectory.appending(path: filename)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoxScriptaError.sourceUnavailable(path: url.path)
            }
            return (url, {})

        case .bookmark(let data):
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope],
                                     relativeTo: nil, bookmarkDataIsStale: &stale) else {
                guard let plain = try? URL(resolvingBookmarkData: data, options: [],
                                           relativeTo: nil, bookmarkDataIsStale: &stale),
                      FileManager.default.fileExists(atPath: plain.path) else {
                    throw VoxScriptaError.sourceUnavailable(path: manifest.source.displayName)
                }
                return (plain, {})
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw VoxScriptaError.sourceUnavailable(path: url.path)
            }
            let scoped = url.startAccessingSecurityScopedResource()
            return (url, { if scoped { url.stopAccessingSecurityScopedResource() } })
        }
    }

    /// Removes derived data once a job is complete.
    ///
    /// `Original/`, `manifest.json` and `Output/` are untouched by any code path
    /// here — the §5 guarantee, enforced by what this function does not do.
    ///
    /// Safe to call on a finished project: the resume planner checks completion
    /// from `Output/` and the recorded hashes, both of which survive, so a
    /// reclaimed project still opens instantly rather than re-running.
    @discardableResult
    public func reclaimDerivedStorage() throws -> Int64 {
        let fm = FileManager.default
        var freed: Int64 = 0
        for directory in package.reclaimableDirectories {
            guard let walker = fm.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            else { continue }
            for case let url as URL in walker {
                freed += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            try? fm.removeItem(at: directory)
        }
        return freed
    }
}
