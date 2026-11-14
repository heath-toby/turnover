// SPDX-License-Identifier: GPL-3.0-or-later
// The mouse settings (14 Nov 2026): NVDA's audio coordinates, the text units under the pointer, and the settings file.
import Foundation
import CoreGraphics
import TurnOverCore

func mouseTests() {
    test("mouse: audio coordinates are NVDA's: 220 Hz at the bottom to 880 Hz at the top, 85 shared left to right") {
        let d = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let top = MouseMath.audioCoordinates(CGPoint(x: 0, y: 0), desktop: d)
        expect(top.frequency, 880, "the top left: the highest pitch")
        expect(top.left, 85, "all on the left")
        expect(top.right, 0)
        let bottom = MouseMath.audioCoordinates(CGPoint(x: 1000, y: 800), desktop: d)
        expect(bottom.frequency, 220, "the bottom right: the lowest pitch")
        expect(bottom.right, 85, "all on the right")
        let middle = MouseMath.audioCoordinates(CGPoint(x: 500, y: 400), desktop: d)
        expect(middle.frequency, 550, "half way up: half way between, as NVDA's linear scale")
        expect(middle.left, 42.5); expect(middle.right, 42.5)
        // A second display above the first: the desktop is the two together.
        let two = CGRect(x: 0, y: -800, width: 1000, height: 1600)
        expect(MouseMath.audioCoordinates(CGPoint(x: 500, y: -800), desktop: two).frequency, 880, "the top of the upper display")
        expect(MouseMath.audioCoordinates(CGPoint(x: 500, y: 2000), desktop: two).frequency, 220, "off the desktop: held at its edge")
    }
    test("mouse: NVDA's left and right volumes become TurnOver's volume and pan") {
        let centre = MouseMath.volumeAndPan(left: 42.5, right: 42.5)
        expect(centre.pan, 0, "the middle: both speakers")
        expect((centre.volume * 1000).rounded(), 179, "42.5 a side: a little under NVDA's ordinary beep (0.21 for 50 a side)")
        let edge = MouseMath.volumeAndPan(left: 85, right: 0)
        expect((edge.volume * 1000).rounded(), 357, "at the edge the near ear has NVDA's 85, louder than the middle")
        expect(edge.pan, -1, "all left")
        let quarter = MouseMath.volumeAndPan(left: 21.25, right: 63.75)
        expect((quarter.volume * 1000).rounded(), 268, "the louder side sets the volume")
        expect((quarter.pan * 1000).rounded(), 667, "the quieter side a third of the louder, as NVDA's")
        expect(MouseMath.volumeAndPan(left: 0, right: 85).pan, 1, "all right")
        expect(MouseMath.volumeAndPan(left: 0, right: 0).volume, 0, "silent")
    }
    test("mouse: the text unit under the pointer: character, word, paragraph") {
        let s = "First line here.\nSecond para, with words.\n" as NSString
        let at = s.range(of: "para").location + 2
        expect(s.substring(with: MouseMath.unitRange(s, at: at, unit: "character")), "r")
        expect(s.substring(with: MouseMath.unitRange(s, at: at, unit: "word")), "para")
        expect(s.substring(with: MouseMath.unitRange(s, at: at, unit: "paragraph")), "Second para, with words.\n")
        expect(MouseMath.unitRange(s, at: s.range(of: ", ").location + 1, unit: "word").length, 0, "between words: nothing")
        expect(s.substring(with: MouseMath.unitRange(s, at: 999, unit: "character")), "\n", "past the end: the last character")
        let emoji = "a👍🏽b" as NSString
        expect(emoji.substring(with: MouseMath.unitRange(emoji, at: 2, unit: "character")), "👍🏽", "a character is all of an emoji")
        expect(MouseMath.unitRange("" as NSString, at: 0, unit: "word").length, 0, "no text")
    }
    test("mouse: the settings are off by default and read back from the file") {
        let m = Config.Mouse()
        expect(m.tracking, false); expect(m.audioCoordinates, false); expect(m.reportRole, false); expect(m.announceWindow, false)
        expect(m.pointer, "ignores", "the pointer ignores the cursor, as before")
        expect(m.textUnit, "paragraph", "NVDA's default unit")
        expect(m.delayMs, 0)
        let old = try? JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        expect(old?.mouse.pointer, "ignores", "a file from before the mouse settings")
        var c = Config(); c.mouse.audioCoordinates = true; c.mouse.pointer = "moves"; c.mouse.delayMs = 500
        let back = (try? JSONEncoder().encode(c)).flatMap { try? JSONDecoder().decode(Config.self, from: $0) }
        expect(back?.mouse.audioCoordinates, true); expect(back?.mouse.pointer, "moves"); expect(back?.mouse.delayMs, 500)
        let partial = try? JSONDecoder().decode(Config.self, from: Data(#"{"mouse": {"tracking": true, "delayMs": "x"}}"#.utf8))
        expect(partial?.mouse.tracking, true, "one value of the wrong kind keeps the others")
        expect(partial?.mouse.delayMs, 0)
    }
}
