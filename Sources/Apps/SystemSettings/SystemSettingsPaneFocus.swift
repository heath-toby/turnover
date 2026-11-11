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
        // A sheet over the window (Bluetooth's Show Detail, 10 Nov 2026): Tab goes round the sheet alone, as a dialog's
        // Tab does; TurnOver stayed in the pane behind it (a tester).
        if let sheet = sheet(of: window) { return (controlsInOrder(sheet), 0) }
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
        if n >= paneStart {
            place(ring[n])
        } else if let real = AXUIElementCreateApplication(ring[n].pid).element(kAXFocusedUIElementAttribute), related(real, ring[n]) {
            // The keyboard never left the sidebar or the search field while TurnOver held a place in the pane, so
            // focusing it again changes nothing and the app says nothing: TurnOver comes back to it itself. Without
            // this, Shift Tab from the pane stayed on the held control (a tester, 10 Nov 2026).
            let obj = ObjectFactory.make(real)
            SettingsPanePlugin.focusMoved(to: obj)
            API.setFocusObject(obj, ancestors: obj.ancestors)
            Tones.focusTick()
            Speech.cancel(); Speech.speakObject(obj, reason: .focus)
        } else {
            SettingsPanePlugin.focus(ring[n])
        }
        return true
    }

    /// The sheet over the window, if one is open.
    static func sheet(of window: AXUIElement) -> AXUIElement? {
        window.elements(kAXChildrenAttribute).last { $0.role == "AXSheet" }
    }

    /// TurnOver on a control of the pane or a sheet: the keyboard focus asked for (a sheet's buttons may take it), the
    /// place held either way so Space and Return press it, the move's sound, and object navigation from there.
    /// `interrupt`: false after something just said (a sheet's text), so the control is said after it, not over it.
    static func place(_ e: AXUIElement, interrupt: Bool = true) {
        _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
        SettingsPanePlugin.holdVirtual(e, speak: interrupt, ownTab: false)
        if !interrupt { Speech.speakObject(ObjectFactory.make(e), reason: .focus) }
        Tones.focusTick()   // the move's sound, as a real focus change has (a tester, 10 Nov 2026)
        ObjectNavigator.shared.releaseHold()
        ObjectNavigator.shared.place(e)
    }

    /// Where a sheet opens: its default button, else its Done, OK, Close or Cancel, else its first control. Never a
    /// first control like Bluetooth's "Forget This Device…", which Space would press, when a safe one is there.
    static func landing(in sheet: AXUIElement) -> AXUIElement? {
        if let d = sheet.element(kAXDefaultButtonAttribute) { return d }
        let controls = controlsInOrder(sheet)
        let safe = ["Done", "OK", "Close", "Cancel"]
        return controls.first { c in safe.contains(c.string(kAXDescriptionAttribute) ?? "") || safe.contains(c.string(kAXTitleAttribute) ?? "") } ?? controls.first
    }

    /// A sheet's text as a dialog's is read when it opens ("Name, APH Mantis Q40…, Device Type, Bluetooth Device"):
    /// its static texts in order, a text inside a text with the same words said once; at most 400 characters.
    static func text(of sheet: AXUIElement) -> String {
        var out: [String] = []
        var visited = 0
        func walk(_ e: AXUIElement) {
            guard visited < 300 else { return }
            visited += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, out.last != v { out.append(v) }
            for k in e.elements(kAXChildrenAttribute) { walk(k) }
        }
        walk(sheet)
        let joined = out.joined(separator: ", ")
        return joined.count > 400 ? String(joined.prefix(400)) : joined
    }

    /// The same control, or one inside the other within a few levels (the search field's stand-in, a sidebar row).
    static func related(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        func within(_ x: AXUIElement, _ outer: AXUIElement) -> Bool {
            var p: AXUIElement? = x; var hops = 0
            while let e = p, hops < 4 { if e.isSame(outer) { return true }; p = e.element(kAXParentAttribute); hops += 1 }
            return false
        }
        return within(a, b) || within(b, a)
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
