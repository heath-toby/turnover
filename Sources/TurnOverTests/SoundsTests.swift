// SPDX-License-Identifier: GPL-3.0-or-later
// VoiceOver's sound files at the loudness of TurnOver's own set (3 Nov 2026).
import Foundation
import AVFoundation
import TurnOverCore
import TurnOverSpeech

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
    test("sounds one by one: 3D placement puts the item across and up or down its screen") {
        let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 500, height: 800)]
        expect(SoundChoices.placement(for: CGRect(x: 450, y: 390, width: 100, height: 20), screens: screens), .middle, "the middle")
        let topLeft = SoundChoices.placement(for: CGRect(x: 0, y: 0, width: 10, height: 10), screens: screens)
        check(topLeft.x < -0.95 && topLeft.y > 0.95, "the top left corner is left and up: \(topLeft)")
        let bottom = SoundChoices.placement(for: CGRect(x: 1245, y: 790, width: 10, height: 10), screens: screens)
        check(abs(bottom.x) < 0.01 && bottom.y < -0.95, "the second screen's bottom middle is down, in the middle: \(bottom)")
        expect(SoundChoices.placement(for: CGRect(x: -500, y: 100, width: 10, height: 20), screens: screens), .middle, "on no screen, the middle")
        let p = SpatialSoundPlayer.position(x: 0, y: 0)
        check(abs(p.x) < 0.001 && abs(p.y) < 0.001 && abs(p.z + 1) < 0.001, "the middle is straight ahead, a metre away: \(p)")
        let right = SpatialSoundPlayer.position(x: 1, y: 1)
        check(right.x > 0.5 && right.y > 0.4 && right.z < -0.3, "the top right is right, up and still in front: \(right)")
        check(abs(right.x * right.x + right.y * right.y + right.z * right.z - 1) < 0.001, "always a metre away")
        let left = SpatialSoundPlayer.position(x: -3, y: -1)
        check(abs(left.x + right.x) < 0.001 && abs(left.y + right.y) < 0.001, "beyond the edge is kept at the edge, mirrored: \(left)")
    }
    test("sounds one by one: which path a sound file plays by") {
        let item = SoundChoices.Placement(x: 0.5, y: -0.5)
        expect(SoundChoices.route(placement: "stereo", reverb: false, at: item, placed: true), nil, "stereo plays as before")
        expect(SoundChoices.route(placement: "off", reverb: false, at: item, placed: true), nil, "off plays as before")
        expect(SoundChoices.route(placement: "3d", reverb: false, at: item, placed: true), .threeD(x: 0.5, y: -0.5), "3D, where the item is")
        expect(SoundChoices.route(placement: "3d", reverb: true, at: item, placed: false), .threeD(x: 0, y: 0), "a sound of no item, in the middle")
        expect(SoundChoices.route(placement: "stereo", reverb: true, at: item, placed: true), .stereo(pan: 0.4), "reverb takes stereo through the engine, panned")
        expect(SoundChoices.route(placement: "off", reverb: true, at: item, placed: true), .stereo(pan: 0), "reverb with placement off, in the middle")
    }
    test("sounds one by one: the old positional switch becomes the placement") {
        @MainActor func decode(_ json: String) throws -> Config.Sounds { try JSONDecoder().decode(Config.self, from: Data(#"{"sounds": \#(json)}"#.utf8)).sounds }
        expect(try decode(#"{"positional": true}"#).placement, "stereo", "on is stereo, as before")
        expect(try decode(#"{"positional": false}"#).placement, "off", "off is off")
        expect(try decode(#"{}"#).placement, "stereo", "nothing said: stereo")
        expect(try decode(#"{"positional": false, "placement": "3d"}"#).placement, "3d", "the placement wins over the old switch")
        expect(try decode(#"{"positional": false, "placement": "surround"}"#).placement, "off", "a placement it doesn't know falls back to the switch")
        expect(try decode(#"{}"#).reverb, false, "reverb off by default")
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(try decode(#"{"placement": "off", "reverb": true}"#))) as? [String: Any]
        expect(saved?["positional"] as? Bool, false, "the old switch is still written, for an older TurnOver")
        expect(saved?["reverb"] as? Bool, true, "reverb saved")
    }
    test("sounds one by one: a levelled WAV in memory reads back as mono for the 3D engine") {
        var wav = Data()
        func tag(_ s: String) { wav.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { wav.append(contentsOf: $0) } }
        func u16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { wav.append(contentsOf: $0) } }
        let frames = 4410
        tag("RIFF"); u32(36 + frames * 4); tag("WAVE"); tag("fmt "); u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
        tag("data"); u32(frames * 4)
        for _ in 0..<frames { u16(16384); u16(0) }   // left at half, right silent
        guard let read = SpatialSoundPlayer.read(wav: wav) else { return Harness.fail("the WAV wasn't read") }
        expect(Int(read.frameLength), frames, "every frame read")
        expect(read.format.channelCount, 2, "both channels")
        guard let mono = SpatialSoundPlayer.mono(read), let s = mono.floatChannelData?[0] else { return Harness.fail("not made mono") }
        expect(mono.format.channelCount, 1, "mono")
        check(abs(Int(mono.frameLength) - 4800) < 100, "at 48 kHz: \(mono.frameLength)")
        let mid = s[Int(mono.frameLength) / 2]
        check(mid > 0.1 && mid < 0.5, "both channels mixed, not the left one alone: \(mid)")
        check(SpatialSoundPlayer.read(wav: Data("RIFF".utf8)) == nil, "a short file isn't read")
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
