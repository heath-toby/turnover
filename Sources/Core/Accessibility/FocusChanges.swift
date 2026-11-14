// SPDX-License-Identifier: GPL-3.0-or-later
// The accessibility API handler (NVDA: IAccessibleHandler / UIAHandler for
// Windows; here the one macOS API). It watches applications through
// AXObservers, keeps the focus and the foreground up to date, and turns each
// notification into an event for an object. Nothing here speaks; the objects
// and modules decide that.
import Foundation
import AppKit
import ApplicationServices
import TurnOverAX

// The focus changed: what to ignore, what to follow somewhere else, and what to present (NVDA: eventHandler's
// focus handling with focusEntered for new ancestors). Each special case is a named rule below, tried in order
// (8 Oct 2026, from the team review: "each `if` with a dated comment becomes a named rule").
extension AXHandler {
    /// What a rule says about a focus report.
    enum FocusVerdict {
        /// Not the focus: say nothing, keep what TurnOver had.
        case ignore
        /// The focus is really this element: start the rules again with it.
        case follow(AXUIElement)
        /// This element with the rule's say over it; on to the next rule.
        case go(AXUIElement)
        /// Taken: the rule has done what is needed (set the focus quietly, re-asked later).
        case done
    }

    /// The rules, in order. Each gets the element as the rules so far have it, the pid it was reported for and the
    /// element first reported (a re-check later asks whether it is still the focus).
    typealias FocusRule = (AXUIElement, pid_t, AXUIElement) -> FocusVerdict
    var focusRules: [(String, FocusRule)] {[
        ("not an application", ruleNotAnApplication),
        ("an application that names itself, not in front", ruleApplicationItself),
        ("background application", ruleBackgroundApplication),
        ("set aside after a settings Tab", ruleSetAside),
        ("behind a sheet just opened", ruleBehindNewSheet),
        ("iPad app's late focus on a nameless group", ruleCatalystLateGroup),
        ("a window the focus passes through on a Tab", ruleWindowInPassing),
        ("untitled window", ruleUntitledWindow),
        ("helper's window", ruleHelperWindow),
        ("switching preference tabs", rulePreferenceTabSwitch),
        ("background window", ruleBackgroundWindow),
        ("stand-in for a text field", ruleTextStandIn),
        ("duplicate", ruleDuplicate),
        ("hidden scroll bar", ruleHiddenScrollBar),
        ("back onto the toolbar it was in", ruleBackOntoToolbar),
        ("blank frame", ruleBlankFrame),
        ("empty web area, no key pressed", ruleEmptyWebAreaUnbidden),
        ("field still has the keys", ruleFieldStillHasKeys),
        ("reported twice", ruleReportedTwice),
        ("Qt item's child echoing it", ruleQtChildEcho),
        ("no role", ruleNoRole),
        ("nameless container", ruleNamelessContainer),
        ("menu gap", ruleMenuGap),
        ("menu open", ruleMenuOpen),
        ("the application itself after a menu", ruleApplicationKeepsPlace),
        ("window while a control has the keys", ruleWindowWhileControlHasKeys),
        ("window already presented", ruleWindowAlreadyPresented),
        ("owned by another process", ruleOwnedByAnotherProcess),
    ]}

    public func focusChanged(_ element: AXUIElement, pid: pid_t) {
        let module = AppModuleHandler.shared.appModule(for: pid)
        var target = module.redirectFocus(element) ?? element
        for (name, rule) in focusRules {
            switch rule(target, pid, element) {
            case .ignore: Log.debug("focus rule \(name): ignored"); return
            case .done: Log.debug("focus rule \(name): handled"); return
            case .follow(let other): Log.debug("focus rule \(name): following"); focusChanged(other, pid: pid); return
            case .go(let t): target = t
            }
        }
        present(target, pid: pid)
    }

    // MARK: The rules

    /// The system's text-input cursor service (com.apple.TextInputUI.xpc.CursorUIViewService) reports its own
    /// untitled window as focused whenever a Chromium text field is typed into; a process that cannot be an
    /// application (an XPC service, activation policy prohibited) never has the keyboard.
    func ruleNotAnApplication(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if pid != activePid, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .prohibited, !isHelperOfActiveApp(app) {
            Log.io("focus from \(app.bundleIdentifier ?? "pid \(pid)") (not an application); ignored")
            return .ignore
        }
        return .go(target)
    }

    /// An ordinary application in the background (Safari's page reloading behind Mail, 2 Oct 2026) can post focus
    /// events: they are not where the keys go. Followed, they put Safari's page under Mail and the arrows read it.
    /// (An application coming to the front is let through: it is frontmost before the activation news arrives.)
    func ruleBackgroundApplication(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if pid != activePid, let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
           NSWorkspace.shared.frontmostApplication?.processIdentifier != pid, !hasKeysBehindFront(app) {
            Log.io("focus from \(app.localizedName ?? "pid \(pid)") in the background; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// An app not in front whose focus is still where the keys go: a helper of the app in front, the Dock, Spotlight
    /// and the like, or an app that says it has the keys. 1Password's Quick Access is a panel that takes the keyboard
    /// while the app before stays active, and its search and results were silent (12 Nov 2026); its application
    /// element says it is frontmost then, a page reloading behind another app doesn't. One answer for the focus rule
    /// and the check before each key (focusBehindFrontApp): the key check had none of these, and moved TurnOver off
    /// Quick Access at every key (a review, 13 Nov 2026). A quarter of a second at most for the question.
    func hasKeysBehindFront(_ app: NSRunningApplication) -> Bool {
        if isHelperOfActiveApp(app) || AXHandler.systemUIAgents.contains(app.bundleIdentifier ?? "") { return true }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25)
        return (element.attr(kAXFrontmostAttribute) as? Bool) == true
    }

    /// Just after a sheet opened: the app's focus on its window behind it is not where the keys go (NewDialogs).
    func ruleBehindNewSheet(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if NewDialogs.isBehindNewSheet(target) { Log.io("focus to \(target.role) behind a sheet just opened; set aside"); return .ignore }
        return .go(target)
    }

    /// Tab from one field to the next, and the app reports the window holding them in between (the Save panel, every
    /// Tab: its dialog and all its words read again, then dropped as the field came, 11 Nov 2026). The window the
    /// focus is already in is no news: set aside, and taken after all if nothing else has come a moment later.
    private static var passingWindowRecheck: AXUIElement?
    /// The key press a Tab stopping on its window was sent on for (once each).
    static var resentFor: Date?

    func ruleWindowInPassing(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWindow" else { return .go(target) }
        if let r = Self.passingWindowRecheck, r.isSame(target) { Self.passingWindowRecheck = nil; return .go(target) }
        guard ["kb:tab", "kb:shift+tab"].contains(InputManager.lastKeyIdentifier), Date().timeIntervalSince(InputManager.lastKeyDownAt) < 0.5,
              let cur = API.focusObject, cur.pid == pid, !cur.isSameElement(as: target),
              // (Up the field's parents, not its AXWindow: the Save panel's field names the document's window.)
              { var p = cur.element.element(kAXParentAttribute); var hops = 0
                while let x = p, hops < 30 { if x.isSame(target) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
                if SettingsPanePlugin.windowOf(cur.element)?.isSame(target) == true { return true }
                // (Nor its parents: the panel's insides come from another process. Where it sits: inside the window.)
                guard let wf = TurnOverObject.frame(target), let cf = TurnOverObject.frame(cur.element), cf.width > 0 else { return false }
                return wf.contains(cf) }() else { return .go(target) }
        Log.io("focus on the window \(Log.words(target.string(kAXTitleAttribute) ?? "")) on the way between its controls; set aside")
        let key = InputManager.lastKeyIdentifier, keyAt = InputManager.lastKeyDownAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, API.focusObject?.isSameElement(as: cur.element) == true,
                  AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute).map({ $0.isSame(target) }) == true else { return }
            // The window was where the key stopped (Contacts' Shift Tab from its list, 13 Nov 2026): the same key once
            // more, on to the next control, as the window itself is nothing to Tab to. Once only for a key.
            if InputManager.lastKeyDownAt == keyAt, Self.resentFor != keyAt, let g = KeyboardGesture(identifier: key) {
                Self.resentFor = keyAt
                Log.io("focus: the window was where \(key) stopped; \(key) again")
                g.send()
                return
            }
            Self.passingWindowRecheck = target
            self.refocus(pid: pid)
            // Taken by this refocus or not at all: refocus runs the rules at once. Left set (a refocus skipped for a
            // held menu bar, or the app's focus elsewhere by then), it let the window through on some later Tab, its
            // words read again (a review, 13 Nov 2026).
            Self.passingWindowRecheck = nil
        }
        return .ignore
    }

    /// An iPad app, while TurnOver's cursor is held by the Tab trap: the app's focus landing on a nameless group is
    /// its slow answer to a key the trap already took (Phone answers a second late), not a move worth leaving the
    /// held place for. Shift Tab went round three toolbar items for ever (11 Nov 2026).
    func ruleCatalystLateGroup(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard SettingsPanePlugin.holdingVirtual, SettingsPanePlugin.inTrapZone, SettingsPanePlugin.isCatalyst(pid),
              target.role == "AXGroup", (target.string(kAXTitleAttribute) ?? "").isEmpty, (target.string(kAXDescriptionAttribute) ?? "").isEmpty
        else { return .go(target) }
        Log.io("focus to a nameless group in an iPad app while TurnOver holds its place; set aside")
        // Back from a menu (Escape on a call's context menu): the place held is said again, as a focus coming back is.
        if let ended = AXHandler.shared.lastMenuEnded, ended.pid == pid, Date().timeIntervalSince(ended.at) < 1.5,
           let held = API.focusObject, held.pid == pid {
            Speech.speakObject(held, reason: .focus)
        }
        return .ignore
    }

    /// An application naming itself as its focus while another is in front: LaunchBar, whose panel was closed, did so
    /// as the Dock took the keyboard (Control F3), and the Dock's arrows said nothing after (11 Nov 2026). An app
    /// itself is no place to be.
    func ruleApplicationItself(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXApplication", NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { return .go(target) }
        Log.io("focus on the application \(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "") itself, not in front; ignored")
        return .ignore
    }

    /// Just after TurnOver took the place on a control that refused the focus: the application's own news is set aside.
    func ruleSetAside(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if pid == activePid, SettingsPanePlugin.setsAside(target) {
            Log.io("focus to \(target.role) just after a settings Tab; set aside")
            return .ignore
        }
        return .go(target)
    }

    /// An untitled window: just after a settings tab switch (Safari's General rebuilds part of its window), back to
    /// the tab showing; from a helper (Safari's SandboxBroker while Safari's settings switch panes, 4 Oct 2026),
    /// ignored, and the application's real focus read a moment later.
    func ruleUntitledWindow(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWindow", (target.string(kAXTitleAttribute) ?? "").isEmpty else { return .go(target) }
        if Date().timeIntervalSince(PreferenceTab.lastTabFocusAt) < 1.5,
           let window = AXUIElementCreateApplication(activePid).element(kAXFocusedWindowAttribute), let tab = PreferenceTab.selectedTab(in: window) {
            Log.io("focus to an untitled window just after a settings tab switch; back to the tab")
            _ = tab.set(kAXFocusedAttribute, kCFBooleanTrue)
            PreferenceTab.lastTabFocusAt = Date()
            API.setFocusObject(ObjectFactory.make(tab), ancestors: API.focusAncestors)
            return .done
        }
        if pid != activePid, let helper = NSRunningApplication(processIdentifier: pid), isHelperOfActiveApp(helper),
           (AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute).map { $0.role == "AXWindow" } ?? true) {
            Log.io("focus to \(helper.bundleIdentifier ?? "a helper")'s untitled window; ignored, reading the real focus")
            let active = activePid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refocus(pid: active) }
            return .done
        }
        return .go(target)
    }

    /// A helper (Safari's SandboxBroker) reports its whole window as focused; the control inside is what has the keys.
    func ruleHelperWindow(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "AXWindow", pid != activePid, let helper = NSRunningApplication(processIdentifier: pid), isHelperOfActiveApp(helper),
           let inner = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), inner.role != "AXWindow" {
            return .go(inner)
        }
        return .go(target)
    }

    /// While a preference tab is being switched, the app may pull focus into the new pane (Safari's General puts
    /// it in the homepage field); the tab bar keeps it, as on Windows. PreferenceTab puts the app's focus back.
    func rulePreferenceTabSwitch(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // Only the switching app's focus, or a helper's drawing for it (a review, 14 Nov 2026).
        if Date() < PreferenceTab.quietUntil, !PreferenceTab.isPreferenceTab(target), target.role != "AXWindow",
           pid == PreferenceTab.quietPid || activePid == PreferenceTab.quietPid
            && (NSRunningApplication(processIdentifier: pid).map { isHelperOfActiveApp($0) } ?? false) {
            Log.io("focus to \(target.role) while switching preference tabs; held on the tab")
            return .ignore
        }
        return .go(target)
    }

    /// Safari reports focus inside its background windows (a page loading, an advertisement taking focus in its own
    /// window); only the application's focused window has the keyboard. A window just opened may report focus before
    /// the application names it focused, so the application is asked again shortly.
    func ruleBackgroundWindow(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard let window = target.element(kAXWindowAttribute), window.string(kAXSubroleAttribute) == "AXStandardWindow",
              let front = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute),
              front.string(kAXSubroleAttribute) == "AXStandardWindow", !front.isSame(window) else { return .go(target) }
        Log.io("focus in the background window \"\(Log.words(String(window.string(kAXTitleAttribute)?.prefix(40) ?? "")))\"; ignored")
        if backgroundRecheckPending {
            if backgroundSetAside.elements.count < 8 { backgroundSetAside.elements.append(target) }
        } else {
            backgroundRecheckPending = true
            backgroundSetAside = ([target], AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self else { return }
                self.backgroundRecheckPending = false
                let setAside = self.backgroundSetAside
                self.backgroundSetAside = ([], nil)
                // The application's focus now, if its window is the front one and TurnOver isn't on it: only the first
                // focus of a burst set aside was tested again, and a later one in a window just opened was never read
                // (a review, 13 Nov 2026). Only if it is one set aside (the window is the front one after all) or has
                // moved since: the app's focus left where it was while TurnOver holds a place of its own (the Tab
                // trap, a toolbar, NewDialogs) is no news, and taking it dropped the place (a review, 13 Nov 2026).
                guard pid == self.activePid else { return }
                let app = AXUIElementCreateApplication(pid)
                guard let f = app.element(kAXFocusedUIElementAttribute), API.focusObject?.isSameElement(as: f) != true,
                      let w = f.element(kAXWindowAttribute), let fw = app.element(kAXFocusedWindowAttribute), w.isSame(fw) else { return }
                let held = SettingsPanePlugin.heldRow.flatMap { SettingsPanePlugin.windowOf($0) }.map { $0.isSame(fw) } ?? false
                guard AXHandler.backgroundRecheckActs(isSetAside: setAside.elements.contains { $0.isSame(f) },
                                                 focusMovedSince: setAside.appFocus.map { !$0.isSame(f) } ?? true,
                                                 holdInFrontWindow: held) else {
                    Log.io("background window recheck: the app's focus is where it was, or TurnOver holds a place; left")
                    return
                }
                self.focusChanged(f, pid: pid)
            }
        }
        return .ignore
    }
    /// Whether the app's focus, read again after focus news in a background window was set aside, is taken.
    nonisolated public static func backgroundRecheckActs(isSetAside: Bool, focusMovedSince: Bool, holdInFrontWindow: Bool) -> Bool {
        !holdInFrontWindow && (isSetAside || focusMovedSince)
    }

    /// SwiftUI reports the focus on a text field twice (System Settings' search field and the fields in its panes, macOS
    /// 27): first a stand-in in the same place that answers nothing about its text (value, caret and length all "no
    /// value"), then the field itself, which the application gives as its focus. "Reported twice" kept the stand-in and
    /// let the field go: the field was read as a bare "edit", and the review keys found no caret in it and said nothing,
    /// press after press (29 Oct 2026). The application's own focus, the same control with text, is the one presented.
    func ruleTextStandIn(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // Its length, or else its caret, never its value: a long document's whole text was copied at each report, only for
        // the report to be set aside as a duplicate (the review of pull request 195, 29 Oct 2026).
        func hasText(_ e: AXUIElement) -> Bool { e.attr(kAXNumberOfCharactersAttribute) != nil || e.attr(kAXSelectedTextRangeAttribute) != nil }
        guard ["AXTextField", "AXTextArea"].contains(target.role), !hasText(target),
              let focused = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), !focused.isSame(target),
              hasText(focused), Self.sameControl(target, focused) else { return .go(target) }
        Log.io("focus on a \(target.role) with nothing behind it; the application's focus in the same place taken instead")
        return .go(focused)
    }

    /// The same element in the same window as TurnOver already has.
    func ruleDuplicate(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let window = target.element(kAXWindowAttribute)
        if let f = API.focusObject, f.isSameElement(as: target), focusWindow.map({ w in window.map { $0.isSame(w) } ?? true }) ?? false {
            Log.debug("duplicate focus for \(f.axRole)")
            return .ignore
        }
        return .go(target)
    }

    /// The key press passed on for, and how many times (main thread).
    private var passedOn: (at: Date, n: Int) { get { Self._passedOn } set { Self._passedOn = newValue } }
    private static var _passedOn: (at: Date, n: Int) = (.distantPast, 0)

    /// Mail's Tab order stops on its message list's hidden scroll bar between the list and the message: a stop
    /// with nothing to say or do. Tab on past it, as the user meant.
    /// Tab from a control of a toolbar that keeps its own stop (Mail's search, at the toolbar's end) onto the same
    /// toolbar's first item: the toolbar came round twice in one round (toolbar, search, toolbar, 13 Nov 2026). The
    /// toolbar was this round's stop already: on to the next stop past the search.
    private static var _backOntoToolbarKey = Date.distantPast
    private var backOntoToolbarKey: Date { get { Self._backOntoToolbarKey } set { Self._backOntoToolbarKey = newValue } }
    func ruleBackOntoToolbar(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let key = InputManager.lastKeyIdentifier
        // Tab only, and once per key: Shift Tab from the search onto the toolbar's item before it is right where it
        // goes, and taking it again from the field went round for a second (a review, 13 Nov 2026).
        guard key == "kb:tab", Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1, backOntoToolbarKey != InputManager.lastKeyDownAt,
              let prev = API.focusObject?.element, !prev.isSame(target), SettingsPanePlugin.ownArrows(prev),
              let w = SettingsPanePlugin.windowOf(target), let (tb, _) = SettingsPanePlugin.toolbarFor(target, in: w),
              let (tb2, _) = SettingsPanePlugin.toolbarFor(prev, in: w), tb.isSame(tb2), !SettingsPanePlugin.ownArrows(target),
              let plugin = SettingsPanePlugin.current, let g = KeyboardGesture(identifier: key),
              // Onto the toolbar's first item: round from its end, not along it.
              let first = SettingsPanePlugin.toolbarItems(around: target)?.items.first, first.isSame(target) else { return .go(target) }
        backOntoToolbarKey = InputManager.lastKeyDownAt
        Log.io("toolbar: \(key) from a control of the toolbar came back onto it; on past it")
        DispatchQueue.main.async { plugin.trapMove(g, forward: true) }
        return .done
    }

    func ruleHiddenScrollBar(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // Likewise a split view or its divider, nameless (Freeform's Tab stopped on its split group, 12 Nov 2026).
        let layout = ["AXSplitGroup", "AXSplitter"].contains(target.role) && ObjectFactory.make(target).name.isEmpty
        // Any scroll bar, shown or not: Mail's message scroll bar took Tab as a stop ("scroll bar 0", 13 Nov 2026), and
        // Tab is for what can be used, which a scroll bar is not from the keyboard.
        guard target.role == "AXScrollBar" || layout else { return .go(target) }
        let key = InputManager.lastKeyIdentifier
        // At most twice for one key press: a Tab order of nothing but split views would go round for ever (a review).
        if Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1.5, key == "kb:tab" || key == "kb:shift+tab", let g = KeyboardGesture(identifier: key),
           passedOn.at != InputManager.lastKeyDownAt || passedOn.n < 2 {
            passedOn = (InputManager.lastKeyDownAt, passedOn.at == InputManager.lastKeyDownAt ? passedOn.n + 1 : 1)
            Log.io("focus on a \(layout ? "nameless \(target.role)" : "scroll bar") after \(key); passing on")
            g.send()
            return .done
        }
        return .go(target)
    }

    /// An advertisement or tracking frame (about:blank, no address, nothing in it) takes focus while a page loads;
    /// following it left the document empty and quick navigation said "no next heading" until Tab. Only a frame:
    /// inside another web area, or detached from any window. Mail's compose body is also a blank web area
    /// (about:blank) but sits in its window, and must be followed (2 Oct: Tab into it said nothing).
    func ruleBlankFrame(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWebArea" else { return .go(target) }
        let address = (target.attr("AXURL") as? URL)?.absoluteString ?? (target.attr("AXURL") as? String) ?? ""
        let blankAddress = address.isEmpty || address == "about:blank"
        var nested = false
        var p = target.element(kAXParentAttribute); var hops = 0
        while let x = p, hops < 40 { if x.role == "AXWebArea" { nested = true; break }; p = x.element(kAXParentAttribute); hops += 1 }
        let detached = target.element(kAXWindowAttribute) == nil
        if blankAddress, nested || detached {
            Log.io("focus on a blank frame (\(address.isEmpty ? "no address" : Log.words(address))); ignored")
            return .ignore
        }
        return .go(target)
    }

    /// An empty web area that takes the focus with no key pressed: an advertisement or consent frame refreshing, or
    /// the page's own web area emptied for a moment by a reload. Following it replaced the document, said blank, and
    /// the heading keys found nothing until the page came back (bridgesandballoons.com, every thirty seconds or so,
    /// 23 Oct 2026, issue 78). Left alone, the document in hand stays; if the page really went, the next key finds
    /// the window's current web area (browse mode's replaced-on-reload check). Only while a page is being read: a
    /// first page, or one reached by a key, is followed as before.
    /// Only in the window of the page in hand: a frame refreshing, or the page's own web area emptied by a reload,
    /// both arrive there; a page chosen with the mouse in another window or another app is followed as it was
    /// (a second reviewer, 23 Oct 2026). A page that fills a moment later posts its focus again with content, and
    /// is followed then.
    func ruleEmptyWebAreaUnbidden(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWebArea" else { return .go(target) }
        guard let document = API.focusTreeInterceptor else { return .go(target) }
        guard !document.passThrough else { return .go(target) }   // in focus mode the keys bypass browse mode's recovery
        guard Date().timeIntervalSince(InputManager.lastKeyDownAt) > 1 else { return .go(target) }
        guard target.elements(kAXChildrenAttribute).isEmpty else { return .go(target) }
        guard let targetWindow = target.element(kAXWindowAttribute) else { return .go(target) }
        let sameWindow: Bool
        if let documentWindow = document.webArea.element(kAXWindowAttribute) {
            sameWindow = targetWindow.isSame(documentWindow)
        } else {
            // The page's web area has been replaced and can no longer name its window: the same process is taken as
            // the same window (a reload is the case this rule exists for; a second reviewer, 23 Oct 2026).
            sameWindow = !document.isAlive && target.pid == document.webArea.pid
        }
        guard sameWindow else { return .go(target) }
        Log.io("focus on an empty web area with no key pressed, in the window of the page in hand; ignored")
        followIfPageWent(document, tries: 6)
        return .ignore
    }

    /// After an ignored empty web area, looked at every 0.4 s for about two seconds: the application's focus is
    /// asked again, and a web area that now has the focus and content, other than the page in hand, is followed
    /// (the ignored one filled, or another tab was chosen with the mouse while it was still empty). Failing that,
    /// if the page in hand has gone (its web area dead or emptied) and the window has a new one with content, that
    /// one is followed. Now, not at the next key, which would have read the old buffer (a second reviewer, 23 Oct
    /// 2026).
    func followIfPageWent(_ document: BrowseModeDocument, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, API.focusTreeInterceptor === document else { return }
            let app = AXUIElementCreateApplication(document.webArea.pid)
            if let focused = app.element(kAXFocusedUIElementAttribute), focused.role == "AXWebArea",
               !focused.isSame(document.webArea), !focused.elements(kAXChildrenAttribute).isEmpty {
                Log.io("focus: the web area that took the focus has content now; following it")
                self.focusChanged(focused, pid: focused.pid)
                return
            }
            let oldGone = !document.isAlive || document.webArea.elements(kAXChildrenAttribute).isEmpty
            if oldGone, let fresh = document.currentWebArea(), !fresh.isSame(document.webArea), !fresh.elements(kAXChildrenAttribute).isEmpty {
                Log.io("focus: the page in hand went; following the window's new web area")
                self.focusChanged(fresh, pid: fresh.pid)
                return
            }
            if tries > 1 { self.followIfPageWent(document, tries: tries - 1) }
        }
    }

    /// Safari reports the page focused while its address bar, with the suggestions popup up, still has the keyboard.
    /// (Only a field you can type in: Mail's message window starts its focus on the read-only header, a text area,
    /// and the message itself was refused, leaving the user stuck on a blank field, 7 Oct 2026.)
    func ruleFieldStillHasKeys(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "AXWebArea", let cur = API.focusObject, cur.pid == pid, [.editableText, .searchField, .comboBox, .passwordEdit].contains(cur.role),
           (cur.element.attr(kAXFocusedAttribute) as? Bool) == true, cur.element.string(kAXIdentifierAttribute) != "message.header.content",
           { var st: DarwinBoolean = false; return AXUIElementIsAttributeSettable(cur.element, kAXValueAttribute as CFString, &st) == .success && st.boolValue }() {
            Log.io("focus to the web area while the \(cur.axRole) \"\(Log.words(cur.name))\" still reports focus; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// Two references to one control: the same role, the same frame.
    nonisolated static func sameControl(_ a: AXUIElement, _ b: AXUIElement) -> Bool {
        let names = [kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute]
        let x = a.attrs(names), y = b.attrs(names)
        guard let ra = x[kAXRoleAttribute] as? String, ra == (y[kAXRoleAttribute] as? String),
              let pa = x[kAXPositionAttribute], let pb = y[kAXPositionAttribute], let sa = x[kAXSizeAttribute], let sb = y[kAXSizeAttribute] else { return false }
        func point(_ v: AnyObject) -> CGPoint { var p = CGPoint.zero; axValue(v, .cgPoint, &p); return p }
        func size(_ v: AnyObject) -> CGSize { var s = CGSize.zero; axValue(v, .cgSize, &s); return s }
        return point(pa) == point(pb) && size(sa) == size(sb) && size(sa).width > 0
    }

    /// The same element reported again within half a second.
    func ruleReportedTwice(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // (SwiftUI hands over two references for one control: System Settings' switches were each read twice,
        // 10 Oct 2026. The same role in the same place on screen is the same control.)
        if let (last, at) = lastGainFocus, Date().timeIntervalSince(at) < 0.5, last.isSame(target) || Self.sameControl(last, target) {
            Log.debug("focus reported twice for the same element; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// A Qt view's item, then at once another view's: KeePassXC's folder tree took Down, and its entry list, showing
    /// the new folder, reported its current entry as the focus too, cutting off the folder (13 Nov 2026). The keys
    /// stay in the tree: a focus outside the item's view (or inside the item) within half a second is set aside.
    func ruleQtChildEcho(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        // (With no key since: a Tab to the entries is the user's, the echo comes on its own; a review, 13 Nov 2026.)
        guard target.role == "AXGroup", QtItemViews.isQt(pid), let (last, at) = lastGainFocus, Date().timeIntervalSince(at) < 0.5,
              InputManager.lastKeyDownAt < at,
              QtItemViews.role(of: last) == .listItem, !target.isSame(last), let view = last.element(kAXParentAttribute),
              SettingsPanePlugin.within(target, last) || !SettingsPanePlugin.within(target, view) else { return .go(target) }
        Log.io("focus to another Qt view's item just after an item; set aside")
        return .ignore
    }

    /// An element that answers no role is nothing to present.
    func ruleNoRole(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "?" { Log.debug("focus on an element with no role; ignored"); return .ignore }
        return .go(target)
    }

    /// Mail hands focus to an unnamed AXUnknown (its message view host). In the list's own window the list keeps
    /// the focus (arrows must stay in the list); in a message window the host's web area is what to read. A nameless
    /// container with a document inside (Mail's message window: an AXGroup or AXUnknown over the message body) is
    /// followed into the document.
    /// The outermost named control inside `e` (a few levels down) that says it is focused.
    static func focusedInside(_ e: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = e.elements(kAXChildrenAttribute).prefix(12).map { ($0, 1) }, seen = 0
        while !queue.isEmpty, seen < 40 {
            let (x, d) = queue.removeFirst(); seen += 1
            if (x.attr(kAXFocusedAttribute) as? Bool) == true, SettingsPanePlugin.controlRoles.contains(x.role) { return x }
            if d < 3 { queue += x.elements(kAXChildrenAttribute).prefix(12).map { ($0, d + 1) } }
        }
        return nil
    }

    /// The page a nameless container holds, if any. Walked on main for every nameless group's focus: up to 300
    /// elements, two calls each, per report (a review, 13 Nov 2026). Now 80, breadth first (a pane's page sits a
    /// level or two in), and the answer kept for the same group a moment: they come in twos and threes.
    private static var lastWebAreaInside: (group: AXUIElement, web: AXUIElement?, at: Date)?
    static func webAreaInside(_ group: AXUIElement) -> AXUIElement? {
        if let c = lastWebAreaInside, c.group.isSame(group), Date().timeIntervalSince(c.at) < 2 { return c.web }
        let web = group.firstDescendant(role: "AXWebArea", maxVisited: 80)
        lastWebAreaInside = (group, web, Date())
        return web
    }

    func ruleNamelessContainer(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let axRole = target.role
        guard axRole == "AXUnknown" || axRole == "AXGroup", let current = API.focusObject else { return .go(target) }
        let obj = ObjectFactory.make(target)
        guard obj.name.isEmpty else { return .go(target) }
        let window = target.element(kAXWindowAttribute)
        let sameWindow = current.element.element(kAXWindowAttribute).map { w in window.map { $0.isSame(w) } ?? false } ?? false
        // What TurnOver is on (a list, a table, a button) still says it has the keyboard: the report is the app
        // announcing a pane it loaded, not a move. Outlook does it as each message loads, half a second after Down;
        // TurnOver followed it into the reading pane (or onto an empty group, before the pane had a page) and the
        // arrows went silent; after Tab to New Email the same report pulled TurnOver off the button (parts request #2
        // and its comment, by an AI making an Outlook plugin, 14 Oct 2026). As Safari's field rule, for any control.
        if sameWindow, current.pid == pid, !current.element.isSame(target) {
            let holder = Self.listHoldingKeys(from: current.element) ?? ((current.element.attr(kAXFocusedAttribute) as? Bool) == true ? current.element : nil)
            if let holder {
                Log.io("focus on a nameless \(axRole) while the \(holder.role) \"\(Log.words(holder.string(kAXDescriptionAttribute) ?? holder.string(kAXTitleAttribute) ?? ""))\" still reports focus; ignored")
                return .ignore
            }
        }
        // A descendant says it has the keyboard (Photos: the focus on a nameless group, the "All Photos" list inside it
        // focused; Tab there was silent, 12 Nov 2026): that is the focus.
        if let inner = Self.focusedInside(target) {
            Log.io("focus on a nameless \(axRole): following it to the focused \(inner.role) inside")
            return .follow(inner)
        }
        if let web = Self.webAreaInside(target) {
            if sameWindow, axRole == "AXUnknown" { Log.io("focus on a nameless \(axRole) in the same window; ignored"); return .ignore }
            // A list or table in the same window still says it has the keyboard: the report is the app announcing a
            // pane it loaded, not a move. Outlook does it for its reading pane each time a message loads, half a
            // second after Down, and the next Down moved by line in the message (parts request #2, written by an AI
            // making an Outlook plugin, 14 Oct 2026). As Safari's field rule, for lists.

            Log.io("focus on a nameless \(axRole): following it to its web area")
            return .follow(web)
        }
        if axRole == "AXUnknown" {
            // Another app's focus still held: keeping it let that app's commands answer here. Byword's text box
            // took Excel's arrows ("caret did not move", silence) because Excel's first focus is a nameless
            // AXUnknown over its grid (Day 2, 10 Oct 2026). Held quietly instead, and the app asked again a moment
            // later: Excel names its cell once it has built its tree for an assistive app.
            if current.pid != pid {
                Log.io("focus on a nameless AXUnknown in a new app; held quietly, asking again shortly")
                let obj = ObjectFactory.make(target)
                API.setFocusObject(obj, ancestors: obj.ancestors)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    guard let self, API.focusPid == pid, let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute),
                          !f.isSame(target), f.role != "AXUnknown" else { return }
                    Log.io("focus asked again: \(f.role)")
                    self.focusChanged(f, pid: pid)
                }
                return .done
            }
            Log.io("focus on a nameless AXUnknown with no document inside; ignored"); return .ignore
        }
        return .go(target)
    }

    /// The list, table or outline the focus is in (the focus itself, or a row or cell of it), if it still says it
    /// has the keyboard.
    static func listHoldingKeys(from e: AXUIElement) -> AXUIElement? {
        var x: AXUIElement? = e; var hops = 0
        while let y = x, hops < 4 {
            if ["AXList", "AXTable", "AXOutline"].contains(y.role) { return (y.attr(kAXFocusedAttribute) as? Bool) == true ? y : nil }
            x = y.element(kAXParentAttribute); hops += 1
        }
        return nil
    }

    static let menuRoles: Set<Role> = [.menu, .menuItem, .checkMenuItem, .radioMenuItem, .menuBar, .popupMenu]

    /// Right or Left in the menu bar closes one menu before opening the next, and the application hands focus back
    /// to its window in between. Wait a moment: if a menu opens, this focus never happened. (0.6 s: Mail can take
    /// longer than Safari between closing one menu and opening the next.)
    func ruleMenuGap(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard !isMenuOpen, let (mpid, at) = lastMenuClosed, mpid == pid, Date().timeIntervalSince(at) < 0.6 else { return .go(target) }
        let role = Role.from(axRole: target.role, subrole: target.string(kAXSubroleAttribute))
        guard !Self.menuRoles.contains(role) else { return .go(target) }
        Log.io("focus to \(target.role) just after a menu closed; waiting to see whether another opens")
        menuGapTarget = target
        if !menuGapRecheckPending {
            menuGapRecheckPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.menuGapRecheckPending = false
                let waited = self.menuGapTarget
                self.menuGapTarget = nil
                guard !self.isMenuOpen else { return }
                // The application may now answer with just its window (Safari loading the page typed into the
                // address bar, whose completion list was the menu): the element that took focus is the news.
                let now = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
                if let w = waited, w.role != "AXWindow", w.element(kAXWindowAttribute) != nil, now == nil || now?.role == "AXWindow" {
                    Log.io("refocus after the menu gap: the application names only its window; taking the \(w.role) that took focus")
                    self.lastMenuClosed = nil
                    self.focusChanged(w, pid: pid)
                } else {
                    // The gap is over: a refocus asked for during it was diverted here and never presented, so this
                    // one must (the text area after a spelling menu was skipped as "again", and the arrows went
                    // quiet, 14 Oct 2026).
                    self.lastMenuClosed = nil
                    Log.io("focus after the menu gap: \(now?.role ?? "none")")
                    self.refocus(pid: pid)
                }
            }
        }
        return .done
    }

    /// Word hands focus back to the document under its menus; a menu open in the same application holds the focus back.
    func ruleMenuOpen(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let role = Role.from(axRole: target.role, subrole: target.string(kAXSubroleAttribute))
        if isMenuOpen, !Self.menuRoles.contains(role), openMenus.contains(where: { $0.pid == pid }) {
            // A page's menu reports no close: focus landing elsewhere in the page means it has gone.
            if topMenuIsWeb, target.enclosingWebArea() != nil {
                Log.io("focus to \(target.role) in the page while its web menu was counted open: the menu has closed")
                openMenus.removeAll { $0.pid == pid }
                return .go(target)
            }
            Log.io("focus to \(target.role) while a menu is open in its application; ignored")
            return .ignore
        }
        return .go(target)
    }

    /// The application itself reported as the focus (Mail, a shortcut menu closed with Escape over a message's audio
    /// attachment): nothing in a window had it, "Mail" was said twice, and every Tab after found no window and went
    /// nowhere (a tester, 13 Nov 2026). The control TurnOver was on keeps the place if it is still there, and the app
    /// is given it back; otherwise the app's focused window.
    func ruleApplicationKeepsPlace(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXApplication" else { return .go(target) }
        // Only in the app's focused (or main) window: reported while windows were switching, the old control would
        // raise the old window again (a review, 13 Nov 2026).
        let front = target.element(kAXFocusedWindowAttribute) ?? target.element(kAXMainWindowAttribute)
        if let f = API.focusObject, f.pid == pid, f.element.role != "?", f.element.role != "AXApplication",
           let fw = f.element.element(kAXWindowAttribute), front.map({ $0.isSame(fw) }) ?? false {
            Log.io("focus on the application itself; \(f.axRole) keeps the place")
            if f.element.role != "AXWebArea", !SettingsPanePlugin.isInWeb(f.element) { _ = f.element.set(kAXFocusedAttribute, kCFBooleanTrue) }
            return .ignore
        }
        if let w = target.element(kAXFocusedWindowAttribute) ?? target.element(kAXMainWindowAttribute) {
            Log.io("focus on the application itself; to its window")
            return .follow(w)
        }
        return .go(target)
    }

    /// The window itself reported as the focus while a control inside it has it: a page in a tab you just left
    /// still says it is focused (Safari's Control+Tab), so if the window now shows another page, that page is the
    /// focus; Chromium and Electron apps send a focus event for the window while a control keeps the keyboard; and
    /// when the control has let go (Safari after Return in the address bar), the keys go to the page.
    func ruleWindowWhileControlHasKeys(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        guard target.role == "AXWindow", let f = API.focusObject, f.pid == pid, !f.isSameElement(as: target),
              f.element.element(kAXWindowAttribute).map({ $0.isSame(target) }) ?? false else { return .go(target) }
        let name = target.string(kAXTitleAttribute) ?? ""
        if let page = f.element.enclosingWebArea(), let shown = target.firstWebArea(), !shown.isSame(page) {
            Log.io("focus to the window \"\(Log.words(name))\": it shows another page now; to that page")
            return .follow(shown)
        }
        if (f.element.attr(kAXFocusedAttribute) as? Bool) != false {
            Log.io("focus to the window \"\(Log.words(name))\" while \(f.axRole) inside it has focus; ignored")
            return .ignore
        }
        if let web = target.firstWebArea() {
            Log.io("focus to the window \"\(Log.words(name))\" after \(f.axRole) let go; to its page")
            return .follow(web)
        }
        // The control let go, but the app may only be passing the focus through its window on the way to the next
        // control: Reminders does it on every Tab between a reminder's title and its notes, and TurnOver said the
        // window and its list before each field (10 Oct 2026). Held a quarter of a second; said only if
        // nothing else takes the focus.
        let since = lastGainFocus?.1
        Log.io("focus to the window \"\(Log.words(name))\" after \(f.axRole) let go; held a moment")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.lastGainFocus?.1 == since, API.focusPid == pid else { return }
            // The app's own focus first: Safari, opening an address, named its window "Untitled" for a moment while
            // the page kept the keyboard, and TurnOver took the window and left browse mode (a sweep, 13 Nov 2026).
            if let real = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute), real.role != "AXWindow", real.role != "?" {
                let page = f.element.enclosingWebArea()
                // (Or the page browse mode is already reading: the new page that took the old one's place.)
                let reading = API.focusTreeInterceptor.map { real.isSame($0.webArea) } ?? false
                if reading || real.isSame(f.element) || (page != nil && real.enclosingWebArea().map { $0.isSame(page!) } == true) {
                    Log.io("focus: the window \"\(Log.words(name))\" passed; the app's focus is still \(f.axRole)")
                    return
                }
                Log.io("focus: nothing followed the window \"\(Log.words(name))\"; the app's focus, \(real.role)")
                self.present(real, pid: pid)
                return
            }
            Log.io("focus: nothing followed the window \"\(Log.words(name))\"; the window")
            self.present(target, pid: pid)
        }
        return .ignore
    }

    /// The window itself, already spoken as the foreground: take it as the focus quietly.
    func ruleWindowAlreadyPresented(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        if target.role == "AXWindow", focusWindow.map({ target.isSame($0) }) ?? false, Date().timeIntervalSince(lastForegroundAt) < 1.0 {
            let obj = ObjectFactory.make(target)
            focusWindow = target
            API.setFocusObject(obj, ancestors: obj.ancestors)
            return .done
        }
        return .go(target)
    }

    /// The element may carry the observed app's pid while its application ancestor is another process: the cursor
    /// service's window arrives this way through the Claude app's observer.
    func ruleOwnedByAnotherProcess(_ target: AXUIElement, _ pid: pid_t, _ element: AXUIElement) -> FocusVerdict {
        let obj = ObjectFactory.make(target)
        let ancestors = obj.ancestors
        madeForFocus = (target, obj, ancestors)
        if let top = ancestors.last, top.role == .application, top.pid != pid || top.pid != activePid {
            let owner = NSRunningApplication(processIdentifier: top.pid)
            let isContentProcess = (owner?.bundleIdentifier ?? "").hasPrefix("com.apple.WebKit.")   // Mail's message bodies live in WebContent
                || owner.map(isHelperOfActiveApp) ?? false   // Safari's Settings window is served by com.apple.Safari.SandboxBroker
            if !isContentProcess, owner == nil || owner?.activationPolicy == .prohibited {
                Log.io("focus on \(obj.axRole) \"\(Log.words(obj.name))\" owned by \(owner?.bundleIdentifier ?? "pid \(top.pid)") (not an application); ignored")
                return .ignore
            }
        }
        return .go(target)
    }

    // MARK: Presenting the new focus

    /// The focus is `target`: the ancestors newly entered, then the focus itself, as events.
    func present(_ target: AXUIElement, pid: pid_t) {
        let (obj, ancestors): (TurnOverObject, [TurnOverObject]) = {
            if let m = madeForFocus, m.element.isSame(target) { return (m.obj, m.ancestors) }
            let o = ObjectFactory.make(target); return (o, o.ancestors)
        }()
        madeForFocus = nil
        let window = target.element(kAXWindowAttribute)
        let old = API.focusObject
        let oldAncestors = API.focusAncestors
        focusWindow = window
        // The focus TurnOver moved itself, after its cursor (VoiceOver's "keyboard focus follows the cursor"): the
        // cursor has said it already, and stays where it is (on a row, while the list has the focus).
        if ObjectNavigator.shared.isFollowedFocus(obj.element) {
            if let old { EventHandler.queue(Event(.loseFocus, old)) }
            API.setFocusObject(obj, ancestors: ancestors, interceptor: BrowseModeHandler.shared.document(for: obj, ancestors: ancestors))
            // No gainFocus is queued, so the settings plugin is told itself: a place it held elsewhere is let go and
            // its trap and toolbar state follow, or Up and Down read the old list and Tab went on from the old place
            // (a review, 14 Nov 2026). It speaks nothing here.
            SettingsPanePlugin.focusMoved(to: obj, followed: true)
            Log.io("focus followed the cursor to \(obj.element.role); not spoken")
            return
        }
        if let old { EventHandler.queue(Event(.loseFocus, old)) }
        // Some apps rest the focus on a nameless group for a moment between items (Spring's timeline: every arrow went
        // tweet, nameless group, next tweet). The group says nothing, but its ancestors became the ones compared with,
        // so the list around the items was "entered" again and said ("Home, grouping"; 13 Oct 2026). Within
        // half a second of such a stop, the ancestors from before it count as known too.
        let namelessStop = obj.name.isEmpty && obj.element.role == "AXGroup"
        var known = oldAncestors
        if let b = beforeNamelessStop, Date().timeIntervalSince(b.at) < 0.5 {
            known += b.ancestors + (b.focus.map { [$0] } ?? [])
            if !namelessStop { Log.io("focus: passed through a nameless group; the ancestors from before it kept") }
        }
        if namelessStop {
            if beforeNamelessStop.map({ Date().timeIntervalSince($0.at) >= 0.5 }) ?? true { beforeNamelessStop = (oldAncestors, old, Date()) }
        } else {
            beforeNamelessStop = nil
        }
        // Dialogs inside dialogs (a sheet opened from a sheet in System Settings): the one in front is said, not each
        // round it too ("dialog, System Services…, dialog, Significant Locations…, dialog, System Services…", 13 Nov 2026).
        let front = ancestors.first { [.dialog, .sheet].contains($0.role) }
        // A tab's page newly entered: "<tab> property page", as NVDA says a tab control's page; and a settings form's
        // pane and sections on Tab (PaneContext), where the focus really moves (a tester, 13 Nov 2026).
        let byTab = ["kb:tab", "kb:shift+tab"].contains(InputManager.lastKeyIdentifier) && Date().timeIntervalSince(InputManager.lastKeyDownAt) < 1
        for a in ancestors where a.axRole == "AXTabGroup" {
            let tabs = a.element.elements(kAXTabsAttribute).isEmpty ? a.element.elements(kAXChildrenAttribute).filter { $0.role == "AXRadioButton" } : a.element.elements(kAXTabsAttribute)
            // Entered: from outside the tab group, or from one of its tabs onto its page (AppKit's tabs sit in it).
            let fromTab = old.map { o in tabs.contains { $0.isSame(o.element) } } ?? false
            if !fromTab, known.contains(where: { $0.isSameElement(as: a) }) || oldAncestors.contains(where: { $0.isSameElement(as: a) }) { break }
            if let sel = tabs.first(where: { ($0.attr(kAXValueAttribute) as? NSNumber)?.intValue == 1 }) {
                let name = ObjectFactory.make(sel).name
                // (Not on the tabs themselves: a tab says its own name.)
                if !name.isEmpty, !tabs.contains(where: { $0.isSame(obj.element) }) {
                    Speech.speakMessage(String(localized: "\(name) property page", comment: "Coming into a settings pane: %@ is its name (NVDA's property page)"))
                }
            }
            break
        }
        if byTab {
            let context = PaneContext.news(from: old?.element, to: obj.element)
            if !context.isEmpty { Speech.speakMessage(context.joined(separator: ", ")) }
        }
        for a in ancestors.reversed() where a.isPresentableFocusAncestor {
            if [.dialog, .sheet].contains(a.role), let front, !a.isSameElement(as: front) { continue }
            if known.contains(where: { $0.isSameElement(as: a) }) || old?.isSameElement(as: a) == true { continue }
            if let w = focusWindow, a.isSameElement(as: w) { continue }   // the window was presented as the foreground
            if let (el, at) = lastEntered, el.isSame(a.element), Date().timeIntervalSince(at) < 1.5 { continue }   // a sheet announced on creation
            // A part named as its window (Electron's root group: 1Password's window, then "Our Family — All Items —
            // 1Password, grouping", 12 Nov 2026): the window said that.
            if !a.name.isEmpty, ![.dialog, .sheet].contains(a.role), let w = focusWindow, a.name == w.string(kAXTitleAttribute) { continue }
            // A cell with the same name as the button in it (WhatsApp's Settings): the button says it.
            if !a.name.isEmpty, a.name == obj.name { continue }
            // Tab on a page: the group the control sits in is not news (BrowseModeDocument.lastTabFromCaretAt).
            if a.role == .groupBox, Date().timeIntervalSince(BrowseModeDocument.lastTabFromCaretAt) < 1.0 { continue }
            lastEntered = (a.element, Date())
            EventHandler.queue(Event(.focusEntered, a))
        }
        lastGainFocus = (target, Date())
        let interceptor = BrowseModeHandler.shared.document(for: obj, ancestors: ancestors)
        // Into a document from outside it (another app, the window around the page): its focus event is told, as NVDA's
        // tree interceptor is (_enteringFromOutside).
        interceptor?.focusFromOutside = interceptor !== API.focusTreeInterceptor
        API.setFocusObject(obj, ancestors: ancestors, interceptor: interceptor)
        ObjectNavigator.shared.focusMoved(to: obj.element, pid: pid)
        EventHandler.queue(Event(.gainFocus, obj))
        // (Its list may come only with the first letter: whether it owns it is asked at typing time.)
        if ["AXTextField", "AXComboBox", "AXSearchField"].contains(target.role) { TurnOverObject.listField = target }
        // Notification Centre's panel taking the focus (Fn N): it has opened, whatever the foreground flag says (an
        // Escape that closed it left the flag set, and the next opening went unnoticed, 12 Nov 2026).
        if target.role == "AXWindow", pid == NotificationCentrePanel.centrePid() { NotificationCentrePanel.panelFocused(target) }
        DesktopNavigator.focusChanged(target, pid: pid)
    }

    /// A dialog or sheet is in front in this application: its focused window is one, or has one on it (Word's Save
    /// sheet is sometimes the focused window, sometimes a child of the document's).
    public static func modalInFront(pid: pid_t) -> Bool {
        guard let w = AXUIElementCreateApplication(pid).element(kAXFocusedWindowAttribute) else { return false }
        if w.role == "AXSheet" || ["AXDialog", "AXSystemDialog"].contains(w.string(kAXSubroleAttribute) ?? "") { return true }
        return w.elements(kAXChildrenAttribute).contains { $0.role == "AXSheet" }
    }

    /// Whether a foreground window change repeats the last: the same window with the same title, and no app switch.
    package static func sameForeground(title: String, lastTitle: String, sameWindow: Bool, appName: String?) -> Bool {
        appName == nil && sameWindow && title == lastTitle
    }

    func foregroundChanged(_ window: AXUIElement, appName: String?) {
        let obj = ObjectFactory.make(window)
        let subrole = obj.axSubrole ?? ""
        if subrole == "AXFloatingWindow" || subrole == "AXUnknown" { return }   // Word's "Cursor Actions" helper and the like
        let title = obj.name
        // Before the repeat check: a page titled Notification Center beneath the panel must not hide the transition.
        NotificationCentrePanel.noteForeground(window)
        // The same window again is no news; another window with the same title is (two "Untitled" documents, two
        // Finder windows on one folder: Command ` between them said nothing, a review, 13 Nov 2026). Compared as
        // elements, not by title.
        if Self.sameForeground(title: title, lastTitle: lastForegroundTitle, sameWindow: focusWindow.map { CFEqual($0, window) } ?? false, appName: appName) { return }
        lastForegroundTitle = title
        lastForegroundAt = Date()
        focusWindow = window
        API.setForegroundObject(obj)
        EventHandler.queue(Event(.foreground, obj))
        if NotificationCentrePanel.isPanelOpeningForKey(window) {
            Log.io("foreground: Notification Centre's panel, for the key; the key says it")
            return
        }
        let isDialog = obj.role == .dialog || obj.role == .sheet
        let shownTitle = appName == title ? "" : title
        // A title with the app's name in it already ("Our Family — All Items — 1Password") isn't led by it again.
        let appName = appName.map { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) && !shownTitle.isEmpty ? "" : $0 }
        // The app's name alone with the role is one phrase, as the language says it ("Finder penceresi" in Turkish);
        // in English as before: "Finder, window" in the Mac style, "Finder window" in the Windows style.
        let text = if let appName, !appName.isEmpty, shownTitle.isEmpty {
            switch (isDialog, config.general.windowsKeys) {
            case (false, false): String(localized: "\(appName), window", comment: "A window in front: %@ is its app (Mac style)")
            case (false, true): String(localized: "\(appName) window", comment: "A window in front: %@ is its app (Windows style)")
            case (true, false): String(localized: "\(appName), dialog", comment: "A dialog in front: %@ is its app (Mac style)")
            case (true, true): String(localized: "\(appName) dialog", comment: "A dialog in front: %@ is its app (Windows style)")
            }
        } else { Speech.joined([appName ?? "", shownTitle, (isDialog ? Role.dialog : Role.window).displayString]) }
        // The focus itself just landed on this window and said it (Notes as its welcome sheet closed: the window's
        // name twice, 11 Nov 2026): once is enough.
        let justSaid = API.focusObject?.isSameElement(as: obj) == true && Speech.sinceFocusSpoken < 0.5
        // A system agent's window (coreautha's Touch ID prompt: "Untitled window" after its words, 12 Nov 2026): the
        // prompt's reading said it.
        let agentWindow = !(obj is Dialog) && SystemPrompts.isProtected(window.pid)
        if obj is Dialog { EventHandler.queue(Event(.focusEntered, obj)) } else if justSaid || agentWindow { Log.io(agentWindow ? "foreground: a system agent's window; its prompt was read" : "foreground: the window the focus just said") } else { Speech.speakOnly(text) }   // a window's name: the display shows the focus in it
        // A window with nothing to read (OpenGL, custom drawing): said a moment later, with the recognition key (issue 74).
        if !(obj is Dialog), window.pid != ProcessInfo.processInfo.processIdentifier { EmptyWindowNotice.check(window, pid: window.pid) }
    }
}
