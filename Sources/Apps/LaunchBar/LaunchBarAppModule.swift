// SPDX-License-Identifier: GPL-3.0-or-later
// LaunchBar (Objective Development, 6.24; observed 10 Nov 2026 on macOS 27.2 with a script and TurnOver's log).
//
// LaunchBar's bar is a window (AXUnknown, subrole AXSystemDialog) holding one AXCell, and that cell keeps the focus
// the whole time. Typing, the arrows, Right and Left into and out of an item, and Control Tab change which item is
// chosen by renaming the cell ("Mail, Application", then "Safari, Application, contains 6 items"), each with an
// AXTitleChanged, and an AXSelectedRowsChanged on a table the window doesn't list as a child. VoiceOver reads the
// new name. TurnOver heard the name changes but compared them with the name it had kept from the focus, the same
// each time, and said nothing; nor was the focus itself said as the bar opened (a tester, 10 Nov 2026).
//
// So for LaunchBar's cell: as the bar opens and at every new name, the cell's title as it is now.
import Foundation
import ApplicationServices
import TurnOverAX

final class LaunchBarAppModule: AppModule {
    static let bundleID = "at.obdev.LaunchBar"
    /// The last title said, and when: the focus and its first name change arrive together with the same title.
    private var lastSaid: (title: String, at: Date)?

    override func handleEvent(_ event: Event, next: () -> Void) {
        guard event.obj.pid == pid, event.obj.axRole == "AXCell", event.kind == .gainFocus || event.kind == .nameChange else {
            next(); return
        }
        let title = event.obj.element.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { next(); return }
        if let last = lastSaid, last.title == title, Date().timeIntervalSince(last.at) < 0.5 { return }
        lastSaid = (title, Date())
        TurnOverObject.lastName = (event.obj.element, title)
        Log.io("launchbar: \(event.kind == .gainFocus ? "opened" : "new item"), \(title.count) characters")
        Speech.cancel()
        Speech.speakMessage(title)
    }
}
