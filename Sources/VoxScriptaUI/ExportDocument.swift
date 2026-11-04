import SwiftUI
import UniformTypeIdentifiers

/// A finished export, wrapped so SwiftUI's file exporter can write it.
///
/// `fileExporter` wants a `FileDocument` rather than bytes and a path, which
/// is the price of a save panel that works on both platforms. The exporters
/// already produce `Data`, so this carries it the few inches to the sheet and
/// does nothing else.
///
/// Reading is unreachable — nothing opens one of these — but the protocol
/// requires an initializer, so it is implemented honestly rather than with a
/// fatalError that could one day fire.
struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    var data: Data
    var contentType: UTType

    init(data: Data, contentType: UTType) {
        self.data = data
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
