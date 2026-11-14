// SPDX-License-Identifier: GPL-3.0-or-later
// Braille's settings and formatting marks (14 Nov 2026).
import Foundation
import AppKit
import TurnOverCore
import TurnOverBraille

func brailleFeatureTests() {
    test("braille formatting: runs join across attribute pieces and keep each kind") {
        let a = NSMutableAttributedString(string: "The quick brown fox")
        let bold: [NSAttributedString.Key: Any] = [NSAttributedString.Key("AXFontBold"): NSNumber(value: true)]
        a.addAttributes(bold, range: NSRange(location: 4, length: 3))
        // A second piece of the same word, with another attribute as well: still one bold run.
        a.addAttributes(bold.merging([NSAttributedString.Key("AXForegroundColor"): "x"]) { $1 }, range: NSRange(location: 7, length: 2))
        a.addAttributes([NSAttributedString.Key("AXUnderline"): NSNumber(value: 1)], range: NSRange(location: 16, length: 3))
        let runs = EmphasisRun.runs(in: a) { AXTextInfo.format(from: $0) }
        expect(runs, [EmphasisRun(.bold, NSRange(location: 4, length: 5)), EmphasisRun(.underline, NSRange(location: 16, length: 3))])
    }
    test("braille formatting: runs are cut to a part of the text and counted from its start") {
        let runs = [EmphasisRun(.italic, NSRange(location: 2, length: 6)), EmphasisRun(.bold, NSRange(location: 20, length: 2))]
        expect(BrailleOutput.clip(runs, to: NSRange(location: 5, length: 10)), [EmphasisRun(.italic, NSRange(location: 0, length: 3))])
        expect(BrailleOutput.clip(runs, to: NSRange(location: 30, length: 5)), [])
    }
    test("braille keys: every VoiceOver display command given a chord has that chord's command") {
        expect(Braille.unmappedVoCommandChords(), [])
    }
    test("braille formatting: the UEB table marks a bold word with its own indicator, when macOS has the table") {
        guard let tr = TOBrailleTranslator(forTable: "com.apple.scrod.braille.table.duxbury.eng-xueb_g2") else { return }
        var loc: NSArray?
        let plain = tr.braille(forText: "big bold text", locations: &loc)
        let marked = tr.braille(forText: "big bold text", locations: &loc, formatting: [[0, 4, 4]])
        check(marked.contains("\u{2818}\u{2802}"), "bold word indicator (dots 4 5, then 2) in \(marked)")
        check(!plain.contains("\u{2818}\u{2802}"), "no indicator without formatting")
        expect((loc as? [NSNumber])?.count ?? -1, marked.unicodeScalars.count, "one location per cell")
    }
}
