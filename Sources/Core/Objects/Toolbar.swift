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

    /// Where the focus was before it came onto a toolbar, and whether Tab (true) or Shift Tab (false) brought it.
    static var lastOffToolbar: AXUIElement?
    static var enteredFrom: (from: AXUIElement?, forward: Bool?) = (nil, nil)

    /// The item last landed on in each toolbar, latest first: Tab comes back to it.
    static var lastToolbarItem: [(toolbar: AXUIElement, item: AXUIElement)] = []

    /// Kinds that take typing: a stop of their own, with arrows of their own.
    static func typesText(_ e: AXUIElement) -> Bool {
        ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"].contains(e.role) || e.string(kAXSubroleAttribute) == "AXSearchField"
    }
    /// Kinds whose arrows are their own (a slider's value, a stepper, a date): a stop of their own too (a review,
    /// 13 Nov 2026: a toolbar's volume slider lost its arrows to the toolbar).
    static func ownArrows(_ e: AXUIElement) -> Bool {
        typesText(e) || ["AXSlider", "AXIncrementor", "AXDateField", "AXColorWell"].contains(e.role)
    }

    /// Toolbars an app's module names that aren't marked as one, by the app's bundle: for a window, each container
    /// and the strip its items fill (Mail's message header, bin to Attachments, a row of buttons the tester heard as a
    /// toolbar, 13 Nov 2026). Asked at most once a second per window.
    static var namedToolbars: [String: (AXUIElement) -> [(AXUIElement, CGRect)]] = [:]
    private static var namedFound: (window: AXUIElement, at: Date, list: [(AXUIElement, CGRect)])?
    /// When `namedFound` was last asked for and still stood (isToolbar trusts it for five seconds after).
    private static var namedConfirmedAt = Date.distantPast
    /// Each named toolbar's container's frame when `namedFound` was made: unmoved, its strip still stands.
    private static var namedContainerFrames: [CGRect?] = []
    static func named(in window: AXUIElement) -> [(AXUIElement, CGRect)] {
        guard let b = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier, let f = namedToolbars[b] else { return [] }
        // Kept a second, or up to half a minute while the app says nothing of its controls changing (as the Tab trap's
        // list, listStillGood): it was asked again on every focus move (a review, 13 Nov 2026).
        // (The strips are on-screen frames: a window moved or a header scrolled, which no structure news says, is
        // asked again.)
        if let c = namedFound, c.window.isSame(window) {
            let age = Date().timeIntervalSince(c.at)
            if age < 1 || age < 30 && AXHandler.shared.observers[window.pid] != nil && (AXHandler.shared.lastStructureAt[window.pid] ?? .distantPast) < c.at
                && c.list.map({ TurnOverObject.frame($0.0) }) == namedContainerFrames {
                namedConfirmedAt = Date()
                return c.list
            }
        }
        let at = Date()
        let list = f(window)
        namedContainerFrames = list.map { TurnOverObject.frame($0.0) }
        namedFound = (window, at, list)
        namedConfirmedAt = at
        return list
    }

    /// One of an app's named toolbars (namedToolbars), as last found.
    static func isNamed(_ e: AXUIElement) -> Bool {
        namedFound.map { c in c.list.contains { $0.0.isSame(e) } } ?? false
    }

    /// A toolbar: the window's own, or a group that calls itself one (Outlook's two groups titled "Toolbar", 13 Nov 2026),
    /// or one an app's module names.
    static func isToolbar(_ e: AXUIElement, role known: String? = nil) -> Bool {
        let r = known ?? e.role
        if r == "AXToolbar" { return true }
        if let c = namedFound, Date().timeIntervalSince(namedConfirmedAt) < 5, c.list.contains(where: { $0.0.isSame(e) }) { return true }
        guard r == "AXGroup" else { return false }
        let name = ((e.string(kAXTitleAttribute) ?? "") + " " + (e.string(kAXDescriptionAttribute) ?? "")).lowercased()
        return name.trimmingCharacters(in: .whitespaces) == "toolbar" || name.hasSuffix(" toolbar") || name.hasSuffix("tool bar")
    }

    /// The window's toolbars, with their strips on screen: its own first.
    static func toolbars(of window: AXUIElement) -> [(AXUIElement, CGRect)] {
        var out: [(AXUIElement, CGRect)] = []
        for k in window.elements(kAXChildrenAttribute) where isToolbar(k) {
            if let f = TurnOverObject.frame(k), f.width > 0, f.height > 0 { out.append((k, f)) }
        }
        out += named(in: window)
        return out.sorted { a, b in (a.0.role == "AXToolbar") && b.0.role != "AXToolbar" }
    }
    static func toolbar(of window: AXUIElement) -> (AXUIElement, CGRect)? { toolbars(of: window).first }

    /// The toolbar a control is an item of.
    static func toolbarFor(_ e: AXUIElement, in w: AXUIElement) -> (AXUIElement, CGRect)? {
        let namedList = named(in: w)   // an app's named toolbars known first: inContent stops at them
        if isToolbar(e), let f = TurnOverObject.frame(e) { return (e, f) }
        guard let f = TurnOverObject.frame(e) else { return nil }
        // A named toolbar's own row first: scrolled up under the window's toolbar, it is still its own.
        if let parent = e.element(kAXParentAttribute), let n = namedList.first(where: { $0.0.isSame(parent) }) { return inStrip(f, of: n.1) ? n : nil }
        guard !inContent(e) else { return nil }
        return toolbars(of: w).first { inStrip(f, of: $0.1) }
    }

    /// Whether a control sits in the toolbar's strip: inside the AXToolbar, or its middle within the strip.
    package static func inStrip(_ f: CGRect, of strip: CGRect) -> Bool {
        strip.insetBy(dx: -1, dy: -1).contains(CGPoint(x: f.midX, y: f.midY)) && f.height <= strip.height + 2
    }

    /// Which of the window's controls (as found by `controls(in:)`'s walk) are toolbar items, left to right.
    static func toolbarMembers(_ found: [(AXUIElement, CGRect)], strip: CGRect) -> [(AXUIElement, CGRect)] {
        found.filter { inStrip($0.1, of: strip) && !ownArrows($0.0) && !inContent($0.0) }.sorted { $0.1.minX < $1.1.minX }
    }

    /// In a list, a scroll area or a split pane, outside the toolbar itself: the window's content, which runs up under a
    /// see-through toolbar (Mail's sidebar header, Mailboxes and All Inboxes, sat in the toolbar's strip, 12 Nov 2026).
    static func inContent(_ e: AXUIElement) -> Bool {
        // The focus's chain, read once per focus move, answers for the same twelve parents (a review, 13 Nov 2026).
        if let c = FocusChain.of(e) {
            for i in 1..<min(13, c.elements.count) {
                let r = c.roles[i]
                if r == "AXWindow" { return false }
                if isToolbar(c.elements[i], role: r) {
                    // An app's named toolbar holds its own row only, a direct child: Mail's is the whole message, and
                    // its banner's buttons, scrolled up under the window's see-through toolbar, were counted toolbar
                    // items (a tester, 13 Nov 2026). Anything deeper in it is the content it is.
                    if !isNamed(c.elements[i]) || i == 1 { return false }
                    continue
                }
                if ["AXScrollArea", "AXOutline", "AXTable", "AXList", "AXSplitGroup", "AXRow", "AXWebArea"].contains(r) { return true }
            }
            return false
        }
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 12 {
            let r = x.role
            if r == "AXWindow" { return false }
            if isToolbar(x) { if !isNamed(x) || hops == 0 { return false }; p = x.element(kAXParentAttribute); hops += 1; continue }
            if ["AXScrollArea", "AXOutline", "AXTable", "AXList", "AXSplitGroup", "AXRow", "AXWebArea"].contains(r) { return true }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return false
    }

    /// The toolbar's items in the window `e` is in, left to right, and the toolbar.
    static func toolbarItems(around e: AXUIElement) -> (toolbar: AXUIElement, items: [AXUIElement])? {
        guard let w = windowOf(e), let (tb, strip) = toolbarFor(e, in: w) else { return nil }
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
        var out = found
        for (tb, strip) in toolbars(of: window) {
            let members = toolbarMembers(out, strip: strip)
            guard members.count > 1, let stop = toolbarStop(tb, members.map { $0.0 }) else { continue }
            let drop = members.map { $0.0 }.filter { !CFEqual($0, stop) }
            // Placed where the toolbar starts, whichever item stands for it: a search field at its end comes after it.
            out = out.filter { x in !drop.contains { CFEqual($0, x.0) } }.map { CFEqual($0.0, stop) ? ($0.0, members[0].1) : $0 }
        }
        return out
    }

    /// The focus moved (or TurnOver holds a place): whether it is on a toolbar item, and that item is remembered.
    /// True when it came onto a toolbar item from elsewhere. A place TurnOver holds isn't said with the focus's
    /// ancestors, so "tool bar" is said by the caller (Messages' toolbar, 12 Nov 2026).
    @discardableResult
    static func noteToolbar(_ e: AXUIElement) -> Bool {
        var on = false
        // Not a settings window's pane buttons: their arrows and Tab are PreferenceTab's (a review, 13 Nov 2026).
        if !ownArrows(e), controlRoles.contains(e.role) || isPressableItem(e), !PreferenceTab.isPreferenceTab(e), let w = windowOf(e), let (tb, _) = toolbarFor(e, in: w) {
            on = true
            lastToolbarItem.removeAll { $0.toolbar.isSame(tb) || $0.toolbar.role == "?" }
            lastToolbarItem.insert((tb, e), at: 0)
            if lastToolbarItem.count > 12 { lastToolbarItem.removeLast() }
        }
        toolbarLock.lock(); let was = _inToolbar; _inToolbar = on; toolbarLock.unlock()
        if !on { lastOffToolbar = e }
        else if !was { enteredFrom = (lastOffToolbar, InputManager.lastKeyIdentifier == "kb:shift+tab" ? false : InputManager.lastKeyIdentifier == "kb:tab" ? true : nil) }
        if was != on { Log.io("toolbar: \(on ? "on a toolbar item; the arrows go along it" : "off the toolbar")") }
        return on && !was
    }

    /// Left, Right, Home or End along the toolbar.
    func toolbarMove(_ g: KeyboardGesture, by delta: Int?, toEnd last: Bool = false) {
        guard let cur = API.focusObject?.element, let (_, items) = Self.toolbarItems(around: cur) else {
            Log.io("toolbar: no items found around the focus; the key goes to the app"); g.send(); return
        }
        let i = items.firstIndex { $0.isSame(cur) }
        if i == nil { Log.io("toolbar: the focus isn't among the \(items.count) items") }
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
        // The window's stops from a moment ago where they're still the window's (a walk costs 100 ms or more).
        var all: [AXUIElement]
        if let c = Self.trapList, c.window.isSame(scope), Self.listStillGood(c.at, pid: scope.pid), !c.controls.contains(where: { $0.role == "?" }) { all = c.controls }
        else { all = Self.controls(in: scope, toolbars: true, unfocusable: true) }
        // The toolbar's stop is the item just used (remembered as the focus landed).
        // The item itself, or whichever of the toolbar's items stands for it (Font Book's Hide Sidebar was missing from
        // the window's list, and Tab fell through to the app's own, on along the toolbar, 13 Nov 2026).
        var at = all.firstIndex(where: { $0.isSame(cur) })
        if at == nil { let items = Self.toolbarItems(around: cur)?.items ?? []; at = all.firstIndex(where: { a in items.contains { $0.isSame(a) } }) }
        guard let here = at, all.count > 1 else {
            Log.io("toolbar: the item isn't among the window's \(all.count) stops; Tab sent on"); g.send(); return
        }
        var n = ((forward ? here + 1 : here - 1) + all.count) % all.count
        // Not back where the same key came from: Safari's own Tab goes from the address field into the toolbar, and
        // Tab from the toolbar went straight back to the field, never reaching the page (13 Nov 2026).
        if Self.enteredFrom.forward == forward, let from = Self.enteredFrom.from, all[n].isSame(from), all.count > 2 {
            n = ((forward ? n + 1 : n - 1) + all.count) % all.count
        }
        Log.io("toolbar: \(forward ? "Tab" : "Shift Tab") leaves the toolbar for \(all[n].role) \(n + 1) of \(all.count)")
        Self.trapList = (scope, all, Date())
        if let (rows, _, _, container) = Self.rowList(of: all[n]) {
            let back = Self.lastRow.first { $0.container.isSame(container) }.flatMap { r in rows.firstIndex { $0.isSame(r.row) } }
            Self.landInRowList(rows, at: back ?? 0, entering: true)
            Self.setTrapState(for: rows[0])
            return
        }
        // Counted towards a short loop as the app's own landings are: Freeform's Tab went sidebar, toolbar, sidebar
        // (its own Tab from the sidebar back to the toolbar, TurnOver's from the toolbar on to the sidebar) and never
        // reached the board (12 Nov 2026). The trap's move notes it itself (focus): noted here too, each landing went
        // in twice, and the loop of two never showed (a review, 14 Nov 2026).
        let trap = Self.inTrapZone || Self.inLoopWindow(all[n])
        if !trap { Self.noteLanding(all[n], forward: forward) }
        Self.focus(all[n], byTrap: trap)
        Self.setTrapState(for: all[n])
    }


    // MARK: Apps whose own Tab skips the toolbar

    /// Where an app's own Tab was seen to go round past the toolbar (Mail's went from the message's Attachments
    /// button to the mailboxes, and its toolbar was never reached, 12 Nov 2026): the control it left from, and which
    /// way. From then on Tab there goes to the toolbar, as on Windows, where a toolbar is in the Tab order.
    static var toolbarSkips: [(window: AXUIElement, from: AXUIElement, forward: Bool, to: AXUIElement?)] = []

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
        let forward = !g.modifiers.contains(.shift), keyAt = InputManager.lastKeyDownAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            // Another key since: the landings no longer belong to this one (a review, 13 Nov 2026).
            guard InputManager.lastKeyDownAt == keyAt,
                  let after = API.focusObject?.element, !after.isSame(before), after.pid == before.pid, !inToolbar,
                  !isInWeb(after), scopeOf(after).map({ $0.isSame(window) }) ?? false else { return }
            // Only a Tab that went back up or left (round the window), or a Shift Tab that went down or right, can
            // have passed the toolbar: the window isn't walked for the rest.
            guard let bf = TurnOverObject.frame(before), let af = TurnOverObject.frame(after) else { return }
            let back = af.midY < bf.minY - 4 || af.midX < bf.minX - 4
            let on = af.midY > bf.maxY + 4 || af.midX > bf.maxX + 4
            guard forward ? back : on else { return }
            // The Tab trap's list of the window's stops where it still stands (a walk of the whole window, on main, after
            // every Tab the app had: a review, 13 Nov 2026); walked afresh when it can't place all three.
            guard let (tb, _) = toolbar(of: window), let items = toolbarItems(around: tb)?.items,
                  let stop = toolbarStop(tb, items) else { Log.io("toolbar: Tab's way round not placed"); return }
            @MainActor func placed(_ all: [AXUIElement]) -> (t: Int, a: Int, b: Int)? {
                guard let t = all.firstIndex(where: { $0.isSame(stop) }), let a = place(before, in: all), let b = place(after, in: all) else { return nil }
                return (t, a, b)
            }
            var all: [AXUIElement] = []
            var found: (t: Int, a: Int, b: Int)?
            // (Stricter than the trap's own reuse: nothing said of the controls changing since, even in its first seconds.)
            if let c = trapList, c.window.isSame(window), listStillGood(c.at, pid: window.pid), AXHandler.shared.observers[window.pid] != nil,
               (AXHandler.shared.lastStructureAt[window.pid] ?? .distantPast) < c.at { all = c.controls; found = placed(all) }
            if found == nil { all = controls(in: window, toolbars: true, unfocusable: true); found = placed(all) }
            guard let (t, a, b) = found else { Log.io("toolbar: Tab's way round not placed"); return }
            // Within one stop (Calendar's events inside its grid, 13 Nov 2026) nothing was passed over.
            guard a != b else { return }
            // The places passed over on the way, going round as Tab does.
            let n = all.count
            var k = a, passed = false, first: Int?
            for _ in 0..<n { k = (k + (forward ? 1 : -1) + n) % n; if k == b { break }; if first == nil { first = k }; if k == t { passed = true; break } }
            guard passed else { return }
            // The first stop passed over, the toolbar or one before it: Shift Tab from Mail's mailboxes passed its
            // search too, on its way back over the toolbar, and the search was skipped (13 Nov 2026).
            // Only a stop of the toolbar's own (inside its frame): any other stays the toolbar's.
            let target = first.flatMap { f -> AXUIElement? in
                guard f != t, let tf = TurnOverObject.frame(tb), let ff = TurnOverObject.frame(all[f]), tf.contains(CGPoint(x: ff.midX, y: ff.midY)) else { return nil }
                return all[f]
            } ?? stop
            Log.io("toolbar: the app's \(forward ? "Tab" : "Shift Tab") went round past the toolbar; to \(target.isSame(stop) ? "the toolbar" : target.role), and remembered")
            toolbarSkips.removeAll { $0.from.isSame(before) && $0.forward == forward }
            toolbarSkips.append((window, before, forward, target.isSame(stop) ? nil : target))
            if toolbarSkips.count > 24 { toolbarSkips.removeFirst() }
            Speech.cancel()
            focus(target)
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
        // The app's module has its own Tab here (Mail's message list): it decides, as on the toolbar (a review).
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(for: g) {
            Log.io("toolbar: the app's module has \(s.name) for this key"); s.handler(g); return
        }
        // To the stop that was passed over first, where it wasn't the toolbar (Mail's search, on Shift Tab).
        if let cur = API.focusObject?.element, let to = Self.toolbarSkips.last(where: { $0.from.isSame(cur) && $0.forward == !g.modifiers.contains(.shift) })?.to, to.role != "?" {
            Log.io("toolbar: Tab here passes over \(to.role); to it"); Self.focus(to); return
        }
        guard let cur = API.focusObject?.element, let w = Self.scopeOf(cur), let (anchor, _) = Self.toolbar(of: w),
              let (tb, items) = Self.toolbarItems(around: anchor), let stop = Self.toolbarStop(tb, items) else { g.send(); return }
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
