import Foundation
import VoxScriptaCore

/// The frozen instructions given to the model.
///
/// Versioned and recorded in `Provenance`. Changing the wording changes the
/// output, so a transcript has to say which prompt produced it — otherwise two
/// runs of "the same" pipeline are not comparable.
public enum PolishPrompt {
    /// The English prompt's version, and the stored default.
    public static let version = "polish-v1"

    /// Each language has its own prompt and therefore its own version.
    ///
    /// English keeps "polish-v1" rather than being renamed: the version is part
    /// of the content hash, so changing it would re-run POLISH on every
    /// existing project to produce identical output.
    public static func version(for language: TranscriptLanguage) -> String {
        switch language {
        case .english: version
        case .spanish: "polish-es-v1"
        }
    }

    public static func instructions(for language: TranscriptLanguage) -> String {
        switch language {
        case .english: instructions
        case .spanish: spanishInstructions
        }
    }

    /// The Spanish instructions, written in Spanish.
    ///
    /// Not a translation of the English prompt. Asking in English and expecting
    /// Spanish back invites the model to drift into English on a difficult
    /// sentence, and the prohibitions that matter are not the same ones.
    ///
    /// Four of these exist only because the language does. Spanish negates
    /// twice — "no vimos nada" is one negation — and a model tidying what looks
    /// like a double negative silently reverses the meaning; that is the single
    /// most dangerous edit available here, and the semantic check cannot catch
    /// it in Spanish. Register is carried by tú and usted, so switching them
    /// rewrites the speaker's relationship with the listener. The subjunctive
    /// carries doubt the indicative does not, which makes a mood change a
    /// modality change. And Spanish vocabulary is strongly regional — coche and
    /// carro, ordenador and computadora — so normalising to one dialect is the
    /// synonym prohibition wearing a different hat, and worth naming outright.
    static let spanishInstructions = """
        Reescribes frases de una transcripción hablada para que se lean bien por         escrito.

        Corrige la gramática, la estructura de la frase, la puntuación y la         claridad.

        Conserva las palabras del hablante. No sustituyas una palabra por un         sinónimo: si dijo «mal», no escribas «incorrecto»; si dijo «aprobar», no         escribas «ratificar». Estás ordenando cómo está construida la frase, no         eligiendo mejor vocabulario que el hablante.

        Nunca debes:
        - cambiar, redondear ni reformatear ninguna cifra, cantidad, fecha o importe
        - cambiar, añadir ni quitar ningún nombre de persona, lugar, empresa o producto
        - añadir ni quitar una negación; «no lo aprobamos» nunca puede convertirse         en «lo aprobamos»
        - deshacer una doble negación; «no vimos nada» niega una sola vez y debe         quedarse tal cual
        - quitar una atenuación; «quizá», «probablemente», «más o menos» y         «parece» tienen que sobrevivir
        - cambiar el modo verbal; el subjuntivo expresa una duda que el         indicativo no expresa
        - cambiar el tratamiento entre tú y usted, ni el registro del hablante
        - sustituir el vocabulario regional por el de otra variedad del español;         «coche» no es «carro», «ordenador» no es «computadora»
        - añadir ningún hecho, detalle, ejemplo o explicación que no esté ya presente
        - quitar información, resumir ni acortar el significado
        - unir dos frases en una, ni dividir una en dos
        - cambiar una opinión, un juicio ni la rotundidad con que se afirma algo

        Devuelve exactamente tantas frases como recibiste, en el mismo orden.
        Si una frase ya se lee bien, devuélvela sin cambios.
        Responde siempre en español.
        """

    /// The standing instructions for every window.
    ///
    /// Written as prohibitions rather than goals. "Improve readability" invites
    /// the model to demonstrate improvement, which is how numbers get rounded and
    /// hedges get tidied away; an explicit list of things it must not touch
    /// measurably reduces the rejection rate.
    public static let instructions = """
        You rewrite spoken transcript sentences so they read well in print.

        Rewrite for grammar, sentence structure, punctuation and clarity.

        Keep the speaker's own words. Do not replace a word with a synonym: if
        they said "wrong", do not write "inaccurate"; if they said "approve", do
        not write "endorse". You are tidying how the sentence is built, not
        choosing better vocabulary than the speaker did.

        You must never:
        - change, round, or reformat any number, quantity, date, or amount
        - change, add, or remove any person, place, company, or product name
        - add or remove a negation; "did not approve" must never become "approved"
        - remove a hedge; "might", "probably", "roughly" and "seems" must survive
        - add any fact, detail, example, or explanation that is not already present
        - remove information, summarize, or shorten the meaning
        - merge two sentences into one, or split one into two
        - change an opinion, judgement, or how strongly something is claimed
        - substitute a synonym for a word the speaker actually used

        Return exactly as many sentences as you were given, in the same order.
        If a sentence already reads well, return it unchanged.
        """

    /// A stricter retry after a window has failed validation.
    ///
    /// Names the specific violations, because a generic "try harder" produces the
    /// same output. Reminding the model what it broke is what makes the retry
    /// worth doing at all.
    public static func retryInstructions(violations: [String],
                                         language: TranscriptLanguage = .english) -> String {
        let listed = violations.map { "- \($0)" }.joined(separator: "\n")
        switch language {
        case .english:
            return """
            \(instructions)

            Your previous attempt was rejected for these reasons:
            \(listed)

            Fix only those problems. Stay as close to the original wording as you can.
            When in doubt, return the sentence unchanged.
            """
        case .spanish:
            return """
            \(spanishInstructions)

            Tu intento anterior se rechazó por estos motivos:
            \(listed)

            Corrige solo esos problemas. Mantente lo más cerca posible de la
            redacción original. Ante la duda, devuelve la frase sin cambios.
            """
        }
    }
}
