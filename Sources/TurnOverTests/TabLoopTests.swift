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
    test("toolbar: an item is in the strip by its middle, and no taller than it") {
        let strip = CGRect(x: 244, y: 59, width: 1024, height: 52)
        expect(SettingsPanePlugin.inStrip(CGRect(x: 520, y: 59, width: 40, height: 52), of: strip), true, "Messages' filter button")
        expect(SettingsPanePlugin.inStrip(CGRect(x: 857, y: 103, width: 118, height: 41), of: strip), false, "the title button under the toolbar")
        expect(SettingsPanePlugin.inStrip(CGRect(x: 244, y: 59, width: 320, height: 768), of: strip), false, "a sidebar running up under it")
    }
    test("grid: five or more rows of five or more, every row as long, in perspective too") {
        var board: [CGRect] = []
        for r in 0..<8 { for c in 0..<8 { let w = CGFloat(46 + r * 2); board.append(CGRect(x: 200 + CGFloat(c) * w, y: 270 + CGFloat(r) * 60, width: w, height: 40 + CGFloat(r) * 2)) } }
        expect(SettingsPanePlugin.gridColumns(of: board), 8, "Chess's board")
        var keys: [CGRect] = []
        for r in 0..<5 { for c in 0..<4 { keys.append(CGRect(x: CGFloat(c) * 60, y: CGFloat(r) * 50, width: 56, height: 46)) } }
        expect(SettingsPanePlugin.gridColumns(of: keys), 0, "Calculator's keys stay keys")
        expect(SettingsPanePlugin.gridColumns(of: Array(board.dropLast())), 0, "a row short is no grid")
    }
}
