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

    /// Phase 1's acceptance target: decode, analyze, detect silence, plan chunks.
    static func runAnalyze(_ args: [String]) async throws {
        let opts = Options(args)
        guard let path = opts.positional.first else {
            throw VoxVerbaError.ioFailure(path: "<none>", reason: "no input file given")
        }
        let url = URL(filePath: path)

        let params = SilenceParameters.default
        let chunkParams = ChunkParameters.default

        let decoder = CanonicalDecoder()
        let format = try await decoder.probe(url: url)

        // Phase 1 fills in the rest of this pipeline; `probe` throws until then.
        _ = format
        _ = params
        _ = chunkParams
        _ = opts.flag("json")
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
