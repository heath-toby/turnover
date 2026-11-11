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
            let words = text(of: sheet)
            Log.io("dialogs: a sheet opened with the focus outside it (\(words.count) characters of text); onto its \(target.role)")
            if !words.isEmpty { Speech.speakMessage(words) }
            land(on: target, interrupt: words.isEmpty)
        }
    }

    /// A window was created in the app in front; a moment later, one holding a progress bar is read and its bar followed,
    /// and a small one that took the focus with no control inside it focused is entered.
    static func windowAppeared(_ window: AXUIElement, pid: pid_t) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
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
                let controls = SettingsPanePlugin.controlsInOrder(in: window).filter { ($0.attr(kAXEnabledAttribute) as? Bool) != false }
                guard bar != nil || (1...6).contains(controls.count) else { return }
                guard let target = bar ?? landing(in: window) else { return }
                let words = text(of: window)
                Log.io("dialogs: a window took the focus with nothing in it focused (\(words.count) characters); onto its \(target.role)")
                if !words.isEmpty { Speech.speakMessage(words) }
                land(on: target, interrupt: false)
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
    static func land(on e: AXUIElement, interrupt: Bool) {
        _ = e.set(kAXFocusedAttribute, kCFBooleanTrue)
        let pid = e.pid
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let real = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute)
            if let real, real.isSame(e) { return }   // the app took it: its own focus news says it
            // ownTab false: the settings panes' Tab would go round the window behind the sheet (a review, 11 Nov 2026).
            SettingsPanePlugin.holdVirtual(e, speak: interrupt, ownTab: false)
            if !interrupt { Speech.speakObject(ObjectFactory.make(e), reason: .focus) }
            ObjectNavigator.shared.releaseHold()
            ObjectNavigator.shared.place(e)
        }
    }

    /// Where a dialog opens: its default button, else its Done, OK, Close or Cancel, else its first control. Never a
    /// first control like Bluetooth's "Forget This Device…", which Space would press, when a safe one is there.
    static func landing(in root: AXUIElement) -> AXUIElement? {
        if let d = root.element(kAXDefaultButtonAttribute) { return d }
        let controls = SettingsPanePlugin.controlsInOrder(in: root).filter { ($0.attr(kAXEnabledAttribute) as? Bool) != false }
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
