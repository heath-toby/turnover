// SPDX-License-Identifier: GPL-3.0-or-later
// Tab going round a short loop (TabLoop.swift, 11 Nov 2026).
import Foundation
import TurnOverCore

func tabLoopTests() {
    test("tab loop: twice round the same few places is a loop") {
        expect(SettingsPanePlugin.shortLoop(["sidebar", "search", "sidebar", "search"]), 2, "System Settings with VoiceOver off")
        expect(SettingsPanePlugin.shortLoop(["list", "sidebar", "search", "list", "sidebar", "search"]), 3, "the Open dialog")
        expect(SettingsPanePlugin.shortLoop(["x", "list", "sidebar", "search", "list", "sidebar", "search"]), 3, "after a first landing elsewhere")
    }
    test("tab loop: going on through a window is not a loop") {
        expect(SettingsPanePlugin.shortLoop(["a", "b", "c", "d", "e", "f"]), nil, "every Tab somewhere new")
        expect(SettingsPanePlugin.shortLoop(["a", "b", "a"]), nil, "not yet twice round")
        expect(SettingsPanePlugin.shortLoop(["a", "a", "a", "a"]), nil, "Tab ignored is the trap's own case")
        expect(SettingsPanePlugin.shortLoop(["a", "b", "a", "b", "c", "d", "e"]), nil, "a loop left behind")
    }
}
