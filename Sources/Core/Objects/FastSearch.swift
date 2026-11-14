// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's fast searching (VoiceOver Utility, Navigation, 14 Nov 2026), done simply: with the keyboard focus in a
// list, table or outline, Right Command and a letter moves the cursor to the next item there starting with that
// letter, round from the top. Off by default: on, Right Command and a letter no longer reaches the app in a list
// (Right Command C does not copy there); Left Command is untouched.
import Foundation
import ApplicationServices

public enum FastSearch {
    /// The right Command key's device bit in an event's flags (IOKit's NX_DEVICERCMDKEYMASK), and the left one's.
    nonisolated static let rightCommandBit: UInt64 = 0x10, leftCommandBit: UInt64 = 0x08

    /// The letter or digit a key searches for, when the key is Right Command and it alone. Pure.
    nonisolated public static func letter(keyName: String, modifiers: Modifiers, flags: UInt64) -> String? {
        guard modifiers == [.command], flags & rightCommandBit != 0, flags & leftCommandBit == 0,
              keyName.count == 1, let c = keyName.lowercased().first, c.isLetter || c.isNumber else { return nil }
        return String(c)
    }

    /// The indices to try, after `start` (nil: from the top), round to the beginning, the start itself last. Pure.
    nonisolated public static func order(count: Int, after start: Int?) -> [Int] {
        guard count > 0 else { return [] }
        let from = start.map { ($0 + 1) % count } ?? 0
        return (0..<count).map { (from + $0) % count }
    }

    /// Whether an item's name starts with the letter, ignoring case, accents and leading spaces. Pure.
    nonisolated public static func matches(_ name: String, _ letter: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return !letter.isEmpty && n.hasPrefix(letter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
    }

    static let listRoles: Set<Role> = [.list, .listItem, .table, .tableRow, .tableCell, .cell, .outline, .treeView, .treeViewItem, .browser]

    /// The script for the key, when fast searching is on and the focus is in a list (main thread; no accessibility
    /// call: the focus's role is already known).
    public static func script(for g: KeyboardGesture) -> Script? {
        guard config.general.fastSearching, let letter = letter(keyName: g.keyName, modifiers: g.modifiers, flags: g.flags.rawValue),
              let role = API.focusObject?.role, listRoles.contains(role) else { return nil }
        return Script(name: "fastSearch", description: String(localized: "Fast searching: the next item starting with a letter (Right Command and the letter)", comment: "A command, as the key list and keyboard help say it"), category: "Navigation", owner: nil) { _ in
            ObjectNavigator.shared.fastSearch(letter)
        }
    }
}
