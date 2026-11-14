// SPDX-License-Identifier: GPL-3.0-or-later
// A line checked against where the text is drawn (14 Nov 2026): Word's lines ran two characters late, and Chromium's
// text boxes (Signal's message box) give a whole paragraph as one line. The row the probe is drawn on is found by
// halving (the characters of a paragraph come row by row). Nil keeps the app's line. Pure, given its questions
// (tested through WordLines).
import Foundation
import CoreGraphics

package enum DrawnRows {
    package nonisolated static func drawnRow(probe: Int, guess: (Int, Int), length n: Int, text: (Int, Int) -> String,
                                     row: (Int) -> (mid: CGFloat, height: CGFloat)?) -> (Int, Int)? {
        // The text around the probe in one question (500 characters each way: a row is far shorter); a character
        // beyond it, asked alone. (2,000 each way cost every arrow a long read: a review, 14 Nov 2026.)
        let base = max(0, probe - 500), local = Array(text(base, min(n, probe + 501)).utf16)
        func char(_ o: Int) -> UInt16? {
            if o >= base, o - base < local.count { return local[o - base] }
            return text(o, o + 1).utf16.first
        }
        func isMark(_ c: UInt16?) -> Bool { guard let c else { return false }; return [13, 10, 12, 11, 7, 0x2029].contains(c) }
        guard probe >= 0, probe < n, !isMark(char(probe)), let here = row(probe) else { return nil }
        // On the same row: middles closer than half the taller one's height, so a larger run, a drop cap or a
        // superscript on the row still counts (a review: the smaller's half-height split such rows).
        func same(_ o: Int) -> Bool? { row(o).map { abs($0.mid - here.mid) < max($0.height, here.height) / 2 } }
        let (a, b) = guess
        // Word's line as it stands: starts on this row after another row or a paragraph's start, ends on it before
        // another row or the paragraph's end.
        let startOK = a <= probe && (same(a) ?? true) && (a == 0 || isMark(char(a - 1)) || same(a - 1) == false)
        let lastChar = b - 1 >= a && isMark(char(b - 1)) ? b - 2 : b - 1
        let endOK = b > probe && (lastChar < a || (same(lastChar) ?? true)) && (b >= n || isMark(char(b - 1)) || same(b) == false)
        if startOK && endOK { return nil }
        // The paragraph around the probe, at most 2,000 characters each way.
        var ps = probe
        while ps > base, !isMark(char(ps - 1)) { ps -= 1 }
        var pe = probe + 1   // one past the last character before the paragraph's mark
        while pe < min(n, base + local.count), !isMark(char(pe)) { pe += 1 }
        var lo = ps, hi = probe
        // (A character Word gives no place for counts as on the row, as in the checks above.)
        while lo < hi { let mid = (lo + hi) / 2; if same(mid) ?? true { hi = mid } else { lo = mid + 1 } }
        let start = lo
        lo = probe; hi = pe - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if same(mid) ?? true { lo = mid } else { hi = mid - 1 } }
        var end = lo + 1
        if end == pe, pe < n { end = pe + 1 }   // the paragraph's last row takes its mark, as Word's lines do
        return (start, end)
    }
}
