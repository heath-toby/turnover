// SPDX-License-Identifier: GPL-3.0-or-later
// SpatialSoundPlayer: TurnOver's sound files placed in space, as VoiceOver's positional audio places its sounds
// (14 Nov 2026: "VoiceOver-like positional audio for TurnOver's sounds"). Settings, Sounds, "Where sounds come from":
// Off and Stereo play through AVAudioPlayer as before (SoundChoices.start); 3D plays here, each sound from left or right
// and up or down by where its item sits on its screen, at a fixed distance in front of you. "A touch of reverb" plays
// here too, whichever placement is chosen, so a small room is heard behind every file.
//
// The graph: 3D sources (mono) -> AVAudioEnvironmentNode (HRTF, the listener at the origin facing -z) -> a bus mixer;
// stereo sources (mono, panned) -> the same bus mixer; the bus -> AVAudioUnitReverb (small room, bypassed when off)
// -> the main mixer. The environment node spatialises only mono sources, so every file is made mono once, as it is
// first played, and kept.
//
// All state lives on one serial queue, as SpeechPlayer's does: starting an engine and playing nodes are calls into
// Apple's audio code that can stall when the output changes (SpeechPlayer saw its own stall, 19 Oct 2026), and the
// main thread never waits for them here. The engine starts with the first sound, and is dropped when the output
// changes (AVAudioEngineConfigurationChange) and built again for the next sound.
import Foundation
import TurnOverObjC
@preconcurrency import AVFoundation   // buffers are made and played on the queue only

public final class SpatialSoundPlayer: @unchecked Sendable {
    // @unchecked Sendable: every stored property below is read and written only on `queue` (play, forget, the
    // configuration observer and teardown all hop there first); `queue` itself is a let. Nothing is touched from the
    // caller's thread but the queue.
    public static let shared = SpatialSoundPlayer()

    /// Where a sound comes from: a file on disk, or a WAV made in memory (VoiceOver's files, levelled), with a name
    /// that stays the same while its contents do.
    public enum Source: Sendable {
        case file(URL)
        case wav(key: String, data: Data)
        var key: String {
            switch self {
            case .file(let url): return "file:" + url.standardizedFileURL.path
            case .wav(let key, _): return "wav:" + key
            }
        }
    }

    /// How a sound is placed: in 3D, x and y from -1 (left, bottom) to 1 (right, top); in stereo, a pan alone.
    public enum Placement: Sendable, Equatable {
        case threeD(x: Float, y: Float)
        case stereo(pan: Float)
    }

    private let queue = DispatchQueue(label: "TurnOver.spatial-sounds", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var environment: AVAudioEnvironmentNode?
    private var reverb: AVAudioUnitReverb?
    private var spatialNodes: [AVAudioPlayerNode] = []
    private var stereoNodes: [AVAudioPlayerNode] = []
    private var nextSpatial = 0, nextStereo = 0
    private var observer: NSObjectProtocol?
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    private var unreadable: Set<String> = []

    /// Every source is made mono at this rate: one connection format for every node.
    private static let rate: Double = 48_000
    private static let monoFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
    /// Sounds that may overlap (a tick, then a link's sound a moment later): each placement's nodes take turns.
    private static let voices = 6

    private init() {}

    /// Plays a sound placed in space, at `volume` (0 to 1). `failed` runs on main when it couldn't be played here
    /// (the file unreadable, no output to start on), so the caller plays it its old way instead.
    public func play(_ source: Source, placement: Placement, volume: Float, reverb wantsReverb: Bool,
                     failed: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            guard let buffer = buffer(for: source), ensureEngine(), let engine, let reverb else {
                Task { @MainActor in failed() }
                return
            }
            reverb.bypass = !wantsReverb
            let node: AVAudioPlayerNode
            switch placement {
            case .threeD(let x, let y):
                node = spatialNodes[nextSpatial]; nextSpatial = (nextSpatial + 1) % spatialNodes.count
                let p = Self.position(x: x, y: y)
                node.position = AVAudio3DPoint(x: p.x, y: p.y, z: p.z)
            case .stereo(let pan):
                node = stereoNodes[nextStereo]; nextStereo = (nextStereo + 1) % stereoNodes.count
                node.pan = max(-1, min(1, pan))
            }
            node.volume = max(0, min(1, volume))
            var reason: NSString?
            // A node played on an engine whose device has just gone raises an Objective-C exception (SpeechPlayer,
            // 18 and 19 Oct 2026): caught, the engine dropped, and the caller plays the sound its old way.
            let ok = engine.isRunning && TOCatch({
                node.stop()
                node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
                node.play()
            }, &reason)
            if !ok {
                NSLog("spatial sounds: the output went as a sound played (%@); the next sound starts it again", (reason ?? "") as String)
                teardown()
                Task { @MainActor in failed() }
            }
        }
    }

    /// Forgets a file's sound, kept since it was first played: your own file for a sound was replaced or removed.
    public func forget(_ source: Source) {
        let key = source.key
        queue.async { [self] in buffers[key] = nil; unreadable.remove(key) }
    }

    /// Stops the engine: placement is back to Off or Stereo without reverb, so nothing plays here now.
    public func stop() {
        queue.async { [self] in teardown() }
    }

    /// Where a 3D sound is put: x across (-1 left, 1 right) turns it up to 60 degrees to either side, y (-1 bottom,
    /// 1 top) up to 35 degrees up or down, always one metre from you and in front. Kept short of 90 degrees so the
    /// edges of the screen are well to the side without being in one ear only, as stereo's ±0.8 is.
    public static func position(x: Float, y: Float) -> (x: Float, y: Float, z: Float) {
        let azimuth = max(-1, min(1, x)) * 60 * .pi / 180
        let elevation = max(-1, min(1, y)) * 35 * .pi / 180
        return (sin(azimuth) * cos(elevation), sin(elevation), -cos(azimuth) * cos(elevation))
    }

    // MARK: On the queue

    private func ensureEngine() -> Bool {
        if let engine, engine.isRunning { return true }
        if engine != nil { teardown() }
        let engine = AVAudioEngine()
        let environment = AVAudioEnvironmentNode()
        let bus = AVAudioMixerNode()
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.smallRoom)
        reverb.wetDryMix = 10   // a touch: the sound itself stays clear
        reverb.bypass = true
        // The listener at the origin facing -z (the default orientation); sources at a metre are within the
        // reference distance, so none is quieter for its place.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.distanceAttenuationParameters.referenceDistance = 5
        environment.reverbParameters.enable = false
        [environment, bus, reverb].forEach { engine.attach($0) }
        let hardwareRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        guard hardwareRate > 0, let stereo = AVAudioFormat(standardFormatWithSampleRate: hardwareRate, channels: 2) else {
            NSLog("spatial sounds: no output to play to")
            return false
        }
        engine.connect(environment, to: bus, format: stereo)
        engine.connect(bus, to: reverb, format: stereo)
        engine.connect(reverb, to: engine.mainMixerNode, format: stereo)
        let spatial = (0..<Self.voices).map { _ in AVAudioPlayerNode() }
        let flat = (0..<Self.voices).map { _ in AVAudioPlayerNode() }
        for node in spatial {
            engine.attach(node)
            engine.connect(node, to: environment, fromBus: 0, toBus: environment.nextAvailableInputBus, format: Self.monoFormat)
            node.renderingAlgorithm = .HRTFHQ
            node.reverbBlend = 0
        }
        for node in flat {
            engine.attach(node)
            engine.connect(node, to: bus, fromBus: 0, toBus: bus.nextAvailableInputBus, format: Self.monoFormat)
        }
        engine.prepare()
        do { try engine.start() } catch {
            NSLog("spatial sounds: the audio engine wouldn't start: %@", "\(error)")
            return false
        }
        self.engine = engine; self.environment = environment; self.reverb = reverb
        spatialNodes = spatial; stereoNodes = flat; nextSpatial = 0; nextStereo = 0
        // The output changed (headphones in or out, a device chosen): the engine has stopped. It is dropped and the
        // next sound builds it again on the new output.
        observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.teardown() }
        }
        return true
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        if let engine { _ = TOCatch({ engine.stop() }, nil) }
        engine = nil; environment = nil; reverb = nil
        spatialNodes = []; stereoNodes = []
    }

    /// The source as mono at the engine's rate, read once and kept.
    private func buffer(for source: Source) -> AVAudioPCMBuffer? {
        let key = source.key
        if let b = buffers[key] { return b }
        if unreadable.contains(key) { return nil }
        let read: AVAudioPCMBuffer?
        switch source {
        case .file(let url): read = Self.read(url)
        case .wav(_, let data): read = Self.read(wav: data)
        }
        guard let read, let mono = Self.mono(read) else {
            unreadable.insert(key)
            NSLog("spatial sounds: couldn't read %@", key)
            return nil
        }
        buffers[key] = mono
        return mono
    }

    private static func read(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0,
              let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: b)) != nil else { return nil }
        return b
    }

    /// A 16-bit PCM WAV as VoiceOverSounds.levelled makes it (a 44-byte header, then the samples).
    package static func read(wav data: Data) -> AVAudioPCMBuffer? {
        guard data.count > 44 else { return nil }
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let channels = u16(22), rate = u32(24), bits = u16(34)
        guard bytes[0..<4].elementsEqual(Array("RIFF".utf8)), bytes[36..<40].elementsEqual(Array("data".utf8)),
              u16(20) == 1, bits == 16, channels > 0, rate > 0 else { return nil }
        let frames = min(u32(40), bytes.count - 44) / (2 * channels)
        guard frames > 0, let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: AVAudioChannelCount(channels)),
              let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = b.floatChannelData else { return nil }
        for f in 0..<frames {
            for c in 0..<channels {
                let i = 44 + (f * channels + c) * 2
                out[c][f] = Float(Int16(bitPattern: UInt16(u16(i)))) / 32768
            }
        }
        b.frameLength = AVAudioFrameCount(frames)
        return b
    }

    /// The buffer made mono (its channels mixed down, not just the left one) at the engine's rate.
    package static func mono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if input.format == monoFormat { return input }
        guard let converter = AVAudioConverter(from: input.format, to: monoFormat) else { return nil }
        converter.downmix = true
        let capacity = AVAudioFrameCount(Double(input.frameLength) * rate / input.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return nil }
        var given = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, state in
            if given { state.pointee = .endOfStream; return nil }
            given = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}
