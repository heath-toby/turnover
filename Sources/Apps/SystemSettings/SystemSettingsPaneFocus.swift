// SPDX-License-Identifier: GPL-3.0-or-later
// Tab into System Settings' pane (10 Nov 2026, macOS 27.2, System Settings 1.0, keyboard navigation on).
//
// Observed with a script pressing Tab through the HID event tap, with TurnOver quit and no event tap at all: Tab
// goes sidebar, search field, Back, then onto the pane's own frame (an AXGroup/AXHostingView beside the splitter),
// and the next Tab back to the sidebar, never into the pane's controls. Sometimes, depending on the pane and on
// timing, it went in (Apple Account's pane did). TurnOver reads the focus faithfully, so with TurnOver Tab seemed
// to go only between the sidebar and the search field, and the frame said nothing (a tester, 10 Nov 2026).
// VoiceOver users meet this less: VoiceOver moves with its own keys.
//
// Also observed: the pane's controls take the keyboard focus when it is set through accessibility (AXFocused), and
// from there the system's own Tab goes on through the pane, VoiceOver, Zoom, Hover Text and on. So when Tab or
// Shift Tab leaves the focus on the frame, the focus is put on the pane's first control (its last for Shift Tab),
// and the system's Tab takes over again.
import Foundation
import ApplicationServices
import TurnOverAX

package enum SystemSettingsPaneFocus {
    /// Roles that take the keyboard in a pane; each is still checked for a settable AXFocused before it is chosen.
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField",
        "AXTextArea", "AXComboBox", "AXOutline", "AXTable", "AXList", "AXLink", "AXIncrementor", "AXDisclosureTriangle",
    ]

    /// The pane's frame: the hosting view beside the splitter, after it, in the window's split group.
    package static func isPaneFrame(role: String?, subrole: String?, parentRole: String?, afterSplitter: Bool) -> Bool {
        role == "AXGroup" && subrole == "AXHostingView" && parentRole == "AXSplitGroup" && afterSplitter
    }

    /// Where the keyboard really went, when Tab or Shift Tab has just left it on the pane's frame: the pane's first
    /// (or last) control, now focused. Nil leaves the report as it is.
    static func intoPane(settingsPid: pid_t) -> AXUIElement? {
        let key = InputManager.lastKeyIdentifier
        guard key == "kb:tab" || key == "kb:shift+tab", Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1.0,
              let focus = AXUIElementCreateApplication(settingsPid).element(kAXFocusedUIElementAttribute),
              let parent = focus.element(kAXParentAttribute) else { return nil }
        let siblings = parent.elements(kAXChildrenAttribute)
        let splitter = siblings.firstIndex { $0.role == "AXSplitter" }
        let mine = siblings.firstIndex { $0.isSame(focus) }
        let after = splitter.flatMap { s in mine.map { $0 > s } } ?? false
        guard isPaneFrame(role: focus.role, subrole: focus.string(kAXSubroleAttribute), parentRole: parent.role, afterSplitter: after) else { return nil }
        var controls = controlsInOrder(focus)
        if key == "kb:shift+tab" { controls.reverse() }
        for c in controls.prefix(4) {
            _ = c.set(kAXFocusedAttribute, kCFBooleanTrue)
            if let now = AXUIElementCreateApplication(settingsPid).element(kAXFocusedUIElementAttribute), now.isSame(c) {
                Log.io("system settings: \(key == "kb:tab" ? "Tab" : "Shift+Tab") left the focus on the pane's frame; into its \(c.role) (\(controls.count) controls)")
                return c
            }
        }
        Log.io("system settings: Tab on the pane's frame, and none of its \(controls.count) controls took the focus")
        return nil
    }

    /// The pane's controls in reading order, bounded: a pane has tens of controls, never thousands.
    static func controlsInOrder(_ root: AXUIElement, maxVisited: Int = 600) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var visited = 0
        func walk(_ e: AXUIElement) {
            guard visited < maxVisited else { return }
            visited += 1
            let role = e.role
            if controlRoles.contains(role), (e.attr(kAXEnabledAttribute) as? Bool) != false, isFocusable(e) {
                out.append(e)
                if ["AXOutline", "AXTable", "AXList"].contains(role) { return }   // a list's rows are its own to move
            }
            for k in e.elements(kAXChildrenAttribute) { walk(k) }
        }
        walk(root)
        return out
    }

    private static func isFocusable(_ e: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success && settable.boolValue
    }
}
