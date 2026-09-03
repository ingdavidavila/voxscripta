import Testing
import Foundation
import VoxVerbaCore
@testable import VoxVerbaExport

@Suite("Export formats")
struct ExportFormatTests {

    @Test("All five documented formats are declared")
    func formats() {
        #expect(ExportFormat.allCases.count == 5)
        #expect(Set(ExportFormat.allCases.map(\.fileExtension))
            == ["txt", "md", "docx", "srt", "vtt"])
    }

    @Test("Only subtitle formats are timed")
    func timedFormats() {
        #expect(ExportFormat.subRip.isTimed)
        #expect(ExportFormat.webVTT.isTimed)
        #expect(!ExportFormat.plainText.isTimed)
        #expect(!ExportFormat.markdown.isTimed)
        #expect(!ExportFormat.docx.isTimed)
    }

    @Test("Every transcript variant is exportable independently")
    func variantsIndependent() {
        // §32: verbatim, clean and polished each export on their own.
        #expect(TranscriptVariant.allCases.count == 3)
        #expect(Set(TranscriptVariant.allCases) == [.verbatim, .clean, .polished])
    }

    @Test("Exporters announce their unimplemented state")
    func placeholders() {
        let t = Transcript(variant: .verbatim, segments: [], provenance: Provenance())
        #expect(throws: VoxVerbaError.self) {
            try PlainTextExporter().export(t, options: .default)
        }
        #expect(throws: VoxVerbaError.self) {
            try SubRipExporter().export(t, options: .default)
        }
    }
}
