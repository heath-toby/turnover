// SPDX-License-Identifier: GPL-3.0-or-later
// The display's brightness said as the brightness keys are pressed, as VoiceOver does (the tester, 14 Nov 2026): the
// first press "Display brightness, 65 percent", each press after it just the number, until TurnOver has said something
// else. The keys are heard through a passive monitor of the system's media-key events (they pass on to macOS, which
// changes the brightness); the level is read from DisplayServices a moment later, once macOS has set it.
import Foundation
import AppKit
import CoreGraphics

@MainActor
public enum BrightnessKeys {
    private static var monitor: Any?
    private static var lastSaid: String?

    public static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { event in
            // Media keys: subtype 8, the key in data1's high half, key down when (data1 & 0xFF00) >> 8 is 0xA.
            guard event.subtype.rawValue == 8 else { return }
            let key = (event.data1 & 0xFFFF0000) >> 16, down = ((event.data1 & 0xFF00) >> 8) == 0xA
            // NX_KEYTYPE_BRIGHTNESS_UP 2, NX_KEYTYPE_BRIGHTNESS_DOWN 3.
            guard down, key == 2 || key == 3 else { return }
            MainActor.assumeIsolated {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { announce() }
            }
        }
    }

    private static func announce() {
        guard Core.active, let level = level() else { return }
        let percent = Int((level * 100).rounded())
        let number = String(localized: "\(String(percent)) percent", comment: "The display's brightness, after the first press: its percentage")
        // The full words on the first press, the number on the presses after it while nothing else has been said.
        let said = (lastSaid != nil && Speech.lastSpoken == lastSaid) ? number
            : String(localized: "Display brightness, \(String(percent)) percent", comment: "The display's brightness, said on the first press of a brightness key")
        Speech.cancel()
        Speech.speakMessage(said)
        lastSaid = Speech.lastSpoken
    }

    /// The main display's brightness, 0 to 1, from DisplayServices (private: the only reader of it on Apple silicon).
    static func level() -> Float? {
        guard let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY),
              let sym = dlsym(h, "DisplayServicesGetBrightness") else { return nil }
        typealias Get = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
        var b: Float = -1
        guard unsafeBitCast(sym, to: Get.self)(CGMainDisplayID(), &b) == 0, b >= 0 else { return nil }
        return b
    }
}
