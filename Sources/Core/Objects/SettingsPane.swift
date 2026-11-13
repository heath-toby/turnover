// SPDX-License-Identifier: GPL-3.0-or-later
// Settings windows (a toolbar of tabs over a pane: Mail's and Safari's Settings). With the Mac's keyboard
// navigation at its default, Tab only reaches text fields and lists: in Safari's General tab it bounced on the one
// Homepage field (4 Oct 2026). Here, as on Windows, Tab and Shift+Tab go through every control in the pane in the
// order they are on screen (top to bottom, then left to right); Shift+Tab from the first goes back to the tab, and
// Tab from the last goes round to it too. The tab itself (PreferenceTab) already sends Tab into the pane.
import Foundation
import AppKit
import ApplicationServices

public final class SettingsPanePlugin: GlobalPlugin {
    /// Whether the focus is in a settings pane: worked out on the main thread as the focus moves, read by the keyboard
    /// thread's availability check (no questions to the app on that thread).
    private static let lock = NSLock()
    private static var _inPane = false
    static var inPane: Bool { lock.lock(); defer { lock.unlock() }; return _inPane }

    /// The focus moved (main thread).
    private static var _onRibbonTab = false
    static var onRibbonTab: Bool { lock.lock(); defer { lock.unlock() }; return _onRibbonTab }

    /// Microsoft Office's ribbon (Word, Excel, PowerPoint, Outlook): a tab group described "ribbon"; each tab's
    /// commands sit in a scroll area described "<Tab> Tab Commands", there only while that tab is open.
    static func ribbon(of e: AXUIElement) -> AXUIElement? {
        if let c = FocusChain.of(e) { return c.first(10) { c.roles[$0] == "AXTabGroup" && c.description($0)?.lowercased() == "ribbon" } }
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 { if x.role == "AXTabGroup", x.string(kAXDescriptionAttribute)?.lowercased() == "ribbon" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }
    static func ribbonCommands(of e: AXUIElement) -> AXUIElement? {
        if let c = FocusChain.of(e) { return c.first(10) { c.roles[$0] == "AXScrollArea" && c.description($0)?.hasSuffix("Tab Commands") == true } }
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 { if x.role == "AXScrollArea", x.string(kAXDescriptionAttribute)?.hasSuffix("Tab Commands") == true { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    /// The parent chain of the control the focus just moved to, read once while focusMoved works (a review, 13 Nov
    /// 2026): the trap's state, the toolbar and the ribbon each walked it again, up to six walks of ten to twenty-five
    /// levels per focus change, two questions a level. The questions below are answered from it as their own walks
    /// would answer them, over the same number of levels. Only for the length of one focusMoved call (main thread).
    final class FocusChain {
        /// The element itself, then its parents, at most 25 (the longest of the walks answered from it).
        let elements: [AXUIElement]
        let roles: [String]
        private var descriptions: [Int: String?] = [:]
        static var current: FocusChain?   // set and cleared by focusMoved

        init(_ e: AXUIElement) {
            var els: [AXUIElement] = [], rs: [String] = []
            var p: AXUIElement? = e
            while let x = p, els.count < 25 { els.append(x); rs.append(x.role); p = x.element(kAXParentAttribute) }
            elements = els; roles = rs
        }
        /// The chain being used, when it is `e`'s.
        static func of(_ e: AXUIElement) -> FocusChain? {
            guard let c = current, let first = c.elements.first, first === e || CFEqual(first, e) else { return nil }
            return c
        }
        func description(_ i: Int) -> String? {
            if let d = descriptions[i] { return d }
            let d = elements[i].string(kAXDescriptionAttribute); descriptions[i] = d; return d
        }
        /// The first of the first `levels` elements (the element itself counted) that passes.
        func first(_ levels: Int, where test: (Int) -> Bool) -> AXUIElement? {
            (0..<min(levels, elements.count)).first(where: test).map { elements[$0] }
        }
        /// Whether any of elements[from..<to] has this role.
        func has(_ role: String, from: Int = 0, to: Int) -> Bool {
            from < min(to, roles.count) && roles[from..<min(to, roles.count)].contains(role)
        }
    }
    static func commandsArea(in ribbon: AXUIElement) -> AXUIElement? {
        ribbon.elements(kAXChildrenAttribute).first { $0.role == "AXScrollArea" && $0.string(kAXDescriptionAttribute)?.hasSuffix("Tab Commands") == true }
    }
    static func selectedRibbonTab(_ ribbon: AXUIElement) -> AXUIElement? {
        let tabs = ribbon.elements(kAXChildrenAttribute).filter { $0.role == "AXRadioButton" }
        return tabs.first { ($0.attr(kAXValueAttribute) as? NSNumber)?.intValue == 1 } ?? tabs.first
    }

    /// Groups where an app was seen to ignore Tab (main thread), and whether the focus is in one now (any thread).
    static var trapZones: [AXUIElement] = []
    /// Groups where the app ignored Tab once, not yet remembered. One 0.4 s with no focus news was enough before, and a
    /// busy app gave that: the place took Tab from the app for the rest of the run, even once the app moved its own
    /// focus there again (a review, 13 Nov 2026). Remembered at the second miss with no success between.
    static var trapZoneMisses: [AXUIElement] = []

    /// A miss in `zone`: true when it is now remembered (seen twice). A success in it (`missed: false`) forgets it,
    /// as a candidate and as a remembered place. Generic so the rule can be tested without an app.
    package static func noteTabOutcome<T>(_ zone: T, missed: Bool, candidates: inout [T], zones: inout [T], same: (T, T) -> Bool) -> Bool {
        if !missed {
            candidates.removeAll { same($0, zone) }
            zones.removeAll { same($0, zone) }
            return false
        }
        if zones.contains(where: { same($0, zone) }) { return false }
        if candidates.contains(where: { same($0, zone) }) {
            candidates.removeAll { same($0, zone) }
            zones.append(zone)
            if zones.count > 20 { zones.removeFirst() }
            return true
        }
        candidates.append(zone)
        if candidates.count > 20 { candidates.removeFirst() }
        return false
    }
    /// The app ignored Tab in this group: remembered at the second time (see trapZoneMisses).
    static func trapZoneMissed(_ zone: AXUIElement) -> Bool {
        pruneTrapZones()
        return noteTabOutcome(zone, missed: true, candidates: &trapZoneMisses, zones: &trapZones) { $0.isSame($1) }
    }
    /// The app moved its own focus on a Tab from `e`: any remembered group around it is forgotten.
    static func trapZoneAnswered(around e: AXUIElement) {
        guard !trapZones.isEmpty || !trapZoneMisses.isEmpty else { return }
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 7 {
            if trapZones.contains(where: { $0.isSame(x) }) || trapZoneMisses.contains(where: { $0.isSame(x) }) {
                Log.io("tab trap: the app moved its own focus on Tab in \(x.role); no longer a place where Tab is TurnOver's")
                _ = noteTabOutcome(x, missed: false, candidates: &trapZoneMisses, zones: &trapZones) { $0.isSame($1) }
            }
            p = x.element(kAXParentAttribute); hops += 1
        }
    }
    /// Groups gone with their window (or the app's view rebuilt) are dropped: kept, they held their place among the 20
    /// for ever (a review, 13 Nov 2026). Asked at Tab time only, not on every focus move.
    static func pruneTrapZones() {
        trapZones.removeAll { $0.role == "?" }
        trapZoneMisses.removeAll { $0.role == "?" }
    }
    /// The app quit: its remembered places, loop windows, per-process answers and the window list kept go with it, so a
    /// new process given the same number doesn't inherit them (a review, 13 Nov 2026).
    static func forget(pid: pid_t) {
        trapZones.removeAll { $0.pid == pid }
        trapZoneMisses.removeAll { $0.pid == pid }
        loopWindows.removeAll { $0.pid == pid }
        loopKinds = loopKinds.filter { !$0.hasPrefix("\(pid)|") }
        moduleTab[pid] = nil
        catalyst[pid] = nil
        if let t = trapList, t.window.pid == pid { trapList = nil }
        if let t = tabLandings, t.window.pid == pid { tabLandings = nil }
    }
    private static var _inTrapZone = false
    /// The focus is a button, and Return would press the window's default button instead.
    static var returnWouldMissFocus: Bool {
        guard let f = API.focusObject, f.role == .button, f.axRole == "AXButton" else { return false }
        let e = f.element
        // The sheet or window holding the button, nearest first: a sheet's default is the sheet's, not its window's.
        // Claude's "Claude is still working" alert is a sheet on the main window: Return on "Quit anyway" went to
        // Claude, which pressed Cancel (7 Oct 2026).
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 30 {
            if let def = x.element(kAXDefaultButtonAttribute) { return !CFEqual(def, e) }
            let modal = x.role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(x.string(kAXSubroleAttribute) ?? "")
            if modal { return true }   // an alert that doesn't say which is its default: the button you're on
            if x.role == "AXWindow" { break }
            p = x.element(kAXParentAttribute); hops += 1
        }
        guard let window = e.element(kAXWindowAttribute) ?? e.element(kAXTopLevelUIElementAttribute),
              let def = window.element(kAXDefaultButtonAttribute) else { return false }
        return !CFEqual(def, e)
    }

    /// Tab is the trap's: in a place where the app ignores it, or while TurnOver holds a place the trap moved to (a
    /// control that refuses the focus: the app's own Tab would go on from its focus elsewhere, Weather, 11 Nov 2026).
    static var inTrapZone: Bool { lock.lock(); defer { lock.unlock() }; return _inTrapZone || (_holding && _heldByTrap) }
    private static var _heldByTrap = false
    /// The last window's controls in screen order, reused for a few seconds (walking the window costs 60 ms), or up to
    /// a minute while the app says nothing of its controls changing.
    /// Not when the window's own children changed in number, or the control Tab last landed on has moved: controls an
    /// app reveals without saying it created them (a disclosure's options) were skipped by Tab for up to a minute (a
    /// review, 13 Nov 2026). Both are one question to the app.
    static func listStillGood(_ at: Date, pid: pid_t) -> Bool {
        let structure = (AXHandler.shared.lastStructureAt[pid] ?? .distantPast) >= at
        return listStillGood(age: Date().timeIntervalSince(at), structureNewsSince: structure, shapeChanged: trapListShapeChanged())
    }
    package static func listStillGood(age: TimeInterval, structureNewsSince: Bool, shapeChanged: Bool) -> Bool {
        !shapeChanged && (age < 5 || age < 60 && !structureNewsSince)
    }
    /// The last window's controls in screen order, reused for a few seconds (walking the window costs 60 ms).
    static var trapList: (window: AXUIElement, controls: [AXUIElement], at: Date)? {
        didSet { trapListChildren = trapList.map { childCount($0.window) } ?? -1 }
    }
    /// The window's number of children when its list was walked, and where the trap's Tab last landed, with its frame.
    private static var trapListChildren = -1
    static var trapLanding: (element: AXUIElement, frame: CGRect?)?
    static func childCount(_ e: AXUIElement) -> Int {
        var n: CFIndex = 0
        return AXUIElementGetAttributeValueCount(e, kAXChildrenAttribute as CFString, &n) == .success ? n : -1
    }
    private static func trapListShapeChanged() -> Bool {
        guard let t = trapList else { return true }
        if childCount(t.window) != trapListChildren { return true }
        if let l = trapLanding, l.element.role != "?", let was = l.frame, let now = TurnOverObject.frame(l.element), now != was { return true }
        return false
    }

    /// The named section around a control (Mail's "Formatting" bar): each button sits in a little group of its own.
    static func zone(of e: AXUIElement) -> AXUIElement? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 5 {
            if ["AXGroup", "AXToolbar", "AXRadioGroup", "AXScrollArea"].contains(x.role),
               !((x.string(kAXDescriptionAttribute) ?? "") + (x.string(kAXTitleAttribute) ?? "")).isEmpty { return x }
            if x.role == "AXWindow" { break }
            p = x.element(kAXParentAttribute); hops += 1
        }
        // No named section: no place to remember. The plain parent it fell back to could be a whole pane, and Tab
        // there was TurnOver's for every control in it (a review, 13 Nov 2026).
        return nil
    }

    func trapMove(_ g: KeyboardGesture, forward: Bool) {
        // An app's module that orders this Tab itself (Mail's message list to the header fields) keeps it.
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(for: g) {
            Log.io("tab trap: the app's module has \(s.name) for this key"); s.handler(g); return
        }
        // From TurnOver's held place when the app's buttons do not take the focus, else from the focus.
        Self.dropDeadHold()
        guard let current = Self.virtual ?? API.focusObject?.element, let window = Self.scopeOf(current) else {
            // Nowhere to go from (the place and the focus both gone with the view they were in): the front window's
            // first control, or last for Shift Tab.
            if let app = NSWorkspace.shared.frontmostApplication, let w = AXUIElementCreateApplication(app.processIdentifier).element(kAXFocusedWindowAttribute),
               let target = forward ? Self.controls(in: w, toolbars: true, unfocusable: true).first : Self.controls(in: w, toolbars: true, unfocusable: true).last {
                Log.io("tab trap: no place left to go from; to the window's \(forward ? "first" : "last") control")
                Self.focus(target, byTrap: true)
                Self.setTrapState(for: target)
                return
            }
            g.send(); return
        }
        var all: [AXUIElement]
        if let c = Self.trapList, c.window.isSame(window), Self.listStillGood(c.at, pid: window.pid) { all = c.controls }
        else { all = Self.controls(in: window, toolbars: true, unfocusable: true); Self.trapList = (window, all, Date()) }
        // On a row of a list the trap made (rowLists): its place is the list's, which stands for all its rows.
        func stop(_ e: AXUIElement) -> AXUIElement { Self.rowList(of: e)?.stop ?? e }
        var here = all.firstIndex { $0.isSame(stop(current)) }
        if here == nil { all = Self.controls(in: window, toolbars: true, unfocusable: true); Self.trapList = (window, all, Date()); here = all.firstIndex { $0.isSame(stop(current)) } }
        // A held place that isn't a control (a copy window's progress bar, NewDialogs): Tab goes from where it sits
        // among the window's controls, in the order of the window's children (11 Nov 2026: Tab said nothing).
        if here == nil, let around = Self.controlsAround(current, in: window) {
            let (order, at) = around
            let next = forward ? order.indices.first { $0 > at } : order.indices.last { $0 < at }
            guard let k = next ?? (forward ? order.indices.first { $0 != at } : order.indices.last { $0 != at }) else { g.send(); return }
            Log.io("tab trap: from a held \(current.role) to \(order[k].role)")
            Self.focus(order[k], byTrap: true)
            Self.setTrapState(for: order[k])
            return
        }
        // A window with one control and a progress bar (Finder's copy window: the bar and its stop button): the bar is
        // a stop too, so Shift Tab goes back to it rather than staying on the button (11 Nov 2026).
        if all.count <= 1, let bar = NewDialogs.firstProgressBar(in: window), let around = Self.controlsAround(bar, in: window),
           let i = around.0.firstIndex(where: { $0.isSame(current) }) {
            let order = around.0
            let k = ((forward ? i + 1 : i - 1) + order.count) % order.count
            Log.io("tab trap: round a control and a progress bar, to \(order[k].role)")
            Self.focus(order[k], byTrap: true)
            Self.setTrapState(for: order[k])
            return
        }
        // TurnOver's place is a container, not a control (an iPad app's focus on its nameless content group: Audible's
        // Tab said nothing at all, 11 Nov 2026): into it, its first control for Tab and its last for Shift Tab, else
        // the window's.
        if here == nil, !all.isEmpty, !Self.controlRoles.contains(current.role) {
            let inside = current.role == "AXWindow" ? all : Self.controls(in: current, toolbars: true, unfocusable: true).filter { !$0.isSame(current) }
            let pool = inside.isEmpty ? all : inside
            if let target = forward ? pool.first : pool.last {
                Log.io("tab trap: from a \(current.role), not a control, into its \(target.role)")
                Self.focus(target, byTrap: true)
                Self.setTrapState(for: target)
                return
            }
        }
        // The last control in sight of a scroll area with more beyond it (a settings pane SwiftUI builds as it is
        // scrolled): a page further, and the window's controls walked again, before Tab goes round to the top.
        // (Not a list's own scroll area: the list is one stop, its rows are its arrows'. Tab from the Open panel's
        // sidebar scrolled the sidebar a page each time, 13 Nov 2026.)
        if let h = here, !["AXOutline", "AXTable", "AXList", "AXBrowser", "AXGrid", "AXTextArea", "AXWebArea"].contains(all[h].role),
           let area = Self.scrollArea(of: all[h]), Self.canScroll(area, down: forward) {
            let n = ((forward ? h + 1 : h - 1) + all.count) % all.count
            let leaves = Self.scrollArea(of: all[n]).map { !$0.isSame(area) } ?? true
            if leaves || (forward ? n < h : n > h), Self.scrollPage(area, down: forward) {
                Log.io("tab trap: the last control in sight of a scroll area with more; scrolled a page")
                Poll.pumping(every: 0.05, limit: 0.3) { false }
                let fresh = Self.controls(in: window, toolbars: true, unfocusable: true)
                Self.trapList = (window, fresh, Date())
                if let j = fresh.firstIndex(where: { $0.isSame(stop(current)) }) {
                    let k = forward ? j + 1 : j - 1
                    if fresh.indices.contains(k), Self.scrollArea(of: fresh[k]).map({ $0.isSame(area) }) ?? false {
                        Self.focus(fresh[k], byTrap: true); Self.setTrapState(for: fresh[k]); return
                    }
                }
            }
        }
        guard var i = here, !all.isEmpty else {
            Log.io("tab trap: \(current.role) \"\(Log.words(ObjectFactory.make(current).name.prefix(30).description))\" not among the window's \(all.count) controls; Tab sent on")
            g.send()
            // And if the app's own Tab went nowhere, the window's control after it by place on the screen (Weather,
            // left open with TurnOver's place on a tab its window no longer listed: ten Tabs went nowhere, a sweep,
            // 13 Nov 2026).
            guard !all.isEmpty else { return }
            let keyAt = InputManager.lastKeyDownAt, from = current
            // (By the app's own focus, after 0.6 s: news late or set aside must not make it two moves, a review.)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                guard InputManager.lastKeyDownAt == keyAt, let f = API.focusObject?.element, f.isSame(from),
                      AXUIElementCreateApplication(from.pid).element(kAXFocusedUIElementAttribute).map({ $0.isSame(from) }) ?? true else { return }
                let cf = TurnOverObject.frame(from)
                func after(_ e: AXUIElement) -> Bool {
                    guard let c = cf, let ef = TurnOverObject.frame(e) else { return false }
                    return ef.minY > c.midY || (abs(ef.midY - c.midY) < 4 && ef.minX > c.maxX)
                }
                let target = forward ? (all.first(where: after) ?? all.first) : (all.last(where: { !after($0) && !$0.isSame(from) }) ?? all.last)
                guard let target else { return }
                Log.io("tab trap: the app's Tab went nowhere; by place to \(target.role)")
                Self.focus(target, byTrap: true)
                Self.setTrapState(for: target)
            }
            return
        }
        var n = ((forward ? i + 1 : i - 1) + all.count) % all.count   // round, as the app's own Tab goes
        // The list kept from a moment ago can name controls the app has since thrown away: TurnOver Settings rebuilds
        // its pane on a new section, and Tab from the sidebar went to a dead check box, held it, and was silent from
        // then on (21 Oct 2026). Walk the window again.
        if all[n].role == "?" || (TurnOverObject.frame(all[n]).map { $0.width <= 0 || $0.height <= 0 } ?? true) || all[n].element(kAXParentAttribute) == nil {
            all = Self.controls(in: window, toolbars: true, unfocusable: true); Self.trapList = (window, all, Date())
            guard let j = all.firstIndex(where: { $0.isSame(current) }), !all.isEmpty else { g.send(); return }
            i = j; n = ((forward ? i + 1 : i - 1) + all.count) % all.count
        }
        // Round to the same control (a window with one, Reminders' Continue): nothing changes, so nothing would be
        // said; it is said again, as Tab on Windows says it (the sweep, 11 Nov 2026).
        if all[n].isSame(current) { Speech.cancel(); Speech.speakObject(ObjectFactory.make(current), reason: .focus); return }
        // Into a list the trap made: on the row last read there, as Windows' lists keep their place; else its first,
        // either way (Shift Tab landed on the last row, 12 Nov 2026).
        if let (rows, _, _, container) = Self.rowList(of: all[n]) {
            let back = Self.lastRow.first { $0.container.isSame(container) }.flatMap { r in rows.firstIndex { $0.isSame(r.row) } }
            Self.landInRowList(rows, at: back ?? 0, entering: true)
            Self.setTrapState(for: rows[0])
            return
        }
        Log.io("tab trap: to \(all[n].role) \(n + 1) of \(all.count)")
        var target = all[n]
        // Onto a toolbar: its item last used, which a list kept from before may not name.
        if let w = Self.windowOf(target), let (tb, _) = Self.toolbarFor(target, in: w), !Self.ownArrows(target),
           let items = Self.toolbarItems(around: tb)?.items, let stop = Self.toolbarStop(tb, items) { target = stop }
        Self.focus(target, byTrap: true)
        Self.setTrapState(for: target)
    }

    /// Whether a control is in a place where the app ignores Tab; set as the focus (or TurnOver's held place) moves.
    /// The focus is in a page (Mail's message, its attachment button): Tab is browse mode's. A focus read by a path
    /// that left the trap's state alone kept Tab, and Shift Tab from the attachment went nowhere (13 Nov 2026).
    static func focusInPage() -> Bool {
        guard let f = API.focusObject?.element else { return false }
        return f.role == "AXWebArea" || isInWeb(f)
    }

    static func setTrapState(for e: AXUIElement) {
        // A text field keeps the app's own Tab even inside a remembered place: Reminders' sidebar was judged to ignore
        // Tab, and the place remembered took Tab from a new reminder's title too, so TurnOver moved the focus itself
        // and the window was announced between the fields (10 Oct 2026).
        let editable = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(e.role)
        // A window where Tab loops short (TabLoop.swift) is TurnOver's for Tab, but not in a field or web content,
        // which keep their own (keepsOwnTab).
        // An iPad app (Catalyst): Tab is TurnOver's everywhere but in a text area or web content, as VoiceOver's
        // cursor goes. The app's own Tab is slow, and reports the focus still on a field it left: Phone's Tab and
        // Shift Tab went silent or round the toolbar for ever (a tester's idea, 11 Nov 2026).
        let catalyst = isCatalyst(e.pid) && !moduleTakesTab(e.pid) && e.role != "AXTextArea" && !isInWeb(e)
        // In a window whose Tab loops short, a one-line field gives Tab up too: a loop of fields alone (the Save sheet's
        // name and tags) never reached Where, Cancel or Save (11 Nov 2026). Tab in a one-line field only moves on.
        let oneLine = ["AXTextField", "AXSearchField"].contains(e.role)
        let anyTrap = catalyst || ((!keepsOwnTab(e) || oneLine) && inLoopWindow(e)) || !trapZones.isEmpty && !editable && {
            var p: AXUIElement? = e.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 6 { if trapZones.contains(where: { $0.isSame(x) }) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
            return false
        }()
        // Never in a page: its Tab is browse mode's or the page's own (BT Cloud Work's settings page: TurnOver's Tab
        // went to the page itself, again and again, 13 Nov 2026).
        let inTrap = anyTrap && e.role != "AXWebArea" && !isInWeb(e)
        lock.lock(); let was = _inTrapZone; _inTrapZone = inTrap; lock.unlock()
        if was != inTrap { Log.io("tab trap: \(inTrap ? "in" : "out of") a remembered place (\(e.role) \"\(Log.words(e.string(kAXDescriptionAttribute) ?? e.string(kAXTitleAttribute) ?? ""))\")") }
    }

    static func focusMoved(to obj: TurnOverObject) {
        // A menu opening on the held place (its context menu) takes the focus for a moment: the place is kept for
        // when it closes.
        if virtual != nil, ["AXMenu", "AXMenuItem"].contains(obj.axRole) { return }
        // Back from a menu opened on the place TurnOver holds (the context menu on a call in Phone): the app hands its
        // focus to a nameless group, and the place was lost, Up and Down silent (a tester, 11 Nov 2026). Kept.
        // (A group holding the place, named or not: Phone's focus went to its calls' group.)
        if let v = virtual, !obj.isSameElement(as: v), v.role != "?", v.pid == obj.pid,
           let ended = AXHandler.shared.lastMenuEnded, ended.pid == v.pid, Date().timeIntervalSince(ended.at) < 2,
           obj.axRole == "AXGroup" && obj.name.isEmpty || { var p = v.element(kAXParentAttribute); var hops = 0
               while let x = p, hops < 10 { if x.isSame(obj.element) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
               return false }() {
            Log.io("settings: back from a menu; TurnOver's place kept")
            let held = ObjectFactory.make(v)
            API.setFocusObject(held, ancestors: API.focusAncestors)
            ObjectNavigator.shared.focusMoved(to: v, pid: v.pid)
            Speech.speakObject(held, reason: .focus)
            return
        }
        let e = obj.element
        let chain = FocusChain(e), outer = FocusChain.current
        FocusChain.current = chain
        defer { FocusChain.current = outer }
        setTrapState(for: e)
        noteToolbar(e)
        let commands = ribbonCommands(of: e)   // (once: it was walked twice per focus, a review, 13 Nov 2026)
        let onTab = chain.roles[0] == "AXRadioButton" && ribbon(of: e) != nil && commands == nil
        lock.lock(); _onRibbonTab = onTab; lock.unlock()
        if commands != nil { lock.lock(); _inPane = true; lock.unlock(); return }
        // A real focus change ends any held place.
        if let v = virtual, !obj.isSameElement(as: v) { virtual = nil; lock.lock(); _holding = false; _heldByTrap = false; lock.unlock() }
        var inside = false
        if let window = windowOf(e), PreferenceTab.selectedTab(in: window) != nil {
            inside = !chain.has("AXToolbar", to: 12)   // the element and eleven parents, as the walk here went
        }
        lock.lock(); _inPane = inside; lock.unlock()
    }

    /// Presses an app's module makes itself, by bundle: true when it handled the held place.
    static var pressOverrides: [String: (AXUIElement) -> Bool] = [:]
    /// A list an app's module makes of rows the app doesn't put in one (Contacts' card details): into it, on row `i`.
    static func enterList(_ rows: [AXUIElement], container: AXUIElement, at i: Int) {
        guard rows.indices.contains(i) else { return }
        rowLists.removeAll { $0.container.isSame(container) }
        rowLists.insert((rows, rows[0], container), at: 0)
        landInRowList(rows, at: i, entering: true)
    }
    /// The row of a list TurnOver holds, if any.
    static var heldRow: AXUIElement? { holdingVirtual ? virtual : nil }

    /// The running plugin, for focus rules that hand a Tab on to the trap.
    static weak var current: SettingsPanePlugin?

    required init() {
        super.init()
        Self.current = self
        InputManager.passThroughWatchers.append(Self.watchTabLoop)
        InputManager.passThroughWatchers.append(NewDialogs.watchCommandKey)
        // An app that ignores Tab or Shift+Tab on a control: Mail's compose window keeps the focus on the formatting
        // bar's "more…" button, so Shift+Tab went nowhere and said nothing (5 Oct 2026). If the focus has not moved
        // shortly after the key, TurnOver moves it to the next or previous control in screen order.
        InputManager.passThroughWatchers.append { g in
            guard g.keyName == "tab", g.modifiers.subtracting(.shift).isEmpty else { return }
            // Nothing focused in the app in front (AirPort Utility and Apple Configurator open with their window and
            // no focus inside it, so Tab went nowhere: the sweep of 11 Nov 2026): its window stands in for the focus,
            // and Tab goes to its first control, as on Windows. Not when TurnOver's focus is in a panel over it
            // (LaunchBar): that panel has the keys.
            let front = NSWorkspace.shared.frontmostApplication
            let f = API.focusObject
            let focusApp = f.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
            let nowhere = f == nil || (focusApp?.activationPolicy == .regular && f?.pid != front?.processIdentifier)
            var before: AXUIElement, window: AXUIElement
            // TurnOver's focus cut off from any window while the app says its window has the focus (iMazing's sidebar
            // after it opens, 13 Nov 2026): as nothing focused, from the window.
            let appEl = front.map { AXUIElementCreateApplication($0.processIdentifier) }
            let detached: AXUIElement? = {
                guard !nowhere, let f, f.axRole != "AXWindow", Self.scopeOf(f.element) == nil, let appEl, f.pid == front?.processIdentifier,
                      let w = appEl.element(kAXFocusedWindowAttribute), let real = appEl.element(kAXFocusedUIElementAttribute), real.isSame(w) else { return nil }
                return w
            }()
            if let w = detached {
                Log.io("tab trap: TurnOver's focus has no window and the app's is its window; from the window")
                before = w; window = w
            } else if nowhere {
                // Asked of the app itself, not judged from TurnOver's own focus, which may be stale (a focus rule set
                // the new one aside): only an app with nothing focused, or its window itself, counts (a review, 11 Nov
                // 2026: Tab in a terminal or an editor must stay theirs).
                guard let front, front.processIdentifier != getpid() else { return }
                let appEl = AXUIElementCreateApplication(front.processIdentifier)
                guard let w = appEl.element(kAXFocusedWindowAttribute) else { return }
                if let real = appEl.element(kAXFocusedUIElementAttribute), !real.isSame(w) { return }
                before = w; window = w
            } else {
                guard let f, !Self.typesTab(f), let w = f.axRole == "AXWindow" ? f.element : Self.scopeOf(f.element) else {
                    if let f, !Self.typesTab(f) { Log.io("tab trap: no window found for \(f.axRole); Tab left to the app") }
                    return
                }
                before = f.element; window = w
            }
            let pid = before.pid, at = Date()
            let chosenBefore = nowhere || detached != nil ? [] : Self.chosen(in: before)
            // 0.4 s: Reminders' SwiftUI sidebar takes longer than a quarter of a second to pass Tab on (10 Oct 2026).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let unmoved = nowhere ? (API.focusObject.map { $0.pid != pid } ?? true)
                    : detached != nil ? (f.map { API.focusObject?.isSameElement(as: $0.element) == true } ?? false)
                    : API.focusObject?.isSameElement(as: before) == true
                guard unmoved,
                      (AXHandler.shared.lastMoveNewsAt[pid] ?? .distantPast) < at else {
                    if unmoved { Log.io("tab trap: the focus stayed, but the app had news of a move; left to it") }
                    // The app moved its own focus on this Tab: a place around it remembered (or half remembered) as
                    // one where the app ignores Tab is forgotten (a review, 13 Nov 2026).
                    else if !nowhere, detached == nil { Self.trapZoneAnswered(around: before) }
                    return
                }
                // The focus stayed, but Tab chose something inside it, with no news of it: Calendar's Tab selects the
                // next event in a day's list, and said nothing (11 Nov 2026). The item now chosen is read.
                if !nowhere, detached == nil, let now = Self.chosen(in: before).first,
                   !chosenBefore.contains(where: { CFEqual($0, now) }) {
                    Log.io("tab trap: Tab chose an item inside the \(before.role), with no news; read")
                    Speech.cancel(); Speech.speakObject(ObjectFactory.make(now), reason: .focus)
                    return
                }
                let all = Self.controls(in: window, toolbars: true, unfocusable: true)
                let forward = !g.modifiers.contains(.shift)
                guard let here = all.firstIndex(where: { $0.isSame(before) }) else {
                    // The focus parked on a container that isn't a control (Calculator opened with a sheet, its focus
                    // on a nameless scroll area, and Tab did nothing: the sweep of 11 Nov 2026, macOS 27.2): into the
                    // container, its first control for Tab and its last for Shift Tab.
                    // Walked from the container itself: Journal's welcome sheet has only a Continue that refuses the
                    // focus, missed among the window's toolbar buttons that take it (11 Nov 2026).
                    let inside = before.role == "AXWindow" ? all : Self.controls(in: before, toolbars: true, unfocusable: true).filter { !$0.isSame(before) }
                    guard let target = forward ? inside.first : inside.last else {
                        // A control the window's list leaves out (Calendar's day list, 11 Nov 2026): on from where it
                        // sits among the window's controls.
                        guard let around = Self.controlsAround(before, in: window) else {
                            // The focus is no longer in the window at all (Calendar put a welcome screen over its days,
                            // and reported the hidden day list as its focus, 11 Nov 2026): the window's first control.
                            if let first = forward ? all.first : all.last {
                                Log.io("tab trap: the focus \(before.role) isn't in its window any more; to the window's \(first.role)")
                                Self.focus(first, byTrap: true); Self.setTrapState(for: first); return
                            }
                            Log.io("tab trap: nowhere to go from \(before.role)"); return
                        }
                        let (order, i) = around
                        let k = ((forward ? i + 1 : i - 1) + order.count) % order.count
                        Log.io("tab trap: the app ignored \(forward ? "Tab" : "Shift+Tab") on \(before.role); TurnOver moves to \(order[k].role)")
                        Self.focus(order[k], byTrap: true)
                        Self.setTrapState(for: order[k])
                        return
                    }
                    Log.io("tab trap: the app ignored \(forward ? "Tab" : "Shift+Tab") on a \(before.role) holding \(inside.count) controls; TurnOver moves into it")
                    // The container is a place where Tab is TurnOver's from now on (Home's sheet: the next Tab went to
                    // the settings panes' Tab and did nothing).
                    // A nameless group only (Catalyst's content group), not a document's scroll area, whose links and
                    // form fields keep the app's Tab (a review, 11 Nov 2026).
                    // (At the second miss: one slow answer from a busy app is no proof, a review, 13 Nov 2026.)
                    if before.role == "AXGroup", Self.trapZoneMissed(before) {
                        Log.io("tab trap: remembering the \(before.role) as a place where Tab is TurnOver's")
                    }
                    Self.trapList = (window, all, Date())
                    Self.focus(target, byTrap: true)
                    Self.setTrapState(for: target)
                    return
                }
                let n = ((forward ? here + 1 : here - 1) + all.count) % all.count
                Log.io("tab trap: the app ignored \(forward ? "Tab" : "Shift+Tab") on \(before.role); TurnOver moves to \(all[n].role) \(n + 1) of \(all.count)")
                // Remember where the app ignores Tab (the group around the control): from now on Tab there is
                // TurnOver's at once, with no wait (each step took 300 ms, "draggy", 5 Oct 2026).
                // Not a whole window: Calendar's welcome screen sat in its main window, and the window kept as such a
                // place took Tab from Calendar's own event to event Tab once the screen was gone (11 Nov 2026).
                // At the second miss in the same place with no success between: one 0.4 s without news is what a busy
                // app gives too (a review, 13 Nov 2026).
                if let zone = Self.zone(of: before), zone.role != "AXWindow", Self.trapZoneMissed(zone) {
                    Log.io("tab trap: remembering \(zone.role) \"\(Log.words(zone.string(kAXDescriptionAttribute) ?? ""))\" as a place where Tab is TurnOver's")
                }
                Self.trapList = (window, all, Date())
                // Round to the same control (a window with one): said again, as Tab on Windows does.
                if all[n].isSame(before) { Speech.cancel(); Speech.speakObject(ObjectFactory.make(before), reason: .focus); return }
                Self.focus(all[n], byTrap: true)
                Self.setTrapState(for: all[n])   // Mail's buttons do not take the focus: TurnOver holds the place
            }
        }
        script("trap_next", String(localized: "Where the app ignores Tab: the next control, in screen order", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Settings") { [weak self] g in self?.trapMove(g, forward: true) }.isAvailable = { Self.inTrapZone && !Self.focusInPage() }
        script("rowList_up", String(localized: "In a column of rows TurnOver reads as a list: the row above", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(-1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { !Self.isSideways($0.container) } == true }
        script("rowList_down", String(localized: "In a column of rows TurnOver reads as a list: the row below", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:downArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { !Self.isSideways($0.container) } == true }
        script("rowList_left", String(localized: "In a row of items TurnOver reads as a list: the item to the left", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(-1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { Self.isSideways($0.container) } == true }
        script("rowList_right", String(localized: "In a row of items TurnOver reads as a list: the item to the right", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { Self.isSideways($0.container) } == true }
        script("trap_previous", String(localized: "Where the app ignores Shift+Tab: the previous control, in screen order", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Settings") { [weak self] g in self?.trapMove(g, forward: false) }.isAvailable = { Self.inTrapZone && !Self.focusInPage() }
        script("settings_next", String(localized: "In a settings pane: the next control, in screen order", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Settings") { [weak self] g in self?.move(g, forward: true) }.isAvailable = { Self.inPane }
        script("settings_previous", String(localized: "In a settings pane: the previous control, in screen order", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Settings") { [weak self] g in self?.move(g, forward: false) }.isAvailable = { Self.inPane }
        script("ribbon_into", String(localized: "On a ribbon tab: into its commands (Tab or Down; Shift+Tab to the last)", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab", "kb:downArrow", "kb:shift+tab"], category: "Settings") { [weak self] g in self?.intoRibbon(g) }.isAvailable = { Self.onRibbonTab }
        // Return on a focused button presses that button, as on Windows. A Mac alert sends Return to its default button
        // whatever has the focus: a tester tabbed to "Open System Settings", heard it, pressed Return, and the alert's
        // default, Deny, was pressed instead (7 Oct 2026). Only where the window's default is another button.
        script("dialog_pressFocused", String(localized: "On a button in a window with a different default button: presses the button you are on", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:enter", "kb:numpadEnter"], category: "Settings") { g in
            guard let b = API.focusObject?.element else { g.send(); return }
            let r = AXUIElementPerformAction(b, kAXPressAction as CFString)
            Log.io("Return on a focused button that is not the default: pressed it → \(r.rawValue)")
            if r != .success { g.send() } else { SystemPrompts.checkPress(of: b, name: ObjectFactory.make(b).name) }
        }.isAvailable = { Self.returnWouldMissFocus }
        script("settings_pressHeld", String(localized: "In a settings pane: presses the control TurnOver is holding", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:space", "kb:enter"], category: "Settings") { [weak self] g in self?.pressHeld(g) }.isAvailable = { Self.holdingVirtual }
        // A grid's arrows (Chess's board): Up and Down a row, Left and Right a column.
        let inGrid = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { Self.gridColumns($0.container) != nil } == true }
        for (name, key, dir) in [("grid_up", "kb:upArrow", -1), ("grid_down", "kb:downArrow", 1), ("grid_left", "kb:leftArrow", -2), ("grid_right", "kb:rightArrow", 2)] {
            script(name, String(localized: "In a grid TurnOver reads as one: the next square that way", comment: "A command, as the key list and keyboard help say it"), gestures: [key], category: "Settings") { [weak self] _ in
                guard let v = Self.virtual, let c = Self.rowList(of: v)?.container, let cols = Self.gridColumns(c) else { return }
                self?.rowListMove(abs(dir) == 1 ? dir * cols : dir / 2)
            }.isAvailable = inGrid
        }
        registerToolbarScripts()
    }

    // MARK: Holding the place on a control that will not take the focus

    private static var virtual: AXUIElement?

    /// Move to a control in the pane (Tab, Shift+Tab, and from the tab bar). Safari's settings buttons take the focus
    /// and Safari moves it straight back to the toolbar (10 ms later); Tab then threw the user back to the tab
    /// (4 Oct 2026). For a moment, focus news for anything else is set aside; if the control has lost the focus by
    /// then, TurnOver holds the place on it, as VoiceOver's cursor does: Space and Return press it, and Tab goes on
    /// from it. A list with nothing selected has its first item selected, as on Windows ("228 items, nothing selected"
    /// said nothing useful).
    /// `byTrap`: moved by the Tab trap, which keeps Tab if the place must be held (not the settings panes' Tab).
    public static func focus(_ target: AXUIElement, byTrap: Bool = false) {
        scrollIntoView(target)
        // Where the trap's Tab landed, and how it lay: if it has moved by the next Tab, the window's list is walked
        // again (listStillGood).
        if byTrap { trapLanding = (target, TurnOverObject.frame(target)) }
        // TurnOver's own Tab moves count towards a loop as the app's do (TabLoop.noteLanding).
        if byTrap, ["kb:tab", "kb:shift+tab"].contains(InputManager.lastKeyIdentifier) {
            noteLanding(target, forward: InputManager.lastKeyIdentifier == "kb:tab")
        }
        // A row of a list the trap made: into the list, on that row.
        if let (rows, i, _, _) = rowList(of: target) {
            landInRowList(rows, at: i, entering: true)
            setTrapState(for: rows[0])
            return
        }
        // An iPad app on the Mac (Catalyst): Tab moves TurnOver's cursor only, as VoiceOver's cursor goes. Its controls
        // refuse the focus anyway, and pushing it at them left Phone not responding (a tester, 11 Nov 2026).
        if isCatalyst(target.pid) {
            expected = nil
            let trap = byTrap || inLoopWindow(target) || inTrapZone
            Log.io("settings: an iPad app; TurnOver's cursor moves, the app's focus is left alone")
            holdVirtual(target, speak: API.focusObject?.isSameElement(as: target) != true, ownTab: !trap)
            lock.lock(); _heldByTrap = trap && target.role != "AXWebArea" && !isInWeb(target); lock.unlock()   // a page keeps its own Tab (BT Cloud Work, 13 Nov 2026)
            return
        }
        _ = target.set(kAXFocusedAttribute, kCFBooleanTrue)
        if ["AXTable", "AXOutline"].contains(target.role), target.elements(kAXSelectedRowsAttribute).isEmpty,
           let first = target.elements(kAXRowsAttribute).first {
            _ = target.set(kAXSelectedRowsAttribute, [first] as CFArray)
        }
        expected = target
        ignoreOthersUntil = Date().addingTimeInterval(0.3)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard expected.map({ $0.isSame(target) }) ?? false else { return }
            expected = nil
            let app = AXUIElementCreateApplication(target.pid)
            if let now = app.element(kAXFocusedUIElementAttribute), !now.isSame(target), within(now, target) || holdsPage(now, target) {
                // Taken, inside: the app's own news of it is the focus (a page's first element). Unless no news came
                // (Surfshark's buttons take the focus on a text inside them and say nothing, 13 Nov 2026): then the
                // control itself is read.
                // A place still held elsewhere is let go: the next Tab goes on from here.
                if let v = virtual, !v.isSame(target) { virtual = nil; lock.lock(); _holding = false; lock.unlock() }
                // A page's own focus inside it is browse mode's to read. A control's (Surfshark's buttons put theirs on
                // a nameless part inside, and nothing was said, 13 Nov 2026) is read as the control.
                // Not when the app's news already put TurnOver there or inside (a list's row): read once, not twice
                // (a review, 13 Nov 2026).
                // (Surfshark's inner part is nameless and said nothing: then the control is read after all.)
                if let f = API.focusObject?.element, f.isSame(target) || holdsPage(f, target)
                    || (f.isSame(now) || within(f, target)) && !ObjectFactory.make(f).name.isEmpty { return }
                Log.io("settings: the app took the focus inside the \(target.role) without saying; read")
                virtual = nil; lock.lock(); _holding = false; lock.unlock()
                let obj = ObjectFactory.make(target)
                API.setFocusObject(obj, ancestors: obj.ancestors)
                focusMoved(to: obj)
                ObjectNavigator.shared.focusMoved(to: target, pid: target.pid)
                Tones.focusTick()
                Speech.cancel(); Speech.speakObject(obj, reason: .focus)
                return
            }
            if app.element(kAXFocusedUIElementAttribute).map({ $0.isSame(target) }) ?? false {
                // The app's focus was there all along (TurnOver held a place elsewhere, a copy window's bar): focusing
                // it again sends no news, so TurnOver comes back to it itself (11 Nov 2026: Shift Tab said nothing).
                // Or the app took the focus and sent no news of it (Surfshark: ten Tabs in silence, 13 Nov 2026).
                // TurnOver already on it: a place still held elsewhere is let go, or the next Tab starts from there
                // again (Surfshark: Tab went to the same second button each time, 13 Nov 2026).
                if API.focusObject?.isSameElement(as: target) == true, let v = virtual, !v.isSame(target) {
                    Log.io("settings: the focus is on the control moved to; the place held before let go")
                    virtual = nil; lock.lock(); _holding = false; lock.unlock()
                }
                guard API.focusObject?.isSameElement(as: target) != true, !(virtual.map { $0.isSame(target) } ?? false) else { return }
                if virtual == nil { Log.io("settings: the app took the focus without saying; read") }
                virtual = nil; lock.lock(); _holding = false; lock.unlock()
                let obj = ObjectFactory.make(target)
                API.setFocusObject(obj, ancestors: obj.ancestors)
                focusMoved(to: obj)
                ObjectNavigator.shared.focusMoved(to: target, pid: target.pid)
                Tones.focusTick()
                Speech.cancel(); Speech.speakObject(obj, reason: .focus)
            } else {
                // In a window whose Tab is the trap's (TabLoop, NewDialogs), the settings panes' Tab must not take
                // over from the held place: Shift Tab went to it and did nothing (11 Nov 2026).
                let trap = byTrap || inLoopWindow(target) || inTrapZone
                holdVirtual(target, speak: API.focusObject?.isSameElement(as: target) != true, ownTab: !trap)
                lock.lock(); _heldByTrap = trap && target.role != "AXWebArea" && !isInWeb(target); lock.unlock()   // a page keeps its own Tab (BT Cloud Work, 13 Nov 2026)
            }
        }
    }

    /// The app's module has Tab keys of its own (Messages' and WhatsApp's parts, Podcasts' areas, Books): the iPad-app
    /// rule leaves Tab to it. Global plugins come first, and the trap would have taken Tab from them. Kept per process.
    private static var moduleTab: [pid_t: Bool] = [:]
    static func moduleTakesTab(_ pid: pid_t) -> Bool {
        if let known = moduleTab[pid] { return known }
        let module = AppModuleHandler.shared.appModule(for: pid)
        let yes = module.everyBinding.contains { id, _ in id == "kb:tab" || id == "kb:shift+tab" }
        moduleTab[pid] = yes
        return yes
    }

    /// Made with Mac Catalyst (an iPad app on the Mac: Phone, Journal, News, Maps, Home): its Info.plist names iPad
    /// or Mac device families, which no AppKit app does. Kept per process.
    private static var catalyst: [pid_t: Bool] = [:]
    public static func isCatalyst(_ pid: pid_t) -> Bool {
        if let known = catalyst[pid] { return known }
        let url = NSRunningApplication(processIdentifier: pid)?.bundleURL
        let yes = url.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "UIDeviceFamily") } != nil
        catalyst[pid] = yes
        return yes
    }

    // MARK: Scrolling

    /// The scroll area an element sits in, nearest first.
    static func scrollArea(of e: AXUIElement) -> AXUIElement? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 15 { if x.role == "AXScrollArea" { return x }; if x.role == "AXWindow" { return nil }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    /// What TurnOver lands on is brought into sight, as VoiceOver's cursor does: a control below a dialog's or a
    /// settings pane's visible part was reached by Tab but stayed out of sight (a tester, 11 Nov 2026).
    /// Scrolled into sight first (its frame is read after): true, for use in a condition.
    static func scrollIntoViewThen(_ e: AXUIElement) -> Bool { scrollIntoView(e); return true }

    static func scrollIntoView(_ e: AXUIElement) {
        guard let area = scrollArea(of: e), let af = TurnOverObject.frame(area), let f = TurnOverObject.frame(e), f.height > 0,
              !af.insetBy(dx: -1, dy: -1).contains(CGRect(x: f.minX, y: f.minY, width: min(f.width, af.width), height: min(f.height, af.height))) else { return }
        let r = AXUIElementPerformAction(e, "AXScrollToVisible" as CFString)
        Log.io("scroll: \(e.role) brought into sight → \(describeError(r))")
    }

    /// Whether a scroll area has more below (or above) what is in sight: its vertical bar not at the end.
    static func canScroll(_ area: AXUIElement, down: Bool) -> Bool {
        guard let bar = area.element(kAXVerticalScrollBarAttribute), let v = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue else { return false }
        return down ? v < 0.995 : v > 0.005
    }

    /// A page down (or up): the area's own action, else its bar moved by what is in sight.
    static func scrollPage(_ area: AXUIElement, down: Bool) -> Bool {
        if AXUIElementPerformAction(area, (down ? "AXScrollDownByPage" : "AXScrollUpByPage") as CFString) == .success { return true }
        guard let bar = area.element(kAXVerticalScrollBarAttribute), let v = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue else { return false }
        // The part in sight as a share of the whole, from the area and its content.
        let seen = TurnOverObject.frame(area)?.height ?? 0
        let whole = area.elements(kAXChildrenAttribute).compactMap { TurnOverObject.frame($0)?.height }.max() ?? 0
        let step = whole > seen && whole > 0 ? (seen * 0.9) / (whole - seen) : 0.25
        let next = down ? min(1, v + step) : max(0, v - step)
        return bar.set(kAXValueAttribute, NSNumber(value: next)) == .success
    }

    /// What a list, table or outline has chosen: its selected rows or children.
    static func chosen(in e: AXUIElement) -> [AXUIElement] {
        guard ["AXList", "AXTable", "AXOutline", "AXGrid", "AXBrowser"].contains(e.role) else { return [] }
        let rows = e.elements(kAXSelectedRowsAttribute)
        return rows.isEmpty ? e.elements(kAXSelectedChildrenAttribute) : rows
    }

    /// The first or last control of a window's pane (from the tab bar: Tab goes to the first, Shift+Tab to the last).
    public static func endControl(in window: AXUIElement, last: Bool) -> AXUIElement? {
        let all = controls(in: window)
        return last ? all.last : all.first
    }

    /// The control just moved to, and until when news of focus elsewhere is set aside (main thread).
    static var expected: AXUIElement?
    public static var ignoreOthersUntil = Date.distantPast
    public static func setsAside(_ e: AXUIElement) -> Bool {
        guard Date() < ignoreOthersUntil, let x = expected else { return false }
        // Inside it, or a nameless group holding a page TurnOver moved to (Safari's focus went to the group round the
        // page). Never the window or a split view: those hold everything (a review, 13 Nov 2026).
        return !x.isSame(e) && !within(e, x) && !holdsPage(e, x)
    }

    /// Whether `e` is inside `container` (a few levels): a page TurnOver moved to puts its focus on a group inside
    /// itself (Safari, 13 Nov 2026: Tab from the toolbar to the page was set aside and said nothing).
    static func holdsPage(_ e: AXUIElement, _ page: AXUIElement) -> Bool {
        page.role == "AXWebArea" && e.role == "AXGroup" && within(page, e)
    }

    static func within(_ e: AXUIElement, _ container: AXUIElement) -> Bool {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 30 { if x.isSame(container) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    /// `ownTab`: false when an app module runs Tab itself and only wants the held place (System Settings' pane,
    /// 10 Nov 2026): this plugin's own Tab, a global plugin's, would otherwise come first and go round its own list.
    static func holdVirtual(_ target: AXUIElement, speak: Bool = true, ownTab: Bool = true) {
        // A control the app has thrown away meanwhile is no place to hold: the keys would go nowhere from it.
        guard target.role != "?" else { Log.io("settings: the control moved to is gone; not held"); return }
        let before = virtual ?? API.focusObject?.element
        virtual = target
        lock.lock(); _holding = true; _heldByTrap = false; lock.unlock()   // focus() says if the trap made this hold
        let obj = ObjectFactory.make(target)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        ObjectNavigator.shared.focusMoved(to: target, pid: target.pid)   // the context menu key acts where the cursor is
        let ontoToolbar = noteToolbar(target)
        lock.lock(); _inPane = ownTab; lock.unlock()
        Log.io("settings: \(target.role) will not keep the focus; TurnOver holds the place on it")
        if speak {
            Speech.cancel()
            // Onto a toolbar held by TurnOver: said, as the focus's ancestors say it when the app's focus goes there.
            if ontoToolbar { Speech.speakMessage(Role.toolBar.displayString) }
            // Into a pane, a section of it, a row with its words (PaneContext): "Keyboard property page", "Text Input
            // grouping", "Input Sources, British – PC…", then the control.
            let context = PaneContext.news(from: before, to: target)
            if !context.isEmpty { Log.io("settings: context, \(context.count) parts"); Speech.speakMessage(context.joined(separator: ", ")) }
            Speech.speakObject(obj, reason: .focus)
        }
    }

    /// Space or Return on a held control: press it.
    private func pressHeld(_ g: KeyboardGesture) {
        // A held place whose control has gone (a view replaced with no news) lets go, and the key goes to the app
        // rather than vanishing in a failed press (a review, 13 Nov 2026).
        Self.dropDeadHold()
        // (Or a helper drawing for the app in front: System Settings' pane extensions, 13 Nov 2026.)
        guard let v = Self.virtual, API.focusObject?.isSameElement(as: v) == true,
              v.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier
                || NSRunningApplication(processIdentifier: v.pid).map({ AXHandler.shared.isHelperOfActiveApp($0) }) == true else { g.send(); return }
        if RowControl.pressToggle(in: v) { return }
        // An app's module that presses some held places its own way (Contacts' details open their menu, its action
        // icons are clicked).
        if let b = NSRunningApplication(processIdentifier: v.pid)?.bundleIdentifier, let press = Self.pressOverrides[b], press(v) { return }
        let window = Self.windowOf(v), titleBefore = window?.string(kAXTitleAttribute)
        // A link with no actions at all (SwiftUI's "Learn more…" in a line of text): clicked.
        if v.role == "AXLink" {
            var names: CFArray?
            AXUIElementCopyActionNames(v, &names)
            // Its address, where it carries one (System Settings keeps it in the identifier: help://…), opened
            // directly: a click missed a link scrolled out of sight.
            if ((names as? [String]) ?? []).isEmpty,
               let id = v.string(kAXIdentifierAttribute) ?? (v.attr(kAXURLAttribute) as? URL)?.absoluteString,
               let url = URL(string: id), let scheme = url.scheme, ["help", "http", "https", "x-apple.systempreferences", "x-help-action"].contains(scheme) {
                Log.io("settings: opened a link's \(scheme) address")
                Tones.press()
                NSWorkspace.shared.open(url)
                return
            }
            if ((names as? [String]) ?? []).isEmpty, Self.scrollIntoViewThen(v), let f = TurnOverObject.frame(v), f.width > 0 {
                Log.io("settings: clicked a link with no actions")
                Tones.press()
                Mouse.click(at: CGPoint(x: f.midX, y: f.midY), button: .left, count: 1)
                return
            }
        }
        let r = AXUIElementPerformAction(v, kAXPressAction as CFString)
        Log.io("settings: pressed the held \(v.role) → \(describeError(r))")
        if r == .success {
            Tones.press()
            // A press that changes the whole view says where it went, by the window's new title. Pressing a stock in
            // Stocks showed its page and said nothing (12 Nov 2026); the focus stays put in an iPad app, so no
            // focus change speaks it.
            if let window {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    // Or took away what was pressed, its view with it: Stocks' Back goes from a stock to the list
                    // under the same title, and said nothing (12 Nov 2026).
                    let gone = v.role == "?" || Self.windowOf(v) == nil
                    guard let t = window.string(kAXTitleAttribute), !t.isEmpty, t != titleBefore || gone else { return }
                    Log.io(gone ? "settings: the press took its control away; saying the window" : "settings: the press changed the window's title; saying it")
                    Speech.speakItem(t)
                    if gone { Self.dropDeadHold() }
                }
            }
            if ["AXCheckBox", "AXRadioButton"].contains(v.role) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { Speech.speakCheckState(of: v) } }
        }
    }
    /// A held place on a control the app has since thrown away (a pane rebuilt): let go, and back to the app's focus.
    static func dropDeadHold() {
        // Gone, or cut loose from its window: an iPad app's view replaced by another keeps answering for the old
        // one's buttons, but with no window (Stocks' Right Arrow to the next story, 12 Nov 2026: Tab said nothing).
        guard let v = virtual, v.role == "?" || windowOf(v) == nil else { return }
        virtual = nil; lock.lock(); _holding = false; lock.unlock()
        Log.io("settings: the held control is gone; back to the app's focus")
        if let pid = API.focusObject?.element.pid, let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) {
            API.setFocusObject(ObjectFactory.make(f), ancestors: API.focusAncestors)
            focusMoved(to: ObjectFactory.make(f))
        }
    }
    /// Another app came to the front: a place held in the one that left is let go. TurnOver kept Phone's buttons
    /// held with Music in front, Tab went round Phone's and Space would have pressed Call (11 Nov 2026).
    static func appActivated(_ pid: pid_t) {
        // The pane, trap and ribbon flags are the app's that left: reset whether or not a place was held, so Tab in
        // the new app isn't taken by the old one's mode (a review, 13 Nov 2026).
        lock.lock(); _inPane = false; _inTrapZone = false; _onRibbonTab = false; lock.unlock()
        pruneTrapZones()   // (places gone with their windows)
        // (A place in a helper drawing for the app now in front stays: System Settings' pane extensions.)
        guard let v = virtual, v.pid != pid,
              NSRunningApplication(processIdentifier: v.pid).map({ AXHandler.shared.isHelperOfActiveApp($0) }) != true else { return }
        Log.io("settings: another app in front; the place held in pid \(v.pid) let go")
        virtual = nil
        lock.lock(); _holding = false; _heldByTrap = false; _inTrapZone = false; lock.unlock()
    }

    static var holdingVirtual: Bool { lock.lock(); defer { lock.unlock() }; return _holding }
    private static var _holding = false

    /// The window an element is in. Safari's settings controls do not say (no AXWindow; 4 Oct 2026): walk up to it.
    /// Where Tab goes round: the sheet a control is in, else its window. Tab in a sheet stays in it, as the app's own
    /// does; TurnOver's went to the toolbar behind Journal's welcome sheet (11 Nov 2026).
    static func scopeOf(_ e: AXUIElement) -> AXUIElement? {
        if let c = FocusChain.of(e) {
            if let x = c.first(25, where: { ["AXSheet", "AXPopover", "AXWindow"].contains(c.roles[$0]) }) { return x }
        } else {
            var p: AXUIElement? = e; var hops = 0
            while let x = p, hops < 25 { let r = x.role; if r == "AXSheet" || r == "AXPopover" { return x }; if r == "AXWindow" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        }
        // Or the app's own front window, for a control that names neither (iMazing's sidebar: Tab there gave up in
        // silence, 13 Nov 2026).
        if let w = windowOf(e) { return w }
        // Only a window the control sits inside on screen: another window's Tab is no place to jump to (a review).
        guard let w = AXUIElementCreateApplication(e.pid).element(kAXFocusedWindowAttribute), let wf = TurnOverObject.frame(w),
              // Where it starts, not all of it: a list counts all its rows and runs past the window (iMazing's
              // sidebar, 13 Nov 2026: Tab there was silent again).
              let f = TurnOverObject.frame(e), f.width > 0, wf.insetBy(dx: -2, dy: -2).contains(CGPoint(x: f.minX + 1, y: f.minY + 1)) else { return nil }
        return w
    }

    public static func windowOf(_ e: AXUIElement) -> AXUIElement? {
        if let w = e.element(kAXWindowAttribute) { return w }
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 20 { if x.role == "AXWindow" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }

    static let controlRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXTextField", "AXTextArea", "AXComboBox",
                                            "AXSlider", "AXTable", "AXOutline", "AXList", "AXIncrementor", "AXMenuButton", "AXColorWell", "AXDateField", "AXLink",
                                            // A document in the window (Mail's message): one stop, read in browse mode there.
                                            "AXWebArea",
                                            // A grid (Calendar's month of day lists): one stop, its own arrows inside.
                                            "AXGrid"]

    /// A scroll area that takes the keyboard itself and holds no list, table, text or page of its own: a board or a
    /// canvas (Freeform's). Scroll areas round lists and documents don't count: what they hold is the stop.
    static func canvas(_ e: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable) == .success, settable.boolValue else { return false }
        let held: Set<String> = ["AXTable", "AXOutline", "AXList", "AXTextArea", "AXWebArea", "AXGrid", "AXBrowser"]
        if e.elements(kAXChildrenAttribute).contains(where: { held.contains($0.role) }) { return false }
        // Nor a page a little way in (Mail's message: a group holding a web area).
        if e.firstDescendant(role: "AXWebArea", maxVisited: 40) != nil { return false }
        // Nor one round controls that take the keyboard themselves (a settings pane): those are the stops (a review,
        // 13 Nov 2026).
        var queue = e.elements(kAXChildrenAttribute).prefix(20).map { ($0, 1) }, seen = 0
        while !queue.isEmpty, seen < 40 {
            let (x, d) = queue.removeFirst(); seen += 1
            if controlRoles.contains(x.role) {
                var st: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(x, kAXFocusedAttribute as CFString, &st) == .success, st.boolValue { return false }
            }
            if d < 2 { queue += x.elements(kAXChildrenAttribute).prefix(20).map { ($0, d + 1) } }
        }
        return true
    }

    /// An item iPad apps make pressable without calling it a button: Stocks' symbols and news stories are generic
    /// elements with a name and a press, so Tab never reached the stock list or the news (12 Nov 2026).
    static func isPressableItem(_ e: AXUIElement) -> Bool {
        guard e.role == "AXGenericElement", !(e.string(kAXDescriptionAttribute) ?? "").isEmpty else { return false }
        var acts: CFArray?
        guard AXUIElementCopyActionNames(e, &acts) == .success else { return false }
        return ((acts as? [String]) ?? []).contains(kAXPressAction)
    }

    /// The pane's controls in screen order: rows top to bottom (within 8 points is one row), then left to right.
    /// `unfocusable`: with the enabled controls that refuse the focus too (the Tab trap's stops: TurnOver holds them).
    static func controls(in window: AXUIElement, toolbars: Bool = false, unfocusable withUnfocusable: Bool = false) -> [AXUIElement] {
        var found: [(AXUIElement, CGRect)] = []
        // Controls that refuse the focus: Catalyst's (Home's and Journal's welcome sheets, 11 Nov 2026) all do, so
        // the window had no stops and Tab did nothing. Used when there is nothing else; TurnOver holds the place.
        var unfocusable: [(AXUIElement, CGRect)] = []
        var visited = 0
        // `clip`: what can be seen of the scroll areas around. A list's frame is all its rows: Contacts' list of 164
        // was 8,000 points tall, its middle far below the window, so it sorted after the card beside it, and Shift
        // Tab from it went to the card, not to the search field above it (12 Nov 2026). Placed by what's in view.
        func walk(_ e: AXUIElement, _ depth: Int, _ clip: CGRect?) {
            guard visited < 600, depth < 14 else { return }
            visited += 1
            let role = e.role
            if role == "AXToolbar", !toolbars { return }
            // A scroll bar's arrows and page areas are buttons no one Tabs to (two nameless stops in Contacts).
            if role == "AXScrollBar" { return }
            var clip = clip
            if role == "AXScrollArea", let f = TurnOverObject.frame(e), f.width > 0, f.height > 0 { clip = clip.map { $0.intersection(f) } ?? f }
            let sub = e.string(kAXSubroleAttribute) ?? ""
            if ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(sub) { return }
            // A canvas: a scroll area that takes the keyboard itself (Freeform's board), where the app's keys work.
            // Tab never came back to it (12 Nov 2026). Still walked into: what's on it may be controls of its own.
            if role == "AXScrollArea", canvas(e), let f = TurnOverObject.frame(e), f.width > 0, f.height > 0 { found.append((e, f)) }
            // (A link in a line of text says it's disabled, and opens when clicked: kept, SwiftUI's "Learn more…".)
            if controlRoles.contains(role) || isPressableItem(e), role == "AXLink" || (e.attr(kAXEnabledAttribute) as? Bool) != false, let whole = TurnOverObject.frame(e), whole.width > 0, whole.height > 0 {
                // Out of view altogether: where it is (a row scrolled away is still in its place in the order).
                let seen = clip.map { whole.intersection($0) }, f = seen.map { $0.isNull || $0.isEmpty ? whole : $0 } ?? whole
                var settable: DarwinBoolean = false
                AXUIElementIsAttributeSettable(e, kAXFocusedAttribute as CFString, &settable)
                if settable.boolValue { found.append((e, f)) } else { unfocusable.append((e, f)) }
                if ["AXTable", "AXOutline", "AXList", "AXTextArea", "AXWebArea", "AXGrid"].contains(role) { return }   // one stop each
            }
            for k in e.elements(kAXChildrenAttribute) { walk(k, depth + 1, clip) }
        }
        walk(window, 0, nil)
        if withUnfocusable { found += unfocusable }
        // Twins: one control inside another in the same place, the same name (Weather's tabs, a radio button with a
        // button in it): one stop, the outer one. Each tab was said twice, a Tab each (11 Nov 2026).
        var kept: [(AXUIElement, CGRect)] = []
        var keptNames: [String] = []
        for (e, f) in found {
            // Only a control in the same place as one kept needs its name (names cost a few calls each).
            let twins = kept.indices.filter { i in let k = kept[i].1; return abs(k.minX - f.minX) < 3 && abs(k.minY - f.minY) < 3 && abs(k.width - f.width) < 3 && abs(k.height - f.height) < 3 }
            if !twins.isEmpty {
                let name = ObjectFactory.make(e).name
                var twin = false
                for i in twins {
                    if keptNames[i].isEmpty { keptNames[i] = ObjectFactory.make(kept[i].0).name }
                    if keptNames[i] == name { twin = true; break }
                }
                if twin { continue }
            }
            kept.append((e, f)); keptNames.append("")
        }
        // A toolbar is one stop; the arrows go along it (Toolbar.swift).
        if toolbars { kept = collapsingToolbar(kept, in: window) }
        return paneOrdered(collapsingRowLists(kept), in: window)
    }

    // MARK: Lists the app doesn't call lists

    /// Rows found as lists: each list's rows, top to bottom (main thread; refreshed by each walk of a window).
    static var rowLists: [(rows: [AXUIElement], stop: AXUIElement, container: AXUIElement)] = []
    /// Row lists that run left to right (their containers): Left and Right move in them, not Up and Down.
    static var sidewaysLists: [AXUIElement] = []
    /// Grids of same-size buttons taken as one stop (Chess's board), with how many columns: the arrows go both ways.
    static var gridLists: [(container: AXUIElement, columns: Int)] = []
    /// How many columns, when the frames form a grid of five or more rows of five or more, every row as long; 0
    /// otherwise. Rows by their middles, a few points apart at most: Chess's board is drawn in perspective, its squares
    /// each a different size (13 Nov 2026). Pure.
    package static func gridColumns(of frames: [CGRect]) -> Int {
        guard frames.count >= 25 else { return 0 }
        var bands: [(y: CGFloat, n: Int)] = []
        for f in frames.sorted(by: { $0.midY < $1.midY }) {
            if let last = bands.last, f.midY - last.y < 6 { bands[bands.count - 1].n += 1 } else { bands.append((f.midY, 1)) }
        }
        guard bands.count >= 5, let n = bands.first?.n, n >= 5, bands.allSatisfy({ $0.n == n }) else { return 0 }
        return n
    }
    static func gridColumns(_ container: AXUIElement) -> Int? { gridLists.first { CFEqual($0.container, container) }?.columns }
    static func isSideways(_ container: AXUIElement) -> Bool { sidewaysLists.contains { CFEqual($0, container) } }

    /// How many rows lie above the rows in sight, counted as the list is scrolled (the list being read).
    static var rowOffset: (container: AXUIElement, n: Int)?

    /// A column of rows the same width, one under another, that fill their container: a list in all but name. iPad
    /// apps build their lists so (Phone's recent calls: a group of groups, one button each), and Tab went through
    /// every call before reaching the buttons beside them. One stop for the trap: Up and Down go through the rows,
    /// Tab goes on past them (a tester's idea, 11 Nov 2026). Not a grid (Calculator's keys: not one column).
    static func collapsingRowLists(_ found: [(AXUIElement, CGRect)]) -> [(AXUIElement, CGRect)] {
        var byContainer: [(container: AXUIElement, members: [(AXUIElement, CGRect)], wrapped: Bool)] = []
        for (e, f) in found where !["AXTable", "AXOutline", "AXList", "AXTextArea", "AXTextField", "AXSlider"].contains(e.role) {
            guard var c = e.element(kAXParentAttribute) else { continue }
            // A row's own wrapper (a group holding just this button) is not the list: its parent is.
            var wrapped = false
            if ["AXGroup", "AXCell", "AXRow"].contains(c.role), c.elements(kAXChildrenAttribute).count == 1, let up = c.element(kAXParentAttribute) { c = up; wrapped = true }
            if let i = byContainer.firstIndex(where: { CFEqual($0.container, c) }) { byContainer[i].members.append((e, f)); byContainer[i].wrapped = byContainer[i].wrapped && wrapped }
            else { byContainer.append((c, [(e, f)], wrapped)) }
        }
        var lists: [(rows: [AXUIElement], stop: AXUIElement, container: AXUIElement)] = []
        var drop: [AXUIElement] = []
        // Rows each in a wrapper of their own (a list's cells), or five or more: an alert's buttons, stacked one
        // under another, are three buttons, not a list (macOS 27's alerts, 11 Nov 2026).
        for (c, members, wrapped) in byContainer where members.count >= (wrapped ? 3 : 5) {
            guard let cf = TurnOverObject.frame(c) else { continue }
            let first = members[0].1
            let column = members.allSatisfy { abs($0.1.minX - first.minX) < 3 && abs($0.1.width - first.width) < 3 }
            let wide = first.width >= cf.width * 0.5
            let ys = members.map { $0.1.minY }
            let stacked = Set(ys.map { Int($0) }).count == members.count
            // Or a row of five or more items side by side, the same size (Stocks' chart: a point an hour, each a
            // Tab, 12 Nov 2026): one stop, Left and Right through it. Not buttons, unless the row runs on past its
            // container (Books' shelves: a Tab per book, 12 Nov 2026): a row of buttons in sight is a segmented
            // choice or a dialog's buttons, and keeps a stop each. The row is the largest set of same-size items on one
            // line: a shelf's heading button sits above its books.
            var rowSet: [(AXUIElement, CGRect)] = []
            if !(column && wide && stacked) {
                var groups: [String: [(AXUIElement, CGRect)]] = [:]
                for m in members { groups["\(Int(m.1.minY / 3)),\(Int(m.1.height / 3)),\(Int(m.1.width / 3))", default: []].append(m) }
                rowSet = groups.values.max { $0.count < $1.count } ?? []
            }
            let buttonKinds = ["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXLink"]
            let overflows = rowSet.contains { !cf.insetBy(dx: -2, dy: -2).contains($0.1) }
            let sideways = rowSet.count >= 5
                && (overflows || rowSet.allSatisfy { !buttonKinds.contains($0.0.role) })
                && Set(rowSet.map { Int($0.1.minX) }).count == rowSet.count
            // Or a picture holding places to press (Maps' map: forty-odd markers, a Tab each, 12 Nov 2026): one
            // stop, Up and Down through the places, top to bottom.
            let picture = c.role == "AXImage" && members.count >= 3
            // Or a grid of buttons, five or more rows of five or more, every row as long (Chess's board: 64 squares,
            // a Tab each, 13 Nov 2026): one stop, all four arrows across it. Calculator's twenty keys stay keys.
            var gridCols = 0
            // (One kind of control, and not a collection that scrolls: its rows go on past the window, a review.)
            if !(column && wide && stacked), !sideways, !picture, Set(members.map { $0.0.role }).count == 1, !scrolls(c) { gridCols = gridColumns(of: members.map { $0.1 }) }
            guard (column && wide && stacked) || sideways || picture || gridCols > 0 else { continue }
            if gridCols > 0 {
                gridLists.removeAll { CFEqual($0.container, c) }
                gridLists.append((c, gridCols)); if gridLists.count > 6 { gridLists.removeFirst() }
            }
            if sideways, !sidewaysLists.contains(where: { CFEqual($0, c) }) { sidewaysLists.append(c); if sidewaysLists.count > 12 { sidewaysLists.removeFirst() } }
            let members = sideways ? rowSet : members
            let sorted = members.sorted { sideways ? $0.1.minX < $1.1.minX : abs($0.1.midY - $1.1.midY) > 5 ? $0.1.midY < $1.1.midY : $0.1.minX < $1.1.minX }
            let rows = sorted.map { $0.0 }
            // The list's stop: its first row in sight (rows scrolled out above sit outside the window, and the list
            // was put in the wrong place in the order, Phone, 11 Nov 2026).
            let stop = sorted.first { cf.insetBy(dx: -2, dy: -2).contains(CGPoint(x: $0.1.midX, y: $0.1.midY)) }?.0 ?? rows[0]
            lists.append((rows, stop, c))
            drop += rows.filter { !CFEqual($0, stop) }
        }
        // Kept from walk to walk (a walk of one part of the window finds none): a list found again replaces its old self.
        if !lists.isEmpty { rowLists = lists + rowLists.filter { old in !lists.contains { new in new.rows.contains { n in old.rows.contains { CFEqual($0, n) } } } }.suffix(8) }
        if !lists.isEmpty { Log.io("tab trap: \(lists.count) column(s) of rows taken as lists (\(lists.map { String($0.rows.count) }.joined(separator: ", ")) rows)") }
        return found.filter { x in !drop.contains { CFEqual($0, x.0) } }
    }

    /// The row list an element is a row of, and where.
    static func rowList(of e: AXUIElement) -> (rows: [AXUIElement], at: Int, stop: AXUIElement, container: AXUIElement)? {
        for l in rowLists { if let i = l.rows.firstIndex(where: { $0.isSame(e) }) { return (l.rows, i, l.stop, l.container) } }
        return nil
    }

    /// A list that holds only the rows in sight and scrolls for the rest (an iPad app's: Phone showed 11 of its calls).
    static func scrolls(_ container: AXUIElement) -> Bool {
        var names: CFArray?
        AXUIElementCopyActionNames(container, &names)
        return ((names as? [String]) ?? []).contains("AXScrollDownByPage")
    }

    /// The rows in a list's container now, found as the first were: the same column, each alone or in a wrapper.
    static func rowsIn(_ container: AXUIElement, like template: AXUIElement) -> [AXUIElement] {
        guard let t = TurnOverObject.frame(template) else { return [] }
        func matches(_ e: AXUIElement) -> CGRect? {
            guard e.role == template.role, let f = TurnOverObject.frame(e), abs(f.minX - t.minX) < 3, abs(f.width - t.width) < 3, f.height > 0 else { return nil }
            return f
        }
        var out: [(AXUIElement, CGRect)] = []
        for c in container.elements(kAXChildrenAttribute) {
            if let f = matches(c) { out.append((c, f)); continue }
            let kids = c.elements(kAXChildrenAttribute)
            if kids.count == 1, let f = matches(kids[0]) { out.append((kids[0], f)) }
        }
        return out.sorted { $0.1.minY < $1.1.minY }.map { $0.0 }
    }

    /// Up and Down in a row list TurnOver is holding.
    private func rowListMove(_ delta: Int) {
        guard let v = Self.virtual, let (rows, i, _, container) = Self.rowList(of: v) else { return }
        // A grid: Left and Right stay in the row; Up and Down (a row's width at a time) stay in the grid.
        if let cols = Self.gridColumns(container) {
            let j = i + delta
            guard rows.indices.contains(j), abs(delta) != 1 || j / cols == i / cols else { Tones.edge(); return }
            Self.landInRowList(rows, at: j, entering: false); return
        }
        let j = i + delta
        if rows.indices.contains(j) { Self.landInRowList(rows, at: j, entering: false); return }
        // Past the rows in sight: the list is scrolled a page, read again, and the move goes on from the same row
        // (found by its words if the list made it anew). Unafraid to scroll (a tester, 11 Nov 2026).
        guard Self.scrolls(container), !Self.isSideways(container) else { Tones.edge(); return }
        let name = ObjectFactory.make(v).name
        let r = AXUIElementPerformAction(container, (delta > 0 ? "AXScrollDownByPage" : "AXScrollUpByPage") as CFString)
        Log.io("row list: scrolled \(delta > 0 ? "down" : "up") a page → \(describeError(r))")
        guard r == .success else { Tones.edge(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            let fresh = Self.rowsIn(container, like: v)
            guard !fresh.isEmpty else { Tones.edge(); return }
            let k = fresh.firstIndex(where: { $0.isSame(v) }) ?? fresh.firstIndex(where: { ObjectFactory.make($0).name == name })
            let next = k.map { $0 + delta } ?? (delta > 0 ? 0 : fresh.count - 1)
            guard fresh.indices.contains(next) else { Log.io("row list: the end of the list"); Tones.edge(); return }
            // Rows above the ones in sight: counted by how far the row held moved up or down the list in sight.
            let before = Self.rowOffset.flatMap { $0.container.isSame(container) ? $0.n : nil } ?? 0
            Self.rowOffset = (container, max(0, before + (k.map { i - $0 } ?? (delta > 0 ? rows.count : -fresh.count))))
            Self.rowLists.removeAll { $0.container.isSame(container) }
            Self.rowLists.insert((fresh, fresh[0], container), at: 0)
            Self.landInRowList(fresh, at: next, entering: false)
        }
    }

    /// On a row of a row list: held, said with its place in the list.
    /// The row last read in each list (latest first, a few lists).
    static var lastRow: [(container: AXUIElement, row: AXUIElement)] = []

    static func landInRowList(_ rows: [AXUIElement], at i: Int, entering: Bool) {
        let row = rows[i]
        if let c = rowList(of: row)?.container {
            lastRow.removeAll { $0.container.isSame(c) }
            lastRow.insert((c, row), at: 0)
            if lastRow.count > 8 { lastRow.removeLast() }
        }
        scrollIntoView(row)
        virtual = row
        lock.lock(); _holding = true; _heldByTrap = true; _inPane = false; lock.unlock()
        let obj = ObjectFactory.make(row)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        // The review cursor too: the context menu key opens the menu for what it is on, and it stayed on the call
        // the app had chosen (a tester, 11 Nov 2026).
        ObjectNavigator.shared.focusMoved(to: row, pid: row.pid)
        noteToolbar(row)
        Tones.focusTick()
        Speech.cancel()
        let container = rowList(of: row)?.container
        let scrolling = container.map { scrolls($0) && !isSideways($0) } ?? false
        // Counted afresh in a list newly entered; kept on coming back to the one being read (still scrolled as it was).
        if entering, let c = container, rowOffset.map({ !$0.container.isSame(c) }) ?? true { rowOffset = (c, 0) }
        let offset = (container.flatMap { c in rowOffset.flatMap { $0.container.isSame(c) ? $0.n : nil } }) ?? 0
        var parts: [String] = []
        // A list that scrolls holds only the rows in sight: no count of them all is known.
        if entering, let c = container, let cols = gridColumns(c) {
            parts.append(String(localized: "grid, \(rows.count / cols) by \(cols)", comment: "A grid of buttons reached by Tab: rows by columns"))
        } else if entering { parts.append(scrolling ? String(localized: "list", comment: "A list reached by Tab, its length unknown") : String(localized: "list, \(Phrases.items(rows.count))", comment: "A column of rows TurnOver reads as a list, reached by Tab: %@ is the count")) }
        parts.append(Speech.joined(Speech.objectPropertiesSpeech(obj, reason: .query)))
        if let c = container, let cols = gridColumns(c) {
            parts.append(String(localized: "row \(i / cols + 1), column \(i % cols + 1)", comment: "A square's place in a grid of buttons"))
        } else {
            parts.append(scrolling ? String(localized: "item \(offset + i + 1)", comment: "A row's place in a list whose length is unknown") : Phrases.position(i + 1, of: rows.count))
        }
        Speech.speakItem(parts.joined(separator: ", "))
    }

    /// Screen order, pane by pane: in a window split into panes (a sidebar, a list, a detail), each pane's controls
    /// go together, left pane first, as a window's own Tab goes. Sorted by rows alone, the sidebar's items were
    /// threaded through the list's and the detail's (TurnOver's own settings; the rules survey, 11 Nov 2026).
    /// Controls outside the split come before it if above, after it if below.
    static func paneOrdered(_ found: [(AXUIElement, CGRect)], in window: AXUIElement) -> [AXUIElement] {
        var split: AXUIElement?, splitFrame: CGRect?, panes: [CGRect] = []
        var queue: [(AXUIElement, Int)] = [(window, 0)], seen = 0
        // Few calls: an iPad app answers slowly, and a walk asking every group for its children's frames left Phone
        // too slow to take Tab (11 Nov 2026). Only big groups near the top are looked into.
        let tall = (TurnOverObject.frame(window)?.height ?? 0) * 0.4
        while split == nil, !queue.isEmpty, seen < 60 {   // the outermost split group, breadth first
            let (e, d) = queue.removeFirst(); seen += 1
            let role = e.role
            if ["AXSplitGroup", "AXGroup"].contains(role), let f = TurnOverObject.frame(e), f.height > 0, role == "AXSplitGroup" || f.height >= tall {
                // Panes are containers: the Save sheet's split group holds its controls themselves beside a divider
                // of no width, and each became a pane of its own, Delete first (12 Nov 2026).
                let kids = e.elements(kAXChildrenAttribute).filter { ["AXGroup", "AXScrollArea", "AXSplitGroup", "AXTabGroup", "AXLayoutArea", "AXList", "AXOutline", "AXTable", "AXWebArea", "AXBrowser"].contains($0.role) }.compactMap { TurnOverObject.frame($0) }.filter { $0.width > 0 && $0.height > 0 }
                    .sorted { $0.minX != $1.minX ? $0.minX < $1.minX : $0.minY < $1.minY }
                // A split group, or a plain group laid out as columns: its children side by side, each the group's
                // height, none overlapping. iPad apps build their sidebar and detail so (Phone's Recents beside the
                // call's details: Tab wove the two together, a tester, 11 Nov 2026).
                let columns = kids.count > 1 && kids.allSatisfy { $0.height >= f.height * 0.7 }
                    && zip(kids, kids.dropFirst()).allSatisfy { $0.maxX <= $1.minX + 2 }
                // A split group's dividers say where its panes are. Its children's frames may not: Mail's message
                // side reports the whole window's width, the sidebar inside it, so the sidebar sorted after the
                // message (12 Nov 2026).
                let dividers = e.role == "AXSplitGroup" ? e.elements(kAXChildrenAttribute).filter { $0.role == "AXSplitter" }.compactMap { TurnOverObject.frame($0) }
                    .filter { $0.height >= f.height * 0.5 && $0.width < 20 }.map { $0.midX }.sorted() : []
                if !dividers.isEmpty {
                    let edges = [f.minX] + dividers + [f.maxX]
                    split = e; splitFrame = f
                    panes = zip(edges, edges.dropFirst()).map { CGRect(x: $0, y: f.minY, width: max(0, $1 - $0), height: f.height) }
                } else if kids.count > 1, e.role == "AXSplitGroup" || columns { split = e; splitFrame = f; panes = kids }
            }
            if d < 5, ["AXWindow", "AXSheet", "AXPopover", "AXGroup", "AXSplitGroup", "AXScrollArea", "AXLayoutArea"].contains(role) { queue += e.elements(kAXChildrenAttribute).map { ($0, d + 1) } }
        }
        // The toolbar comes first, whole: it sits over the columns, and its buttons were dealt out among them.
        let toolbars = window.elements(kAXChildrenAttribute).filter { $0.role == "AXToolbar" }.compactMap { TurnOverObject.frame($0) }
        // Rows: middles within 8 points of a row's first are one row. Cut into fixed 8-point bands, two buttons a
        // point apart could fall either side of a line (a Save sheet's Delete went after Cancel and Save, 12 Nov 2026).
        var rowStarts: [CGFloat] = []
        for y in found.map({ $0.1.midY }).sorted() where rowStarts.last.map({ y - $0 > 8 }) ?? true { rowStarts.append(y) }
        func key(_ f: CGRect) -> (Int, Int, Int, CGFloat) {
            let row = rowStarts.lastIndex { $0 <= f.midY } ?? 0
            if toolbars.contains(where: { $0.contains(CGPoint(x: f.midX, y: f.midY)) }) { return (-1, 0, row, f.minX) }
            guard let sf = splitFrame else { return (0, 0, row, f.minX) }
            if f.midY < sf.minY { return (0, 0, row, f.minX) }
            if f.midY > sf.maxY { return (2, 0, row, f.minX) }
            // In none (Contacts' search field, over its list but outside the list's scroll area): the column it's in.
            let pane = panes.firstIndex { $0.insetBy(dx: -1, dy: -1).contains(CGPoint(x: f.midX, y: f.midY)) }
                ?? panes.firstIndex { f.midX >= $0.minX - 1 && f.midX <= $0.maxX + 1 } ?? panes.count
            return (1, pane, row, f.minX)
        }
        return found.map { ($0.0, key($0.1)) }.sorted { a, b in a.1 < b.1 }.map { $0.0 }
    }

    /// Where Tab is typed or handled by the page, not a move between controls: text, documents, web content.
    static func typesTab(_ obj: TurnOverObject) -> Bool {
        if [.editableText, .passwordEdit, .document].contains(obj.role) { return true }
        var p: AXUIElement? = obj.element; var hops = 0
        while let x = p, hops < 20 { if x.role == "AXWebArea" { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }

    private func intoRibbon(_ g: KeyboardGesture) {
        guard let tab = API.focusObject?.element, let r = Self.ribbon(of: tab) else { g.send(); return }
        let last = g.modifiers.contains(.shift)
        func enter() -> Bool {
            guard let area = Self.commandsArea(in: r) else { return false }
            // The app's own order (its children), as Word's Tab goes: Paste first, not the Font box at the top.
            // Not a greyed-out one (Paste with nothing to paste): it refuses the focus.
            let all = Self.controlsInOrder(in: area).filter { ($0.attr(kAXEnabledAttribute) as? Bool) != false }
            guard let target = last ? all.last : all.first else { return false }
            Log.io("ribbon: into \(area.string(kAXDescriptionAttribute).map(Log.words) ?? "the commands") at \(target.role)")
            Self.focus(target)
            return true
        }
        if enter() { return }
        // A collapsed ribbon shows a tab's commands only while it is open: open it, then go in.
        AXUIElementPerformAction(tab, kAXPressAction as CFString)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            if !enter() { Speech.speakMessage(String(localized: "no commands", comment: "Spoken message")) }
        }
    }

    /// The window's enabled controls in the order of its children with `e` among them, and where it is; nil when `e`
    /// isn't in the window.
    static func controlsAround(_ e: AXUIElement, in window: AXUIElement) -> ([AXUIElement], Int)? {
        var out: [AXUIElement] = []; var at: Int?; var visited = 0
        func walk(_ x: AXUIElement) {
            visited += 1
            guard visited < 800 else { return }
            if x.isSame(e) { at = out.count; out.append(x); return }
            if controlRoles.contains(x.role) || x.role == "AXRadioButton" {
                // Not the title bar's close, zoom and minimise buttons: they aren't the window's controls.
                let frame = ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(x.string(kAXSubroleAttribute) ?? "")
                if !frame, (x.attr(kAXEnabledAttribute) as? Bool) != false { out.append(x) }
                return
            }
            for c in x.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(window)
        guard let at, out.count > 1 else { return nil }
        return (out, at)
    }

    /// The controls inside an element in the order of its children (depth first).
    static func controlsInOrder(in root: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []; var visited = 0
        func walk(_ e: AXUIElement) {
            visited += 1
            guard visited < 800 else { return }
            if controlRoles.contains(e.role) || e.role == "AXRadioButton" { out.append(e); return }
            for c in e.elements(kAXChildrenAttribute) { walk(c) }
        }
        walk(root)
        return out
    }

    private func move(_ g: KeyboardGesture, forward: Bool) {
        // An app's module that orders this Tab itself (Contacts' card) keeps it, as with the trap.
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(for: g) {
            Log.io("settings: the app's module has \(s.name) for this key"); s.handler(g); return
        }
        Self.dropDeadHold()
        guard let focus = API.focusObject, let window = Self.windowOf(focus.element) else { g.send(); return }
        let commands = Self.ribbonCommands(of: focus.element)
        let all = Self.controls(in: commands ?? window)
        guard !all.isEmpty else { g.send(); return }
        // Where the focus is: the control itself, or the control it is inside (a cell in a table).
        var here: Int?
        var p: AXUIElement? = focus.element; var hops = 0
        while let x = p, hops < 8, here == nil { here = all.firstIndex { $0.isSame(x) }; p = x.element(kAXParentAttribute); hops += 1 }
        let next: Int? = here.map { forward ? $0 + 1 : $0 - 1 } ?? (forward ? 0 : all.count - 1)
        if let n = next, all.indices.contains(n) {
            Log.io("settings: \(forward ? "Tab" : "Shift+Tab") to \(all[n].role) \(n + 1) of \(all.count)")
            Self.focus(all[n])
            return
        }
        // Past either end: back to the tab showing (Windows' Ctrl+Tab bar is the way out of a pane).
        if commands != nil, let r = Self.ribbon(of: focus.element), let tab = Self.selectedRibbonTab(r) {
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("ribbon: \(forward ? "Tab" : "Shift+Tab") back to the tab")
        } else if let tab = PreferenceTab.selectedTab(in: window) {
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("settings: \(forward ? "Tab" : "Shift+Tab") back to the tab")
        } else { g.send() }
    }
}
