// SPDX-License-Identifier: GPL-3.0-or-later
// The battery's own figures, from its AppleSmartBattery node in the I/O Registry: the firmware's time to empty and to
// full, its charge and its current. macOS 27 gives -1 for the times everywhere else (the tester's recmon spoon reads
// these too, 14 Nov 2026). No shell, no permission: the registry is open to every app.
import Foundation
import IOKit

public enum SmartBattery {
    public struct Figures { public let avgToEmpty: Int?, avgToFull: Int?, remaining: Int?, full: Int?, amperage: Int? }

    public static func read() -> Figures? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return nil }
        func int(_ k: String) -> Int? { (d[k] as? NSNumber)?.intValue }
        // Amperage is signed (negative while discharging) but can arrive as its unsigned 64-bit pattern.
        let amp: Int? = (d["Amperage"] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) }
        return Figures(avgToEmpty: int("AvgTimeToEmpty"), avgToFull: int("AvgTimeToFull"), remaining: int("AppleRawCurrentCapacity") ?? int("RemainingCapacity"),
                       full: int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity"), amperage: amp)
    }

    /// Minutes to full (charging) or to empty: the firmware's estimate when it has one (0 and 65535 mean none), else
    /// the charge still to come or left divided by the current. Nil when neither can say. Pure (tested).
    public static func minutes(charging: Bool, avgToFull: Int?, avgToEmpty: Int?, remaining: Int?, full: Int?, amperage: Int?) -> Int? {
        func valid(_ t: Int?) -> Int? { guard let t, t > 0, t < 65535 else { return nil }; return t }
        if charging {
            if let t = valid(avgToFull) { return t }
            if let f = full, let r = remaining, let a = amperage, a > 0, f > r { return (f - r) * 60 / a }
        } else {
            if let t = valid(avgToEmpty) { return t }
            if let r = remaining, let a = amperage, a < 0 { return r * 60 / -a }
        }
        return nil
    }
}
