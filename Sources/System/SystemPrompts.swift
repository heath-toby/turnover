// SPDX-License-Identifier: GPL-3.0-or-later
// The system's own prompts over an application: Touch ID ("Safari is trying to use AutoFill"), and the password
// prompt for an administrator. They are drawn by agents (coreautha, SecurityAgent) that never become the active
// application, so TurnOver never looked at them and they went unspoken (3 Oct 2026; VoiceOver reads them).
// While TurnOver leads, a prompt's text is read when it appears and the focus goes into it (its buttons, its
// password field); when it goes, the focus goes back to the application. With CoExist, a prompt is VoiceOver's:
// TurnOver steps aside while it is open (onPromptChange) and comes back after.
import Foundation
import AppKit
import ApplicationServices

public final class SystemPrompts {
    public static let shared = SystemPrompts()
    /// The agents that draw the system's own prompts. UserNotificationCenter ("would like access to record your system
    /// audio") and CoreLocationAgent ("would like to use your current location") were not watched, so a prompt that
    /// came up behind Claude was never said (12 Oct 2026: VoiceOver says there is a system request).
    static let agents = ["com.apple.LocalAuthentication.UIAgent", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                         "com.apple.CoreLocationAgent", "com.apple.coreservices.uiagent"]

    /// Prompts macOS protects: an Accessibility press from TurnOver is refused (CoreLocationAgent put its focus back on
    /// "Don't Allow" and drew the prompt again, twice, 12 Oct 2026); the user's own keys always work.
    public static func isProtected(_ pid: pid_t) -> Bool {
        guard let b = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return agents.contains(b)
    }

    /// After TurnOver pressed a button in a protected prompt: if the prompt is still there a moment later, macOS
    /// refused the press. The focus goes back onto the button and the user is asked for a real Space, which macOS takes.
    public static func checkPress(of button: AXUIElement, name: String) {
        guard isProtected(button.pid), let window = button.element(kAXWindowAttribute) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            let r = window.role
            guard !r.isEmpty, r != "?" else { Log.io("protected prompt: the press of \(Log.words(name)) was taken"); return }
            _ = button.set(kAXFocusedAttribute, kCFBooleanTrue)
            Log.io("protected prompt: macOS refused TurnOver's press of \(Log.words(name)); focus put back on it, Space asked for")
            Speech.speakMessage(String(localized: "macOS only takes a real key here. \(name) has the focus: press Space.", comment: "A protected macOS prompt: %@ is the button"))
        }
    }
    private var timer: Timer?
    private var shown: [AXUIElement] = []
    private var missedOnce: [AXUIElement] = []
    /// Window queries failed in a row, per agent: its prompts are kept through four, then taken as gone, so one that
    /// never answers again can't keep TurnOver stepped aside for good (a review, 11 Nov 2026).
    private var failures: [pid_t: Int] = [:]
    /// With VoiceOver running (CoExist), macOS's own prompts are VoiceOver's entirely (18 Oct 2026: VoiceOver
    /// "could take over in higher security dialogues, which keeps TurnOver more secure"): TurnOver neither reads them
    /// nor takes their keys. The app is told when the first opens (true) and the last closes (false), and steps aside.
    public var onPromptChange: ((Bool) -> Void)?
    public var handsToVoiceOver: Bool { Coexist.on && NSWorkspace.shared.isVoiceOverEnabled && onPromptChange != nil }
    /// What each prompt said first, for the reminder and the application chooser.
    private var summaries: [(window: AXUIElement, pid: pid_t, text: String)] = []

    /// The prompts open now, with their first line: a prompt read once while the user was away stayed open with
    /// nothing pointing to it (Command Tab and the application chooser left it out; the keychain's password prompt
    /// at build 18's publish, 14 Oct 2026, was found only by turning VoiceOver on).
    public var waiting: [(window: AXUIElement, pid: pid_t, text: String)] {
        summaries.filter { p in shown.contains { $0.isSame(p.window) } && p.window.role != "?" && !p.window.role.isEmpty }
    }
    private var lastReminder = Date.distantPast
    /// The application in front when a prompt was given the keyboard: it comes back when the prompts close.
    private var returnTo: NSRunningApplication?

    /// Another application came to the front while a prompt waits: say so, after the application, with the way to it.
    public func remindIfWaiting(activated pid: pid_t) {
        guard let p = waiting.first, p.pid != pid, Date().timeIntervalSince(lastReminder) > 5 else { return }
        lastReminder = Date()
        let key = config.general.windowsKeys ? String(localized: "Option Tab", comment: "Keys to reach a waiting system dialog") : String(localized: "VO-F1 twice", comment: "Keys to reach a waiting system dialog")
        Log.io("system prompt still open (pid \(p.pid)); reminded")
        Speech.speakMessage(String(localized: "system dialog waiting: \(p.text). \(key) to go to it", comment: "A system dialog waiting: its words, then the keys to reach it"))
    }

    func start() {
        // The agents start when first needed and may go again: look twice a second (a list of running
        // applications and, for an agent that is running, its windows: cheap).
        timer?.invalidate()   // (one timer, however many hand-overs: they piled up, 8 Oct 2026)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    }

    private func check() {
        var windows: [(AXUIElement, pid_t)] = []
        for bundle in Self.agents {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                let pid = app.processIdentifier
                AXHandler.shared.observe(pid)
                let ax = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(ax, 0.5)
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success {
                    failures[pid] = nil
                    windows += ((value as? [AXUIElement]) ?? []).map { ($0, pid) }
                } else {
                    failures[pid, default: 0] += 1
                    // An agent too busy to answer (a timeout) still has its prompts: taken as gone, every waiting
                    // prompt was read out again, over what was being said, with the focus thrown back to the app
                    // (11 Nov 2026: four of them, each time a window opened). Up to four looks in a row.
                    if failures[pid, default: 0] <= 4 { windows += shown.filter { $0.pid == pid }.map { ($0, pid) } }
                }
            }
        }
        // Gone only when missed twice running: an agent's list can come back empty for a moment, and the prompts were
        // taken as closed, the app refocused, and each read out again (11 Nov 2026).
        let missing = shown.filter { w in !windows.contains { $0.0.isSame(w) } }
        let goneNow = missing.filter { w in missedOnce.contains { $0.isSame(w) } }
        missedOnce = missing.filter { w in !goneNow.contains { $0.isSame(w) } }
        windows += missedOnce.map { ($0, $0.pid) }
        let gone = !goneNow.isEmpty
        shown.removeAll { w in goneNow.contains { $0.isSame(w) } }
        summaries.removeAll { p in !shown.contains { $0.isSame(p.window) } }
        if gone, shown.isEmpty, let front = NSWorkspace.shared.frontmostApplication {
            if handsToVoiceOver { onPromptChange?(false) }
            // The agent TurnOver brought forward for the prompt stays the active application when its window goes:
            // "focus back to CoreLocationAgent", a window gone and nothing to read until Command Tab (a tester, after
            // allowing News the location, 12 Nov 2026). The application that was in front before comes back.
            // Nothing kept when the prompt already had the keys as TurnOver started (a restart while News asked for
            // the location: "focus back to CoreLocationAgent" again, 13 Nov 2026): the application whose window is
            // frontmost behind it.
            if let b = front.bundleIdentifier, Self.agents.contains(b),
               let back = (returnTo.flatMap { $0.isTerminated ? nil : $0 }) ?? Self.appBehind() {
                Log.io("system prompt closed; focus back to \(back.localizedName ?? "?"), in front before it")
                back.activate()
                let pid = back.processIdentifier
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AXHandler.shared.refocus(pid: pid) }
            } else {
                Log.io("system prompt closed; focus back to \(front.localizedName ?? "?")")
                AXHandler.shared.refocus(pid: front.processIdentifier)
            }
            returnTo = nil
        }
        for (w, pid) in windows where !shown.contains(where: { $0.isSame(w) }) {
            let first = shown.isEmpty
            shown.append(w)
            if handsToVoiceOver {
                // VoiceOver's: the prompt is given the keyboard (its window can open without it) and TurnOver steps aside.
                Log.io("system prompt from pid \(pid): VoiceOver's")
                if first { onPromptChange?(true) }
                if let f = AXUIElementCreateApplication(pid).element(kAXFocusedUIElementAttribute) { giveKeyboard(to: f) }
                continue
            }
            announce(w, pid: pid, fromTimer: true)
        }
    }

    /// The ordinary application with the frontmost window on screen, the prompts' agents left out.
    static func appBehind() -> NSRunningApplication? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != getpid(),
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                  !agents.contains(app.bundleIdentifier ?? "") else { continue }
            return app
        }
        return nil
    }

    /// The agent came to the front: read its window now (the regular look comes every half second, after the focus
    /// had already been read).
    func announceFront(pid: pid_t) {
        if handsToVoiceOver { return }
        let ax = AXUIElementCreateApplication(pid)
        guard let w = ax.element(kAXFocusedWindowAttribute) ?? ax.elements(kAXWindowsAttribute).first else { return }
        if shown.contains(where: { $0.isSame(w) }), Date().timeIntervalSince(lastAnnounced) < 2 { return }
        if !shown.contains(where: { $0.isSame(w) }) { shown.append(w) }
        announce(w, pid: pid)
    }
    private var lastAnnounced = Date.distantPast
    private var readAt: [String: Date] = [:]

    /// `fromTimer`: found by the regular look, where the same prompt in a new window isn't read again; asked for
    /// (the agent came to the front, the user went to it), it always is (a review, 11 Nov 2026).
    private func announce(_ window: AXUIElement, pid: pid_t, fromTimer: Bool = false) {
        lastAnnounced = Date()
        var texts: [String] = []
        var stack = [window]; var visited = 0
        while let e = stack.popLast(), visited < 200 {
            visited += 1
            if e.role == "AXStaticText", let v = e.string(kAXValueAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty { texts.append(v) }
            stack.append(contentsOf: e.elements(kAXChildrenAttribute).reversed())
        }
        guard !texts.isEmpty || window.element(kAXFocusedUIElementAttribute) != nil else { return }
        summaries.removeAll { $0.window.isSame(window) }
        summaries.append((window, pid, texts.first.map { String($0.prefix(120)) } ?? "untitled"))
        // The same prompt again from the same agent, a new window for it: not read out, nor given the keyboard, again.
        let key = "\(pid)|" + texts.joined(separator: "|")
        if fromTimer, let at = readAt[key], Date().timeIntervalSince(at) < 120 { Log.io("system prompt from pid \(pid) again, the same; not read again"); return }
        readAt[key] = Date()
        if readAt.count > 50 { readAt = readAt.filter { Date().timeIntervalSince($0.value) < 120 } }
        Log.io("system prompt from pid \(pid): \(texts.count) lines")
        Speech.cancel()
        let words = ([Self.isProtected(pid) ? String(localized: "system dialog", comment: "A role: a macOS system dialog") : Role.dialog.displayString] + texts).joined(separator: ", ")
        Speech.speakMessage(words)
        // Read: the agent coming forward enters the window as a dialog, and it isn't read again ("system dialog, Crash
        // Test quit unexpectedly…", then "alert, Crash Test quit unexpectedly…", 12 Nov 2026). Its words outlast the
        // focus settling on a button.
        Dialog.spokenAt = (window, Date())
        Speech.noteContext(words)
        let ax = AXUIElementCreateApplication(pid)
        // A prompt with nothing focused in it (the "quit unexpectedly" report: Ignore, Report, Reopen, and no focus at
        // all, 12 Nov 2026) left TurnOver's focus in the app behind it, and Tab moved Finder's sidebar under the
        // report. Its default button, or its first, takes the focus.
        let named = window.elements(kAXChildrenAttribute).first { $0.role == "AXButton" && !($0.string(kAXTitleAttribute) ?? "").isEmpty }
        if let f = ax.element(kAXFocusedUIElementAttribute) ?? window.element(kAXDefaultButtonAttribute) ?? named {
            giveKeyboard(to: f)
            AXHandler.shared.focusChanged(f, pid: pid)
        }
        // After the button's own hint: what to do with the prompt as a whole.
        let all = texts.joined(separator: " ").lowercased()
        DispatchQueue.main.async {
            Hints.schedule(all.contains("touch id") ? String(localized: "Touch the Touch ID sensor, or Tab to Enter Password or Cancel.", comment: "A hint in a system dialog")
                           : Self.isProtected(pid) ? String(localized: "Tab moves between the choices; Space presses the one you are on.", comment: "A hint in a system dialog") : String(localized: "Tab moves between the choices; Return presses.", comment: "A hint in a system dialog"))
        }
    }

    /// Make a prompt's control really have the keyboard, not only TurnOver's attention: the agent's window can open
    /// without becoming the key window, and typing then goes to the application behind it (5 Oct 2026). Bring the
    /// agent forward, raise its window and focus the control.
    public func giveKeyboard(to control: AXUIElement) {
        let pid = control.pid
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid, !Self.agents.contains(front.bundleIdentifier ?? "") { returnTo = front }
        NSRunningApplication(processIdentifier: pid)?.activate()
        let app = AXUIElementCreateApplication(pid)
        _ = app.set(kAXFrontmostAttribute, kCFBooleanTrue)
        if let w = control.element(kAXWindowAttribute) {
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            _ = w.set(kAXMainAttribute, kCFBooleanTrue)
        }
        _ = control.set(kAXFocusedAttribute, kCFBooleanTrue)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            Log.io("system prompt: keyboard \(front == pid ? "is with the prompt" : "still with pid \(front ?? -1)")")
        }
    }
}
