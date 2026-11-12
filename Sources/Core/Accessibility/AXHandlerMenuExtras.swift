// SPDX-License-Identifier: GPL-3.0-or-later
// Menu extras opened from outside TurnOver. An app is watched once it is active, or when TurnOver's own list of status
// menus opens one of its items; a menu extra opened any other way (a click, a Hammerspoon key, the app's own shortcut)
// belongs to an app TurnOver isn't watching, and its menu said nothing: 1Password's, opened with the MenuExt spoon,
// played the menu sound and no more (a tester, 12 Nov 2026). VoiceOver reads it.
//
// Watching an app in full sets AXEnhancedUserInterface on it (Chromium then builds its whole tree), too much for every
// app with an icon in the menu bar. So each one that has a menu extra is watched for its menus opening alone; the
// first one that opens brings the app into full watching and is handled as any menu.
import Foundation
import AppKit
import ApplicationServices

extension AXHandler {
    /// The light observers, by process (main thread).
    static var menuExtraObservers: [pid_t: AXObserver] = [:]

    func watchMenuExtras() {
        for app in NSWorkspace.shared.runningApplications { watchMenuExtra(app) }
    }

    func unwatchMenuExtras() {
        for (_, obs) in Self.menuExtraObservers { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode) }
        Self.menuExtraObservers.removeAll()
    }

    /// A new app: its menu extra comes a moment after it starts, so it is looked for twice.
    func watchMenuExtraLater(_ app: NSRunningApplication) {
        for delay in [3.0, 15.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.running, !app.isTerminated else { return }
                self.watchMenuExtra(app)
            }
        }
    }

    func forgetMenuExtra(_ pid: pid_t) {
        if let obs = Self.menuExtraObservers.removeValue(forKey: pid) {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
    }

    private func watchMenuExtra(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), Self.menuExtraObservers[pid] == nil, observers[pid] == nil, app.activationPolicy != .prohibited else { return }
        let ax = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(ax, 0.3)
        guard let bar = ax.element("AXExtrasMenuBar"), !bar.elements(kAXChildrenAttribute).isEmpty else { return }
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, element, name, refcon in
            guard let refcon else { return }
            let handler = Unmanaged<AXHandler>.fromOpaque(refcon).takeUnretainedValue()
            // On the main run loop (the source is added there).
            MainActor.assumeIsolated { handler.menuExtraOpened(element, name: name as String) }
        }, &obs) == .success, let obs else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(obs, ax, kAXMenuOpenedNotification as CFString, refcon) == .success else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        Self.menuExtraObservers[pid] = obs
        Log.info("menu extras: watching \(app.bundleIdentifier ?? "pid \(pid)") for its menu opening")
    }

    private func menuExtraOpened(_ element: AXUIElement, name: String) {
        let pid = element.pid
        // Watched in full by now (it came to the front, or TurnOver opened the menu): that observer has it.
        guard running, observers[pid] == nil else { return }
        Log.io("menu extras: a menu of pid \(pid) opened, from outside TurnOver; watched in full from now")
        forgetMenuExtra(pid)
        observe(pid)
        notification(name, element, nil)
    }
}
