// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's "Speak the following greeting after login" (VoiceOver Utility, General; 14 Nov 2026): the words in
// Settings, General, said once TurnOver has started at login. Empty, the default, says nothing.
//
// TurnOver started at login is told apart two ways: the launch event says so (a login item's open event carries
// keyAELaunchedAsLogInItem), or the login session itself began moments ago (loginwindow, which starts afresh for each
// login, started under two minutes before TurnOver did). The second covers a start by the Key helper or launchd,
// whose launch event says nothing. Either way, once a login session: which one was greeted is kept (UserDefaults).
import Foundation
import AppKit

public enum LoginGreeting {
    /// How soon after the session began a start still counts as at login.
    nonisolated static let window: TimeInterval = 120

    /// Whether this start is at login. Pure.
    nonisolated public static func atLogin(launchedAsLoginItem: Bool, sessionStarted: Date?, processStarted: Date) -> Bool {
        if launchedAsLoginItem { return true }
        guard let s = sessionStarted else { return false }
        let gap = processStarted.timeIntervalSince(s)
        return gap >= 0 && gap < window
    }

    /// The words to say, or nil (empty or only spaces). Pure.
    nonisolated public static func words(_ greeting: String) -> String? {
        let t = greeting.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// The login session as remembered once greeted: loginwindow's start (a new one for each login), else the Mac's
    /// boot. Pure.
    nonisolated public static func sessionKey(sessionStarted: Date?, bootedAt: Date?) -> String? {
        if let s = sessionStarted { return "login \(Int(s.timeIntervalSince1970))" }
        return bootedAt.map { "boot \(Int($0.timeIntervalSince1970))" }
    }
    /// Whether to greet: at login, and not already for this session. Pure.
    nonisolated public static func due(atLogin: Bool, session: String?, lastGreeted: String?) -> Bool {
        atLogin && (session == nil || session != lastGreeted)
    }
    nonisolated static let greetedKey = "loginGreetingSession"

    /// Says the greeting when this start is at login. Called by the app once the reader has started.
    public static func sayIfDue(launchedAsLoginItem: Bool) {
        guard let text = words(config.general.loginGreeting) else { return }
        let started = processStart(getpid()) ?? Date()
        let session = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first.flatMap { processStart($0.processIdentifier) }
        // Once a session: a restart within two minutes of login (a crash, a build, a CoExist change) greeted again
        // (a review, 14 Nov 2026).
        let key = sessionKey(sessionStarted: session, bootedAt: bootTime())
        guard due(atLogin: atLogin(launchedAsLoginItem: launchedAsLoginItem, sessionStarted: session, processStarted: started),
                  session: key, lastGreeted: UserDefaults.standard.string(forKey: greetedKey)) else { return }
        if let key { UserDefaults.standard.set(key, forKey: greetedKey) }
        Log.info("login greeting: said")
        // After the hand-over's own words.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Speech.speakMessage(text) }
    }

    /// When the Mac started, from the kernel.
    nonisolated static func bootTime() -> Date? {
        var t = timeval()
        var size = MemoryLayout<timeval>.stride
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &t, &size, nil, 0) == 0, t.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec))
    }

    /// When a process started, from the kernel.
    nonisolated static func processStart(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(t.tv_sec) + TimeInterval(t.tv_usec) / 1_000_000)
    }
}
