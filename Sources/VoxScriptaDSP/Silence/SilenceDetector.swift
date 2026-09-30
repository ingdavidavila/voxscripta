import Foundation
import VoxScriptaCore

/// The five-stage deterministic silence detector (§6).
///
/// No model participates in this decision, by requirement and by design. The
/// stages run in a fixed order, and the order is load-bearing:
///
/// 1. **Noise floor estimation** — minimum-statistics tracking, so thresholds
///    follow a changing room rather than a fixed guess.
/// 2. **Adaptive dual thresholds** — an enter level and a lower exit level,
///    both floating with the noise floor and clamped to an absolute floor.
/// 3. **Fricative protection** — low-energy frames adjacent to speech are held
///    when they show high ZCR *and* high spectral flatness. This is what keeps
///    `/s/`, `/f/`, `/ʃ/` and `/θ/` from being truncated, which otherwise costs
///    the transcript its plurals and possessives.
/// 4. **Duration gating** — short speech runs demoted first, then short silence
///    runs promoted. Reversing the order merges noise into speech.
/// 5. **Asymmetric padding** — outward only, more after than before.
///
/// - Note: Phase 1 implements all five stages against the synthetic ground-truth
///   corpus, which is what makes the boundary-error assertions meaningful.
public protocol SilenceDetecting: Sendable {
    func detect(
        features: FrameFeatures,
        parameters: SilenceParameters,
        sourceDuration: MediaTime,
        parameterHash: String
    ) throws -> SilenceMap
}

/// The five-stage cascade.
public struct SilenceDetector: SilenceDetecting {
    public let noiseFloorTracker: NoiseFloorTracker

    /// Zero-crossing rate above which a low-energy frame may be unvoiced speech.
    public let fricativeZCRThreshold: Float
    /// Spectral flatness above which a low-energy frame may be unvoiced speech.
    public let fricativeFlatnessThreshold: Float
    /// A fricative candidate must still sit at least this far above the floor,
    /// so room tone — which is also flat and high-ZCR — is not held as speech.
    public let fricativeMarginDB: Float

    public init(
        noiseFloorTracker: NoiseFloorTracker = .default,
        fricativeZCRThreshold: Float = 0.15,
        fricativeFlatnessThreshold: Float = 0.22,
        fricativeMarginDB: Float = 2
    ) {
        self.noiseFloorTracker = noiseFloorTracker
        self.fricativeZCRThreshold = fricativeZCRThreshold
        self.fricativeFlatnessThreshold = fricativeFlatnessThreshold
        self.fricativeMarginDB = fricativeMarginDB
    }

    public func detect(
        features: FrameFeatures,
        parameters: SilenceParameters,
        sourceDuration: MediaTime,
        parameterHash: String
    ) throws -> SilenceMap {
        let n = features.count
        guard n > 0 else {
            throw VoxScriptaError.analysisFailed(stage: "silence detection", reason: "no analysis frames")
        }

        // ── Stage 1: noise floor ────────────────────────────────────────────
        let floor = try noiseFloorTracker.track(features)

        // ── Stage 2: adaptive dual thresholds with hysteresis ───────────────
        var isSpeech = [Bool](repeating: false, count: n)
        var inSpeech = false
        for i in 0..<n {
            let exit = Swift.max(floor[i] + parameters.marginDB, parameters.absoluteFloorDB)
            let enter = exit + parameters.hysteresisDB
            let level = features.rmsDB[i]

            if inSpeech {
                if level < exit {
                    // ── Stage 3: fricative protection ───────────────────────
                    // A frame below the exit level is still speech when it looks
                    // spectrally like sibilance. Without this the detector clips
                    // /s/, /f/, /ʃ/ and /θ/ and the transcript loses plurals.
                    let isFricative = parameters.fricativeProtection
                        && features.zeroCrossingRate[i] > fricativeZCRThreshold
                        && features.spectralFlatness[i] > fricativeFlatnessThreshold
                        && level > floor[i] + fricativeMarginDB
                    if !isFricative { inSpeech = false }
                }
            } else if level > enter {
                inSpeech = true
            }
            isSpeech[i] = inSpeech
        }

        // ── Stage 4: duration gating ────────────────────────────────────────
        // Order matters. Demoting short speech first removes clicks; promoting
        // short silence afterwards protects stop closures. Reversed, noise gets
        // merged into speech and never removed.
        let hop = features.geometry.hopDuration
        let minSpeechFrames = frames(parameters.minSpeechDuration, hop: hop)
        let minSilenceFrames = frames(parameters.minSilenceDuration, hop: hop)

        var runs = runLengths(of: isSpeech)
        for i in runs.indices where runs[i].value && runs[i].length < minSpeechFrames {
            runs[i].value = false
        }
        runs = coalesce(runs)
        for i in runs.indices where !runs[i].value && runs[i].length < minSilenceFrames {
            // Leading and trailing silence is real silence, never a closure.
            guard i > 0, i < runs.count - 1 else { continue }
            runs[i].value = true
        }
        runs = coalesce(runs)

        // ── Stage 5: asymmetric padding ─────────────────────────────────────
        let media = TimeRange(start: .zero, end: sourceDuration)
        var padded: [TimeRange] = []
        for run in runs where run.value {
            let range = TimeRange(
                start: features.geometry.time(ofFrame: run.start),
                end: Swift.min(features.geometry.time(ofFrame: run.start + run.length), sourceDuration)
            )
            guard !range.isEmpty else { continue }
            let expanded = range.padded(lead: parameters.padLead,
                                        trail: parameters.padTrail, within: media)
            if let last = padded.last, expanded.start <= last.end {
                padded[padded.count - 1] = TimeRange(start: last.start,
                                                     end: Swift.max(last.end, expanded.end))
            } else {
                padded.append(expanded)
            }
        }

        guard !padded.isEmpty else { throw VoxScriptaError.noSpeechDetected }

        // ── Assemble ────────────────────────────────────────────────────────
        let regions = padded.map { range in
            SpeechRegion(range: range,
                         meanEnergyDB: meanDB(features, range),
                         peakEnergyDB: peakDB(features, range))
        }
        var gaps: [SilenceGap] = []
        var cursor = MediaTime.zero
        for region in regions {
            if region.range.start > cursor {
                let range = TimeRange(start: cursor, end: region.range.start)
                gaps.append(SilenceGap(range: range, meanEnergyDB: meanDB(features, range)))
            }
            cursor = region.range.end
        }
        if cursor < sourceDuration {
            let range = TimeRange(start: cursor, end: sourceDuration)
            gaps.append(SilenceGap(range: range, meanEnergyDB: meanDB(features, range)))
        }

        return SilenceMap(
            speechRegions: regions,
            gaps: gaps,
            noiseFloorProfile: floor,
            parameters: parameters,
            parameterHash: parameterHash,
            sourceDuration: sourceDuration
        )
    }

    // MARK: - Helpers

    struct Run {
        var value: Bool
        var start: Int
        var length: Int
    }

    private func frames(_ duration: MediaTime, hop: MediaTime) -> Int {
        hop.nanoseconds > 0 ? Int(duration.nanoseconds / hop.nanoseconds) : 0
    }

    private func runLengths(of flags: [Bool]) -> [Run] {
        var runs: [Run] = []
        var start = 0
        for i in 1...flags.count {
            if i == flags.count || flags[i] != flags[start] {
                runs.append(Run(value: flags[start], start: start, length: i - start))
                start = i
            }
        }
        return runs
    }

    /// Merges neighbouring runs that now share a value after a gating pass.
    private func coalesce(_ runs: [Run]) -> [Run] {
        var out: [Run] = []
        for run in runs {
            if var last = out.last, last.value == run.value {
                last.length += run.length
                out[out.count - 1] = last
            } else {
                out.append(run)
            }
        }
        return out
    }

    private func frameRange(_ features: FrameFeatures, _ range: TimeRange) -> Range<Int> {
        let lo = Swift.max(0, features.geometry.frame(atTime: range.start))
        let hi = Swift.min(features.count, features.geometry.frame(atTime: range.end))
        return lo < hi ? lo..<hi : lo..<Swift.min(lo + 1, features.count)
    }

    private func meanDB(_ features: FrameFeatures, _ range: TimeRange) -> Float {
        let r = frameRange(features, range)
        guard !r.isEmpty else { return FrameAnalyzer.minimumDB }
        var sum: Float = 0
        for i in r { sum += features.rmsDB[i] }
        return sum / Float(r.count)
    }

    private func peakDB(_ features: FrameFeatures, _ range: TimeRange) -> Float {
        let r = frameRange(features, range)
        guard !r.isEmpty else { return FrameAnalyzer.minimumDB }
        var peak = FrameAnalyzer.minimumDB
        for i in r { peak = Swift.max(peak, features.rmsDB[i]) }
        return peak
    }
}
