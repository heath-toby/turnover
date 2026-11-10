// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's sound files at the loudness of TurnOver's own set (3 Nov 2026).
import Foundation
import AVFoundation
import TurnOverCore

func soundsTests() {
    test("VoiceOver's sounds: each file to -20 dBFS RMS, or as near as keeps its peaks under -1 dBFS") {
        expect(VoiceOverSounds.gain(rms: 0.2, peak: 0.9), 0.5, "a loud file comes down to -20 dBFS")
        expect((VoiceOverSounds.gain(rms: 0.04, peak: 0.5) * 100).rounded(), 178, "a quiet one comes up, as far as peaks of -1 dBFS")
        let url = VoiceOverSounds.folder.appendingPathComponent("LinkBegin.aiff")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let data = VoiceOverSounds.levelled(url), let player = try? AVAudioPlayer(data: data) else { return Harness.fail("LinkBegin.aiff: no WAV a player reads") }
        expect(Int((player.duration * 1000).rounded()), 52, "the file's length, 52 ms, kept")
        expect(player.numberOfChannels, 2, "its two channels kept")
    }

    test("sounds one by one: every sound in the Settings list has a known name, once") {
        let listed = SoundChoices.all.map(\.id)
        expect(Set(listed).count, listed.count, "no sound listed twice")
        expect(Set(listed), SoundChoices.ids, "the list and the known names agree")
    }
    test("sounds one by one: TurnOver's files and VoiceOver's map to their sound") {
        expect(SoundChoices.id(forFile: "heading3"), "heading", "a heading's level is one sound")
        expect(SoundChoices.id(forFile: "tick"), "tick")
        expect(SoundChoices.id(forVoiceOverFile: "QuickNavArrowKeyOn.wav"), "quicknav_on", "by name whatever the ending")
        expect(SoundChoices.id(forVoiceOverFile: "WrapBoundary.aiff"), "edge")
        expect(SoundChoices.id(forVoiceOverFile: "Nothing.aiff"), nil, "an unknown file is no sound of the list")
        // The set's files in the source tree (Resources/Sounds), each a sound of the list.
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Sounds").standardized
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".wav") }
        check(files.count > 30, "TurnOver's sound files found in \(folder.path)")
        // "done" is made by make-sounds.py but nothing plays it (10 Nov 2026), so Settings doesn't list it.
        for name in files.map({ String($0.dropLast(4)) }) where name != "done" {
            check(SoundChoices.ids.contains(SoundChoices.id(forFile: name)), "TurnOver's file \(name) belongs to a sound in the list")
        }
    }
    test("sounds one by one: positional sound pans by where the item's middle sits across its screen") {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 500, height: 800)]
        expect(SoundChoices.pan(for: CGRect(x: 450, y: 100, width: 100, height: 20), screens: screens), 0, "the middle")
        expect(SoundChoices.pan(for: CGRect(x: 0, y: 100, width: 10, height: 20), screens: screens) < -0.75, true, "the left edge, nearly left")
        expect(SoundChoices.pan(for: CGRect(x: -500, y: 100, width: 10, height: 20), screens: screens), 0, "on no screen, the middle")
        expect(SoundChoices.pan(for: CGRect(x: 1490, y: 100, width: 10, height: 20), screens: screens) > 0.75, true, "the second screen's right edge")
        expect(SoundChoices.pan(for: CGRect(x: 1240, y: 100, width: 20, height: 20), screens: screens), 0, "the second screen's middle")
        let far = SoundChoices.pan(for: CGRect(x: 995, y: 100, width: 4, height: 20), screens: screens)
        check(far <= 0.8, "never in one ear only: \(far)")
    }
    test("sounds one by one: a settings file without the section, or with part of it, keeps the rest") {
        let none = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        expect(none.sounds.off, [], "nothing off")
        expect(none.sounds.positional, true, "positional on, as VoiceOver's")
        let some = try JSONDecoder().decode(Config.self, from: Data(#"{"sounds": {"off": ["link", "tick"], "positional": "yes"}}"#.utf8))
        expect(some.sounds.off, ["link", "tick"], "the sounds turned off are kept")
        expect(some.sounds.positional, true, "a value of the wrong kind falls back alone")
        let again = try JSONDecoder().decode(Config.self, from: try JSONEncoder().encode(some))
        expect(again.sounds.off, ["link", "tick"], "saved and read back")
    }
}
