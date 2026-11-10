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
// Then the cause (10 Nov 2026, same script): with VoiceOver running, System Settings puts Back and the pane in its
// Tab order (search field, Back, VoiceOver, Zoom, Hover Text...); with no screen reader running it goes only sidebar,
// search field, sidebar, and Tab on a control inside the pane goes to the sidebar. TurnOver turns VoiceOver off, so
// System Settings always behaved as with no screen reader. Nor do the pane's controls take the keyboard with VoiceOver
// off: they say AXFocused can't be set, and setting it answers success and changes nothing (with VoiceOver on, it
// works). AXPress works either way.
//
// So in System Settings' main window, Tab and Shift Tab are TurnOver's: round the sidebar, the search field and the
// pane's controls in the pane's own order. The sidebar and the search field get the keyboard focus; on a pane control
// TurnOver holds its place, as in other settings windows that refuse the focus (SettingsPanePlugin.holdVirtual), and
// Space and Return press it.
import Foundation
import ApplicationServices
import TurnOverAX

package enum SystemSettingsPaneFocus {
    /// Roles that are stops of Tab's round in a pane (enabled ones; not a scroll bar's parts).
    static let controlRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXTextField",
        "AXTextArea", "AXComboBox", "AXOutline", "AXTable", "AXList", "AXLink", "AXIncrementor", "AXDisclosureTriangle",
    ]

    /// The pane's frame: the hosting view beside the splitter, after it, in the window's split group.
    package static func isPaneFrame(role: String?, subrole: String?, parentRole: String?, afterSplitter: Bool) -> Bool {
        role == "AXGroup" && subrole == "AXHostingView" && parentRole == "AXSplitGroup" && afterSplitter
    }

    /// Tab's round in the window: the sidebar, the search field, then the pane's controls; empty if the window isn't
    /// laid out as System Settings' main window is.
    static func ring(in window: AXUIElement) -> (stops: [AXUIElement], paneStart: Int) {
        guard let split = window.firstDescendant(role: "AXSplitGroup", maxVisited: 40) else { return ([], 0) }
        let parts = split.elements(kAXChildrenAttribute)
        guard let splitter = parts.firstIndex(where: { $0.role == "AXSplitter" }) else { return ([], 0) }
        var ring: [AXUIElement] = []
        for part in parts[..<splitter] {
            if let outline = part.firstDescendant(role: "AXOutline", maxVisited: 20) { ring.append(outline) }
            else if let field = part.firstDescendant(role: "AXTextField", maxVisited: 20) { ring.append(field) }
        }
        let paneStart = ring.count
        for part in parts[(splitter + 1)...] where isPaneFrame(role: part.role, subrole: part.string(kAXSubroleAttribute), parentRole: "AXSplitGroup", afterSplitter: true) {
            ring += controlsInOrder(part)
        }
        return (ring, paneStart)
    }

    /// Tab (forward) or Shift Tab from the focus: the next stop of the round, focused. False when the window isn't
    /// System Settings' main window as known, so the key goes to the app.
    static func tab(forward: Bool, from focus: AXUIElement, window: AXUIElement) -> Bool {
        let (ring, paneStart) = ring(in: window)
        guard ring.count > 1 else { return false }
        // Where the focus is: a stop itself, or inside one (a row of the sidebar).
        var here: Int?
        var p: AXUIElement? = focus; var hops = 0
        while let x = p, here == nil, hops < 8 { here = ring.firstIndex { $0.isSame(x) }; p = x.element(kAXParentAttribute); hops += 1 }
        let n = here.map { (forward ? $0 + 1 : $0 - 1 + ring.count) % ring.count } ?? (forward ? 0 : ring.count - 1)
        Log.io("system settings: \(forward ? "Tab" : "Shift+Tab") to stop \(n + 1) of \(ring.count), \(ring[n].role)")
        if n >= paneStart { SettingsPanePlugin.holdVirtual(ring[n], ownTab: false) } else { SettingsPanePlugin.focus(ring[n]) }
        return true
    }

    /// The pane's controls in reading order, bounded: a pane has tens of controls, never thousands.
    static func controlsInOrder(_ root: AXUIElement, maxVisited: Int = 600) -> [AXUIElement] {
        var out: [AXUIElement] = []
        var visited = 0
        func walk(_ e: AXUIElement) {
            guard visited < maxVisited else { return }
            visited += 1
            let role = e.role
            if role == "AXScrollBar" { return }
            if controlRoles.contains(role), (e.attr(kAXEnabledAttribute) as? Bool) != false {
                out.append(e)
                if ["AXOutline", "AXTable", "AXList"].contains(role) { return }   // a list's rows are its own to move
            }
            for k in e.elements(kAXChildrenAttribute) { walk(k) }
        }
        walk(root)
        return out
    }
}
