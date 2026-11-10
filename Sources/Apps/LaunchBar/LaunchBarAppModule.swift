// SPDX-License-Identifier: GPL-3.0-or-later
// LaunchBar (Objective Development, 6.24; observed 10 Nov 2026 on macOS 27.2 with a script and TurnOver's log).
//
// LaunchBar's bar is a window (AXUnknown, subrole AXSystemDialog) holding one AXCell, and that cell keeps the focus
// the whole time. Typing, the arrows, Right and Left into and out of an item, and Control Tab change which item is
// chosen by renaming the cell ("Mail, Application", then "Safari, Application, contains 6 items"), each with an
// AXTitleChanged, and an AXSelectedRowsChanged on a table the window doesn't list as a child. VoiceOver reads the
// new name. TurnOver heard the name changes but compared them with the name it had kept from the focus, the same
// each time, and said nothing; nor was the focus itself said as the bar opened (a tester, 10 Nov 2026).
//
// The title-change notification arrives before the new title, and the new title can come much later or not at all
// (with VoiceOver off, 10 Nov 2026: the item before was read, and half the moves were missed even waiting 650 ms).
// What does arrive on time is AXSelectedRowsChanged on LaunchBar's list (a table the window doesn't list, with no
// focus; its rows say only "Table View Cell"): by then the focused cell's title is the new item, every move checked.
// So the item is said from the list's selection change (listSelectionChanged), and the cell's own name changes are
// left unsaid.
//
// The shortcut menu (About, Preferences, Quit; VoiceOver opens it with VO-Shift-M) belongs to the bar's window, an
// AXUnknown with AXShowMenu; the cell has only AXPress, so TurnOver's own way right-clicked the cell and nothing
// opened. AXShowMenu on the window opens it, answering -25204 (cannot complete) because the menu runs while the call
// waits; the menu's AXMenuOpened arrives as usual (10 Nov 2026).
//
// LaunchBar runs as an accessory app and never comes forward, so TurnOver watches it from the start
// (AXHandler.launcherPanels).
import Foundation
import ApplicationServices
import TurnOverAX

final class LaunchBarAppModule: AppModule {
    static let bundleID = "at.obdev.LaunchBar"
    /// The last title said, and when: the focus and the list's first selection arrive together with the same title.
    private var lastSaid: (title: String, at: Date)?

    override func handleEvent(_ event: Event, next: () -> Void) {
        guard event.obj.pid == pid, event.obj.axRole == "AXCell" else { next(); return }
        switch event.kind {
        case .gainFocus: sayCell(opened: true)
        case .nameChange: return   // late or stale; the list's selection says the item (above)
        default: next()
        }
    }

    override func showContextMenu() -> Bool {
        guard let cell = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), cell.role == "AXCell",
              let window = cell.element(kAXWindowAttribute) ?? cell.element(kAXParentAttribute) else { return false }
        var acts: CFArray?
        guard AXUIElementCopyActionNames(window, &acts) == .success, ((acts as? [String]) ?? []).contains("AXShowMenu") else { return false }
        TurnOverObject.contextMenuRequestedAt = Date()
        AXUIElementSetMessagingTimeout(window, 0.3)   // the call waits while the menu runs: never long on main
        let r = AXUIElementPerformAction(window, "AXShowMenu" as CFString)
        AXUIElementSetMessagingTimeout(window, 0)
        Log.io("launchbar: the bar's menu → \(r.rawValue)")
        return true
    }

    override func listSelectionChanged(_ list: AXUIElement) -> Bool {
        // With the bar's menu open, the arrows move in the menu and LaunchBar still reports its list's selection
        // each time: read, it talked over every menu item (a tester, 10 Nov 2026). The bar is read once the menu
        // closes (its focus comes back).
        if AXHandler.shared.isMenuOpen { return true }
        sayCell(opened: false)
        return true
    }

    /// Says the focused cell's title, LaunchBar's chosen item, unless it was just said.
    private func sayCell(opened: Bool) {
        guard let cell = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), cell.role == "AXCell" else { return }
        let title = cell.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return }
        if let last = lastSaid, last.title == title, Date().timeIntervalSince(last.at) < 0.4 { return }
        lastSaid = (title, Date())
        TurnOverObject.lastName = (cell, title)
        Log.io("launchbar: \(opened ? "opened" : "item"), \(title.count) characters")
        Speech.cancel()
        Speech.speakMessage(title)
    }
}
