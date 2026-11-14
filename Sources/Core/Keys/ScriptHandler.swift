// SPDX-License-Identifier: GPL-3.0-or-later
// Script resolution and execution (NVDA: scriptHandler).
//
// A gesture is offered, in order, to: the global plugins, the focused app's
// module, the focused object, its ancestors (scripts marked canPropagate), and
// the global commands. Resolution runs on the keyboard thread with no
// accessibility calls, so the tap can answer in microseconds. Execution runs
// on the main thread, one script at a time; a script that is still waiting
// for the caret gives way when another gesture arrives.
import Foundation
import AppKit
import TurnOverAX

public enum ScriptHandler {
    private static let lock = NSLock()
    private static var queued: [(Script, KeyboardGesture, Bool)] = []
    private static var _running = false
    private static var lastScript: Script?
    private static var lastScriptTime = Date.distantPast
    private static var lastScriptCount = 0
    /// Commands run from TurnOver-key chords (TO or VO with a key): such a key is the reader's, never the app's. A
    /// mode that ends when the user goes back to the app's own keys tells the two apart by it (DesktopNavigator: a
    /// TO command in between ended desktop mode, and the arrows, Return and Space then went to Finder's desktop; a
    /// review, 13 Nov 2026). Main thread.
    public private(set) static var turnOverScriptsRun = 0

    /// Find the script for a gesture (NVDA: findScript). Any thread.
    public static func findScript(for gesture: KeyboardGesture, styleTable: Bool = true) -> Script? {
        // The user's own keys first (the keyboard commands editor): a key given to a command or an app, or taken away.
        switch UserGestures.lookup(gesture) {
        case .script(let s)?: return s
        case .removed?: return nil
        case nil: break
        }
        // The style's own table (Narrator and JAWS keys over TurnOver's commands), before the built-in keys.
        if styleTable, let s = StyleKeymap.script(for: gesture) { return s }
        for p in GlobalPluginHandler.shared.plugins { if let s = p.script(for: gesture) { return s } }
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(for: gesture) { return s }
        if let d = API.focusTreeInterceptor, let s = d.script(for: gesture) { return s }
        if let focus = API.focusObject {
            if let s = focus.script(for: gesture) { return s }
            for a in API.focusAncestors { if let s = a.script(for: gesture), s.canPropagate { return s } }
        }
        return GlobalCommands.shared.script(for: gesture)
    }

    /// How the keyboard thread asks (8 Oct 2026, from the team review; redone for Swift 6, 10 Oct 2026). The
    /// decision is made on the main thread, where the object model lives, and the keyboard thread waits for it, up
    /// to `lookupLimit`. A late answer is not thrown away: the key is swallowed now, and when the main thread gets
    /// to it, its script runs or the key is sent on to the application (re-posted, marked). Only a main thread that
    /// has stopped beating altogether lets keys straight through, as the watchdog would have it. (Before, the
    /// lookup ran on its own queue and read the object model while the main thread changed it.)
    public enum Lookup {
        case found(Script)
        case none
        /// The question was not answered in time: the key goes to the application, or a chord is dropped.
        case timedOut
        public var script: Script? { if case .found(let s) = self { return s } else { return nil } }
    }
    /// The main thread's own lookup (tests, the probe, chords already on the main thread).
    public static func lookup(_ gesture: KeyboardGesture) -> Lookup { findScript(for: gesture).map { .found($0) } ?? .none }

    /// The longest the keyboard thread waits for the main thread. Normal answers take microseconds.
    nonisolated(unsafe) public static var lookupLimit: TimeInterval = 0.15
    /// Whether the main thread has stopped beating (the app's watchdog says): then keys pass straight through.
    nonisolated(unsafe) public static var mainStuck: (@Sendable () -> Bool)?

    public enum KeyDecision: Equatable { case taken, passed, deferred }
    private enum Wait { case waiting, answered(Bool), timedOut }

    /// Whether TurnOver has a script for a gesture, asked of the main thread (the Windows style translates a key
    /// only when TurnOver has nothing of its own for it). nil: the main thread did not answer in time.
    nonisolated public static func mainHasScript(for gesture: KeyboardGesture) -> Bool? {
        guard !(mainStuck?() ?? false) else { return nil }
        let answer = Locked<Bool?>(nil); let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { MainActor.assumeIsolated { answer.value = findScript(for: gesture) != nil; done.signal() } }
        _ = done.wait(timeout: .now() + lookupLimit)
        return answer.value
    }

    /// The main thread handles the key down (InputManager.handleKeyDown) while the keyboard thread waits.
    /// Keys that have reached the tap, counted on the keyboard thread: a script waiting on the application (for the
    /// caret) gives way when the count moves, even while the main thread is too busy to look the new key up.
    nonisolated private static let keysArrived = Locked(0)
    nonisolated public static var keysArrivedCount: Int { keysArrived.value }
    /// Keys deferred (main did not answer within `lookupLimit`) whose turn on main has not finished yet.
    nonisolated private static let outstandingLate = Locked(0)

    nonisolated public static func askMain(_ gesture: KeyboardGesture) -> KeyDecision { askMain(gesture, otherwise: nil).decision }

    /// As askMain, with the Windows style's translation in the same round trip: when TurnOver has no script for
    /// `gesture`, main handles `alternative` (the Mac key it becomes) instead. It asked main twice in turn, once
    /// whether there was a script and once to handle the key, and each wait is a main-thread turn the user hears
    /// (a review, 13 Nov 2026). `usedAlternative`: main handled the alternative (only known when it answered in
    /// time; a late answer sends on whichever it chose).
    nonisolated public static func askMain(_ gesture: KeyboardGesture, otherwise alternative: KeyboardGesture?) -> (decision: KeyDecision, usedAlternative: Bool) {
        keysArrived.lock.lock(); keysArrived.unsafeValue &+= 1; keysArrived.lock.unlock()
        guard !(mainStuck?() ?? false) else { Log.warning("keyboard: the main thread is not beating; \(gesture.logDescription()) goes through"); return (.passed, false) }
        InputManager.cancelSpeechEarly(for: gesture)
        let state = Locked(Wait.waiting); let done = DispatchSemaphore(value: 0)
        let usedAlternative = Locked(false)
        let started = DispatchTime.now()
        // A key behind a late one waits its turn: while main still owes an earlier key (it re-posts it when it gets
        // there), this one is deferred at once, and main, taking its blocks in order, sends both in the order typed.
        // Answered in time, "b" went on to the app while main still owed it "a", and the app got "b a" (a review,
        // 13 Nov 2026).
        let behindLate: Bool = {
            outstandingLate.lock.lock(); defer { outstandingLate.lock.unlock() }
            guard outstandingLate.unsafeValue > 0 else { return false }
            outstandingLate.unsafeValue += 1
            return true
        }()
        if behindLate { state.value = .timedOut }
        DispatchQueue.main.async { MainActor.assumeIsolated {
            // TurnOver's focus still another ordinary app's, behind the one in front: read the front app's first, so the
            // key isn't looked up among the app behind's commands (Weather launched from Finder: Tab ran Finder's, a
            // sweep, 13 Nov 2026). Cheap unless it is so.
            AXHandler.shared.focusBehindFrontApp()
            var handled = gesture
            // Each key is looked up once, and what was found handed on: availability checks talk to the application,
            // and the Windows style's leftToApp scans its menus, up to three times a key (a review, 13 Nov 2026).
            // nil: handleKeyDown looks `handled` up itself.
            var resolved: Script?? = nil
            // Never in a terminal, whatever app it is in: Control C is the shell's there, as GlobalCommands.leftToApp
            // has it. WindowsRemap.keepControl knows terminal apps only by name, and VS Code's terminal, Ghostty,
            // Alacritty and WezTerm got Command C (a review, 13 Nov 2026).
            // Nor when the key itself is wanted: the keyboard commands editor capturing a key, input help naming it,
            // or pass next key sending it on untouched. The Mac key replaced the user's own there (a review, 13 Nov 2026).
            let keyItselfWanted = InputManager.isInputHelpActive
                || (InputManager.captureNext != nil || InputManager.passNextKey) && !gesture.isRepeat
            if let alternative, !keyItselfWanted, API.focusObject?.role != .terminal {
                let own = findScript(for: gesture)
                // No command for the Windows key: the Mac key it becomes. Or the same command for both (End and
                // Command Right both a text field's caret move): the Mac key too, so the app gets the key that moves
                // its caret. End went on to TextEdit as End, which only scrolls, and said nothing (a sweep, 13 Nov 2026).
                if let own {
                    let other = findScript(for: alternative)
                    if other?.name == own.name { handled = alternative; usedAlternative.value = true; resolved = .some(other) }
                    else { resolved = .some(own) }
                } else { handled = alternative; usedAlternative.value = true }
            }
            // Still another app's focus behind the one in front (the front app not answering yet as it starts): a key
            // of no TurnOver chord goes to the front app as it is, not to the app behind's commands (Finder's Tab ran
            // on its window behind Weather, 13 Nov 2026).
            if AXHandler.shared.focusIsBehindFrontApp, !handled.modifiers.contains(.turnover) {
                Log.io("key: TurnOver's focus is still an app's behind the front one; \(handled.logDescription()) goes to the front app")
                resolved = .some(nil)
                // (Tab then says why nothing is read yet, as the Tab trap does while an app comes up.)
                // (Only while the app may still be coming up, not for ever in an app that never answers: a review.)
                let launched = NSRunningApplication(processIdentifier: AXHandler.shared.activePid)?.launchDate.map { Date().timeIntervalSince($0) }
                if handled.keyName == "tab", !handled.isRepeat, SettingsPanePlugin.saysPleaseWait(launchedAgo: launched, hasWindow: false) {
                    Speech.speakMessage(String(localized: "please wait", comment: "Spoken message"), remember: false)
                }
            }
            let taken = InputManager.handleKeyDown(handled, script: resolved)
            var late = false
            state.lock.lock()
            if case .timedOut = state.unsafeValue { late = true } else { state.unsafeValue = .answered(taken) }
            state.lock.unlock()
            if late {
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                Log.warning("keyboard: \(handled.logDescription()) answered after \(Int(ms)) ms: \(taken ? "its script runs now" : "sent on to the application now")")
                if !taken { handled.send() }
                outstandingLate.lock.lock(); outstandingLate.unsafeValue -= 1; outstandingLate.lock.unlock()
            } else { done.signal() }
        } }
        if behindLate { return (.deferred, false) }
        if done.wait(timeout: .now() + lookupLimit) == .timedOut {
            state.lock.lock(); defer { state.lock.unlock() }
            if case .answered(let taken) = state.unsafeValue { return (taken ? .taken : .passed, usedAlternative.value) }
            state.unsafeValue = .timedOut
            // Counted while `state` is held: main's late branch reads `state` first, so it cannot count this key
            // down before it is counted.
            outstandingLate.lock.lock(); outstandingLate.unsafeValue += 1; outstandingLate.lock.unlock()
            return (.deferred, false)
        }
        if case .answered(let taken) = state.value { return (taken ? .taken : .passed, usedAlternative.value) }
        return (.passed, false)
    }

    /// A script by name from whatever answers here: the app module, the document, the focus and its ancestors,
    /// then the global commands. (VoiceOver's VO-U finds Word's elements list this way.)
    public static func findScript(named name: String) -> Script? {
        if let pid = API.focusPid, let s = AppModuleHandler.shared.appModule(for: pid).script(named: name) { return s }
        if let d = API.focusTreeInterceptor, !d.passThrough, let s = d.script(named: name) { return s }
        if let f = API.focusObject {
            if let s = f.script(named: name) { return s }
            for a in API.focusAncestors { if let s = a.script(named: name) { return s } }
        }
        // The global plugins' commands too (VoiceOver's and NVDA's keys live there): a key the user gave to one of them
        // ("vo_nextParagraph") found nothing and did nothing (a tester, and 19 Oct 2026).
        for p in GlobalPluginHandler.shared.plugins { if let s = p.script(named: name) { return s } }
        return GlobalCommands.shared.script(named: name)
    }

    /// Queue a script for the main thread (NVDA: queueScript). Any thread.
    public static func queueScript(_ script: Script, gesture: KeyboardGesture) {
        let wasInSayAll = SayAll.isRunning
        lock.lock(); queued.append((script, gesture, wasInSayAll)); lock.unlock()
        DispatchQueue.main.async { runQueued() }
    }

    /// True while a script runs (main thread).
    public static var isScriptRunning: Bool { _running }
    /// NVDA: isScriptWaiting — another gesture's script is queued behind the running one.
    public static var isScriptWaiting: Bool { lock.lock(); defer { lock.unlock() }; return !queued.isEmpty }

    private static func runQueued() {
        guard !_running else { return }
        while true {
            lock.lock()
            guard !queued.isEmpty else { lock.unlock(); break }
            let (script, gesture, wasInSayAll) = queued.removeFirst()
            lock.unlock()
            executeScript(script, gesture: gesture, wasInSayAll: wasInSayAll)
        }
        EventHandler.drain()
    }

    /// NVDA: executeScript, with the repeat count for "press twice".
    public static func executeScript(_ script: Script, gesture: KeyboardGesture, wasInSayAll: Bool = false) {
        BrailleInput.flushForKey()   // a word half typed on the display goes in before any command runs
        if _running, lastScript === script { gesture.send(); return }
        _running = true
        if gesture.modifiers.contains(.turnover) { turnOverScriptsRun &+= 1 }
        let now = Date()
        if now.timeIntervalSince(lastScriptTime) * 1000 <= Double(config.keyboard.multiPressTimeoutMs), lastScript === script { lastScriptCount += 1 } else { lastScriptCount = 0 }
        lastScript = script
        lastScriptTime = now
        Log.io("script \(script.name) for \(gesture.identifier)\(lastScriptCount > 0 ? " (repeat \(lastScriptCount))" : "")")
        let resume = wasInSayAll && script.resumesSayAll
        let (calls0, ms0, t0) = (AXStats.calls, AXStats.ms, DispatchTime.now().uptimeNanoseconds)
        SayAll.resuming = resume
        // NVDA's on-demand speech mode: a reporting command may speak (the time, the line, the title …).
        if Speech.mode == .onDemand, Self.speaksOnDemand(script.name) { Speech.demandedUntil = Date().addingTimeInterval(2) }
        script.handler(gesture)
        SayAll.resuming = false
        // The cost of a slow script, measured: how many questions it asked the application and how long they took.
        let took = Double(DispatchTime.now().uptimeNanoseconds &- t0) / 1e6
        if took > 100 { Log.warning(String(format: "script %@ took %.0f ms: %d accessibility calls, %.0f ms in them", script.name, took, AXStats.calls - calls0, AXStats.ms - ms0)) }
        // A key gives way to a message held on the display ("indefinitely"): browse mode's line moves change no
        // focus and no caret, and the display stayed on "nothing more" while speech read on (21 Oct 2026). A message the
        // script itself just put up stays.
        Braille.focusOrCaretMoved()
        Braille.refreshSoon()
        KeySettings.refresh()   // a script may have changed a setting the keyboard thread reads
        _running = false
        EventHandler.drain()
        if resume, let obj = API.caretObject { SayAll.readText(from: obj) }
    }

    /// NVDA: getLastScriptRepeatCount — 0 the first time, 1 for the second press within the timeout.
    public static var lastScriptRepeatCount: Int {
        Date().timeIntervalSince(lastScriptTime) * 1000 > Double(config.keyboard.multiPressTimeoutMs) ? 0 : lastScriptCount
    }

    public static func clearLastScript() { lastScript = nil; lastScriptTime = .distantPast; lastScriptCount = 0 }

    /// The commands that speak in on-demand mode: those that report something asked for, as NVDA marks its own. JAWS's
    /// reading keys too (Caps Lock U, O, J, L, M, Period): they move as the arrows do, but read as the review keys on
    /// their letters did, which spoke (the review of pull request 144, 28 Oct 2026).
    static func speaksOnDemand(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["report", "sayall", "readcontents", "speak", "describe", "datetime", "time", "title", "spell", "review",
                "navigatorobject", "where", "battery", "statusbar", "selecteditem", "readwindow", "readline", "currentline",
                "jaws_sayprior", "jaws_saynext"].contains { n.contains($0) }
    }
}
