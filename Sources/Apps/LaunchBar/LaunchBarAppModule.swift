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
// The title-change notification arrives before the new title does: read at once, the cell still had the item before
// (with VoiceOver off, 10 Nov 2026: "Safari" read when "Siri" was chosen). So the title is read a moment later, and
// once more if it hasn't changed yet.
//
// LaunchBar runs as an accessory app and never comes forward, so TurnOver watches it from the start
// (AXHandler.launcherPanels).
//
// So for LaunchBar's cell: as the bar opens and at every new name, the cell's title as it is now.
import Foundation
import ApplicationServices
import TurnOverAX

final class LaunchBarAppModule: AppModule {
    static let bundleID = "at.obdev.LaunchBar"
    /// The last title said, and when: the focus and its first name change arrive together with the same title.
    private var lastSaid: (title: String, at: Date)?
    /// Each name change's read; a newer one makes an older one's pending read moot.
    private var generation = 0

    override func handleEvent(_ event: Event, next: () -> Void) {
        guard event.obj.pid == pid, event.obj.axRole == "AXCell", event.kind == .gainFocus || event.kind == .nameChange else {
            next(); return
        }
        let cell = event.obj.element
        if event.kind == .gainFocus { say(cell, opened: true); return }
        generation += 1
        let g = generation
        // The new title a moment after the news; if it is still the one last said, once more a little later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, g == self.generation else { return }
            if self.say(cell, opened: false) { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, g == self.generation else { return }
                self.say(cell, opened: false)
            }
        }
    }

    /// Says the cell's title if it is new; false if there was nothing new to say.
    @discardableResult
    private func say(_ cell: AXUIElement, opened: Bool) -> Bool {
        guard API.focusObject?.element.isSame(cell) == true || opened else { return false }
        let title = cell.string(kAXTitleAttribute)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return false }
        if let last = lastSaid, last.title == title, opened ? Date().timeIntervalSince(last.at) < 0.5 : true { return false }
        lastSaid = (title, Date())
        TurnOverObject.lastName = (cell, title)
        Log.io("launchbar: \(opened ? "opened" : "new item"), \(title.count) characters")
        Speech.cancel()
        Speech.speakMessage(title)
        return true
    }
}
