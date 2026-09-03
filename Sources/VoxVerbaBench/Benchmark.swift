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
/// - Note: Phase 2 implements this over `task_info` with `TASK_VM_INFO`.
public enum MemoryFootprint {
    public static func current() throws -> Int64 {
        throw VoxVerbaError.notImplemented("MemoryFootprint.current — Phase 2")
    }
}
