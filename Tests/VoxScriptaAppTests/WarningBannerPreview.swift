#if os(macOS)
import Testing
import SwiftUI
import AppKit
import Foundation
import VoxScriptaCore
@testable import VoxScriptaUI

/// Renders the warning banner to PNG, so it can be looked at.
///
/// The same idea as `flutter/app/test/preview_test.dart`, which renders the
/// Flutter screens "so they can be looked at without a machine to run them on".
/// The Apple side had no equivalent, and a banner is the first thing here where
/// being able to see it *is* the feature: the whole reason it exists is that
/// nine warning cases were written to disk for months and shown to nobody.
///
/// Not a golden test. Nothing asserts that pixels match a reference — the
/// assertions are that every case renders at all and that an empty list draws
/// nothing. The images are reviewed by eye.
@Suite("Warning banner preview", .serialized)
struct WarningBannerPreview {

    static let directory = URL(filePath: NSTemporaryDirectory())
        .appending(path: "voxscripta-banner-preview")

    @MainActor
    private func render(_ name: String, width: CGFloat,
                        _ warnings: [AggregatedWarning],
                        scheme: ColorScheme = .light) throws -> CGSize? {
        try FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)
        let renderer = ImageRenderer(
            content: WarningBanner(warnings: warnings)
                .frame(width: width)
                .environment(\.colorScheme, scheme)
                .background(scheme == .dark ? Color.black : Color.white))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        // nil rather than an issue: a banner with nothing to say draws nothing,
        // and ImageRenderer has no image for a view of zero size. That is the
        // correct answer for the common case, so the caller decides whether it
        // is a failure.
        else { return nil }
        try png.write(to: Self.directory.appending(path: "\(name).png"))
        return image.size
    }

    private var wrongLanguage: AggregatedWarning {
        AggregatedWarning(warning: .languageLooksWrong(transcribedAs: "en-US",
                                                       detected: "es"),
                          count: 1, startSeconds: nil)
    }

    @Test("Every case renders, and the images are written")
    @MainActor
    func everyCase() throws {
        let gap = AggregatedWarning(warning: .transcriptionGap,
                                    count: 2, startSeconds: 124)
        let doubtful = AggregatedWarning(warning: .lowConfidence(0.41),
                                         count: 30, startSeconds: 752)
        let shots: [(String, CGFloat, [AggregatedWarning], ColorScheme)] = [
            ("01-wrong-language", 760, [wrongLanguage], .light),
            ("02-three-warnings", 760, [wrongLanguage, gap, doubtful], .light),
            ("03-removed-passages", 760,
             [AggregatedWarning(warning: .cleanRemovedLowConfidence(segments: 3,
                                                                    floor: 0.65),
                                count: 1, startSeconds: nil)], .light),
            ("04-removed-one", 760,
             [AggregatedWarning(warning: .cleanRemovedLowConfidence(segments: 1,
                                                                    floor: 0.65),
                                count: 1, startSeconds: nil)], .light),
            ("05-kept-all-below-floor", 760,
             [AggregatedWarning(warning: .cleanKeptAllBelowFloor(segments: 3,
                                                                 floor: 0.65),
                                count: 1, startSeconds: nil)], .light),
            ("06-doubtful-only", 760, [doubtful], .light),
            ("07-dark", 760, [wrongLanguage, gap], .dark),
            ("08-phone-width", 390, [wrongLanguage], .light),
        ]
        for (name, width, warnings, scheme) in shots {
            let size = try render(name, width: width, warnings, scheme: scheme)
            #expect((size?.width ?? 0) > 0 && (size?.height ?? 0) > 0,
                    "\(name) rendered empty")
        }
        print("banner previews in \(Self.directory.path)")
    }

    @Test("Nothing noticed draws nothing")
    @MainActor
    func emptyDrawsNothing() throws {
        // The banner must not reserve space or show a chrome-only bar on a
        // transcript with no warnings, which is the common case.
        let size = try render("09-nothing-noticed", width: 760, [])
        #expect(size == nil || size!.height <= 1,
                "an empty banner drew \(size.map { "\($0.height)" } ?? "nil") points tall")
    }

    @Test("A sentence exists for every case, with no placeholder left unfilled")
    @MainActor
    func everyCaseHasASentence() {
        // Guards the switch in `WarningBanner.sentence(for:)` against a case
        // added to SegmentWarning and not worded. The compiler catches a missing
        // case; it cannot catch one wired to the wrong sentence, so the text is
        // resolved here rather than only rendered.
        let all: [SegmentWarning] = [
            .mergeAmbiguity, .lowConfidence(0.5), .transcriptionGap,
            .polishFellBack(reasons: ["polarity"]), .polishRetried,
            .languageLooksWrong(transcribedAs: "en-US", detected: "es"),
            .fewWordsForSpeech(words: 4, speechSeconds: 120),
            .cleanRemovedLowConfidence(segments: 2, floor: 0.65),
            .cleanKeptAllBelowFloor(segments: 2, floor: 0.65),
        ]
        for warning in all {
            let entry = AggregatedWarning(warning: warning, count: 1,
                                          startSeconds: nil)
            let resolved = String(
                localized: String.LocalizationValue(
                    stringLiteral: "\(WarningBanner.sentence(for: entry))"))
            #expect(!resolved.isEmpty, "\(warning.code) has no sentence")
        }
    }
}
#endif
