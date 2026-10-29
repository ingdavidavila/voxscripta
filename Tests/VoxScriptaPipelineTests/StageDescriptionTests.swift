import Testing
import Foundation
import VoxScriptaCore
import VoxScriptaLanguage
@testable import VoxScriptaPipeline

/// Guards the thing a stage hash is for: noticing that a setting changed.
///
/// A parameter missing from `describe` is invisible. The stage hash does not
/// move, the resume planner decides the work is still current, and the setting
/// the user just changed does nothing at all — while the interface shows it as
/// applied. This has already shipped once in this project: for a while neither
/// CLEAN nor POLISH folded its own parameters in, and a comment claimed
/// otherwise.
///
/// So rather than testing one field, this tests that every field is covered,
/// and fails when a new one is added without being described.
@Suite("Stage descriptions")
struct StageDescriptionTests {

    /// Each variant differs from `.default` in exactly one field.
    private static let cleanVariants: [(field: String, parameters: CleanParameters)] = {
        var out: [(String, CleanParameters)] = []

        var a = CleanParameters.default; a.removeFillers.toggle()
        out.append(("removeFillers", a))
        var b = CleanParameters.default; b.collapseRepetitions.toggle()
        out.append(("collapseRepetitions", b))
        var c = CleanParameters.default; c.repairPunctuation.toggle()
        out.append(("repairPunctuation", c))
        var d = CleanParameters.default; d.normalizeCapitalization.toggle()
        out.append(("normalizeCapitalization", d))
        var e = CleanParameters.default; e.terminateSentences.toggle()
        out.append(("terminateSentences", e))
        var f = CleanParameters.default; f.language = .spanish
        out.append(("language", f))
        var g = CleanParameters.default; g.maximumStutterGap = .milliseconds(900)
        out.append(("maximumStutterGap", g))
        var h = CleanParameters.default; h.confidenceFloor = nil
        out.append(("confidenceFloor (off)", h))
        var i = CleanParameters.default; i.confidenceFloor = 0.8
        out.append(("confidenceFloor (moved)", i))

        return out
    }()

    @Test("Changing any CLEAN parameter changes its description")
    func everyCleanFieldIsDescribed() {
        let baseline = JobRunner.describe(.default)
        for variant in Self.cleanVariants {
            let message = "\(variant.field) does not reach the stage hash, so changing"
                + " it in Settings would silently do nothing"
            #expect(JobRunner.describe(variant.parameters) != baseline, "\(message)")
        }
    }

    @Test("Every stored CLEAN parameter has a variant above")
    func noFieldIsUntested() {
        // The structural half. Without this, adding a parameter and forgetting
        // both `describe` and this file would leave the gap wide open again.
        let fields = Mirror(reflecting: CleanParameters.default).children.count
        let covered = Set(Self.cleanVariants.map {
            $0.field.split(separator: " ").first.map(String.init) ?? $0.field
        })
        let message = "CleanParameters has \(fields) fields and \(covered.count) are"
            + " exercised; a new one needs a variant here and a place in JobRunner.describe"
        #expect(covered.count == fields, "\(message)")
    }

    @Test("The confidence floor is part of the hash in both directions")
    func floorInvalidatesBothWays() {
        var off = CleanParameters.default
        off.confidenceFloor = nil
        var strict = CleanParameters.default
        strict.confidenceFloor = 0.9

        let descriptions = Set([JobRunner.describe(.default),
                                JobRunner.describe(off),
                                JobRunner.describe(strict)])
        // Turning it off, and moving it, must each re-run CLEAN — the second
        // is the one a `Bool`-only description would miss.
        #expect(descriptions.count == 3)
    }
}
