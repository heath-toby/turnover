// SPDX-License-Identifier: GPL-3.0-or-later
// NVDA's "Brightness controls audio coordinates volume" (the tester, 14 Nov 2026, once TurnOver had screen recording):
// how bright the screen is under the pointer, 0 for black to 1 for white, from a square of pixels around it
// (NVDA's blur factor), smoothed over time taken through ScreenCaptureKit, at most 25 times a second, in the background. The beep uses the
// latest reading, so the pointer's movement is never held up by it. TurnOver's own panels are left out of the picture.
import Foundation
import AppKit
import ScreenCaptureKit

@MainActor
public enum ScreenBrightness {
    /// The latest brightness under the pointer, and where it was read; nil until one has been read.
    public private(set) static var latest: (value: Double, at: CGPoint)?
    private static var busy = false
    private static var lastAsked = Date.distantPast
    private static var logged = false

    /// Read again around `point` (accessibility coordinates, top left origin) unless a reading is under way or one
    /// was asked for in the last 40 ms.
    public static func update(at point: CGPoint) {
        guard !busy, Date().timeIntervalSince(lastAsked) >= 0.04 else { return }
        busy = true; lastAsked = Date()
        Task.detached(priority: .userInitiated) {
            let value = await Sampler.shared.read(at: point)
            await MainActor.run {
                busy = false
                // Smoothed: each reading moves the volume a third of the way, so crossing text (dark letters, white
                // gaps) doesn't make it fade in and out with every letter (the tester, 14 Nov 2026).
                if let value { latest = (latest.map { $0.value + (value - $0.value) * 0.35 } ?? value, point) }
                // Once, for the log: whether readings work at all (no permission gives none).
                if !logged { logged = true; Log.info(value == nil ? "mouse: the screen's brightness can't be read (Screen Recording?); the beeps keep their volume" : "mouse: brightness under the pointer read (\(Int((value ?? 0) * 100)) percent)") }
            }
        }
    }

    /// The capture side, off the main thread: the displays and windows list is kept five seconds (asking for it is
    /// the slow part), behind a lock.
    private final class Sampler: @unchecked Sendable {
        static let shared = Sampler()
        private let lock = NSLock()
        private var content: (SCShareableContent, Date)?

        func read(at p: CGPoint) async -> Double? {
            do {
                let cached = lock.withLock { content.flatMap { Date().timeIntervalSince($0.1) < 5 ? $0.0 : nil } }
                let c: SCShareableContent
                if let cached { c = cached } else {
                    c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    lock.withLock { content = (c, Date()) }
                }
                guard let display = c.displays.first(where: { $0.frame.contains(p) }) ?? c.displays.first else { return nil }
                let config = SCStreamConfiguration()
                config.showsCursor = false
                // A 31-point square, taken at 16 by 16 pixels: the area's brightness, not a letter's.
                config.sourceRect = CGRect(x: p.x - display.frame.minX - 15, y: p.y - display.frame.minY - 15, width: 31, height: 31)
                config.width = 16; config.height = 16
                let own = c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingApplications: own, exceptingWindows: []), configuration: config)
                return ScreenBrightness.brightness(of: image)
            } catch {
                return nil
            }
        }
    }

    /// The average brightness of an image's pixels, 0 to 1. Pure (tested with a made-up image).
    nonisolated public static func brightness(of image: CGImage) -> Double {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return 1 }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            sum += 0.299 * Double(pixels[i]) + 0.587 * Double(pixels[i + 1]) + 0.114 * Double(pixels[i + 2])
        }
        return sum / Double(w * h) / 255
    }
}
