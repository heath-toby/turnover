// SPDX-License-Identifier: GPL-3.0-or-later
// What the Windows style made of a key as it went down (WindowsRemap): the Mac key it became and the modifiers it
// swapped. The key tap keeps it until the key comes up, and the release becomes the same key. Worked out again from
// the release itself, it could differ: Control let go before Home, the press was Command Up and the release Command
// Left; the app in front changed in between, the release went untranslated (a review, 13 Nov 2026).
import CoreGraphics

nonisolated public struct KeyTranslation: Equatable, Sendable {
    public let code: Int64
    public let add: CGEventFlags
    public let remove: CGEventFlags

    public init(code: Int64, add: CGEventFlags, remove: CGEventFlags) {
        self.code = code; self.add = add; self.remove = remove
    }

    /// The arrow keys carry Fn and the keypad flag, as the keyboard's own do.
    public static let arrows: Set<Int64> = [123, 124, 125, 126]

    /// `flags` (the press's, or the release's as they are now) with the translation's modifiers swapped in.
    public func flags(from flags: CGEventFlags) -> CGEventFlags {
        var f = flags
        f.remove(remove); f.insert(add)
        if Self.arrows.contains(code) { f.insert([.maskSecondaryFn, .maskNumericPad]) }
        return f
    }

    /// Rewrite a key down or up in place.
    public func apply(to event: CGEvent) {
        event.setIntegerValueField(.keyboardEventKeycode, value: code)
        event.flags = flags(from: event.flags)
    }
}
