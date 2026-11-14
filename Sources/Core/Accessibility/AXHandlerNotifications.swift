// SPDX-License-Identifier: GPL-3.0-or-later
// The accessibility API handler (NVDA: IAccessibleHandler / UIAHandler for
// Windows; here the one macOS API). It watches applications through
// AXObservers, keeps the focus and the foreground up to date, and turns each
// notification into an event for an object. Nothing here speaks; the objects
// and modules decide that.
//
// Measured on Word (30 Sep 2026): AXSelectedTextChanged on every caret move,
// AXFocusedUIElementChanged when the caret crosses a page, AXValueChanged noise
// from AutoSave labels and scroll bars with every move. The focus object is
// the only one whose value changes are spoken, so the noise costs an object
// construction and nothing else.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

// Each accessibility notification becomes an event for an object; menus opening and closing; windows closing.
extension AXHandler {
    // MARK: Notifications → events


    func notification(_ name: String, _ element: AXUIElement, _ info: [String: Any]?) {
        lastNewsAt[element.pid] = Date()
        if [kAXFocusedUIElementChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
            kAXSelectedCellsChangedNotification, kAXSelectedTextChangedNotification, kAXTitleChangedNotification,
            kAXFocusedWindowChangedNotification, kAXMenuOpenedNotification, kAXSheetCreatedNotification].contains(name) {
            lastMoveNewsAt[element.pid] = Date()
        }
        // (A view switched with no controls created says so by its title or a selection: those count too, a review.)
        if [kAXCreatedNotification, kAXLayoutChangedNotification, kAXRowCountChangedNotification, kAXWindowCreatedNotification,
            kAXSheetCreatedNotification, kAXTitleChangedNotification, kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification,
            kAXFocusedWindowChangedNotification].contains(name)
            || name == kAXValueChangedNotification as String && ["AXTabGroup", "AXRadioGroup", "AXRadioButton"].contains(element.role) {
            lastStructureAt[element.pid] = Date()
        }
        guard running else { return }
        let pid = element.pid
        // A banner from Notification Centre (a message, a calendar alert): read as it appears, as VoiceOver and NVDA do
        // (a tester, 6 Oct 2026). The banner is a group of subrole AXNotificationCenterAlert, with title, subtitle and
        // body texts, in a "Notification Center" window (measured 8 Oct 2026).
        if pid == notificationCentrePid, [kAXCreatedNotification, kAXWindowCreatedNotification, kAXLayoutChangedNotification].contains(name) {
            NotificationCentrePanel.cursorBackIfStranded()
            announceNotificationsSoon()
            return
        }
        switch name {
        case kAXFocusedUIElementChangedNotification:
            if API.focusTreeInterceptor != nil, element.role == "AXWebArea" {
                if Date().timeIntervalSince(lastWebAreaFocus) < 0.2 {
                    webAreaFocusSkipped += 1
                    // The last of a burst can be the one that matters: Control Tab twice in Safari left TurnOver on the
                    // first tab's page, the second's news set aside with nothing after it (a review, 13 Nov 2026). Once
                    // the burst has settled, the app's focused page is read if it is not the one TurnOver has.
                    if !webAreaTrailing {
                        webAreaTrailing = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                            guard let self else { return }
                            self.webAreaTrailing = false
                            guard pid == self.activePid, let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute),
                                  f.role == "AXWebArea", !(API.focusTreeInterceptor?.webArea.isSame(f) ?? false) else { return }
                            Log.io("web area focus: the last of a burst was set aside; the app's page read again")
                            self.refocus(pid: pid)
                        }
                    }
                    return
                }
                if webAreaFocusSkipped > 0 { Log.io("skipped \(webAreaFocusSkipped) web area focus events in a burst"); webAreaFocusSkipped = 0 }
                lastWebAreaFocus = Date()
            }
            focusChanged(element, pid: pid)
        case kAXFocusedWindowChangedNotification:
            // A window change in an app that is neither active nor holding the keys: a panel of its own closing
            // (1Password's Quick Access, on Escape, from Finder). Its main window behind was announced and the focus
            // left in 1Password, with Finder in front (a tester, 12 Nov 2026). The active app gets the focus back.
            if pid != activePid, NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, !SystemPrompts.isProtected(pid),
               (AXUIElementCreateApplication(pid).attr(kAXFrontmostAttribute) as? Bool) != true {
                if API.focusObject?.pid == pid, activePid > 0 {
                    Log.io("a window of pid \(pid) in the background took over from its panel; focus back to the active app")
                    lastForegroundTitle = ""   // (the panel opening again is news again)
                    refocus(pid: activePid)
                }
                return
            }
            foregroundChanged(element, appName: nil)
            // The window's own focus follows; if the app does not say, ask it.
            if let app = observers[pid].map({ _ in AXUIElementCreateApplication(pid) }), let f = app.element(kAXFocusedUIElementAttribute), !f.isSame(element) {
                focusChanged(f, pid: pid)
            }
            // Word, closing its Find bar with Escape, gives the document back its focus a moment later and says
            // nothing: only "Document1, window" was heard (7 Oct 2026). Ask again once it has settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, pid == self.activePid else { return }
                let app = AXUIElementCreateApplication(pid)
                // (Only while TurnOver's focus is still in another window: Word's table cells are TurnOver's own
                // objects, and asking again took the caret "out of table" as a table was inserted.)
                guard let f = app.element(kAXFocusedUIElementAttribute), f.element(kAXWindowAttribute)?.isSame(element) == true,
                      !(API.focusObject.map { $0.element.isSame(f) } ?? false),
                      !(API.focusObject?.element.element(kAXWindowAttribute)?.isSame(element) ?? false) else { return }
                Log.io("focus after a window change, asked again: \(f.role)")
                self.focusChanged(f, pid: pid)
            }
        case kAXSelectedTextChangedNotification:
            EventHandler.queue(Event(.caret, selectedTextTarget(element, info)))
        case kAXValueChangedNotification:
            // Safari sends a thousand of these a second for dying elements while a page loads; only the focus's matter,
            // and elements a plugin watches (a status line, a progress bar) in the application in front.
            // The progress bar being watched beeps as it moves (ProgressWatch); the event goes on as before.
            ProgressWatch.valueChanged(element)
            if let f = API.focusObject, f.isSameElement(as: element) { EventHandler.queue(Event(.valueChange, f)); return }
            if pid == activePid, !ProfileStore.shared.profiles(for: ProfileStore.shared.bundle(of: pid)).isEmpty,
               ProfileStore.shared.watchRule(for: element, pid: pid) != nil {
                EventHandler.queue(Event(.valueChange, ObjectFactory.make(element)))
            }
        case kAXTitleChangedNotification:
            // The front window's title changing because of a key (Control+Tab to another tab, Command+1 to another
            // mailbox) is the news of where you are (NVDA reads a foreground name change). Not without a key: Mail
            // retitles its window as mail arrives.
            if element.role == "AXWindow", let w = focusWindow, w.isSame(element), pid == activePid,
               Date().timeIntervalSince(InputManager.lastKeyDownAt) < 2, Self.switchesView(InputManager.lastKeyIdentifier),
               let t = element.string(kAXTitleAttribute), !t.isEmpty, t != lastForegroundTitle {
                lastForegroundTitle = t
                if let f = API.focusObject, f.axRole == "AXWebArea", f.pid == pid, Speech.sinceFocusSpoken < 0.6 {
                    // The page took focus a moment before its title arrived: the title first, then where you are in it.
                    Speech.cancel()
                    Speech.speakMessage(t)
                    Speech.speakObject(f, reason: .focus)
                } else {
                    Speech.speakMessage(t)
                }
            }
            guard let f = API.focusObject, f.isSameElement(as: element) else { return }
            EventHandler.queue(Event(.nameChange, f))
        case kAXMenuOpenedNotification:
            guard element.role == "AXMenu" else { Log.io("menu opened on a \(element.role); not a menu, ignored"); return }
            // A page's own navigation (role="menu") announces itself as a menu opening while the page loads, and
            // never closes: it held Safari's focus back for a whole visit and ate the letters typed in the next app
            // as menu type-ahead (17 Oct 2026). A popup needs a key; the page's structure arrives without one.
            if Date().timeIntervalSince(InputManager.lastKeyDownAt) > 2, MenuNavigationPlugin.isWebMenu(element) {
                Log.io("menu opened in a web page with no key for 2 s: the page's own menu, not counted")
                return
            }
            openMenus.removeAll { $0.isSame(element) }
            openMenus.append(element)
            menuOpenedAt = Date()
            logMenu(element)
            // Word opens its context menu and every submenu at once: one announcement.
            if Date().timeIntervalSince(lastMenuStart) > 0.5 { EventHandler.queue(Event(.menuStart, ObjectFactory.make(element))) }
            lastMenuStart = Date()
        case kAXMenuClosedNotification:
            let before = openMenus.count
            openMenus.removeAll { $0.isSame(element) }
            if openMenus.count == before { openMenus.removeAll { $0.role != "AXMenu" } }
            if openMenus.count == before, before > 0 { Log.io("menu closed under another identity; clearing \(before) open menus"); openMenus.removeAll() }
            if element.role == "AXMenu" { EventHandler.queue(Event(.menuEnd, ObjectFactory.make(element))) }
            // Only a real menu closing opens the gap: Safari's address completions (a scroll area, never counted as
            // open) closing made the next focus wait and the window get read ("Boson - Wikipedia, window").
            if openMenus.isEmpty, before > 0 || element.role == "AXMenu" { lastMenuClosed = (pid, Date()); lastMenuEnded = (pid, Date()) }
        case kAXMenuItemSelectedNotification:
            // A keyboard shortcut also "selects" its menu item (Cmd+A: "Select All"); only a menu the user is in counts.
            if isMenuOpen { focusChanged(element, pid: pid) } else { Log.debug("menu item selected by shortcut: \(element.string(kAXTitleAttribute) ?? "")") }
        case kAXLayoutChangedNotification, "AXLiveRegionChanged", "AXLoadComplete":
            if name == "AXLiveRegionChanged", pid == activePid { EventHandler.queue(Event(.liveRegionChange, ObjectFactory.make(element))) }
            if let d = API.focusTreeInterceptor, d.webArea.pid == pid {
                d.buffer.isDirty = true
                // The page's own load only: every frame in it (an advertisement) sends AXLoadComplete too, and each was
                // taken for the page finishing, read again under a say all (a review, 13 Nov 2026).
                let pageLoaded = name == "AXLoadComplete" && element.isSame(d.webArea)
                if pageLoaded { loadCompleteSeen = true }
                // Back, Forward or a link: the page in this web area changed. Once it settles, resume where it was left.
                if !navigationCheckPending { scheduleNavigationCheck(after: pageLoaded ? 0.1 : 0.6, name: name) }
            }
        case kAXWindowCreatedNotification, kAXDrawerCreatedNotification, kAXHelpTagCreatedNotification, kAXSelectedColumnsChangedNotification,
             kAXCreatedNotification, kAXRowCountChangedNotification,
             kAXMainWindowChangedNotification, kAXElementBusyChangedNotification, "AXLiveRegionCreated":
            // Role and title only, and at most 20 a second: a loading page or an 800-row list sends hundreds, each
            // costing the main thread four round trips for a log line (a code review, 14 Oct 2026).
            // A second window: does this app list every window's elements under each (Qt Quick)? Checked once it does.
            if name == kAXWindowCreatedNotification, !ForeignChildren.contains(pid) { ForeignChildren.check(pid: pid) }
            // A window beside the one in use, with a progress bar (Finder's copy window): read and its bar followed.
            if name == kAXWindowCreatedNotification, element.role == "AXWindow", pid == activePid || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                NewDialogs.windowAppeared(element, pid: pid)
            }
            if Date().timeIntervalSince(loggedOnlyWindow) > 1 { loggedOnlyWindow = Date(); loggedOnlyCount = 0 }
            loggedOnlyCount += 1
            if loggedOnlyCount <= 20 { Log.io("notification \(name): \(element.role) \"\(Log.words(element.string(kAXTitleAttribute) ?? ""))\"") }
            else if loggedOnlyCount == 21 { Log.io("notifications: more than 20 this second; the rest not logged") }
        case kAXSelectedCellsChangedNotification:
            // A grid that moves its selection without moving the focus: Excel says only "selected cells changed" on
            // each arrow, and its focused cell catches up seconds later, if at all (Day 2, 10 Oct 2026). Where the
            // focus is in this grid, the one cell selected is the new focus (a range keeps the focus where it is).
            Log.io("notification \(name): \(element.role) \"\(Log.words(element.string(kAXTitleAttribute) ?? element.string(kAXDescriptionAttribute) ?? ""))\"")
            guard pid == activePid, let f = API.focusObject,
                  f.isSameElement(as: element) || API.focusAncestors.contains(where: { $0.isSameElement(as: element) }) else { return }
            // Counted, not fetched: a whole column selected is a million cells.
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(element, "AXSelectedCells" as CFString, &count)
            if AppModuleHandler.shared.appModule(for: pid).gridSelectionChanged(element, count: count) { return }
            var first: CFArray?
            guard count == 1, AXUIElementCopyAttributeValues(element, "AXSelectedCells" as CFString, 0, 1, &first) == .success,
                  var cell = (first as? [AXUIElement])?.first else { return }
            // Excel's selected cell is a wrapper with no name; the cell with the address and value is inside it.
            let inner = cell.elements(kAXChildrenAttribute)
            if inner.count == 1, inner[0].role == "AXCell" { cell = inner[0] }
            guard !f.element.isSame(cell), !Self.sameControl(f.element, cell) else { return }
            focusChanged(cell, pid: pid)
        case kAXSelectedChildrenChangedNotification, kAXSelectedRowsChangedNotification:
            if AppModuleHandler.shared.appModule(for: pid).listSelectionChanged(element) { return }
            // Several rows highlighted at once (Shift Down, Command click): the row that just changed is said, then
            // how many are selected, as VoiceOver does; the first selected row was said every time (16 Oct
            // 2026). Counted first, so a whole column of a million never comes across; at most 200 rows fetched.
            let key = { () -> String in var n: CFIndex = 0; AXUIElementGetAttributeValueCount(element, kAXSelectedRowsAttribute as CFString, &n); return n > 0 ? kAXSelectedRowsAttribute : kAXSelectedChildrenAttribute }()
            var count: CFIndex = 0
            AXUIElementGetAttributeValueCount(element, key as CFString, &count)
            var all: [AXUIElement] = []
            if count > 0 { var arr: CFArray?; if AXUIElementCopyAttributeValues(element, key as CFString, 0, min(count, 200), &arr) == .success { all = (arr as? [AXUIElement]) ?? [] } }
            let focused = API.focusObject.map { f in f.isSameElement(as: element) || API.focusAncestors.contains(where: { $0.isSameElement(as: element) }) } ?? false
            let before = lastSelectedRows?.container.isSame(element) == true ? (lastSelectedRows?.rows ?? []) : []
            lastSelectedRows = (element, all)
            if count > 1 {
                let added = all.filter { a in !before.contains { $0.isSame(a) } }
                let removed = before.filter { b in !all.contains { $0.isSame(b) } }
                guard focused, let target = added.last ?? removed.last ?? all.last else { return }
                TurnOverObject.selectionNote = (removed.isEmpty || !added.isEmpty ? "" : "not selected, ") + "\(count) selected"
                lastSelectionReport = (target, Date())
                EventHandler.queue(Event(.selection, ObjectFactory.make(target)))
                return
            }
            if count == 0, before.count > 0, focused, element.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) == nil {
                Speech.speakMessage(String(localized: "nothing selected", comment: "Spoken message")); return
            }
            // The Dock's Cmd+Tab list marks its highlighted item focused rather than selected.
            guard let selected = all.first ?? element.elements(kAXChildrenAttribute).first(where: { ($0.attr(kAXFocusedAttribute) as? Bool) == true }) else { return }
            if let (last, at) = lastSelectionReport, last.isSame(selected), Date().timeIntervalSince(at) < 0.4 { return }
            lastSelectionReport = (selected, Date())
            // Only the focused container's selection matters (a sidebar changing under a dialog does not).
            if focused || API.focusObject?.isSameElement(as: selected) == true {
                EventHandler.queue(Event(.selection, ObjectFactory.make(selected)))
            }
        case kAXRowExpandedNotification, kAXRowCollapsedNotification:
            EventHandler.queue(Event(.stateChange, object(for: element)))
        case kAXSheetCreatedNotification:
            if let (last, at) = lastSheet, last.isSame(element), Date().timeIntervalSince(at) < 1 { return }
            // System Settings makes Bluetooth's Show Detail sheet twice, a third of a second apart, and it was said
            // twice (11 Nov 2026, macOS 27.2): a second sheet of the same app so soon is taken over, not said again.
            // The same words, too: a different sheet straight after one (an error after a confirmation) is said (a
            // review, 11 Nov 2026).
            let words = NewDialogs.text(of: element)
            let again = (lastSheet.map { $0.0.pid == pid && Date().timeIntervalSince($0.1) < 1 } ?? false) && words == NewDialogs.lastSheetText
            NewDialogs.lastSheetText = words
            lastSheet = (element, Date())
            lastEntered = (element, Date())
            let obj = ObjectFactory.make(element)
            lastForegroundTitle = obj.name
            focusWindow = element
            API.setForegroundObject(obj)
            if !again { EventHandler.queue(Event(.focusEntered, obj)); NewDialogs.announced = (pid, Date()) }
            NewDialogs.sheetAppeared(element, pid: pid)   // the focus left behind it: TurnOver goes in
        case kAXAnnouncementRequestedNotification:
            // Safari announces "Page Menu, Reader Available" as each page loads, sometimes twice: the same news once.
            if let text = info?["AXAnnouncementKey"] as? String, !text.isEmpty {
                if text == lastAnnouncement.0, Date().timeIntervalSince(lastAnnouncement.1) < 30 { Log.io("announcement repeated; skipped"); break }
                // Not into the middle of a page being read ("Page Menu, Reader Available" between its lines).
                if SayAll.isRunning { Log.io("announcement during say all; skipped: \(Log.words(text))"); break }
                // iTerm2 announces each piece of new output itself; TurnOver's terminal reads it already (it was heard
                // twice, parts sweep 15 Oct 2026).
                if API.focusObject is TerminalText, API.focusObject?.pid == pid { Log.io("terminal's own announcement; TurnOver reads the output itself"); break }
                if AppModuleHandler.shared.appModule(for: pid).ignoresAnnouncement(text, after: InputManager.lastKeyIdentifier,
                        elapsed: Date().timeIntervalSince(InputManager.lastKeyDownAt)) {
                    Log.io("app module suppressed a native announcement: \(Log.words(text))"); break
                }
                lastAnnouncement = (text, Date())
                Speech.speakMessage(text)
            }
        default:
            break
        }
    }

    /// The object for a notification: the live focus object when it is the same element, so its state carries.
    /// Once a web page's news settles: whether the page in the browse mode document in front changed (Back, Forward, a
    /// link), arrived after being blank, or finished loading. One check pending at a time.
    func scheduleNavigationCheck(after delay: Double, name: String) {
        navigationCheckPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            navigationCheckPending = false
            guard let d = API.focusTreeInterceptor else { loadCompleteSeen = false; return }
            // Checked for the document in front now, not the one whose news scheduled this: dropped when another tab
            // had come to the front, a check pending for one tab blocked the next tab's AXLoadComplete, which was never
            // read again (a review, 13 Nov 2026). The load seen may then be the tab left's: at worst the tab in front is
            // read again keeping its place. A script running: checked again in a moment, the load kept; it waited for
            // news that might never come (a review, 13 Nov 2026).
            guard !ScriptHandler.isScriptRunning else { scheduleNavigationCheck(after: 0.2, name: name); return }
            let loaded = loadCompleteSeen
            loadCompleteSeen = false
            if d.refreshIfNavigated(announce: !d.passThrough, byKey: false) { Log.io("browse mode: page changed under the document (\(name))") }
            else if d.loadedAfterBlank(announce: !d.passThrough) { Log.io("browse mode: page finished loading (\(name))") }
            // Read while still loading, now finished: read again, the reading kept where it is, so say all and the
            // arrows have the whole page (a review, 13 Nov 2026).
            // A reload (the same address) is told by the document, which says the title (pageLoadCompleted).
            else if loaded { d.pageLoadCompleted() }
        }
    }

    func object(for element: AXUIElement) -> TurnOverObject {
        if let f = API.focusObject, f.isSameElement(as: element) { return f }
        return ObjectFactory.make(element)
    }

    /// Chromium (Discord, Slack, Signal, Chrome) posts AXSelectedTextChanged on the page's root web area, with the
    /// field that changed in the notice's AXTextChangeElement, not on the field: Command+A in a message box and a
    /// mouse selection there were never read, as the event went to the web area (a review, 13 Nov 2026). The notice
    /// goes to the focus when the focus is an editable field and is the changed element or lies inside that web area,
    /// and only while the keys go to the page (focus mode, or no browse mode): browse mode follows WebKit's selection
    /// itself. Anything else goes where it was posted, as before.
    func selectedTextTarget(_ element: AXUIElement, _ info: [String: Any]?) -> TurnOverObject {
        guard let f = API.focusObject as? EditableText, !f.isSameElement(as: element), element.role == "AXWebArea" else { return object(for: element) }
        let changed: AXUIElement? = info?["AXTextChangeElement"].flatMap { v in
            CFGetTypeID(v as CFTypeRef) == AXUIElementGetTypeID() ? (v as! AXUIElement) : nil
        }
        let route = Self.routesSelectionToFocus(changedIsFocus: changed.map { f.isSameElement(as: $0) } ?? false,
                                                keysGoToPage: API.focusTreeInterceptor?.passThrough ?? true,
                                                focusInsideWebArea: { Self.focus(f.element, isInside: element) })
        return route ? f : object(for: element)
    }
    /// Whether a selection notice on a web area is the focused field's (selectedTextTarget).
    nonisolated public static func routesSelectionToFocus(changedIsFocus: Bool, keysGoToPage: Bool, focusInsideWebArea: () -> Bool) -> Bool {
        guard keysGoToPage else { return false }
        return changedIsFocus || focusInsideWebArea()
    }
    /// The last answer, kept: the notice comes with every caret move, and the walk up is up to 40 calls.
    private static var insideAnswer: (focus: AXUIElement, area: AXUIElement, inside: Bool)?
    static func focus(_ focus: AXUIElement, isInside area: AXUIElement) -> Bool {
        if let a = insideAnswer, CFEqual(a.focus, focus), CFEqual(a.area, area) { return a.inside }
        var p = focus.element(kAXParentAttribute), hops = 0, inside = false
        while let x = p, hops < 40 { if CFEqual(x, area) { inside = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
        insideAnswer = (focus, area, inside)
        return inside
    }

    /// A menu was closed by an action the application does not report (Word's menu-bar items chosen by press).
    public func menusClosed() {
        if !openMenus.isEmpty { Log.io("menus cleared: \(openMenus.count) were open"); openMenus.removeAll() }
    }


    /// Keys that show another tab, mailbox or page in the same window. Only after these is a new window title news:
    /// Terminal retitles its window as the shell starts and with every cd, and that is noise.
    static func switchesView(_ key: String) -> Bool {
        let k = key.replacingOccurrences(of: "kb:", with: "")
        // Not Back and Forward: Safari's title is the bare address until the page arrives, and the page reads itself.
        if ["control+tab", "control+shift+tab", "command+shift+[", "command+shift+]", "command+w"].contains(k) { return true }
        if k.hasPrefix("command+"), let last = k.last, last.isNumber, k.count == "command+1".count { return true }
        return false
    }

    /// Command+W closed a window. If it was the application's last, nothing reports a new focus: TurnOver stayed on
    /// the closed message and the arrows read it ("top, blank", Mail, 3 Oct 2026). Say so, and let the page go. If a
    /// window is left but the old focus has gone with the closed one, read the focus again.
    public func afterWindowClose(pid: pid_t) {
        guard pid == activePid, running else { return }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1.0)
        let all = app.elements(kAXWindowsAttribute)
        let open = all.filter { ($0.attr(kAXMinimizedAttribute) as? Bool) != true }
        if open.isEmpty {
            Log.io("window closed: no window left")
            API.setFocusObject(ObjectFactory.make(app), ancestors: [])
            let minimised = all.count
            Speech.speakMessage(minimised == 0 ? String(localized: "no windows", comment: "An app with no windows") : String(localized: "no windows open, \(String(minimised)) minimised", comment: "Spoken message: %@ is how many windows are in the Dock"))
            return
        }
        if let f = API.focusObject, f.pid == pid, f.element.role == "?" || f.element.element(kAXWindowAttribute) == nil {
            Log.io("window closed: the focus went with it; reading it again")
            refocus(pid: pid)
        }
    }

    /// Before each key: TurnOver's focus is another ordinary app's while this one is in front. An app launched without
    /// a word of its focus (Weather, an iPad app, came forward from Finder, and Tab ran Finder's commands on its window
    /// behind, a sweep, 13 Nov 2026): the front app's focus is read, so the key is looked up there. Not an app whose
    /// focus has the keys while another stays in front (hasKeysBehindFront: Quick Access, a helper, the Dock,
    /// Spotlight). Not throttled with checkFocusAtKey, which runs after every key and kept this from the next one
    /// typed within a second (a review, 13 Nov 2026). Cheap unless it is so; when it is, every question to the front
    /// app has a quarter of a second, as an app still launching can hold one for six (the default) with the key
    /// waiting.
    /// TurnOver's focus is another ordinary app's while this one is in front (cheap; no app is asked).
    public var focusIsBehindFrontApp: Bool {
        guard running, activePid > 0, let f = API.focusObject, f.pid != activePid, f.pid != getpid(), !isMenuOpen,
              let other = NSRunningApplication(processIdentifier: f.pid), other.activationPolicy == .regular,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == activePid else { return false }
        // (Not an app that has the keys while another stays in front: 1Password's Quick Access, a helper.)
        return !hasKeysBehindFront(other)
    }

    public func focusBehindFrontApp() {
        guard running, activePid > 0, let f = API.focusObject, f.pid != activePid, f.pid != getpid(),
              !isMenuOpen, MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil,
              let other = NSRunningApplication(processIdentifier: f.pid), other.activationPolicy == .regular,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == activePid, !hasKeysBehindFront(other) else { return }
        Log.io("key: TurnOver's focus is \(other.localizedName ?? "another app")'s, behind the app in front; the front app's focus read")
        let app = AXUIElementCreateApplication(activePid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        if let real = app.element(kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(real, 0.25)
            if real.role != "?" { focusChanged(real, pid: activePid) }
            // Taken: done. Set aside by a rule (Weather starting, its first focus a nameless group: three Tabs were
            // silent, 13 Nov 2026): the front window is presented itself, so the keys are the front app's.
            if API.focusObject?.pid == activePid { return }
        }
        if let w = app.element(kAXFocusedWindowAttribute) ?? app.element(kAXMainWindowAttribute) {
            AXUIElementSetMessagingTimeout(w, 0.25)
            present(w, pid: activePid)
        }
    }

    /// Any key: if TurnOver's focus has died (its window closed, a view rebuilt) or come loose from any window, with no
    /// news of the app's new focus, the app's real focus is read, as after Command W. Only Command W checked this, and
    /// a window closed by Escape, a button or the app itself left the arrows reading the dead element (a review, 13 Nov
    /// 2026). Once a second at most, after the key, so the key itself is never held up.
    public func checkFocusAtKey() {
        guard running, activePid > 0, Date().timeIntervalSince(lastFocusCheckAt) > 1 else { return }
        guard let f = API.focusObject, !isMenuOpen, MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil else { return }
        lastFocusCheckAt = Date()
        // A focus with no window of its own by nature: the app itself (no window left), the menus, the Dock's items.
        let windowless: Set<String> = ["AXApplication", "AXMenuBar", "AXMenuBarItem", "AXMenu", "AXMenuItem", "AXDockItem", "AXWindow", "AXSheet"]
        let role = f.element.role
        let dead = role == "?"
        // Loose from its window: only in the app in front (a control TurnOver made keeps its place: the app must name
        // another focus, below). In no window up its parents either, not only by its own AXWindow, which many
        // controls lack; and never a place TurnOver holds (Tab trap, toolbar, NewDialogs), whose app's focus is
        // elsewhere by nature: those were dropped a second after they were reached (a review, 13 Nov 2026).
        let loose = !dead && f.pid == activePid && !windowless.contains(role) && !SettingsPanePlugin.holdingVirtual
            && SettingsPanePlugin.windowOf(f.element) == nil
        guard dead || loose else { return }
        // Only when the app names a live focus of its own elsewhere: else there is nothing better to read, and reading
        // the same again at every key would be noise.
        let app = AXUIElementCreateApplication(activePid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let real = app.element(kAXFocusedUIElementAttribute), !real.isSame(f.element), real.role != "?" else { return }
        if loose, SettingsPanePlugin.windowOf(real) == nil, real.role != "AXWindow" { return }
        Log.io("key: TurnOver's focus is \(dead ? "gone" : "out of any window"); the app's focus read again")
        refocus(pid: activePid)
    }

    public func refocus(pid: pid_t) {
        guard pid != 0, running else { return }
        // While TurnOver holds the menu bar or the status menus (Mac style, VO M), the application's focus is not
        // news: it spoke over "Apple menu, 1 of 10" (a tester, 8 Oct 2026).
        guard MenuNavigationPlugin.heldBar == nil, MenuNavigationPlugin.heldStatus == nil else { Log.io("refocus skipped: the menu bar is held"); return }
        let app = AXUIElementCreateApplication(pid)
        guard let f = app.element(kAXFocusedUIElementAttribute) else { return }
        // The same element again within a moment (two Escapes closing two menus each set a watch, and the message
        // row was read three times, 8 Oct 2026): once is enough.
        // Once is enough only when that refocus was presented: one diverted into the menu gap never was.
        if let (el, at) = lastRefocus, el.isSame(f), Date().timeIntervalSince(at) < 1.5, API.focusObject?.isSameElement(as: f) == true {
            Log.io("refocus: \(f.role) again; skipped"); return
        }
        lastRefocus = (f, Date())
        Log.io("refocus: \(f.role)")
        focusChanged(f, pid: pid)
    }

}
