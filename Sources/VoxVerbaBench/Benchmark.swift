import Foundation
import VoxVerbaCore

/// One stage's measurement.
public struct StageMeasurement: Sendable, Codable {
    public let stage: String
    public let wallTime: TimeInterval
    /// Peak resident footprint during the stage, in bytes.
    public let peakFootprint: Int64
    /// Audio seconds processed per wall second. Higher is faster.
    public let realTimeFactor: Double?

    public init(stage: String, wallTime: TimeInterval, peakFootprint: Int64, realTimeFactor: Double? = nil) {
        self.stage = stage
        self.wallTime = wallTime
        self.peakFootprint = peakFootprint
        self.realTimeFactor = realTimeFactor
    }
}

/// A full pipeline run's measurements (§34).
public struct BenchmarkReport: Sendable, Codable {
    public let sourceDuration: MediaTime
    public let sourceByteSize: Int64
    public let engineID: EngineID?
    public let modelID: ModelID?
    public let concurrency: Int
    public let stages: [StageMeasurement]
    public let totalWallTime: TimeInterval
    public let peakFootprint: Int64
    public let recordedAt: Date
    /// Chip identifier, so trend files stay comparable across machines.
    public let hardware: String

    public init(
        sourceDuration: MediaTime,
        sourceByteSize: Int64,
        engineID: EngineID?,
        modelID: ModelID?,
        concurrency: Int,
        stages: [StageMeasurement],
        totalWallTime: TimeInterval,
        peakFootprint: Int64,
        recordedAt: Date = Date(),
        hardware: String
    ) {
        self.sourceDuration = sourceDuration
        self.sourceByteSize = sourceByteSize
        self.engineID = engineID
        self.modelID = modelID
        self.concurrency = concurrency
        self.stages = stages
        self.totalWallTime = totalWallTime
        self.peakFootprint = peakFootprint
        self.recordedAt = recordedAt
        self.hardware = hardware
    }
}

/// Reads the process's current resident footprint.
///
/// `phys_footprint` is the figure macOS actually uses for memory-limit decisions,
/// which makes it the right number to assert against in the memory tests — resident
/// size overstates the cost of the memory-mapped canonical audio, since those are
/// clean pages the kernel can evict.
///
public enum MemoryFootprint {
    /// The process's current physical footprint in bytes.
    ///
    /// Deliberately `phys_footprint` rather than `resident_size`: resident size
    /// counts the clean, evictable pages of the memory-mapped canonical audio,
    /// which would make a six-hour recording look like a 1.4 GB leak. Footprint
    /// is also the figure macOS itself uses for memory-limit decisions, so it is
    /// the number worth asserting against.
    public static func current() throws -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            throw VoxVerbaError.analysisFailed(
                stage: "memory measurement",
                reason: "task_info failed with code \(result)")
        }
        return Int64(info.phys_footprint)
    }

    /// Runs `body`, sampling the footprint on a background task throughout.
    ///
    /// Peak footprint cannot be read after the fact — the allocation is already
    /// gone — so it has to be sampled while the work runs.
    public static func peak<T: Sendable>(
        samplingEvery interval: Duration = .milliseconds(25),
        during body: @Sendable () async throws -> T
    ) async throws -> (value: T, peakBytes: Int64) {
        let baseline = try current()
        let peak = Peak(initial: baseline)
        let sampler = Task.detached {
            while !Task.isCancelled {
                if let now = try? current() { peak.observe(now) }
                try? await Task.sleep(for: interval)
            }
        }
        defer { sampler.cancel() }
        let value = try await body()
        if let final = try? current() { peak.observe(final) }
        return (value, peak.value)
    }

    /// Thread-safe maximum, written by the sampler and read by the caller.
    private final class Peak: @unchecked Sendable {
        private let lock = NSLock()
        private var maximum: Int64
        init(initial: Int64) { maximum = initial }
        func observe(_ v: Int64) { lock.lock(); maximum = Swift.max(maximum, v); lock.unlock() }
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return maximum }
    }
}
