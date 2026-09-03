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
            print(String(format: "    %-10@ %.3fs", name as NSString, Double(d.components.seconds)
                         + Double(d.components.attoseconds) / 1e18))
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

    static func runTranscribe(_ args: [String]) async throws {
        let opts = Options(args)
        let engine: any TranscriptionEngine =
            opts.value("engine") == "whisperkit" ? WhisperKitEngine() : AppleSpeechEngine()
        try await engine.prepare(locale: opts.value("locale") ?? "en-US")
    }

    static func runBench(_ args: [String]) async throws {
        _ = Options(args)
        _ = try MemoryFootprint.current()
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
          version      Print the version
          help         Print this message

        OPTIONS
          --json                 Emit machine-readable output
          --silence-threshold <dB>  Margin above the noise floor, default 8
          --min-silence <s>      Shortest gap treated as a pause, default 0.5
          --pad-lead <s>         Padding before speech, default 0.2
          --pad-trail <s>        Padding after speech, default 0.35
          --chunk-max <s>        Maximum chunk duration, default 300
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

    func value(_ key: String) -> String? { values[key] }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}
