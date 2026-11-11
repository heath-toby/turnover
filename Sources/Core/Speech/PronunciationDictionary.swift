// SPDX-License-Identifier: GPL-3.0-or-later
// A pronunciation dictionary (NVDA's speech dictionary, VoiceOver's Pronunciation settings): words said the way
// you want them said. The parity checklist of 11 Nov 2026 found none.
//
// One file, ~/Library/Application Support/TurnOver/pronunciations.txt, a line each:
//     TurnOver = turn over
//     LBRF = L B R F
//     # a comment
// The word on the left is matched whole, whatever its case; the right is what the voice says. It changes speech only:
// braille, the copy of the last thing said and the log keep the text as written. The file is read again when it
// changes, so an edit applies at once.
import Foundation

public enum PronunciationDictionary {
    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TurnOver", isDirectory: true).appendingPathComponent("pronunciations.txt")
    }

    nonisolated(unsafe) private static var entries: [(NSRegularExpression, String)] = []
    nonisolated(unsafe) private static var loadedStamp: Date?
    nonisolated(unsafe) private static var checkedAt = Date.distantPast
    private static let lock = NSLock()

    /// The entries of a dictionary file's text (for the tests too).
    package static func parse(_ text: String) -> [(NSRegularExpression, String)] {
        var out: [(NSRegularExpression, String)] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let eq = line.range(of: "=") else { continue }
            let word = line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
            let say = line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            guard !word.isEmpty else { continue }
            // Whole words: not inside another word (letters or digits either side).
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: word) + "(?![\\p{L}\\p{N}])"
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                out.append((re, NSRegularExpression.escapedTemplate(for: say)))
            }
        }
        // Longest first: "New York City" before "New York".
        return out.sorted { $0.0.pattern.count > $1.0.pattern.count }
    }

    /// The file read again if it changed (looked at no more than once a second).
    private static func refresh() {
        guard Date().timeIntervalSince(checkedAt) > 1 else { return }
        checkedAt = Date()
        let stamp = (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
        guard stamp != loadedStamp else { return }
        loadedStamp = stamp
        let text = stamp == nil ? "" : ((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "")
        entries = parse(text)
        if stamp != nil { Log.info("pronunciations: \(entries.count) entries read") }
    }

    /// The text as the voice should say it.
    public static func apply(_ text: String) -> String {
        lock.lock(); defer { lock.unlock() }
        refresh()
        guard !entries.isEmpty else { return text }
        return apply(text, entries)
    }

    package static func apply(_ text: String, _ list: [(NSRegularExpression, String)]) -> String {
        var s = text
        for (re, say) in list {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: say)
        }
        return s
    }
}
