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
    test("tab trap: a place is remembered at the second miss, and forgotten when the app moves its own focus there") {
        var candidates: [String] = [], zones: [String] = []
        let same: (String, String) -> Bool = { $0 == $1 }
        expect(SettingsPanePlugin.noteTabOutcome("bar", missed: true, candidates: &candidates, zones: &zones, same: same), false, "one slow answer from a busy app is no proof")
        expect(zones, [], "nothing remembered after one miss")
        _ = SettingsPanePlugin.noteTabOutcome("bar", missed: false, candidates: &candidates, zones: &zones, same: same)
        expect(SettingsPanePlugin.noteTabOutcome("bar", missed: true, candidates: &candidates, zones: &zones, same: same), false, "a success between starts the count again")
        expect(SettingsPanePlugin.noteTabOutcome("bar", missed: true, candidates: &candidates, zones: &zones, same: same), true, "the second miss in a row remembers it")
        expect(zones, ["bar"], "remembered once")
        expect(candidates, [], "no longer a candidate")
        _ = SettingsPanePlugin.noteTabOutcome("bar", missed: false, candidates: &candidates, zones: &zones, same: same)
        expect(zones, [], "the app moved its own focus there: forgotten")
    }
    test("tab trap: the window's list is reused only while it keeps its shape") {
        expect(SettingsPanePlugin.listStillGood(age: 2, structureNewsSince: true, shapeChanged: false), true, "a few seconds old")
        expect(SettingsPanePlugin.listStillGood(age: 30, structureNewsSince: false, shapeChanged: false), true, "quiet app, under a minute")
        expect(SettingsPanePlugin.listStillGood(age: 30, structureNewsSince: true, shapeChanged: false), false, "the app said its controls changed")
        expect(SettingsPanePlugin.listStillGood(age: 2, structureNewsSince: false, shapeChanged: true), false, "the window's children or the landing moved")
        expect(SettingsPanePlugin.listStillGood(age: 61, structureNewsSince: false, shapeChanged: false), false, "a minute at most")
    }
    test("tab trap: please wait only for an app just launched or with no window") {
        expect(SettingsPanePlugin.saysPleaseWait(launchedAgo: 2, hasWindow: true), true, "launched a moment ago")
        expect(SettingsPanePlugin.saysPleaseWait(launchedAgo: 600, hasWindow: false), true, "no window at all")
        expect(SettingsPanePlugin.saysPleaseWait(launchedAgo: 600, hasWindow: true), false, "a window with no controls (an image viewer)")
        expect(SettingsPanePlugin.saysPleaseWait(launchedAgo: nil, hasWindow: true), false, "no launch date")
    }
    test("tab loop: only sheets and dialogs are remembered by kind, not document windows") {
        expect(SettingsPanePlugin.loopKindApplies(role: "AXSheet", subrole: nil), true, "a Save sheet")
        expect(SettingsPanePlugin.loopKindApplies(role: "AXWindow", subrole: "AXDialog"), true, "a dialog")
        expect(SettingsPanePlugin.loopKindApplies(role: "AXWindow", subrole: "AXStandardWindow"), false, "an Untitled document")
    }
    test("review cursor: only a bounce with no key since, in the same app and window, is ignored") {
        let t0 = Date(timeIntervalSince1970: 1000)
        func b(_ after: TimeInterval, key: TimeInterval = -0.1, pid: Bool = true, window: Bool = true) -> Bool {
            ObjectNavigator.isBounce(since: t0, limit: 1.5, lastKeyAt: t0.addingTimeInterval(key), now: t0.addingTimeInterval(after), samePid: pid, sameWindow: window)
        }
        expect(b(0.2), true, "Safari handing the focus back to its page")
        expect(b(0.2, key: 0.1), false, "a Tab pressed since")
        expect(b(0.2, pid: false), false, "Command Tab to another app")
        expect(b(0.2, window: false), false, "another window")
        expect(b(2), false, "too long after")
    }
    test("speech: the same focus words again are said when the last were cut off") {
        expect(Speech.repeatsFocus("OK, button", last: "OK, button", elapsed: 0.2, lastCut: false), true, "heard whole: not repeated")
        expect(Speech.repeatsFocus("OK, button", last: "OK, button", elapsed: 0.2, lastCut: true), false, "cancelled before the end: said again")
        expect(Speech.repeatsFocus("OK, button", last: "OK, button", elapsed: 0.6, lastCut: false), false, "half a second on")
        expect(Speech.repeatsFocus("Cancel, button", last: "OK, button", elapsed: 0.1, lastCut: false), false, "other words")
    }
    test("foreground: another window with the same title is news; the same window again is not") {
        expect(AXHandler.sameForeground(title: "Untitled", lastTitle: "Untitled", sameWindow: true, appName: nil), true, "the same window")
        expect(AXHandler.sameForeground(title: "Untitled", lastTitle: "Untitled", sameWindow: false, appName: nil), false, "a second Untitled window")
        expect(AXHandler.sameForeground(title: "Untitled", lastTitle: "Untitled", sameWindow: true, appName: "TextEdit"), false, "an app switch is always said")
        expect(AXHandler.sameForeground(title: "Notes", lastTitle: "Untitled", sameWindow: true, appName: nil), false, "retitled")
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
    test("tab loop: landings skipped by fast Tabs look like a short loop, so a skip starts the count again") {
        // Every third landing of a round of six, read only when no newer Tab came (watchTabLoop): a false loop of two.
        let round = ["a", "b", "c", "d", "e", "f"]
        let sampled = (0..<12).filter { $0 % 3 == 0 }.map { round[$0 % 6] }
        expect(SettingsPanePlugin.shortLoop(sampled), 2, "why watchTabLoop forgets its landings when it skips one")
    }
    test("system prompts: an agent that keeps failing rests before it is asked again") {
        expect(SystemPrompts.rest(afterFailures: 1), 0, "one slow answer is no hang")
        expect(SystemPrompts.rest(afterFailures: 2), 0, "nor two")
        expect(SystemPrompts.rest(afterFailures: 3), 5, "the third in a row rests it")
        check(SystemPrompts.rest(afterFailures: 4) > 0, "and it keeps resting while it fails")
    }
}
