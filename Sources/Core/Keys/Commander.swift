// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's Keyboard Commander key, chosen as in VoiceOver Utility (Commanders, Keyboard: "Modifier key"), 14 Nov 2026.
// Until then it was right Option only. Whichever key is chosen, a letter with it is stored as before, under
// "kb:rightoption+…" (UserGestures), so the keys given to letters survive a change of modifier; the name said for it
// follows the chosen key. Pure: read on the keyboard thread through KeySettings and on main through config.
import Foundation

nonisolated public enum Commander {
    public enum Key: String, CaseIterable, Sendable {
        case rightOption, leftOption, rightCommand, leftCommand, rightControl

        /// The device-dependent bit macOS sets in an event's flags for this side's key (IOKit's NX_DEVICE…KEYMASK).
        var deviceBit: UInt64 {
            switch self {
            case .rightOption: return 0x40; case .leftOption: return 0x20
            case .rightCommand: return 0x10; case .leftCommand: return 0x08
            case .rightControl: return 0x2000
            }
        }
        /// The same modifier's other side: both held at once is not the Commander.
        var otherSideBit: UInt64 {
            switch self {
            case .rightOption: return 0x20; case .leftOption: return 0x40
            case .rightCommand: return 0x08; case .leftCommand: return 0x10
            case .rightControl: return 0x01
            }
        }
        /// The modifier as a gesture carries it.
        public var modifier: Modifiers {
            switch self {
            case .rightOption, .leftOption: return .option
            case .rightCommand, .leftCommand: return .command
            case .rightControl: return .control
            }
        }
        /// An Option key: with a letter it types a character, so taking the letter costs no app's shortcut. A Command
        /// or Control Commander's letters are shortcuts: TurnOver's own default letters (T, the time) are not put
        /// on them, or Left Command T (a new tab) would be taken (a review, 14 Nov 2026).
        public var typesCharacters: Bool { modifier == .option }
        /// As said and shown ("right option S").
        public var spokenName: String {
            switch self {
            case .rightOption: return String(localized: "right option", comment: "The Keyboard Commander's key, as said before a letter")
            case .leftOption: return String(localized: "left option", comment: "The Keyboard Commander's key, as said before a letter")
            case .rightCommand: return String(localized: "right command", comment: "The Keyboard Commander's key, as said before a letter")
            case .leftCommand: return String(localized: "left command", comment: "The Keyboard Commander's key, as said before a letter")
            case .rightControl: return String(localized: "right control", comment: "The Keyboard Commander's key, as said before a letter")
            }
        }
    }

    public static func key(_ stored: String) -> Key { Key(rawValue: stored) ?? .rightOption }

    /// Whether a key's modifiers are the Commander's, alone or with Shift: the chosen side's key down, not the other
    /// side's, and no other modifier but Shift. `flags` is the event's raw flags (device bits included).
    public static func holds(_ key: Key, modifiers: Modifiers, flags: UInt64) -> Bool {
        guard modifiers == key.modifier || modifiers == key.modifier.union(.shift) else { return false }
        return flags & key.deviceBit != 0 && flags & key.otherSideBit == 0
    }
}
