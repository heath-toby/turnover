// SPDX-License-Identifier: GPL-3.0-or-later
// Toolbars are one stop for Tab, and the arrows move along them (a tester, 12 Nov 2026: "I'd rather have one formula,
// and personally, if it calls toolbar, we use arrows to navigate"). Before this, Messages' Tab went through each of its
// toolbar's buttons in turn, while other windows' toolbars were not reached by Tab at all. As on Windows: Tab lands on
// the toolbar (on the button last used there, else its first), Left and Right go from button to button, Home and End
// to its ends, and Tab and Shift Tab leave it for the window's next or previous control.
//
// A toolbar's items are what sits in its strip: an iPad app puts some of its toolbar's buttons in the content beside
// the toolbar (Messages' Conversation Details and FaceTime sit in the same strip, outside the AXToolbar). A text field
// in a toolbar (a search field, Safari's address field) stays a Tab stop of its own: the arrows there are the field's.
import Foundation
import AppKit
import ApplicationServices

extension SettingsPanePlugin {
    private static let toolbarLock = NSLock()
    private static var _inToolbar = false
    /// TurnOver's focus is on a toolbar item (not a text field): the arrows and Tab are the toolbar's (any thread).
    static var inToolbar: Bool { toolbarLock.lock(); defer { toolbarLock.unlock() }; return _inToolbar }

    /// The item last landed on in each toolbar, latest first: Tab comes back to it.
    static var lastToolbarItem: [(toolbar: AXUIElement, item: AXUIElement)] = []

    /// Kinds that take typing: a stop of their own, with arrows of their own.
    static func typesText(_ e: AXUIElement) -> Bool {
        ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"].contains(e.role) || e.string(kAXSubroleAttribute) == "AXSearchField"
    }

    /// The window's toolbar (its strip on screen), if it has one.
    static func toolbar(of window: AXUIElement) -> (AXUIElement, CGRect)? {
        for k in window.elements(kAXChildrenAttribute) where k.role == "AXToolbar" {
            if let f = TurnOverObject.frame(k), f.width > 0, f.height > 0 { return (k, f) }
        }
        return nil
    }

    /// Whether a control sits in the toolbar's strip: inside the AXToolbar, or its middle within the strip.
    static func inStrip(_ f: CGRect, of strip: CGRect) -> Bool {
        strip.insetBy(dx: -1, dy: -1).contains(CGPoint(x: f.midX, y: f.midY)) && f.height <= strip.height + 2
    }

    /// Which of the window's controls (as found by `controls(in:)`'s walk) are toolbar items, left to right.
    static func toolbarMembers(_ found: [(AXUIElement, CGRect)], strip: CGRect) -> [(AXUIElement, CGRect)] {
        found.filter { inStrip($0.1, of: strip) && !typesText($0.0) && !inContent($0.0) }.sorted { $0.1.minX < $1.1.minX }
    }

    /// In a list, a scroll area or a split pane, outside the toolbar itself: the window's content, which runs up under a
    /// see-through toolbar (Mail's sidebar header, Mailboxes and All Inboxes, sat in the toolbar's strip, 12 Nov 2026).
    static func inContent(_ e: AXUIElement) -> Bool {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 12 {
            let r = x.role
            if r == "AXToolbar" || r == "AXWindow" { return false }
            if ["AXScrollArea", "AXOutline", "AXTable", "AXList", "AXSplitGroup", "AXRow", "AXWebArea"].contains(r) { return true }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// The toolbar's items in the window `e` is in, left to right, and the toolbar.
    static func toolbarItems(around e: AXUIElement) -> (toolbar: AXUIElement, items: [AXUIElement])? {
        guard let w = windowOf(e), let (tb, strip) = toolbar(of: w) else { return nil }
        var found: [(AXUIElement, CGRect)] = []
        var visited = 0
        func walk(_ x: AXUIElement, _ depth: Int) {
            guard visited < 400, depth < 10 else { return }
            visited += 1
            let role = x.role
            if role == "AXScrollBar" || ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(x.string(kAXSubroleAttribute) ?? "") { return }
            if let f = TurnOverObject.frame(x) {
                // Only what overlaps the strip can hold an item of it.
                if f.width > 0, f.height > 0, !f.intersects(strip) { return }
                if (controlRoles.contains(role) || isPressableItem(x)), (x.attr(kAXEnabledAttribute) as? Bool) != false, f.width > 0, f.height > 0 {
                    found.append((x, f))
                    if ["AXTable", "AXOutline", "AXList", "AXTextArea", "AXWebArea", "AXGrid"].contains(role) { return }
                }
            }
            for k in x.elements(kAXChildrenAttribute) { walk(k, depth + 1) }
        }
        walk(w, 0)
        let items = toolbarMembers(found, strip: strip).map { $0.0 }
        return items.isEmpty ? nil : (tb, items)
    }

    /// Where Tab lands in a toolbar: the item last used there, else its first.
    static func toolbarStop(_ toolbar: AXUIElement, _ items: [AXUIElement]) -> AXUIElement? {
        if let last = lastToolbarItem.first(where: { $0.toolbar.isSame(toolbar) })?.item, let hit = items.first(where: { $0.isSame(last) }) { return hit }
        return items.first
    }

    /// One stop for the toolbar among a window's controls: its other items are dropped (`controls(in:)`).
    static func collapsingToolbar(_ found: [(AXUIElement, CGRect)], in window: AXUIElement) -> [(AXUIElement, CGRect)] {
        guard let (tb, strip) = toolbar(of: window) else { return found }
        let members = toolbarMembers(found, strip: strip)
        guard members.count > 1, let stop = toolbarStop(tb, members.map { $0.0 }) else { return found }
        let drop = members.map { $0.0 }.filter { !CFEqual($0, stop) }
        // Placed where the toolbar starts, whichever item stands for it: a search field at its end comes after it.
        return found.filter { x in !drop.contains { CFEqual($0, x.0) } }.map { CFEqual($0.0, stop) ? ($0.0, members[0].1) : $0 }
    }

    /// The focus moved (or TurnOver holds a place): whether it is on a toolbar item, and that item is remembered.
    /// True when it came onto a toolbar item from elsewhere. A place TurnOver holds isn't said with the focus's
    /// ancestors, so "tool bar" is said by the caller (Messages' toolbar, 12 Nov 2026).
    @discardableResult
    static func noteToolbar(_ e: AXUIElement) -> Bool {
        var on = false
        if !typesText(e), controlRoles.contains(e.role) || isPressableItem(e), let w = windowOf(e), let (tb, strip) = toolbar(of: w),
           let f = TurnOverObject.frame(e), inStrip(f, of: strip), !inContent(e) {
            on = true
            lastToolbarItem.removeAll { $0.toolbar.isSame(tb) || $0.toolbar.role == "?" }
            lastToolbarItem.insert((tb, e), at: 0)
            if lastToolbarItem.count > 12 { lastToolbarItem.removeLast() }
        }
        toolbarLock.lock(); let was = _inToolbar; _inToolbar = on; toolbarLock.unlock()
        if was != on { Log.io("toolbar: \(on ? "on a toolbar item; the arrows go along it" : "off the toolbar")") }
        return on && !was
    }

    /// Left, Right, Home or End along the toolbar.
    func toolbarMove(_ g: KeyboardGesture, by delta: Int?, toEnd last: Bool = false) {
        guard let cur = API.focusObject?.element, let (_, items) = Self.toolbarItems(around: cur) else { g.send(); return }
        let i = items.firstIndex { $0.isSame(cur) }
        let j: Int
        if let d = delta {
            guard let i else { g.send(); return }
            j = i + d
            guard items.indices.contains(j) else { Tones.edge(); return }
        } else {
            j = last ? items.count - 1 : 0
            if let i, i == j { Tones.edge(); return }
        }
        Log.io("toolbar: \(delta.map { $0 > 0 ? "Right" : "Left" } ?? (last ? "End" : "Home")) to item \(j + 1) of \(items.count)")
        Self.focus(items[j])
    }

    /// Tab or Shift Tab on a toolbar item: on to the window's next or previous control outside the toolbar.
    func toolbarLeave(_ g: KeyboardGesture, forward: Bool) {
        guard let cur = API.focusObject?.element, let scope = Self.scopeOf(cur) else { g.send(); return }
        let all = Self.controls(in: scope, toolbars: true, unfocusable: true)
        // The toolbar's stop is the item just used (remembered as the focus landed).
        guard let here = all.firstIndex(where: { $0.isSame(cur) }), all.count > 1 else { g.send(); return }
        let n = ((forward ? here + 1 : here - 1) + all.count) % all.count
        Log.io("toolbar: \(forward ? "Tab" : "Shift Tab") leaves the toolbar for \(all[n].role) \(n + 1) of \(all.count)")
        Self.trapList = (scope, all, Date())
        if let (rows, _, _, container) = Self.rowList(of: all[n]) {
            let back = Self.lastRow.first { $0.container.isSame(container) }.flatMap { r in rows.firstIndex { $0.isSame(r.row) } }
            Self.landInRowList(rows, at: back ?? 0, entering: true)
            Self.setTrapState(for: rows[0])
            return
        }
        Self.focus(all[n], byTrap: Self.inTrapZone)
        Self.setTrapState(for: all[n])
    }


    // MARK: Apps whose own Tab skips the toolbar

    /// Where an app's own Tab was seen to go round past the toolbar (Mail's went from the message's Attachments
    /// button to the mailboxes, and its toolbar was never reached, 12 Nov 2026): the control it left from, and which
    /// way. From then on Tab there goes to the toolbar, as on Windows, where a toolbar is in the Tab order.
    static var toolbarSkips: [(window: AXUIElement, from: AXUIElement, forward: Bool)] = []

    static func skipsToolbar(from e: AXUIElement, forward: Bool) -> Bool {
        toolbarSkips.removeAll { $0.window.role == "?" || $0.from.role == "?" }
        return toolbarSkips.contains { $0.forward == forward && $0.from.isSame(e) }
    }

    /// An app's own Tab or Shift Tab: if it went round the window and passed over the toolbar, TurnOver goes to the
    /// toolbar instead, and remembers the place it went round from.
    static func watchToolbarSkip(_ g: KeyboardGesture) {
        // From web content too (Mail's attachment button in the message), but not from text, where Tab types.
        guard g.keyName == "tab", g.modifiers.subtracting(.shift).isEmpty, !inToolbar, let before = API.focusObject?.element,
              !["AXTextArea", "AXTextField", "AXWebArea"].contains(before.role), let window = scopeOf(before), window.role == "AXWindow", toolbar(of: window) != nil else { return }
        let forward = !g.modifiers.contains(.shift)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard let after = API.focusObject?.element, !after.isSame(before), after.pid == before.pid, !inToolbar,
                  !isInWeb(after), scopeOf(after).map({ $0.isSame(window) }) ?? false else { return }
            let all = controls(in: window, toolbars: true, unfocusable: true)
            guard let (tb, _) = toolbar(of: window), let items = toolbarItems(around: after)?.items,
                  let stop = toolbarStop(tb, items), let t = all.firstIndex(where: { $0.isSame(stop) }),
                  let a = place(before, in: all), let b = place(after, in: all) else { Log.io("toolbar: Tab's way round not placed"); return }
            // The places passed over on the way, going round as Tab does.
            let n = all.count
            var k = a, passed = false
            for _ in 0..<n { k = (k + (forward ? 1 : -1) + n) % n; if k == b { break }; if k == t { passed = true; break } }
            guard passed else { return }
            Log.io("toolbar: the app's \(forward ? "Tab" : "Shift Tab") went round past the toolbar; to the toolbar, and remembered")
            toolbarSkips.removeAll { $0.from.isSame(before) && $0.forward == forward }
            toolbarSkips.append((window, before, forward))
            if toolbarSkips.count > 24 { toolbarSkips.removeFirst() }
            Speech.cancel()
            focus(stop)
        }
    }

    /// Where a control sits among the window's stops: itself, or the stop holding it (a message's button is in its
    /// web area, one stop).
    static func place(_ e: AXUIElement, in all: [AXUIElement]) -> Int? {
        var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 15 { if let i = all.firstIndex(where: { $0.isSame(y) }) { return i }; x = y.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    /// Tab where the app's own would skip the toolbar: to the toolbar.
    func toolbarEnter(_ g: KeyboardGesture) {
        guard let cur = API.focusObject?.element, let (tb, items) = Self.toolbarItems(around: cur), let stop = Self.toolbarStop(tb, items) else { g.send(); return }
        Log.io("toolbar: Tab here goes round past the toolbar; to it")
        Self.focus(stop)
    }

    func registerToolbarScripts() {
        InputManager.passThroughWatchers.append(Self.watchToolbarSkip)
        for (name, key, forward) in [("toolbar_enter", "kb:tab", true), ("toolbar_enterBack", "kb:shift+tab", false)] {
            script(name, forward ? String(localized: "Where the app's Tab would skip the toolbar: to the toolbar", comment: "A command, as the key list and keyboard help say it")
                                 : String(localized: "Where the app's Shift Tab would skip the toolbar: to the toolbar", comment: "A command, as the key list and keyboard help say it"),
                   gestures: [key], category: "Settings") { [weak self] g in self?.toolbarEnter(g) }.isAvailable = {
                !Self.inToolbar && (API.focusObject.map { Self.skipsToolbar(from: $0.element, forward: forward) } ?? false)
            }
        }
        // Still on the item noted: an app module moving TurnOver's focus itself (Messages' parts) sends no focus news.
        let along = { Self.inToolbar && !AXHandler.shared.isMenuOpen && !TurnOverMenu.shared.isOpen
            && (Self.lastToolbarItem.first.map { t in API.focusObject?.isSameElement(as: t.item) ?? false } ?? false) }
        script("toolbar_right", String(localized: "On a toolbar: the next item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow"], category: "Settings") { [weak self] g in self?.toolbarMove(g, by: 1) }.isAvailable = along
        script("toolbar_left", String(localized: "On a toolbar: the previous item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow"], category: "Settings") { [weak self] g in self?.toolbarMove(g, by: -1) }.isAvailable = along
        script("toolbar_first", String(localized: "On a toolbar: its first item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:home"], category: "Settings") { [weak self] g in self?.toolbarMove(g, by: nil, toEnd: false) }.isAvailable = along
        script("toolbar_last", String(localized: "On a toolbar: its last item", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:end"], category: "Settings") { [weak self] g in self?.toolbarMove(g, by: nil, toEnd: true) }.isAvailable = along
        // An app whose module orders Tab itself (Messages' parts, which make the toolbar one stop too) keeps its Tab.
        func leaveOrModule(_ g: KeyboardGesture, forward: Bool) {
            if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(for: g) {
                Log.io("toolbar: the app's module has \(s.name) for this key"); s.handler(g); return
            }
            toolbarLeave(g, forward: forward)
        }
        script("toolbar_next", String(localized: "On a toolbar: Tab leaves it for the next control", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Settings") { g in leaveOrModule(g, forward: true) }.isAvailable = along
        script("toolbar_previous", String(localized: "On a toolbar: Shift Tab leaves it for the previous control", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Settings") { g in leaveOrModule(g, forward: false) }.isAvailable = along
    }
}
