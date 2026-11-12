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
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 { if x.role == "AXTabGroup", x.string(kAXDescriptionAttribute)?.lowercased() == "ribbon" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
    }
    static func ribbonCommands(of e: AXUIElement) -> AXUIElement? {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 10 { if x.role == "AXScrollArea", x.string(kAXDescriptionAttribute)?.hasSuffix("Tab Commands") == true { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return nil
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
    /// The last window's controls in screen order, reused for a few seconds (walking the window costs 60 ms).
    static var trapList: (window: AXUIElement, controls: [AXUIElement], at: Date)?

    /// The named section around a control (Mail's "Formatting" bar): each button sits in a little group of its own.
    static func zone(of e: AXUIElement) -> AXUIElement? {
        var p = e.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 5 {
            if ["AXGroup", "AXToolbar", "AXRadioGroup", "AXScrollArea"].contains(x.role),
               !((x.string(kAXDescriptionAttribute) ?? "") + (x.string(kAXTitleAttribute) ?? "")).isEmpty { return x }
            if x.role == "AXWindow" { break }
            p = x.element(kAXParentAttribute); hops += 1
        }
        return e.element(kAXParentAttribute)
    }

    private func trapMove(_ g: KeyboardGesture, forward: Bool) {
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
        if let c = Self.trapList, c.window.isSame(window), Date().timeIntervalSince(c.at) < 5 { all = c.controls }
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
        if let h = here, let area = Self.scrollArea(of: all[h]), Self.canScroll(area, down: forward) {
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
            g.send(); return
        }
        var n = ((forward ? i + 1 : i - 1) + all.count) % all.count   // round, as the app's own Tab goes
        // The list kept from a moment ago can name controls the app has since thrown away: TurnOver Settings rebuilds
        // its pane on a new section, and Tab from the sidebar went to a dead check box, held it, and was silent from
        // then on (21 Oct 2026). Walk the window again.
        if all[n].role == "?" {
            all = Self.controls(in: window, toolbars: true, unfocusable: true); Self.trapList = (window, all, Date())
            guard let j = all.firstIndex(where: { $0.isSame(current) }), !all.isEmpty else { g.send(); return }
            i = j; n = ((forward ? i + 1 : i - 1) + all.count) % all.count
        }
        Self.trapList = (window, all, Date())
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
        Self.focus(all[n], byTrap: true)
        Self.setTrapState(for: all[n])
    }

    /// Whether a control is in a place where the app ignores Tab; set as the focus (or TurnOver's held place) moves.
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
        let inTrap = catalyst || ((!keepsOwnTab(e) || oneLine) && inLoopWindow(e)) || !trapZones.isEmpty && !editable && {
            var p: AXUIElement? = e.element(kAXParentAttribute); var hops = 0
            while let x = p, hops < 6 { if trapZones.contains(where: { $0.isSame(x) }) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
            return false
        }()
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
        setTrapState(for: e)
        let onTab = e.role == "AXRadioButton" && ribbon(of: e) != nil && ribbonCommands(of: e) == nil
        lock.lock(); _onRibbonTab = onTab; lock.unlock()
        if ribbonCommands(of: e) != nil { lock.lock(); _inPane = true; lock.unlock(); return }
        // A real focus change ends any held place.
        if let v = virtual, !obj.isSameElement(as: v) { virtual = nil; lock.lock(); _holding = false; _heldByTrap = false; lock.unlock() }
        var inside = false
        if let window = windowOf(e), PreferenceTab.selectedTab(in: window) != nil {
            var p: AXUIElement? = e; var hops = 0; var inToolbar = false
            while let x = p, hops < 12 { if x.role == "AXToolbar" { inToolbar = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
            inside = !inToolbar
        }
        lock.lock(); _inPane = inside; lock.unlock()
    }

    required init() {
        super.init()
        InputManager.passThroughWatchers.append(Self.watchTabLoop)
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
            let before: AXUIElement, window: AXUIElement
            if nowhere {
                // Asked of the app itself, not judged from TurnOver's own focus, which may be stale (a focus rule set
                // the new one aside): only an app with nothing focused, or its window itself, counts (a review, 11 Nov
                // 2026: Tab in a terminal or an editor must stay theirs).
                guard let front, front.processIdentifier != getpid() else { return }
                let appEl = AXUIElementCreateApplication(front.processIdentifier)
                guard let w = appEl.element(kAXFocusedWindowAttribute) else { return }
                if let real = appEl.element(kAXFocusedUIElementAttribute), !real.isSame(w) { return }
                before = w; window = w
            } else {
                guard let f, !Self.typesTab(f), let w = f.axRole == "AXWindow" ? f.element : Self.scopeOf(f.element) else { return }
                before = f.element; window = w
            }
            let pid = before.pid, at = Date()
            let chosenBefore = nowhere ? [] : Self.chosen(in: before)
            // 0.4 s: Reminders' SwiftUI sidebar takes longer than a quarter of a second to pass Tab on (10 Oct 2026).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                let unmoved = nowhere ? (API.focusObject.map { $0.pid != pid } ?? true) : API.focusObject?.isSameElement(as: before) == true
                guard unmoved,
                      (AXHandler.shared.lastMoveNewsAt[pid] ?? .distantPast) < at else { return }
                // The focus stayed, but Tab chose something inside it, with no news of it: Calendar's Tab selects the
                // next event in a day's list, and said nothing (11 Nov 2026). The item now chosen is read.
                if !nowhere, let now = Self.chosen(in: before).first,
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
                    if before.role == "AXGroup", !Self.trapZones.contains(where: { $0.isSame(before) }) {
                        Self.trapZones.append(before)
                        if Self.trapZones.count > 20 { Self.trapZones.removeFirst() }
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
                if let zone = Self.zone(of: before), zone.role != "AXWindow", !Self.trapZones.contains(where: { $0.isSame(zone) }) {
                    Log.io("tab trap: remembering \(zone.role) \"\(Log.words(zone.string(kAXDescriptionAttribute) ?? ""))\" as a place where Tab is TurnOver's")
                    Self.trapZones.append(zone)
                    if Self.trapZones.count > 20 { Self.trapZones.removeFirst() }
                }
                Self.trapList = (window, all, Date())
                // Round to the same control (a window with one): said again, as Tab on Windows does.
                if all[n].isSame(before) { Speech.cancel(); Speech.speakObject(ObjectFactory.make(before), reason: .focus); return }
                Self.focus(all[n], byTrap: true)
                Self.setTrapState(for: all[n])   // Mail's buttons do not take the focus: TurnOver holds the place
            }
        }
        script("trap_next", String(localized: "Where the app ignores Tab: the next control, in screen order", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:tab"], category: "Settings") { [weak self] g in self?.trapMove(g, forward: true) }.isAvailable = { Self.inTrapZone }
        script("rowList_up", String(localized: "In a column of rows TurnOver reads as a list: the row above", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:upArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(-1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { !Self.isSideways($0.container) } == true }
        script("rowList_down", String(localized: "In a column of rows TurnOver reads as a list: the row below", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:downArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { !Self.isSideways($0.container) } == true }
        script("rowList_left", String(localized: "In a row of items TurnOver reads as a list: the item to the left", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:leftArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(-1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { Self.isSideways($0.container) } == true }
        script("rowList_right", String(localized: "In a row of items TurnOver reads as a list: the item to the right", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:rightArrow"], category: "Settings") { [weak self] _ in self?.rowListMove(1) }.isAvailable = { Self.holdingVirtual && Self.virtual.flatMap { Self.rowList(of: $0) }.map { Self.isSideways($0.container) } == true }
        script("trap_previous", String(localized: "Where the app ignores Shift+Tab: the previous control, in screen order", comment: "A command, as the key list and keyboard help say it"), gestures: ["kb:shift+tab"], category: "Settings") { [weak self] g in self?.trapMove(g, forward: false) }.isAvailable = { Self.inTrapZone }
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
            lock.lock(); _heldByTrap = trap; lock.unlock()
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
            if app.element(kAXFocusedUIElementAttribute).map({ $0.isSame(target) }) ?? false {
                // The app's focus was there all along (TurnOver held a place elsewhere, a copy window's bar): focusing
                // it again sends no news, so TurnOver comes back to it itself (11 Nov 2026: Shift Tab said nothing).
                guard let held = virtual, !held.isSame(target), API.focusObject?.isSameElement(as: target) != true else { return }
                virtual = nil; lock.lock(); _holding = false; lock.unlock()
                let obj = ObjectFactory.make(target)
                API.setFocusObject(obj, ancestors: obj.ancestors)
                focusMoved(to: obj)
                Tones.focusTick()
                Speech.cancel(); Speech.speakObject(obj, reason: .focus)
            } else {
                // In a window whose Tab is the trap's (TabLoop, NewDialogs), the settings panes' Tab must not take
                // over from the held place: Shift Tab went to it and did nothing (11 Nov 2026).
                let trap = byTrap || inLoopWindow(target) || inTrapZone
                holdVirtual(target, speak: API.focusObject?.isSameElement(as: target) != true, ownTab: !trap)
                lock.lock(); _heldByTrap = trap; lock.unlock()
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
        return !x.isSame(e)
    }

    /// `ownTab`: false when an app module runs Tab itself and only wants the held place (System Settings' pane,
    /// 10 Nov 2026): this plugin's own Tab, a global plugin's, would otherwise come first and go round its own list.
    static func holdVirtual(_ target: AXUIElement, speak: Bool = true, ownTab: Bool = true) {
        // A control the app has thrown away meanwhile is no place to hold: the keys would go nowhere from it.
        guard target.role != "?" else { Log.io("settings: the control moved to is gone; not held"); return }
        virtual = target
        lock.lock(); _holding = true; _heldByTrap = false; lock.unlock()   // focus() says if the trap made this hold
        let obj = ObjectFactory.make(target)
        API.setFocusObject(obj, ancestors: API.focusAncestors)
        ObjectNavigator.shared.focusMoved(to: target, pid: target.pid)   // the context menu key acts where the cursor is
        lock.lock(); _inPane = ownTab; lock.unlock()
        Log.io("settings: \(target.role) will not keep the focus; TurnOver holds the place on it")
        if speak { Speech.cancel(); Speech.speakObject(obj, reason: .focus) }
    }

    /// Space or Return on a held control: press it.
    private func pressHeld(_ g: KeyboardGesture) {
        guard let v = Self.virtual, API.focusObject?.isSameElement(as: v) == true,
              v.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier else { g.send(); return }
        let window = Self.windowOf(v), titleBefore = window?.string(kAXTitleAttribute)
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
        guard let v = virtual, v.pid != pid else { return }
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
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 25 { let r = x.role; if r == "AXSheet" || r == "AXPopover" { return x }; if r == "AXWindow" { return x }; p = x.element(kAXParentAttribute); hops += 1 }
        return windowOf(e)
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
            if controlRoles.contains(role) || isPressableItem(e), (e.attr(kAXEnabledAttribute) as? Bool) != false, let whole = TurnOverObject.frame(e), whole.width > 0, whole.height > 0 {
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
        return paneOrdered(collapsingRowLists(kept), in: window)
    }

    // MARK: Lists the app doesn't call lists

    /// Rows found as lists: each list's rows, top to bottom (main thread; refreshed by each walk of a window).
    static var rowLists: [(rows: [AXUIElement], stop: AXUIElement, container: AXUIElement)] = []
    /// Row lists that run left to right (their containers): Left and Right move in them, not Up and Down.
    static var sidewaysLists: [AXUIElement] = []
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
            // Tab, 12 Nov 2026): one stop, Left and Right through it. Not buttons: a row of buttons is a toolbar or a
            // segmented choice, and keeps a stop each.
            let sideways = !(column && wide && stacked) && members.count >= 5
                && members.allSatisfy { abs($0.1.minY - first.minY) < 3 && abs($0.1.height - first.height) < 3 && abs($0.1.width - first.width) < 3 && !["AXButton", "AXRadioButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXLink"].contains($0.0.role) }
                && Set(members.map { Int($0.1.minX) }).count == members.count
            guard (column && wide && stacked) || sideways else { continue }
            if sideways, !sidewaysLists.contains(where: { CFEqual($0, c) }) { sidewaysLists.append(c); if sidewaysLists.count > 12 { sidewaysLists.removeFirst() } }
            let sorted = members.sorted { sideways ? $0.1.minX < $1.1.minX : $0.1.minY < $1.1.minY }
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
        Tones.focusTick()
        Speech.cancel()
        let container = rowList(of: row)?.container
        let scrolling = container.map { scrolls($0) && !isSideways($0) } ?? false
        // Counted afresh in a list newly entered; kept on coming back to the one being read (still scrolled as it was).
        if entering, let c = container, rowOffset.map({ !$0.container.isSame(c) }) ?? true { rowOffset = (c, 0) }
        let offset = (container.flatMap { c in rowOffset.flatMap { $0.container.isSame(c) ? $0.n : nil } }) ?? 0
        var parts: [String] = []
        // A list that scrolls holds only the rows in sight: no count of them all is known.
        if entering { parts.append(scrolling ? String(localized: "list", comment: "A list reached by Tab, its length unknown") : String(localized: "list, \(Phrases.items(rows.count))", comment: "A column of rows TurnOver reads as a list, reached by Tab: %@ is the count")) }
        parts.append(Speech.joined(Speech.objectPropertiesSpeech(obj, reason: .query)))
        parts.append(scrolling ? String(localized: "item \(offset + i + 1)", comment: "A row's place in a list whose length is unknown") : Phrases.position(i + 1, of: rows.count))
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
                if kids.count > 1, e.role == "AXSplitGroup" || columns { split = e; splitFrame = f; panes = kids }
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
