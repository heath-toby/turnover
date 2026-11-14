// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's "Speak the following greeting after login" (VoiceOver Utility, General; 14 Nov 2026): the words in
// Settings, General, said once TurnOver has started at login. Empty, the default, says nothing.
//
// TurnOver started at login is told apart two ways: the launch event says so (a login item's open event carries
// keyAELaunchedAsLogInItem), or the login session itself began moments ago (loginwindow, which starts afresh for each
// login, started under two minutes before TurnOver did). The second covers a start by the Key helper or launchd,
// whose launch event says nothing.
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

    /// Says the greeting when this start is at login. Called by the app once the reader has started.
    public static func sayIfDue(launchedAsLoginItem: Bool) {
        guard let text = words(config.general.loginGreeting) else { return }
        let started = processStart(getpid()) ?? Date()
        let session = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.loginwindow").first.flatMap { processStart($0.processIdentifier) }
        guard atLogin(launchedAsLoginItem: launchedAsLoginItem, sessionStarted: session, processStarted: started) else { return }
        Log.info("login greeting: said")
        // After the hand-over's own words.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Speech.speakMessage(text) }
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
