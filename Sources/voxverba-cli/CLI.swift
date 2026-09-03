import Foundation
import VoxVerbaCore
import VoxVerbaDSP
import VoxVerbaTranscription
import VoxVerbaLanguage
import VoxVerbaProject
import VoxVerbaExport
import VoxVerbaBench

/// Headless driver for the pipeline.
///
/// This exists so every stage can be exercised, tested and benchmarked without the
/// app — which is what makes the crash-recovery suite possible (Phase 3 drives
/// `SIGKILL` at each state through this binary) and keeps the benchmark harness
/// free of UI timing noise.
///
/// Argument parsing is hand-rolled rather than pulled from a package, so the whole
/// scaffold builds offline with no dependency resolution. If the surface grows past
/// a handful of flags, swift-argument-parser is the natural replacement.
@main
struct CLI {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(EXIT_FAILURE)
        }
        args.removeFirst()

        do {
            switch command {
            case "analyze":   try await runAnalyze(args)
            case "transcribe": try await runTranscribe(args)
            case "bench":     try await runBench(args)
            case "wer":       try runWER(args)
            case "version", "--version", "-v":
                print("voxverba \(VoxVerba.version)")
            case "help", "--help", "-h":
                printUsage()
            default:
                FileHandle.standardError.write(Data("Unknown command: \(command)\n\n".utf8))
                printUsage()
                exit(EXIT_FAILURE)
            }
        } catch let error as VoxVerbaError {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        } catch {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    // MARK: - Commands

    /// Decode, analyse, detect silence, and emit a chunk plan.
    static func runAnalyze(_ args: [String]) async throws {
        let opts = Options(args)
        guard let path = opts.positional.first else {
            throw VoxVerbaError.ioFailure(path: "<none>", reason: "no input file given")
        }
        let url = URL(filePath: path)
        let json = opts.flag("json")

        var parameters = SilenceParameters.default
        if let v = opts.value("silence-threshold").flatMap(Float.init) { parameters.marginDB = v }
        if let v = opts.value("min-silence").flatMap(Double.init) {
            parameters.minSilenceDuration = .seconds(v)
        }
        if let v = opts.value("pad-lead").flatMap(Double.init) { parameters.padLead = .seconds(v) }
        if let v = opts.value("pad-trail").flatMap(Double.init) { parameters.padTrail = .seconds(v) }

        var chunkParameters = ChunkParameters.default
        if let v = opts.value("chunk-max").flatMap(Double.init) {
            chunkParameters.maxDuration = .seconds(v)
            chunkParameters.targetDuration = .seconds(v * 0.8)
            chunkParameters.minDuration = .seconds(v * 0.4)
        }

        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "voxverba-analyze-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let canonical = scratch.appending(path: "canonical.f32")

        let decoder = CanonicalDecoder()
        let format = try await decoder.probe(url: url)
        let clock = ContinuousClock()

        if !json { log("Analyzing \(url.lastPathComponent)…") }

        let decodeTime = try await clock.measure {
            _ = try await decoder.decode(url: url, to: canonical) { p in
                if !json { progressBar("Decoding", p) }
            }
        }
        if !json { endProgress() }

        var features: FrameFeatures!
        let analyzeTime = try await clock.measure {
            features = try await FrameAnalyzer().analyze(canonicalFile: canonical, geometry: .default) { p in
                if !json { progressBar("Measuring", p) }
            }
        }
        if !json { endProgress() }

        let hash = "\(parameters.hashValue)"
        let duration = features.duration

        var map: SilenceMap!
        let silenceTime = try clock.measure {
            map = try SilenceDetector().detect(
                features: features, parameters: parameters,
                sourceDuration: duration, parameterHash: hash)
        }

        var plan: ChunkPlan!
        let planTime = try clock.measure {
            plan = try ChunkPlanner().plan(
                silenceMap: map, parameters: chunkParameters, parameterHash: hash)
        }

        let footprint = (try? MemoryFootprint.current()) ?? 0

        if json {
            try emitJSON(url: url, format: format, map: map, plan: plan, footprint: footprint)
        } else {
            report(url: url, format: format, map: map, plan: plan, footprint: footprint,
                   timings: [("decode", decodeTime), ("measure", analyzeTime),
                             ("silence", silenceTime), ("plan", planTime)])
        }
    }

    // MARK: - Output

    private static func emitJSON(
        url: URL, format: AudioFormatDescription,
        map: SilenceMap, plan: ChunkPlan, footprint: Int64
    ) throws {
        struct Output: Encodable {
            struct Region: Encodable { let start: Double; let end: Double; let meanDB: Float }
            struct Chunk: Encodable {
                let sequence: Int
                let originalStart: Double
                let originalEnd: Double
                let processedStart: Double
                let processedEnd: Double
                let boundary: String
                let overlapLead: Double
            }
            let file: String
            let sourceSampleRate: Double
            let sourceChannels: Int
            let duration: Double
            let speechDuration: Double
            let speechFraction: Double
            let speechRegions: [Region]
            let chunks: [Chunk]
            let hardCuts: Int
            let peakFootprintBytes: Int64
        }

        let out = Output(
            file: url.lastPathComponent,
            sourceSampleRate: format.sampleRate,
            sourceChannels: format.channelCount,
            duration: map.sourceDuration.seconds,
            speechDuration: map.speechDuration.seconds,
            speechFraction: map.speechFraction,
            speechRegions: map.speechRegions.map {
                .init(start: $0.range.start.seconds, end: $0.range.end.seconds,
                      meanDB: $0.meanEnergyDB)
            },
            chunks: plan.chunks.map {
                .init(sequence: $0.sequence,
                      originalStart: $0.originalRange.start.seconds,
                      originalEnd: $0.originalRange.end.seconds,
                      processedStart: $0.processedRange.start.seconds,
                      processedEnd: $0.processedRange.end.seconds,
                      boundary: boundaryLabel($0.boundaryKind),
                      overlapLead: $0.overlapLead.seconds)
            },
            hardCuts: plan.hardCutCount,
            peakFootprintBytes: footprint
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(out), as: UTF8.self))
    }

    private static func report(
        url: URL, format: AudioFormatDescription,
        map: SilenceMap, plan: ChunkPlan, footprint: Int64,
        timings: [(String, Duration)]
    ) {
        let pct = Int((map.speechFraction * 100).rounded())
        print("""

        \(url.lastPathComponent)
          source      \(Int(format.sampleRate)) Hz, \(format.channelCount == 1 ? "mono" : "\(format.channelCount) ch")
          duration    \(map.sourceDuration)
          speech      \(map.speechDuration)  (\(pct)% of the recording)
          regions     \(map.speechRegions.count)
          chunks      \(plan.count)  (\(plan.hardCutCount) hard cut\(plan.hardCutCount == 1 ? "" : "s"))
          footprint   \(footprint / (1 << 20)) MB
        """)

        print("\n  chunks")
        for chunk in plan.chunks.prefix(20) {
            let kind = boundaryLabel(chunk.boundaryKind)
            let overlap = chunk.overlapLead > .zero
                ? "  +\(String(format: "%.1f", chunk.overlapLead.seconds))s overlap" : ""
            print(String(format: "    %3d  %@ → %@   %@%@",
                         chunk.sequence, "\(chunk.originalRange.start)",
                         "\(chunk.originalRange.end)", kind, overlap))
        }
        if plan.count > 20 { print("    … \(plan.count - 20) more") }

        print("\n  timings")
        for (name, d) in timings {
            print(String(format: "    %-10@ %.3fs", name as NSString, d.elapsedSeconds))
        }
        print("")
    }

    /// One label for a boundary, shared by the JSON and human output paths.
    private static func boundaryLabel(_ kind: BoundaryKind) -> String {
        switch kind {
        case .silence(let gap): "silence \(String(format: "%.2f", gap.seconds))s"
        case .hardCut: "hard cut"
        case .endOfMedia: "end of media"
        }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func progressBar(_ label: String, _ fraction: Double) {
        let width = 24
        let filled = Int(fraction * Double(width))
        let bar = String(repeating: "█", count: filled)
            + String(repeating: "░", count: width - filled)
        let line = String(format: "\r  %@ %@ %3d%%", label as NSString, bar as NSString,
                          Int(fraction * 100))
        FileHandle.standardError.write(Data(line.utf8))
    }

    private static func endProgress() {
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
    }

    /// The whole pipeline, ending in one merged transcript.
    static func runTranscribe(_ args: [String]) async throws {
        let opts = Options(args)
        guard let path = opts.positional.first else {
            throw VoxVerbaError.ioFailure(path: "<none>", reason: "no input file given")
        }
        let result = try await runPipeline(url: URL(filePath: path), opts: opts, quiet: opts.flag("json"))

        if let output = opts.value("out") {
            try result.transcript.plainText().write(to: URL(filePath: output),
                                                    atomically: true, encoding: .utf8)
            log("Wrote \(output)")
        } else {
            print(result.transcript.plainText())
        }

        if !opts.flag("json") {
            let gaps = result.transcript.segments.filter { $0.warnings.contains(.transcriptionGap) }
            log("")
            log("  segments   \(result.transcript.segments.count)")
            log("  words      \(result.transcript.wordCount)")
            if !gaps.isEmpty { log("  gaps       \(gaps.count) chunk(s) could not be transcribed") }
            log("  total      \(String(format: "%.1fs", result.totalSeconds))")
        }
    }

    /// Runs the pipeline repeatedly across concurrency settings and reports timings.
    static func runBench(_ args: [String]) async throws {
        let opts = Options(args)
        guard let path = opts.positional.first else {
            throw VoxVerbaError.ioFailure(path: "<none>", reason: "no input file given")
        }
        let url = URL(filePath: path)

        let levels = (opts.value("concurrency") ?? "1,2,4")
            .split(separator: ",").compactMap { Int($0) }
        var reports: [BenchmarkReport] = []

        for level in levels {
            log("── concurrency \(level) ─────────────────────────────")
            var o = opts
            o.set("concurrency", String(level))
            let result = try await runPipeline(url: url, opts: o, quiet: true)

            let stages = result.timings.map { name, seconds in
                StageMeasurement(
                    stage: name, wallTime: seconds, peakFootprint: result.peakFootprint,
                    realTimeFactor: seconds > 0 ? result.duration.seconds / seconds : nil)
            }
            let report = BenchmarkReport(
                sourceDuration: result.duration,
                sourceByteSize: result.sourceBytes,
                engineID: .appleSpeech, modelID: nil, concurrency: level,
                stages: stages, totalWallTime: result.totalSeconds,
                peakFootprint: result.peakFootprint, hardware: hardwareName())
            reports.append(report)

            let rtf = result.totalSeconds > 0 ? result.duration.seconds / result.totalSeconds : 0
            log(String(format: "   total %.1fs   %.1f× real time   peak %d MB",
                       result.totalSeconds, rtf, result.peakFootprint / (1 << 20)))
            for (name, seconds) in result.timings {
                log(String(format: "     %-12@ %7.2fs", name as NSString, seconds))
            }
        }

        if opts.flag("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(reports), as: UTF8.self))
        } else if reports.count > 1 {
            log("")
            log("  fastest: concurrency \(reports.min { $0.totalWallTime < $1.totalWallTime }.map(\.concurrency) ?? 1)")
        }
    }

    /// Compares a transcript against a known reference.
    static func runWER(_ args: [String]) throws {
        let opts = Options(args)
        guard opts.positional.count == 2 else {
            throw VoxVerbaError.ioFailure(
                path: "<args>", reason: "usage: voxverba-cli wer <reference.txt> <hypothesis.txt>")
        }
        let reference = try String(contentsOf: URL(filePath: opts.positional[0]), encoding: .utf8)
        let hypothesis = try String(contentsOf: URL(filePath: opts.positional[1]), encoding: .utf8)
        let result = WordErrorRate.measure(reference: reference, hypothesis: hypothesis)

        if opts.flag("json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(result), as: UTF8.self))
        } else {
            print(result.description)
            print(String(format: "  accuracy %.2f%%", result.accuracy * 100))
        }
    }

    // MARK: - Pipeline

    struct PipelineResult {
        let transcript: Transcript
        let duration: MediaTime
        let sourceBytes: Int64
        let timings: [(String, TimeInterval)]
        let totalSeconds: TimeInterval
        let peakFootprint: Int64
        let outcome: SchedulerOutcome
    }

    static func runPipeline(url: URL, opts: Options, quiet: Bool) async throws -> PipelineResult {
        // Everything the sampling closure touches is immutable, so the whole
        // pipeline can run inside a @Sendable footprint sampler.
        let silence: SilenceParameters = {
            var p = SilenceParameters.default
            if let v = opts.value("silence-threshold").flatMap(Float.init) { p.marginDB = v }
            if let v = opts.value("min-silence").flatMap(Double.init) { p.minSilenceDuration = .seconds(v) }
            return p
        }()
        let chunking: ChunkParameters = {
            var p = ChunkParameters.default
            if let v = opts.value("chunk-max").flatMap(Double.init) {
                p.maxDuration = .seconds(v)
                p.targetDuration = .seconds(v * 0.8)
                p.minDuration = .seconds(v * 0.4)
            }
            return p
        }()
        let options: TranscriptionOptions = {
            var o = TranscriptionOptions.default
            if let v = opts.value("concurrency").flatMap(Int.init) { o.concurrency = v }
            if let v = opts.value("locale") { o.locale = v }
            return o
        }()

        let scratch = URL(filePath: NSTemporaryDirectory())
            .appending(path: "voxverba-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let canonical = scratch.appending(path: "canonical.f32")

        let sourceBytes = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let overallStart = ContinuousClock.now

        let (stages, peak) = try await MemoryFootprint.peak {
            try await Self.execute(url: url, canonical: canonical, silence: silence,
                                   chunking: chunking, options: options, quiet: quiet)
        }

        return PipelineResult(
            transcript: stages.transcript, duration: stages.duration, sourceBytes: sourceBytes,
            timings: stages.timings,
            totalSeconds: (ContinuousClock.now - overallStart).elapsedSeconds,
            peakFootprint: peak, outcome: stages.outcome)
    }

    /// One full pass, returning everything the caller needs to report.
    struct PipelineStages: Sendable {
        let transcript: Transcript
        let duration: MediaTime
        let timings: [(String, TimeInterval)]
        let outcome: SchedulerOutcome
    }

    static func execute(
        url: URL, canonical: URL,
        silence: SilenceParameters, chunking: ChunkParameters,
        options: TranscriptionOptions, quiet: Bool
    ) async throws -> PipelineStages {
        let clock = ContinuousClock()

        var samples: Int64 = 0
        let decodeTime = try await clock.measure {
            samples = try await CanonicalDecoder().decode(url: url, to: canonical) { p in
                if !quiet { progressBar("Decoding", p) }
            }
        }
        if !quiet { endProgress() }

        var features: FrameFeatures?
        let analyzeTime = try await clock.measure {
            features = try await FrameAnalyzer().analyze(
                canonicalFile: canonical, geometry: .default) { p in
                if !quiet { progressBar("Measuring", p) }
            }
        }
        if !quiet { endProgress() }
        guard let features else {
            throw VoxVerbaError.analysisFailed(stage: "frame analysis", reason: "no features produced")
        }

        let duration = MediaTime(samples: samples, sampleRate: CanonicalFormat.sampleRate)
        let hash = "\(silence.hashValue)"

        var map: SilenceMap?
        let silenceTime = try clock.measure {
            map = try SilenceDetector().detect(features: features, parameters: silence,
                                               sourceDuration: duration, parameterHash: hash)
        }
        guard let map else { throw VoxVerbaError.noSpeechDetected }

        var plan: ChunkPlan?
        let planTime = try clock.measure {
            plan = try ChunkPlanner().plan(silenceMap: map, parameters: chunking, parameterHash: hash)
        }
        guard let plan else { throw VoxVerbaError.noSpeechDetected }

        let engine = AppleSpeechEngine()
        let prepareTime = try await clock.measure {
            try await engine.prepare(locale: options.locale)
        }

        var outcome: SchedulerOutcome?
        let total = plan.count
        let transcribeTime = try await clock.measure {
            outcome = try await ChunkScheduler().run(
                plan: plan, canonicalFile: canonical, engine: engine, options: options,
                progress: { done, _ in
                    if !quiet { progressBar("Transcribing", Double(done) / Double(total)) }
                })
        }
        if !quiet { endProgress() }
        await engine.release()
        guard let outcome else {
            throw VoxVerbaError.analysisFailed(stage: "transcription", reason: "no results")
        }

        var merged: Transcript?
        let mergeTime = try clock.measure {
            merged = try TranscriptMerger().merge(
                chunks: outcome.transcripts, plan: plan, silenceMap: map,
                provenance: Provenance(engineID: engine.identifier,
                                       silenceParameterHash: hash, chunkParameterHash: hash,
                                       concurrency: options.concurrency))
        }
        guard let merged else {
            throw VoxVerbaError.analysisFailed(stage: "transcript merge", reason: "no transcript")
        }

        return PipelineStages(
            transcript: merged, duration: duration,
            timings: [("decode", decodeTime.elapsedSeconds), ("measure", analyzeTime.elapsedSeconds),
                      ("silence", silenceTime.elapsedSeconds), ("plan", planTime.elapsedSeconds),
                      ("prepare", prepareTime.elapsedSeconds),
                      ("transcribe", transcribeTime.elapsedSeconds),
                      ("merge", mergeTime.elapsedSeconds)],
            outcome: outcome)
    }

    static func hardwareName() -> String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    // MARK: - Usage

    static func printUsage() {
        print("""
        voxverba \(VoxVerba.version) — local-first transcription

        USAGE
          voxverba-cli <command> [options] <file>

        COMMANDS
          analyze      Decode, analyze, detect silence, and emit a chunk plan
          transcribe   Run the full pipeline to a merged transcript
          bench        Run the pipeline and emit a JSON measurement report
          wer          Compare a transcript against a known reference
          version      Print the version
          help         Print this message

        OPTIONS
          --json                 Emit machine-readable output
          --silence-threshold <dB>  Margin above the noise floor, default 8
          --min-silence <s>      Shortest gap treated as a pause, default 0.5
          --pad-lead <s>         Padding before speech, default 0.2
          --pad-trail <s>        Padding after speech, default 0.35
          --chunk-max <s>        Maximum chunk duration, default 300
          --concurrency <n>      Chunks in flight; bench accepts a list, e.g. 1,2,4
          --out <path>           Write the transcript to a file
          --engine <id>          apple (default) | whisperkit
          --locale <bcp47>       Transcription locale, default en-US
          --concurrency <n>      Chunks in flight, default 1

        Nothing this tool does requires a network connection.
        """)
    }
}

/// Minimal `--key value` / `--flag` parser.
struct Options {
    private(set) var values: [String: String] = [:]
    private(set) var flags: Set<String> = []
    private(set) var positional: [String] = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    values[key] = args[i + 1]
                    i += 2
                } else {
                    flags.insert(key)
                    i += 1
                }
            } else {
                positional.append(a)
                i += 1
            }
        }
    }

    mutating func set(_ key: String, _ value: String) { values[key] = value }

    func value(_ key: String) -> String? { values[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}
