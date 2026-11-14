// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's Verbosity > Announcements, and the NVDA keyboard options that go with them (14 Nov 2026): what TurnOver
// says or sounds when status text changes under the review cursor, when the focused table or outline gains or loses
// rows, when a dialog appears (a sound; its text is Presentation.speakDialogText's), and while typing (a lowercase letter with Caps Lock on, a word just typed misspelt).
// The settings are Config.Presentation's statusTextChanges, rowCountChanges and dialogSound, and Config.Keyboard's
// beepForLowercaseWithCapsLock and spellingErrorSoundWhileTyping. Every default keeps what TurnOver did before.
import Foundation
import AppKit
import ApplicationServices

public enum Announcements {
    // MARK: Pure rules (tested in PureTests)

    /// "off", "tone" or "speak": status text and row count changes.
    nonisolated public static let changeModes = ["off", "tone", "speak"]
    /// A saved mode if it is one of `allowed`, else the fallback (a hand-edited file keeps working).
    nonisolated public static func mode(_ saved: String?, allowed: [String], fallback: String) -> String {
        saved.flatMap { allowed.contains($0) ? $0 : nil } ?? fallback
    }

    /// Whether an element is status text VoiceOver would follow: plain static text, or a web page's status, timer or
    /// log region. Not a progress bar: ProgressWatch already beeps or says its climb.
    nonisolated public static func isStatusText(role: String, subrole: String?) -> Bool {
        role == "AXStaticText" || ["AXApplicationStatus", "AXApplicationTimer", "AXApplicationLog"].contains(subrole ?? "")
    }

    /// NVDA's caps lock beep: a lowercase letter typed while Caps Lock is on (Shift held turns Caps Lock's capitals back
    /// to lowercase, usually by mistake).
    nonisolated public static func lowercaseWithCapsLock(_ ch: Character, capsLockOn: Bool) -> Bool {
        capsLockOn && ch.isLetter && ch.isLowercase && ch.uppercased() != String(ch)
    }

    /// Whether a key cuts what is being said (NVDA's two speech interrupt options). Return and Enter follow their own
    /// switch, typed characters theirs; every other key (Backspace, arrows, commands) always cuts speech.
    nonisolated public static func keyInterruptsSpeech(keyName: String, plain: Bool, typesCharacter: Bool,
                                                       forCharacters: Bool, forEnter: Bool) -> Bool {
        if plain, ["enter", "numpadEnter"].contains(keyName) { return forEnter }
        if typesCharacter, keyName != "backspace" { return forCharacters }
        return true
    }

    /// "5 rows", "1 row", "no rows".
    public static func rows(_ n: Int) -> String {
        n == 0 ? String(localized: "no rows", comment: "A table or list now has no rows")
            : n == 1 ? String(localized: "1 row", comment: "A table's size") : String(localized: "\(n) rows", comment: "A table's size")
    }

    // MARK: Status text under the review cursor

    private static var pendingStatus: DispatchWorkItem?
    private static var lastStatusTone = Date.distantPast
    private static var lastStatusText: String?

    /// AXValueChanged or AXTitleChanged on an element in the app in front. Said only for the element the review
    /// cursor is on, when it isn't the focus (the focus's own value change is read by its object as before).
    static func statusTextChanged(_ element: AXUIElement) {
        let mode = config.presentation.statusTextChanges
        guard mode != "off", let cursor = ObjectNavigator.shared.reviewElement, cursor.isSame(element),
              !(API.focusObject?.isSameElement(as: element) ?? false),
              isStatusText(role: element.role, subrole: element.string(kAXSubroleAttribute)) else { return }
        if mode == "tone" {
            // A clock ticking every second, or a counter racing: one tone each half second at most.
            guard Date().timeIntervalSince(lastStatusTone) > 0.5 else { return }
            lastStatusTone = Date()
            if !VoiceOverSounds.play("Announcement.aiff") { Tones.beep(1046, 30, volume: 0.15) }
            return
        }
        // Speak the text once it settles: a status line rewritten several times in a burst is said once, as it ends.
        pendingStatus?.cancel()
        let work = DispatchWorkItem {
            guard let cursor = ObjectNavigator.shared.reviewElement, cursor.isSame(element) else { return }
            let text = [element.string(kAXValueAttribute), element.string(kAXTitleAttribute), element.string(kAXDescriptionAttribute)]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
            guard let text, text != lastStatusText else { return }
            lastStatusText = text
            Speech.speakMessage(text)
        }
        pendingStatus = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: Rows of the focused table or outline

    private static var pendingRows: DispatchWorkItem?
    private static var lastRows: (element: AXUIElement, count: Int)?

    /// AXRowCountChanged on an element. Only the table or outline the focus is in counts; a burst (a list filling as
    /// it loads) is said once, 0.4 s after the last change, and only when the count differs from the one last said.
    static func rowCountChanged(_ element: AXUIElement) {
        let mode = config.presentation.rowCountChanges
        guard mode != "off", let f = API.focusObject,
              f.isSameElement(as: element) || API.focusAncestors.contains(where: { $0.isSameElement(as: element) }) else { return }
        pendingRows?.cancel()
        let work = DispatchWorkItem {
            // Counted, not fetched: a list can have thousands of rows.
            var n: CFIndex = 0
            guard AXUIElementGetAttributeValueCount(element, kAXRowsAttribute as CFString, &n) == .success else { return }
            let count = Int(n)
            if let last = lastRows, last.element.isSame(element), last.count == count { return }
            lastRows = (element, count)
            Log.io("rows changed under the focus: \(count)")
            if mode == "tone" { if !VoiceOverSounds.play("LayoutChanged.aiff") { Tones.beep(740, 40, volume: 0.18) } }
            else { Speech.speakMessage(rows(count)) }
        }
        pendingRows = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: Dialogs

    /// VoiceOver's alert sound as a dialog appears (or TurnOver's tone where the file is missing).
    static func dialogTone() {
        if !VoiceOverSounds.play("Alert.aiff") { Tones.beep(880, 60, volume: 0.2) }
    }

    // MARK: Typing

    /// A typed letter: NVDA's beep for a lowercase letter while Caps Lock is on.
    static func typed(_ ch: Character, flags: CGEventFlags) {
        guard config.keyboard.beepForLowercaseWithCapsLock, lowercaseWithCapsLock(ch, capsLockOn: flags.contains(.maskAlphaShift)) else { return }
        Tones.beep(3000, 40, volume: 0.15)   // NVDA's: 3000 Hz, 40 ms
    }

    /// A word just typed and echoed: the spelling error sound when the system's spelling checker doesn't know it.
    /// The checker, not the app's own marking: apps mark a misspelling some time after the word ends, or not at all
    /// to accessibility, and the sound has to come as the word ends to mean anything.
    static func typedWord(_ word: String) {
        guard config.keyboard.spellingErrorSoundWhileTyping, word.count > 1, word.contains(where: \.isLetter),
              !word.contains(where: \.isNumber) else { return }
        let miss = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0)
        if miss.location != NSNotFound { Tones.spellingError() }
    }
}
