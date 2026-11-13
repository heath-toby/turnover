// SPDX-License-Identifier: GPL-3.0-or-later
// The app's own Undo and Redo menu items ("Undo Typing", "Redo Paste"), so Command-Z in a text field can say what it
// undoes, as VoiceOver does (a review, 13 Nov 2026: Undo was silent). The items are found in the background when a
// text field gets the focus; the key itself reads one title.
import Foundation
import ApplicationServices
import TurnOverAX

enum UndoMenu {
    private static var items: [pid_t: (undo: AXUIElement?, redo: AXUIElement?, at: Date)] = [:]
    private static var finding: Set<pid_t> = []

    /// Find the app's Undo and Redo items off the main thread, once in five minutes at most.
    static func prepare(pid: pid_t) {
        if let k = items[pid], Date().timeIntervalSince(k.at) < 300 { return }
        guard pid > 0, pid != getpid(), !finding.contains(pid) else { return }
        finding.insert(pid)
        DispatchQueue.global(qos: .utility).async {
            let found = find(pid)
            DispatchQueue.main.async {
                finding.remove(pid)
                items[pid] = (found.undo, found.redo, Date())
                if items.count > 40 { items = items.filter { Date().timeIntervalSince($0.value.at) < 300 } }
                Log.debug("undo menu: pid \(pid), undo \(found.undo != nil), redo \(found.redo != nil)")
            }
        }
    }

    /// The item's title now, and whether it can be chosen; nil when the item isn't known yet (it is looked for).
    /// One accessibility call, with a short timeout: a slow app costs at most 0.1 s.
    static func title(pid: pid_t, redo: Bool) -> (text: String, enabled: Bool)? {
        guard let k = items[pid] else { prepare(pid: pid); return nil }
        guard let item = redo ? k.redo : k.undo else { return nil }
        AXUIElementSetMessagingTimeout(item, 0.1)
        guard let t = item.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespaces), !t.isEmpty else {
            // The item has gone (the app rebuilt its menus): look again for the next time.
            items[pid] = nil
            prepare(pid: pid)
            return nil
        }
        return (t, (item.attr(kAXEnabledAttribute) as? Bool) ?? true)
    }

    /// The menu items with Command-Z (Undo) and Command-Shift-Z (Redo). The Edit menu is the fourth in the menu bar
    /// (Apple, the app, File, Edit) in nearly every app, so it is looked in first; at most 12 menus of 60 items.
    nonisolated static func find(_ pid: pid_t) -> (undo: AXUIElement?, redo: AXUIElement?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar = app.element(kAXMenuBarAttribute) else { return (nil, nil) }
        let barItems = bar.elements(kAXChildrenAttribute)
        var order: [Int] = []
        for i in [3, 2, 4] + Array(0..<barItems.count) where i < barItems.count && !order.contains(i) { order.append(i) }
        var undo: AXUIElement?, redo: AXUIElement?
        for i in order.prefix(12) {
            guard let menu = barItems[i].elements(kAXChildrenAttribute).first else { continue }
            for item in menu.elements(kAXChildrenAttribute).prefix(60) {
                guard let key = item.string(kAXMenuItemCmdCharAttribute), key.uppercased() == "Z" else { continue }
                switch item.int(kAXMenuItemCmdModifiersAttribute) ?? 0 {
                case 0: undo = item                    // Command alone (kAXMenuItemModifierNone)
                case 1: redo = item                    // with Shift (kAXMenuItemModifierShift)
                default: break
                }
            }
            if undo != nil { break }
        }
        return (undo, redo)
    }
}
