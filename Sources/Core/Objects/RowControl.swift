// SPDX-License-Identifier: GPL-3.0-or-later
// A row that is pressed for its one control. In System Settings' Privacy & Security lists (Accessibility, Input
// Monitoring and the like) each app is a row of an outline with a switch inside it; the outline won't keep the
// focus, so TurnOver holds the place on it, and Space pressed the outline, which has no press (-25206). Object
// navigation's activate on the row tried to focus it instead: "cannot take the focus" (a tester, 13 Nov 2026,
// macOS 27.2). VoiceOver presses the row's switch. So does TurnOver now, when the row holds one toggle.
import Foundation
import ApplicationServices

enum RowControl {
    static let toggles: Set<String> = ["AXCheckBox", "AXSwitch", "AXRadioButton"]

    /// The selected row of a list, outline or table, or the element itself when it is not one.
    static func row(of e: AXUIElement) -> AXUIElement {
        guard ["AXOutline", "AXTable", "AXList"].contains(e.role) else { return e }
        return e.elements(kAXSelectedRowsAttribute).first ?? e.elements(kAXSelectedChildrenAttribute).first ?? e
    }

    /// The one toggle inside `e` (a row, a cell) that can be pressed; nil when there is none, or more than one, so a
    /// row of several controls is never guessed at. A short, bounded walk.
    static func toggle(in e: AXUIElement) -> AXUIElement? {
        var found: [AXUIElement] = []
        var stack: [(AXUIElement, Int)] = e.elements(kAXChildrenAttribute).map { ($0, 1) }
        var visited = 0
        while let (x, depth) = stack.popLast(), visited < 80 {
            visited += 1
            if toggles.contains(x.role) || x.string(kAXSubroleAttribute) == "AXSwitch" {
                if canPress(x) { found.append(x); if found.count > 1 { return nil } }
                continue
            }
            if depth < 4 { stack.append(contentsOf: x.elements(kAXChildrenAttribute).map { ($0, depth + 1) }) }
        }
        return found.first
    }

    static func canPress(_ e: AXUIElement) -> Bool {
        var acts: CFArray?
        AXUIElementCopyActionNames(e, &acts)
        return ((acts as? [String]) ?? []).contains(kAXPressAction as String)
    }

    /// Press the toggle in `e`'s selected row (or in `e`), and say its new state. False when there is none.
    static func pressToggle(in e: AXUIElement) -> Bool {
        guard !canPress(e), let t = toggle(in: row(of: e)) else { return false }
        let r = AXUIElementPerformAction(t, kAXPressAction as CFString)
        Log.io("row control: pressed the \(t.role) in a \(e.role) → \(r.rawValue)")
        guard r == .success else { return false }
        Tones.press()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Speech.speakCheckState(of: t) }
        return true
    }
}
