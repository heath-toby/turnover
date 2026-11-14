// SPDX-License-Identifier: GPL-3.0-or-later
// NVDA's Speech History add-on (the tester asked, 14 Nov 2026): step back and forward through what TurnOver said, and
// copy the one you are on, to report what was misread or keep what was said. TurnOver already kept the history (the
// last 3,000 things said, never private speech: a password, a code, typed text); these are the keys onto it.
// Reading an item back doesn't add it to the history. Any new speech puts the place back at the newest.
// Recording (TO Shift F11 on, and off again): everything said meanwhile, copied with TO Shift F12, a line each, as
// written where the text came with its own words (a message, a line of a document), else as spoken.
import Foundation
import AppKit

public enum SpeechHistory {
    /// The place in the history: its index, and how long the history was when the place was set (new speech since
    /// starts again from the newest).
    private static var place: (index: Int, count: Int)?

    /// The item `step` before (-1) or after (+1) the place, said; the edge sounds at either end.
    public static func move(_ step: Int) {
        let items = Speech.history.value.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !items.isEmpty else { Speech.speakMessage(String(localized: "nothing said yet", comment: "The speech history is empty")); return }
        var i: Int
        if let p = place, p.count == items.count { i = p.index + step } else { i = step < 0 ? items.count - 1 : items.count }
        // (From the newest, back goes to the newest itself: the thing just said, as NVDA's add-on starts.)
        if place == nil || place!.count != items.count, step < 0 { i = items.count - 1 }
        guard items.indices.contains(i) else { Tones.edge(); return }
        place = (i, items.count)
        say(items[i])
    }

    /// The item at the place (the newest if none) to the clipboard.
    public static func copy() {
        let items = Speech.history.value.map(\.text).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !items.isEmpty else { Speech.speakMessage(String(localized: "nothing said yet", comment: "The speech history is empty")); return }
        let i = place.flatMap { $0.count == items.count && items.indices.contains($0.index) ? $0.index : nil } ?? items.count - 1
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(items[i], forType: .string)
        Log.io("speech history: copied an item (\(items[i].count) characters)")
        say(String(localized: "copied", comment: "Spoken message: the speech history item was copied"))
    }

    // MARK: Recording

    private static var recording: [String]?
    private static var lastRecorded: [String] = []
    public static var isRecording: Bool { recording != nil }

    /// Called as each thing is said (not private speech, not the history read back).
    static func recorded(spoken: String, written: String) {
        guard recording != nil else { return }
        let w = written.trimmingCharacters(in: .whitespacesAndNewlines)
        let line = w.isEmpty ? spoken : w
        // A text said in pieces (by language, by comma) carries the same written text with each: kept once.
        if recording?.last == line { return }
        recording?.append(line)
    }

    /// Start recording, or stop and keep what was said.
    public static func toggleRecording() {
        if let r = recording {
            recording = nil; lastRecorded = r
            say(r.isEmpty ? String(localized: "recording stopped, nothing said", comment: "Spoken message: speech recording stopped empty")
                : String(localized: "recording stopped, \(String(r.count)) things said", comment: "Spoken message: speech recording stopped"))
        } else {
            say(String(localized: "recording speech", comment: "Spoken message: speech recording started"))
            recording = []
        }
    }

    /// What was recorded (stopping a recording still going), a line each, to the clipboard.
    public static func copyRecording() {
        if let r = recording { recording = nil; lastRecorded = r }
        guard !lastRecorded.isEmpty else { say(String(localized: "nothing recorded", comment: "Spoken message: no recorded speech to copy")); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastRecorded.joined(separator: "\n"), forType: .string)
        Log.io("speech history: copied the recording (\(lastRecorded.count) things)")
        say(String(localized: "recorded speech copied", comment: "Spoken message"))
    }

    private static func say(_ text: String) {
        Speech.historyQuiet = true
        defer { Speech.historyQuiet = false }
        Speech.cancel()
        Speech.speakMessage(text, remember: false)
    }
}
