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

func brailleMapTests() {
    test("braille formatting: a sign's place outside the text takes the next character's") {
        expect(BrailleOutput.fillInvalid([0, -1, -1, 1, 2, Int.max], length: 3), [0, 1, 1, 1, 2, 2])
        expect(BrailleOutput.fillInvalid([-1, 0], length: 1), [0, 0])
        expect(BrailleOutput.fillInvalid([], length: 0), [])
    }
    test("Word lines: a line running two characters late is put back on the row it is drawn on") {
        // "ab⏎" then a paragraph drawn ten characters to a row; Word's lines start two characters late, and the
        // paragraph's first two characters are lines of their own (Dead Souls, 14 Nov 2026).
        let text = "ab\n" + String(repeating: "x", count: 25) + "\nz"
        let ns = text as NSString, n = ns.length
        func row(_ o: Int) -> (mid: CGFloat, height: CGFloat)? {
            guard o >= 3, o < 28 else { return o < 3 ? (0, 12) : (100, 12) }
            return (CGFloat(10 + (o - 3) / 10 * 13), 12)
        }
        func t(_ a: Int, _ b: Int) -> String { ns.substring(with: NSRange(location: a, length: max(0, min(b, n) - a))) }
        expect(WordLines.drawnRow(probe: 3, guess: (3, 4), length: n, text: t, row: row).map { [$0.0, $0.1] }, [3, 13], "the one-letter line is the whole first row")
        expect(WordLines.drawnRow(probe: 14, guess: (5, 15), length: n, text: t, row: row).map { [$0.0, $0.1] }, [13, 23], "a late line is the second row")
        expect(WordLines.drawnRow(probe: 25, guess: (25, 29), length: n, text: t, row: row).map { [$0.0, $0.1] }, [23, 29], "the last row takes the paragraph mark")
        check(WordLines.drawnRow(probe: 14, guess: (13, 23), length: n, text: t, row: row) == nil, "a right line is kept")
    }
}
