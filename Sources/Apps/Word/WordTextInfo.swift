// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ApplicationServices
import AppKit

/// Word's text through the page areas. Indices are document-global, so any page
/// area answers a range read; the caret is read from the object's own page area,
/// or from the neighbouring page when the caret has just crossed.
final class WordTextInfo: AXTextInfo {
    override func caretOffset() -> Int? {
        if let c = super.caretOffset() { return c }
        return neighbourSelection().map { $0.location + $0.length }
    }
    override func selectionOffsets() -> (Int, Int)? {
        guard let s = super.selectionOffsets() ?? neighbourSelection().map({ ($0.location, $0.location + $0.length) }) else { return nil }
        guard s.1 > s.0 else { return s }
        // Each page area answers with its own part of a selection over several pages: after Command-A, the last page
        // said only its own text and what page 1 had was "unselected" (a tester, 14 Nov 2026). The parts joined.
        let shared = textElement.elements("AXSharedTextUIElements")
        guard shared.count > 1 else { return s }
        func part(_ j: Int) -> (Int, Int)? {
            guard let r = cfRange(shared[j].attr(kAXSelectedTextRangeAttribute)), r.location != Int.max, r.location >= 0 else { return nil }
            return (r.location, r.location + r.length)
        }
        // The page the part came from: this one, or the neighbour the caret crossed to (identity checks cost nothing).
        guard let i = shared.firstIndex(where: { $0.isSame(textElement) }),
              let here = [i, i + 1, i - 1].first(where: { shared.indices.contains($0) && part($0).map { $0 == s } == true }) else { return s }
        return WordSelection.joined(s, page: here, pages: shared.count, part: part)
    }
    /// The pages before and after this one, when the caret has moved off it.
    private func neighbourSelection() -> CFRange? {
        let shared = textElement.elements("AXSharedTextUIElements")
        guard let i = shared.firstIndex(where: { $0.isSame(textElement) }) else { return nil }
        for j in [i + 1, i - 1] where shared.indices.contains(j) {
            if let r = cfRange(shared[j].attr(kAXSelectedTextRangeAttribute)), r.location != Int.max { return r }
        }
        return nil
    }
    override func setCaretOffset(_ o: Int) {
        // Setting the selection on a page area that does not hold the caret works: the index space is shared.
        super.setCaretOffset(o)
    }
    /// Lines are per page: AXLineForIndex on the wrong page answers with that page's last line
    /// (the repeated lines at page boundaries, 1 Oct 2026). Ask the page that holds the index.
    override func lineOffsets(_ offset: Int) -> (Int, Int)? {
        let module = obj.appModule as? WordAppModule
        let area = module?.pageArea(containing: offset, near: textElement) ?? textElement
        let n = storyLength()
        guard offset >= 0, n >= 0 else { return nil }
        // The empty last paragraph (after Return at the end): Word counts no mark for it, so the caret is past the end.
        if offset >= n, n > 0, let last = textRange(n - 1, n).last, last == "\r" || last == "\n" { return (n, n) }
        let probe = offset >= n && n > 0 ? n - 1 : offset
        guard let line = (area.param(kAXLineForIndexParameterizedAttribute, probe as CFNumber) as? NSNumber)?.intValue,
              let r = cfRange(area.param(kAXRangeForLineParameterizedAttribute, line as CFNumber)), r.length > 0 else { return nil }
        let (lineEnd, overflow) = r.location.addingReportingOverflow(r.length)
        let (storyEnd, storyOverflow) = n.addingReportingOverflow(1)
        guard r.location >= 0, !overflow, !storyOverflow, r.location <= n, lineEnd <= storyEnd else { return nil }
        // An empty paragraph is one paragraph mark; Word's line for its index can be the line after it.
        // The line must hold the index asked for, or the empty line is the mark itself.
        if offset < n, (offset < r.location || offset >= lineEnd) {
            let ch = textRange(offset, offset + 1)
            if ch == "\r" || ch == "\n" { return (offset, offset + 1) }
        }
        // Word answers the wrong page's last line when a page disappeared or moved between queries. Refuse that
        // line so the existing paragraph fallback can read the requested position instead of repeating old text.
        guard probe >= r.location, probe < lineEnd else { return nil }
        // Word's line can run past a paragraph mark into a table's stand-in ("Client details⏎Table, 6 Rows,
        // 2 Columns, , "): a line ends at its paragraph mark.
        var a = r.location, b = lineEnd
        let t = textRange(a, b) as NSString
        let base = a
        for i in 0..<max(0, t.length - 1) where t.character(at: i) == 13 || t.character(at: i) == 10 {
            if offset <= base + i { b = base + i + 1; break }
            a = base + i + 1
        }
        return WordLines.drawnRow(probe: probe, guess: (a, b), length: n,
                             text: { [self] a, b in textRange(a, b) },
                             row: { o in Self.row(of: o, in: area) }) ?? (a, b)
    }

    /// Where Word draws the character at `o`: the middle of its row and the row's height, or nil if it won't say.
    private static func row(of o: Int, in area: AXUIElement) -> (mid: CGFloat, height: CGFloat)? {
        guard let v = area.param(kAXBoundsForRangeParameterizedAttribute, axRangeValue(o, 1)), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0 else { return nil }
        return (r.midY, r.height)
    }

    /// The text Word puts in a page for a table: "Table, 6 Rows, 2 Columns, , ".
    static func isTableStandIn(_ text: String) -> Bool {
        text.range(of: #"^\s*Table, \d+ Rows, \d+ Columns"#, options: .regularExpression) != nil
    }
    override var brailleHeadingLevel: Int? {
        guard let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(start, 1)) as? NSAttributedString, a.length > 0,
              let custom = a.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key("AXCustom")] as? [String],
              let style = custom.first(where: { $0.hasPrefix("Heading") || $0 == "Title" }) else { return nil }
        return Int(style.filter(\.isNumber)) ?? (style == "Title" ? 1 : 0)
    }
    /// Word puts the paragraph style in AXCustom ("Heading 1", "Paragraph"); NVDA says "heading level 1" as a line is read.
    override func controlFieldSpeech() -> (prefix: [String], text: String?) {
        pendingTones.removeAll()
        guard end > start, let a = textElement.param(kAXAttributedStringForRangeParameterizedAttribute, axRangeValue(start, min(end - start, 400))) as? NSAttributedString, a.length > 0 else { return ([], nil) }
        var prefix: [String] = []
        // The paragraph style at the start: a heading announces itself (speech, tone or nothing).
        if let custom = a.attributes(at: 0, effectiveRange: nil)[NSAttributedString.Key("AXCustom")] as? [String],
           let style = custom.first(where: { $0.hasPrefix("Heading") || $0 == "Title" }) {
            let level = Int(style.filter(\.isNumber)) ?? (style == "Title" ? 1 : 0)
            switch config.documentFormatting.headings {
            case .off: break
            case .tone: pendingTones.append { Tones.heading(level: level) }
            case .speech: prefix.append(level > 0 && config.documentFormatting.reportHeadingLevel ? Phrases.headingLevel(level) : Role.heading.displayString)
            }
        }
        // Annotations anywhere in the range (measured 2 Oct 2026): a comment is an AXAnnotation with an element and
        // no label; a grammar error carries AXAnnotationLabel "Grammatical error".
        var hasComment = false
        var labels: [String] = []
        a.enumerateAttribute(NSAttributedString.Key("AXAnnotation"), in: NSRange(location: 0, length: a.length)) { v, _, _ in
            for d in (v as? [[String: Any]]) ?? [] {
                if let label = d["AXAnnotationLabel"] as? String { if !labels.contains(label) { labels.append(label) } } else { hasComment = true }
            }
        }
        if hasComment {
            switch WordAppModule.commentReport {
            case .off: break
            case .tone: pendingTones.append { Tones.comment() }
            case .speech: prefix.append(String(localized: "comment", comment: "A Word comment, as a kind of thing to find"))
            }
        }
        for label in labels {
            switch config.documentFormatting.spellingErrors {
            case .off: break
            case .tone: pendingTones.append { Tones.spellingError() }
            case .speech: prefix.append(label.lowercased().replacingOccurrences(of: "grammatical", with: "grammar"))
            }
        }
        return (prefix, nil)
    }

    /// Asked on Word's script queue, never the main thread: two Apple Events of up to 5 s each, and on first use
    /// macOS's permission question, held TurnOver's main thread (E6 audit, 4 Oct 2026).
    override func locationText(_ done: @escaping (String?) -> Void) {
        guard let module = obj.appModule as? WordAppModule else { done(nil); return }
        module.script.selectionInformation { page, line in
            let parts = [page.map(Phrases.page), line.map { String(localized: "line \(String($0))", comment: "Where the caret is: the line number") }].compactMap { $0 }
            DispatchQueue.main.async { done(parts.isEmpty ? nil : parts.joined(separator: ", ")) }
        }
    }
}

/// Word's lines as drawn (pure, tested).
package enum WordSelection {
    /// A selection's part on page `page` joined with the parts on the pages either side that meet it end to start.
    /// Bounded at 500 pages each way.
    package static func joined(_ s: (Int, Int), page: Int, pages: Int, part: (Int) -> (Int, Int)?) -> (Int, Int) {
        var a = s.0, b = s.1
        var j = page - 1
        while j >= 0, page - j <= 500, let p = part(j), p.1 > p.0, p.1 == a { a = p.0; j -= 1 }
        j = page + 1
        while j < pages, j - page <= 500, let p = part(j), p.1 > p.0, p.0 == b { b = p.1; j += 1 }
        return (a, b)
    }
}

package enum WordLines {
    /// Word's line checked against where it draws the text, and the row it is really on if they differ. In some
    /// documents (Dead Souls, a Word 97 file in compatibility mode, 14 Nov 2026) Word's lines run two characters late:
    /// each paragraph began with two one-letter lines ("W", "i", then "thout limiting the rights…"), all three drawn on
    /// one row, and every line after ended two letters into the next. The check costs four questions; the row is found
    /// by halving (the characters of a paragraph come row by row). Nil keeps Word's line: a character with no place
    /// on the page, or a paragraph mark asked about. Pure, given its questions (tested).
    package nonisolated static func drawnRow(probe: Int, guess: (Int, Int), length n: Int, text: (Int, Int) -> String,
                                     row: (Int) -> (mid: CGFloat, height: CGFloat)?) -> (Int, Int)? {
        // The text around the probe in one question (2,000 characters each way); a character beyond it, asked alone.
        let base = max(0, probe - 2000), local = Array(text(base, min(n, probe + 2001)).utf16)
        func char(_ o: Int) -> UInt16? {
            if o >= base, o - base < local.count { return local[o - base] }
            return text(o, o + 1).utf16.first
        }
        func isMark(_ c: UInt16?) -> Bool { guard let c else { return false }; return [13, 10, 12, 11, 7, 0x2029].contains(c) }
        guard probe >= 0, probe < n, !isMark(char(probe)), let here = row(probe) else { return nil }
        func same(_ o: Int) -> Bool? { row(o).map { abs($0.mid - here.mid) < here.height / 2 } }
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
        while lo < hi { let mid = (lo + hi) / 2; if same(mid) == true { hi = mid } else { lo = mid + 1 } }
        let start = lo
        lo = probe; hi = pe - 1
        while lo < hi { let mid = (lo + hi + 1) / 2; if same(mid) == true { lo = mid } else { hi = mid - 1 } }
        var end = lo + 1
        if end == pe, pe < n { end = pe + 1 }   // the paragraph's last row takes its mark, as Word's lines do
        return (start, end)
    }
}
