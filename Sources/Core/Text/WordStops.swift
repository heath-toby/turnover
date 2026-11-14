// SPDX-License-Identifier: GPL-3.0-or-later
// The Windows style's word stops (Option or Control and the arrows), as a tester asked (14 Nov 2026): punctuation
// ending a word is a stop of its own ("lazy", "comma", "dog", "question mark"), and punctuation opening one is read
// with it ("quote I", then "am", then "period quote"). Punctuation inside a word ("e-mail", "3.5") stays in it.
import Foundation

nonisolated public enum WordStops {
    nonisolated public enum Kind: Equatable { case word, marks, blank }
    /// A stop: where the caret goes, the range read, and what it is. For a word, `lead` is how many of its first
    /// characters are opening punctuation.
    nonisolated public struct Stop: Equatable {
        public let at: Int, end: Int, kind: Kind, lead: Int
    }

    nonisolated static func isWordChar(_ u: unichar) -> Bool {
        if UTF16.isLeadSurrogate(u) || UTF16.isTrailSurrogate(u) { return true }
        guard let s = Unicode.Scalar(u) else { return false }
        return CharacterSet.alphanumerics.contains(s) || u == 0x27 || u == 0x2019
    }
    nonisolated static func isSpace(_ u: unichar) -> Bool {
        guard let s = Unicode.Scalar(u) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(s) || u == 0xFFFC
    }
    nonisolated static func isBreak(_ u: unichar) -> Bool { u == 10 || u == 13 || u == 0x2028 || u == 0x2029 || u == 11 || u == 12 }

    /// The stops in `text`, in order. A run of spaces holding two line breaks or more has a stop on the empty line.
    public nonisolated static func stops(in text: String) -> [Stop] {
        let u = Array(text.utf16)
        var out: [Stop] = []
        var i = 0, breaks = 0, firstBreakEnd = -1
        while i < u.count {
            if isSpace(u[i]) {
                if isBreak(u[i]) {
                    // \r\n is one break.
                    if !(u[i] == 10 && i > 0 && u[i - 1] == 13) { breaks += 1; if breaks == 1 { firstBreakEnd = i + 1 } }
                    if breaks == 1, u[i] == 13, i + 1 < u.count, u[i + 1] == 10 { firstBreakEnd = i + 2 }
                }
                i += 1; continue
            }
            if breaks > 1, firstBreakEnd >= 0 { out.append(Stop(at: firstBreakEnd, end: firstBreakEnd, kind: .blank, lead: 0)) }
            breaks = 0; firstBreakEnd = -1
            let s = i
            while i < u.count, !isSpace(u[i]) { i += 1 }
            let e = i
            guard let fw = (s..<e).first(where: { isWordChar(u[$0]) }), let lw = (s..<e).last(where: { isWordChar(u[$0]) }) else {
                out.append(Stop(at: s, end: e, kind: .marks, lead: 0)); continue
            }
            out.append(Stop(at: s, end: lw + 1, kind: .word, lead: fw - s))
            if lw + 1 < e { out.append(Stop(at: lw + 1, end: e, kind: .marks, lead: 0)) }
        }
        return out
    }

    /// The next stop after `caret` (forward) or the last before it, in `text`; nil when there is none.
    public nonisolated static func stop(in text: String, from caret: Int, forward: Bool) -> Stop? {
        let all = stops(in: text)
        return forward ? all.first { $0.at > caret } : all.last { $0.at < caret }
    }
}
