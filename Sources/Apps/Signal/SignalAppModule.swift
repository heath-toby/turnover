// SPDX-License-Identifier: GPL-3.0-or-later
// Signal Desktop (14 Nov 2026): read by TurnOver's general web navigation like any Electron app; this module adds only
// the announcements of the tester's VoiceOver Signal Filter (SignalFilter.swift): message sent, message received,
// typing and stopped typing. No keys of its own.
import Foundation

package final class SignalAppModule: AppModule {
    package static var bundleIDs: [String] { SignalDOMMarkers.bundles.sorted() }

    private let filter: SignalFilter

    package required init(pid: pid_t, bundleIdentifier: String, appName: String) {
        filter = SignalFilter(pid: pid)
        super.init(pid: pid, bundleIdentifier: bundleIdentifier, appName: appName)
    }

    /// Started the first time Signal comes to the front (not in init: a module made in a race is thrown away without
    /// terminate), then kept until Signal quits or TurnOver stops, so a message received with Signal behind is said,
    /// as the filter did.
    package override func event_appModuleGainFocus() { filter.start() }

    package override func terminate() { filter.stop() }

    /// Signal's own live regions say what the filter already says (a message, someone typing), so they are left
    /// unspoken here, as the tester's filter does for VoiceOver (14 Nov 2026). Everything else goes on as usual.
    package override func handleEvent(_ event: Event, next: () -> Void) {
        if event.kind == .liveRegionChange { return }
        next()
    }
}
