import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif
import VoxScriptaCore

/// A passage of known text rendered to speech.
///
/// This is the other half of the corpus strategy. The signal synthesizer produces
/// audio with speech-like *acoustics* for testing the detector; this produces
/// audio with actual *words* for testing transcription. Both are generated, so
/// ground truth is exact and no human transcription or licensed recording is
/// involved.
public struct SpeechPassage: Sendable {
    public let name: String
    /// The exact words spoken, which is the reference for word error rate.
    public let text: String
    /// Seconds of silence inserted after this passage.
    public let trailingSilence: Double

    public init(name: String, text: String, trailingSilence: Double = 1.0) {
        self.name = name
        self.text = text
        self.trailingSilence = trailingSilence
    }
}

/// Renders passages to audio with `AVSpeechSynthesizer`, entirely offline.
public enum SpeechCorpus {

    /// Passages chosen to exercise what the polish validator must later protect:
    /// numbers, names, dates, negations and hedges.
    public static let standard: [SpeechPassage] = [
        SpeechPassage(
            name: "numbers",
            text: "We sold five hundred units in the third quarter, up from three hundred and twelve."),
        SpeechPassage(
            name: "names",
            text: "David met with Sarah Chen and the team from Northwind Trading on Tuesday."),
        SpeechPassage(
            name: "negation",
            text: "We did not approve the revised budget, and the committee has not scheduled a follow up."),
        SpeechPassage(
            name: "hedges",
            text: "It might be possible to finish by Friday, but I would probably plan for the following week."),
        SpeechPassage(
            name: "plain",
            text: "The quick brown fox jumps over the lazy dog near the river bank at sunrise."),
    ]

    /// The same five shapes in Spanish.
    ///
    /// Deliberately parallel to ``standard`` rather than a translation of it:
    /// each passage exercises the same thing its English counterpart does —
    /// numbers, names, negation, hedges, plain prose — so the two word error
    /// rates measure the same job in two languages and can be compared.
    ///
    /// Spanish-specific on purpose in two places. The names carry accents and
    /// a surname that is not a word, because the orthography check exists for
    /// exactly that; and the negation passage uses the double negative that
    /// Spanish requires, which is the shape the polarity count has to survive.
    public static let spanish: [SpeechPassage] = [
        SpeechPassage(
            name: "numbers",
            text: "Vendimos quinientas unidades en el tercer trimestre, "
                + "frente a trescientas doce del anterior."),
        SpeechPassage(
            name: "names",
            text: "David se reunió con Sara Chen y el equipo de Northwind "
                + "Trading el martes por la mañana."),
        SpeechPassage(
            name: "negation",
            text: "No aprobamos el presupuesto revisado, y el comité no ha "
                + "programado ninguna reunión de seguimiento."),
        SpeechPassage(
            name: "hedges",
            text: "Quizá sea posible terminar el viernes, pero yo "
                + "probablemente contaría con la semana siguiente."),
        SpeechPassage(
            name: "plain",
            text: "El análisis de los resultados muestra una mejora "
                + "significativa respecto al periodo anterior."),
    ]

    /// Ordinary prose with no proper nouns in it, for measuring acoustics.
    ///
    /// Added after the first full conditioned run, which produced a table that
    /// barely moved between conditions. The diagnosis was not that the engine
    /// is robust: "northwind" was lost in all eighteen rows, and "sara",
    /// "chen", "quizá" and "unidades" in all nine of their language's rows.
    /// Four constant errors on a seventy-word reference *is* the 5.6% English
    /// figure. The acoustic conditions were moving one or two other words,
    /// which rounds back to the same rate.
    ///
    /// So ``standard`` measures the wrong thing for this job. It was built to
    /// exercise what the polish validator protects — names, numbers, dates,
    /// negations — and names are the hardest case in every recogniser, so it
    /// has a high fixed floor that hides everything else.
    ///
    /// These passages are the complement: common vocabulary only, no names, no
    /// places, no coined words, and roughly twice the length, so an error is a
    /// smaller share of the rate and what moves is attributable to hearing
    /// rather than to spelling a name. Both sets are kept, because they answer
    /// different questions and neither answers the other's.
    public static let acoustic: [SpeechPassage] = [
        SpeechPassage(
            name: "weather",
            text: "The weather turned cold before the end of the week and the "
                + "roads were covered in a thin layer of ice."),
        SpeechPassage(
            name: "window",
            text: "She opened the window to let the warm air out and heard the "
                + "sound of children playing in the street below."),
        SpeechPassage(
            name: "boxes",
            text: "Most of the boxes were empty, but the one at the bottom held "
                + "a stack of old letters tied with string."),
        SpeechPassage(
            name: "train",
            text: "If the train leaves on time we should arrive before dark, "
                + "though the last part of the journey is slow."),
        SpeechPassage(
            name: "report",
            text: "He asked whether the report had been finished, and she said "
                + "it would be ready by the middle of the afternoon."),
        SpeechPassage(
            name: "bread",
            text: "The bread had gone stale, so they fed what was left of it to "
                + "the birds along the edge of the pond."),
        SpeechPassage(
            name: "chairs",
            text: "There were seven chairs around the table and not one of them "
                + "matched any of the others."),
        SpeechPassage(
            name: "lock",
            text: "Nothing about the arrangement seemed unusual until somebody "
                + "noticed the lock had been changed."),
    ]

    /// The Spanish counterpart, written rather than translated.
    ///
    /// Written to the same constraints — common words, no names — instead of
    /// translated from the English, because a translation inherits the English
    /// sentence rhythm and measures the synthesizer reading foreign-shaped
    /// Spanish. The two sets are comparable in what they contain, not in
    /// wording.
    public static let acousticSpanish: [SpeechPassage] = [
        SpeechPassage(
            name: "weather",
            text: "El tiempo cambió antes del final de la semana y los caminos "
                + "quedaron cubiertos de una fina capa de hielo."),
        SpeechPassage(
            name: "window",
            text: "Abrió la ventana para dejar salir el aire caliente y escuchó "
                + "a los niños que jugaban en la calle de abajo."),
        SpeechPassage(
            name: "boxes",
            text: "Casi todas las cajas estaban vacías, pero la del fondo "
                + "guardaba un montón de cartas viejas atadas con un cordel."),
        SpeechPassage(
            name: "train",
            text: "Si el tren sale a tiempo deberíamos llegar antes de que "
                + "oscurezca, aunque el último tramo del camino es lento."),
        SpeechPassage(
            name: "report",
            text: "Preguntó si el informe ya estaba terminado, y ella dijo que "
                + "estaría listo a media tarde."),
        SpeechPassage(
            name: "bread",
            text: "El pan se había puesto duro, así que dieron lo que quedaba a "
                + "los pájaros junto a la orilla del estanque."),
        SpeechPassage(
            name: "chairs",
            text: "Había siete sillas alrededor de la mesa y ninguna de ellas "
                + "hacía juego con las demás."),
        SpeechPassage(
            name: "lock",
            text: "Nada en el arreglo parecía extraño hasta que alguien notó "
                + "que habían cambiado la cerradura."),
    ]

    /// Passages containing real disfluencies, for exercising the CLEAN pass.
    ///
    /// The fillers are spoken, not inserted afterwards, so the engine has to
    /// transcribe them and CLEAN has to remove them from genuine output — which
    /// is a materially different test from feeding it a hand-built transcript.
    public static let disfluent: [SpeechPassage] = [
        SpeechPassage(
            name: "fillers",
            text: "Uh, so I think we should, um, start on Monday if that works."),
        SpeechPassage(
            name: "stutter",
            text: "I, I wanted to ask about the, the budget for next quarter."),
        SpeechPassage(
            name: "mixed",
            text: "Um, we did not approve it, uh, because the numbers were wrong."),
        SpeechPassage(
            name: "affirmation",
            text: "Uh-huh, that is right, and we sold five hundred units."),
    ]

    /// The reference transcript for a set of passages, joined as spoken.
    public static func referenceText(for passages: [SpeechPassage]) -> String {
        passages.map(\.text).joined(separator: " ")
    }

}

// Rendering, which needs a speech synthesizer, and so exists only where
// AVFoundation does. The passages above are plain data and stay available
// everywhere: a Linux run can still read the reference text, it just cannot
// produce the audio. Docs/PARITY.md records what that leaves uncovered.
#if canImport(AVFoundation)
extension SpeechCorpus {
    /// Renders passages to canonical-rate mono float samples.
    ///
    /// - Note: Voice availability differs between machines, so the audio is not
    ///   bit-reproducible across hosts the way the signal corpus is. Word error
    ///   rate against the known text remains exact regardless.
    /// - Parameter language: the BCP-47 tag whose default voice to speak in.
    ///   It used to be hardcoded to en-US inside the renderer, which meant
    ///   Spanish passages were read aloud by an English voice — audio that
    ///   measures the wrong thing entirely.
    public static func render(
        _ passages: [SpeechPassage],
        voiceIdentifier: String? = nil,
        rate: Float = 0.45,
        language: String = "en-US"
    ) async throws -> [Float] {
        var out: [Float] = []
        for passage in passages {
            out += try await renderOne(passage.text, voiceIdentifier: voiceIdentifier,
                                       rate: rate, language: language)
            let silence = Int(passage.trailingSilence * Double(CanonicalFormat.sampleRate))
            out += [Float](repeating: 0, count: silence)
        }
        return out
    }

    private static func renderOne(
        _ text: String,
        voiceIdentifier: String?,
        rate: Float,
        language: String = "en-US"
    ) async throws -> [Float] {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        if let voiceIdentifier, let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        } else if let voice = AVSpeechSynthesisVoice(language: language) {
            utterance.voice = voice
        }

        let collector = BufferCollector()
        let synthesizer = AVSpeechSynthesizer()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumed = ResumeGuard(continuation)
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                // A zero-length buffer is the synthesizer's end-of-stream signal.
                if pcm.frameLength == 0 {
                    resumed.resumeOnce()
                    return
                }
                collector.append(pcm)
            }
        }

        let raw = collector.samples()
        guard let format = collector.format else {
            throw VoxScriptaError.decodingFailed(reason: "the synthesizer produced no audio")
        }
        return try resample(raw, from: format.sampleRate, to: Double(CanonicalFormat.sampleRate))
    }

    /// Linear resampling to the canonical rate.
    ///
    /// Adequate here because the result is re-encoded to a real audio file and
    /// decoded through `CanonicalDecoder` before any measurement happens.
    private static func resample(_ input: [Float], from source: Double, to target: Double) throws -> [Float] {
        guard source > 0 else {
            throw VoxScriptaError.decodingFailed(reason: "the synthesizer reported a zero sample rate")
        }
        if abs(source - target) < 1 { return input }
        let ratio = source / target
        let count = Int(Double(input.count) / ratio)
        guard count > 0 else { return [] }

        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let position = Double(i) * ratio
            let low = Int(position)
            let high = Swift.min(low + 1, input.count - 1)
            let fraction = Float(position - Double(low))
            out[i] = input[low] * (1 - fraction) + input[high] * fraction
        }
        return out
    }
}


/// Accumulates synthesizer output across callbacks.
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Float] = []
    private var captured: AVAudioFormat?

    var format: AVAudioFormat? { lock.lock(); defer { lock.unlock() }; return captured }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        captured = buffer.format
        let n = Int(buffer.frameLength)
        if let floats = buffer.floatChannelData?[0] {
            storage.append(contentsOf: UnsafeBufferPointer(start: floats, count: n))
        } else if let ints = buffer.int16ChannelData?[0] {
            storage.append(contentsOf: UnsafeBufferPointer(start: ints, count: n)
                .map { Float($0) / 32768 })
        }
    }

    func samples() -> [Float] { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Ensures a continuation resumes exactly once, whatever the callback does.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func resumeOnce() {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}

#endif
