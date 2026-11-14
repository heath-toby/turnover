// SPDX-License-Identifier: GPL-3.0-or-later
// The "TurnOver" Activity in VoiceOver: speech off in TurnOver's apps, so VoiceOver can stay on while TurnOver reads
// them (16 Oct 2026). VoiceOver gives an app one Activity, so a person's own Activity covering one
// of the apps gets the same setting and the Speech category bit added, and loses them again when TurnOver's goes.
// This file is the pure part: an exported archive in, an archive out. The flow that exports and imports through
// VoiceOver Utility is ActivityFlow.swift in the app.
import Foundation

nonisolated public enum VoiceOverActivity {
    public static let profileName = "TurnOver"
    static let speechOffKey = "SCRCategories_SCRCategorySystemWide_SCRSpeechComponentSettings_SCRDisableSpeech"
    static let speechMask = 2   // profileMask bit for the Speech category (measured on an export, 16 Oct 2026)
    /// The hush (TurnOver speaking through VoiceOver): VoiceOver's cursor no longer follows the keyboard focus and its
    /// verbosity is low, so it announces nothing of its own in TurnOver's apps while its voice stays on for TurnOver's
    /// phrases. The category bits for those settings aren't known, so every category but Speech is applied (the values
    /// are the person's own defaults, copied at install, so nothing else changes; the voice stays live).
    static let cursorTrackingKey = "SCRCUserDefaultsCursorTrackingEnabled"
    static let verbosityKey = "SCRVerbosity_SCRVerbosityLevel"
    /// What VoiceOver says of its own accord with its speech on, each turned off in the hush: the cursor following the
    /// keyboard, the text cursor and the mouse; typing echo (VoiceOver echoed every word typed in Word under
    /// TurnOver's: "echo or aliasing"); modifier and lock keys. Names from the system's library cache, 16 Oct 2026.
    static var hushValues: [String: Any] { trackingValues.merging([
        "SCRTypingEchoFeedback": "SCRTypingEchoNone",
        "SCRCUserDefaultsEchoModifierKeysEnabled": false, "SCRCUserDefaultsEchoLockKeysEnabled": false,
        "SCRCUserDefaultsAnnounceMouseEnteringContainerAreaEnabled": false, "SCRCUserDefaultsTextUnderMouseEnabled": false,
        // Live regions (Claude's "Claude is responding"): VoiceOver read them itself, cut by TurnOver's phrase ("Claude is Claude is responding").
        "SCRCUserDefaultsWebObserveLiveRegions": false,
        verbosityKey: "SCRVerbosityLow",
    ]) { $1 } }
    static let hushMask = 0x7FFF & ~speechMask
    /// The recipe of the Activity as installed; a change makes TurnOver install it again at start.
    public static let recipe = 7
    /// VoiceOver's cursor no longer follows the keyboard, the text cursor or the mouse in TurnOver's apps, and the
    /// keyboard focus no longer follows VoiceOver's cursor: in Steam's Big Picture VoiceOver found nothing to land on
    /// and slid off to another window, taking the focus with it (16 Oct 2026). Every category is applied so
    /// the Navigation one (bit unknown) is among them; the values are the person's own defaults, so nothing else changes.
    static var trackingValues: [String: Any] { [
        // (VoiceOver's sounds stay on, 17 Oct 2026, "we should be using VoiceOver sounds"; TurnOver's own edge
        // tone is the one that goes, Tones.edge.)
        cursorTrackingKey: false,
        // VoiceOver's Trackpad Commander off in TurnOver's apps: TurnOver's own gestures read the trackpad there (17 Oct 2026).
        "SCRCTrackpadCommanderEnabled": false,
        // VoiceOver's Quick Nav off in TurnOver's apps: on, VoiceOver acts on the arrows TurnOver passes to the app and
        // drags the focus with its cursor (Mail's list jumped into the message on every Up, 17 Oct 2026).
        "SCRCUserDefaultsArrowKeyQuickNavEnabled": false, "SCRCUserDefaultsSingleKeyQuickNavEnabled": false,
        // Its Keyboard and NumPad Commanders too: both act on keys TurnOver passes to its apps (the code review, 17 Oct 2026).
        "SCRCKeyboardCommanderEnabled": false, "SCRNumPadCommanderEnabled": false,
        "SCRConfigurationCursorTrackingKBToVO": false, "SCRConfigurationCursorTrackingVOToKB": false,
        "SCRConfigurationCursorTrackingTXTToVO": false, "SCRConfigurationCursorTrackingMToVO": false,
    ] }
    static let allMask = 0x7FFF

    public enum ArchiveError: Error { case notAnArchive, noDefaults }

    /// The archive with TurnOver's Activity for `apps` (nil: without it, and the person's own Activities put back).
    /// `touched` names the person's own profiles (by name: VoiceOver gives every profile a new key on import, so a
    /// key never matches across a round trip; found 16 Oct 2026) given the setting last time, so they can be undone.
    /// Returns the new archive and the profiles touched this time.
    /// `originals`: each touched profile's own values for `changedKeys` (a key it didn't have is left out), saved on
    /// install as `masks` is and put back on removal. VoiceOver's defaults were put back instead, so a person's own
    /// Activity lost its typing echo, verbosity, quick nav and the rest when TurnOver's went (a review, 14 Nov 2026).
    /// A profile with no originals known falls back to the defaults, as before.
    public static func archive(_ data: Data, apps: [String]?, touched: [String], hush: Bool = false, masks: [String: Int] = [:],
                               originals: [String: [String: Any]] = [:]) throws -> (data: Data, touched: [String], masks: [String: Int], originals: [String: [String: Any]]) {
        guard var top = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var export = top["export"] as? [String: Any] else { throw ArchiveError.notAnArchive }
        guard let defaults = export["default"] as? [String: Any] else { throw ArchiveError.noDefaults }
        var profiles = (export["allProfiles"] as? [[String: Any]]) ?? []
        profiles.removeAll { (($0["profileInfo"] as? [String: Any])?["profileName"] as? String) == profileName }
        var touchedNow: [String] = []
        var masksNow: [String: Int] = [:]
        var originalsNow: [String: [String: Any]] = [:]
        for i in profiles.indices {
            guard var info = profiles[i]["profileInfo"] as? [String: Any], var values = profiles[i]["profileValues"] as? [String: Any] else { continue }
            let key = info["profileName"] as? String ?? ""
            let theirApps = info["profileApps"] as? [String] ?? []
            let mask = (info["profileMask"] as? NSNumber)?.intValue ?? 0
            if let apps, theirApps.contains(where: { apps.contains($0) }) {
                masksNow[key] = masks[key] ?? mask   // their own mask, kept for the undo (a second install keeps the first's)
                // Their own values likewise. A profile TurnOver changed last time keeps what was saved then (its values
                // now are TurnOver's own; none saved, its undo falls back to the defaults); any other profile's values
                // now are the person's, taken over anything older saved for its name.
                if !touched.contains(key) { originalsNow[key] = values.filter { changedKeys.contains($0.key) } }
                else if let saved = originals[key] { originalsNow[key] = saved }
                if hush {
                    values[speechOffKey] = defaults[speechOffKey] ?? false
                    for (k, v) in hushValues { values[k] = v }
                    info["profileMask"] = mask | hushMask
                } else {
                    values[speechOffKey] = true
                    for (k, v) in trackingValues { values[k] = v }
                    info["profileMask"] = allMask
                }
                touchedNow.append(key)
            } else if touched.contains(key) {
                if let saved = originals[key] {
                    for k in changedKeys { values[k] = saved[k] }   // (a key it never had: removed again)
                } else {
                    values[speechOffKey] = defaults[speechOffKey] ?? false
                    for k in hushValues.keys { if let v = defaults[k] { values[k] = v } else { values[k] = nil } }
                }
                info["profileMask"] = masks[key] ?? (mask & ~speechMask)
            }
            profiles[i]["profileInfo"] = info; profiles[i]["profileValues"] = values
        }
        if let apps {
            var values = defaults
            if hush { for (k, v) in hushValues { values[k] = v } } else { values[speechOffKey] = true; for (k, v) in trackingValues { values[k] = v } }
            profiles.append(["profileInfo": ["profileApps": apps, "profileKey": "profile-" + UUID().uuidString, "profileMask": hush ? hushMask : allMask, "profileName": profileName],
                             "profileValues": values])
        }
        export["allProfiles"] = profiles
        top["export"] = export
        let out = try PropertyListSerialization.data(fromPropertyList: top, format: .xml, options: 0)
        return (out, touchedNow, masksNow, originalsNow)
    }

    /// Every key TurnOver's Activity changes in a person's own profile: the ones whose own values are saved and put back.
    static var changedKeys: Set<String> { Set(hushValues.keys).union(trackingValues.keys).union([speechOffKey]) }

    /// Each profile's own values for `changedKeys`, by name, from the export made before TurnOver's first install: the
    /// fallback when the marker has none (as `masks` falls back to the same export).
    public static func originalValues(in data: Data) -> [String: [String: Any]] {
        guard let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let export = top["export"] as? [String: Any], let profiles = export["allProfiles"] as? [[String: Any]] else { return [:] }
        var out: [String: [String: Any]] = [:]
        for p in profiles {
            guard let info = p["profileInfo"] as? [String: Any], let name = info["profileName"] as? String, name != profileName,
                  let values = p["profileValues"] as? [String: Any] else { continue }
            out[name] = values.filter { changedKeys.contains($0.key) }
        }
        return out
    }

    /// `originals` as a property list for the marker file (property-list values, not Codable), and back.
    public static func encode(originals: [String: [String: Any]]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: originals, format: .binary, options: 0)
    }
    public static func decodeOriginals(_ data: Data?) -> [String: [String: Any]] {
        guard let data, let v = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String: Any]] else { return [:] }
        return v
    }

    /// Whether an archive holds TurnOver's Activity, and for which apps.
    public static func installedApps(in data: Data) -> [String]? {
        guard let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let export = top["export"] as? [String: Any], let profiles = export["allProfiles"] as? [[String: Any]] else { return nil }
        for p in profiles {
            guard let info = p["profileInfo"] as? [String: Any], info["profileName"] as? String == profileName else { continue }
            return info["profileApps"] as? [String] ?? []
        }
        return nil
    }
}
