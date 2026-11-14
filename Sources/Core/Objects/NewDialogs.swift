// SPDX-License-Identifier: GPL-3.0-or-later
// Dialogs that appear without the focus (11 Nov 2026). Two kinds were missed:
// - A sheet over a window, its focus left behind it: Bluetooth's Show Detail in System Settings was announced but Tab,
//   the arrows and object navigation stayed in the pane behind (a tester, 10 Nov 2026).
// - A window that opens beside the one in use and never takes the focus, with a progress bar: Finder's copy window
//   was announced, but its bar was never heard, since a bar is followed only once TurnOver has read it (ProgressWatch),
//   and nothing moved into the window (a tester, 10 Nov 2026).
// So a sheet whose app leaves the focus outside it is read (its text) and TurnOver lands on its safe button; a new
// window of the app in front that holds a progress bar is read and its bar followed. An app module may do its own
// (AppModule.sheetOpened).
import Foundation
import AppKit
import ApplicationServices

enum NewDialogs {
    /// When a sheet was last announced as it opened, and in which app: its text was said with it ("dialog, Name, …"),
    /// so landing in it doesn't say it again (three times in all, 11 Nov 2026).
    static var announced: (pid: pid_t, at: Date)?
    /// The last sheet's text, to tell a sheet made twice from a new one.
    static var lastSheetText = ""

    /// Focus the app moves behind its sheet just as the sheet opens (System Settings makes Bluetooth's Show Detail
    /// twice and moves its focus to the pane's switch in between: "Bluetooth switch on" between the sheet's text and
    /// its Done button, 11 Nov 2026): within a second of the sheet, in its app and in no sheet.
    static func isBehindNewSheet(_ e: AXUIElement) -> Bool {
        guard let a = announced, Date().timeIntervalSince(a.at) < 1, e.pid == a.pid,
              InputManager.lastKeyDownAt < a.at else { return false }   // not after Escape: the focus is back for real
        // Not a control of a sheet now on its window whose parents don't name the sheet: looked for down the sheet's
        // own tree (a review, 11 Nov 2026).
        if let w = SettingsPanePlugin.windowOf(e) {
            for sheet in w.elements(kAXChildrenAttribute) where sheet.role == "AXSheet" {
                var queue = [sheet], visited = 0
                while !queue.isEmpty, visited < 300 {
                    let x = queue.removeFirst(); visited += 1
                    if x.isSame(e) { return false }
                    queue.append(contentsOf: x.elements(kAXChildrenAttribute))
                }
            }
        }
        // Same app, and in no sheet. Not compared by window: System Settings' sheet hangs from another element than
        // the window its pane's controls name (11 Nov 2026).
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 25 { if x.role == "AXSheet" { return false }; p = x.element(kAXParentAttribute); hops += 1 }
        return true
    }

    static func textJustSaid(pid: pid_t) -> Bool {
        guard let a = announced else { return false }
        return a.pid == pid && Date().timeIntervalSince(a.at) < 2
    }

    /// A sheet was created; a moment later, if the focus is still outside it, TurnOver goes in.
    static func sheetAppeared(_ sheet: AXUIElement, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard sheet.role == "AXSheet", NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            // Only a sheet on the window in use: one on a window behind (Mail's send error while another message is
            // being written) must not take the keys from it (a review, 11 Nov 2026).
            let appEl = AXUIElementCreateApplication(pid)
            guard let focusedWindow = appEl.element(kAXFocusedWindowAttribute),
                  sheet.element(kAXParentAttribute)?.isSame(focusedWindow) == true || sheet.isSame(focusedWindow) else { return }
            if AppModuleHandler.shared.appModule(for: pid).sheetOpened(sheet) { return }
            // The app's own focus, not only TurnOver's: in the sheet already, in a field (typing), or in another process
            // (an Open or Save panel is drawn by a service of its own): left as it is.
            if let real = appEl.element(kAXFocusedUIElementAttribute) {
                if isInside(real, sheet) || real.pid != pid || ["AXTextField", "AXTextArea", "AXComboBox"].contains(real.role) { return }
            }
            if let f = API.focusObject?.element, isInside(f, sheet) { return }
            guard let target = landing(in: sheet) else { return }
            let words = textJustSaid(pid: pid) ? "" : text(of: sheet)
            Log.io("dialogs: a sheet opened with the focus outside it (\(words.count) characters of text); onto its \(target.role)")
            if !words.isEmpty { Speech.speakMessage(words) }
            land(on: target, interrupt: false)   // after the sheet's announcement, not over it
        }
    }

    /// A Command shortcut that went to the app in front (Command N in Mail): if a moment later the app says another
    /// window has the focus, TurnOver goes there. Mail opened its New Message window with no window or focus news at
    /// all, and Tab went on in the main window behind it until the user left Mail and came back (a tester, 13 Nov 2026).
    static func watchCommandKey(_ g: KeyboardGesture) {
        guard g.modifiers.contains(.command), !g.modifiers.contains(.turnover), g.keyName.count == 1,
              let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() else { return }
        let pid = front.processIdentifier, before = AXHandler.shared.focusWindow, keyAt = InputManager.lastKeyDownAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard InputManager.lastKeyDownAt == keyAt, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  !AXHandler.shared.isMenuOpen else { return }
            let appEl = AXUIElementCreateApplication(pid)
            guard let w = appEl.element(kAXFocusedWindowAttribute), w.role == "AXWindow", before.map({ !$0.isSame(w) }) ?? true,
                  API.focusObject.map({ !isInside($0.element, w) }) ?? true else { return }
            Log.io("new window: \(g.keyName) opened a window the app gave no news of; going there")
            AXHandler.shared.foregroundChanged(w, appName: nil)
            if let f = appEl.element(kAXFocusedUIElementAttribute) { AXHandler.shared.focusChanged(f, pid: pid) }
        }
    }

    /// A window was created in the app in front; a moment later, one holding a progress bar is read and its bar followed,
    /// and a small one that took the focus with no control inside it focused is entered.
    static func windowAppeared(_ window: AXUIElement, pid: pid_t) {
        // Only while that app is still in front and no key came since: a window that appeared as the person
        // switched away or typed on was entered and spoken over them half a second later (a review, 14 Nov 2026).
        let keyAt = InputManager.lastKeyDownAt
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            guard InputManager.lastKeyDownAt == keyAt, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard window.role == "AXWindow" else { return }
            let appEl = AXUIElementCreateApplication(pid)
            if let f = API.focusObject?.element, !f.isSame(window), isInside(f, window) { return }
            let bar = firstProgressBar(in: window).flatMap { hasPercent($0) ? $0 : nil }
            let title = window.string(kAXTitleAttribute) ?? ""
            if let fw = appEl.element(kAXFocusedWindowAttribute), fw.isSame(window) {
                // The window in use, its focus on the window itself and no control (11 Nov 2026, macOS 27.2: Finder's
                // copy window takes the focus as a window; Tab and the arrows did nothing and the bar wasn't heard, a
                // tester). A new document or settings window focuses a control or is larger: left to the app.
                if let real = appEl.element(kAXFocusedUIElementAttribute), !real.isSame(window) { return }
                let controls = SettingsPanePlugin.controlsInOrder(in: window).filter { ($0.attr(kAXEnabledAttribute) as? Bool) != false && !isTitleBarButton($0) }
                guard bar != nil || (1...6).contains(controls.count) else { return }
                guard let target = bar ?? landing(in: window) else { return }
                let words = text(of: window)
                Log.io("dialogs: a window took the focus with nothing in it focused (\(words.count) characters); onto its \(target.role)")
                // Not when the dialog itself was just said with these words (an alert announced as it came forward:
                // its message twice, 11 Nov 2026).
                let alreadySaid = !words.isEmpty && Speech.lastSpoken.contains(String(words.prefix(60)))
                if !words.isEmpty, !alreadySaid { Speech.speakMessage(words) }
                land(on: target, interrupt: false, ownWindow: window)
                if let bar { ProgressWatch.watch(ObjectFactory.make(bar)) }
                return
            }
            // Not the window in use (a new document window, Command N): only one beside it, and only a bar with a
            // percentage, not a spinner (a review, 11 Nov 2026).
            guard let bar else { return }
            let words = [title, text(of: window)].filter { !$0.isEmpty }.joined(separator: ", ")
            Log.io("dialogs: a window with a progress bar appeared (\(words.count) characters); its bar followed")
            if !words.isEmpty { Speech.speakMessage(words) }
            ProgressWatch.watch(ObjectFactory.make(bar))
        }
    }

    /// A bar with a percentage: a range, or no maximum and a value from 0 to 1 (Finder's copy window, macOS 27.2).
    static func hasPercent(_ bar: AXUIElement) -> Bool {
        guard let v = (bar.attr(kAXValueAttribute) as? NSNumber)?.doubleValue, v.isFinite else { return false }
        let lo = (bar.attr(kAXMinValueAttribute) as? NSNumber)?.doubleValue ?? 0
        if let hi = (bar.attr(kAXMaxValueAttribute) as? NSNumber)?.doubleValue { return hi > lo }
        return v >= 0 && v <= 1
    }

    /// TurnOver on a control: the keyboard focus asked for, and if the app keeps it elsewhere, the place held (Space
    /// and Return press it), with object navigation from there.
    /// `ownWindow`: a window whose Tab is TurnOver's from now on (its app moves no focus in it); not a sheet's window,
    /// which has its own Tab again once the sheet goes.
    static func land(on e: AXUIElement, interrupt: Bool, ownWindow: AXUIElement? = nil) {
        _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
        let pid = e.pid, keyAt = InputManager.lastKeyDownAt, scope = SettingsPanePlugin.scopeOf(e)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let real = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
            if let real, real.isSame(e) { return }   // the app took it: its own focus news says it
            // A key since (the user's Tab), or a focus the app put elsewhere in the same sheet or window (its own
            // choice of first control), or TurnOver already there by the app's news: theirs stands. Held over them, the
            // place went back to `e` and was said twice (a review, 13 Nov 2026). The scope itself (a window focused as
            // a whole, Finder's copy window) is no choice.
            guard InputManager.lastKeyDownAt == keyAt else { return }
            if let scope {
                let elsewhere = [real, API.focusObject?.element].compactMap { $0 }
                if elsewhere.contains(where: { !$0.isSame(scope) && !$0.isSame(e) && isInside($0, scope) }) { return }
            }
            // ownTab false: the settings panes' Tab would go round the window behind the sheet (a review, 11 Nov 2026).
            SettingsPanePlugin.holdVirtual(e, speak: interrupt, ownTab: false)
            if !interrupt { Speech.speakObject(ObjectFactory.make(e), reason: .focus) }
            ObjectNavigator.shared.releaseHold()
            ObjectNavigator.shared.place(e)
            if let w = ownWindow {
                // The trap's own watcher can't take Tab here: the bar's climb counts as news from the app, as if Tab
                // had moved something.
                SettingsPanePlugin.loopWindows.append(w)
                if SettingsPanePlugin.loopWindows.count > 20 { SettingsPanePlugin.loopWindows.removeFirst() }
                SettingsPanePlugin.setTrapState(for: e)
            }
        }
    }

    /// Where a dialog opens: its default button, else its Done, OK, Close or Cancel, else its first control. Never a
    /// first control like Bluetooth's "Forget This Device…", which Space would press, when a safe one is there.
    static func landing(in root: AXUIElement) -> AXUIElement? {
        if let d = root.element(kAXDefaultButtonAttribute) { return d }
        let controls = SettingsPanePlugin.controlsInOrder(in: root).filter { ($0.attr(kAXEnabledAttribute) as? Bool) != false && !isTitleBarButton($0) }
        let safe = ["Done", "OK", "Close", "Cancel"]
        return controls.first { c in safe.contains(c.string(kAXDescriptionAttribute) ?? "") || safe.contains(c.string(kAXTitleAttribute) ?? "") } ?? controls.first
    }

    /// A dialog's text as it is read when it opens: its static texts in order, a text inside a text with the same words
    /// said once; at most 400 characters.
    static func text(of root: AXUIElement) -> String {
        var out: [String] = []
        var visited = 0
        func walk(_ e: AXUIElement) {
            guard visited < 300 else { return }
            visited += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, out.last != v { out.append(v) }
            for k in e.elements(kAXChildrenAttribute) { walk(k) }
        }
        walk(root)
        let joined = out.joined(separator: ", ")
        return joined.count > 400 ? String(joined.prefix(400)) : joined
    }

    /// The title bar's close, zoom, minimise and full-screen buttons: never where a window opens (Space on the close
    /// button would close it, a review, 11 Nov 2026).
    static func isTitleBarButton(_ e: AXUIElement) -> Bool {
        ["AXCloseButton", "AXZoomButton", "AXMinimizeButton", "AXFullScreenButton"].contains(e.string(kAXSubroleAttribute) ?? "")
    }

    static func firstProgressBar(in root: AXUIElement) -> AXUIElement? {
        var queue = [root], visited = 0
        while !queue.isEmpty, visited < 120 {
            let e = queue.removeFirst(); visited += 1
            if e.role == "AXProgressIndicator" { return e }
            queue.append(contentsOf: e.elements(kAXChildrenAttribute))
        }
        return nil
    }

    static func isInside(_ e: AXUIElement, _ root: AXUIElement) -> Bool {
        var p: AXUIElement? = e; var hops = 0
        while let x = p, hops < 25 { if x.isSame(root) { return true }; p = x.element(kAXParentAttribute); hops += 1 }
        return false
    }
}
