// SPDX-License-Identifier: GPL-3.0-or-later
// The "TurnOver" Activity put into VoiceOver and taken out again, through VoiceOver Utility, with every sheet
// answered by TurnOver (16 Oct 2026, when VoiceOver began staying on). Export fresh each time, so the person's
// other VoiceOver changes are never overwritten; the archive with (or without) the Activity is imported back.
// The marker file says whether the Activity is in, for which apps, and which of the person's own Activities were
// given the setting, so a crash and a relaunch, or a quit, can put things right.
import AppKit
import CoreGraphics
import TurnOverCore

@MainActor
final class ActivityFlow {
    static let shared = ActivityFlow()
    struct Marker: Codable { var installed: Bool; var apps: [String]; var touched: [String]; var hush: Bool?; var masks: [String: Int]?; var recipe: Int?
        /// The person's own values for the keys TurnOver changed in their profiles, a property list (VoiceOverActivity.encode).
        var originals: Data? }
    private var markerURL: URL { AppPaths.file("voiceover-activity.json") }
    private var folder: URL { AppPaths.file("voiceover") }
    private(set) var running = false

    var marker: Marker { (try? JSONDecoder().decode(Marker.self, from: Data(contentsOf: markerURL))) ?? Marker(installed: false, apps: [], touched: []) }
    private func save(_ m: Marker) { try? JSONEncoder().encode(m).write(to: markerURL) }

    /// Put the Activity in (apps) or take it out (nil), then say how it went. About six seconds; the Utility shows.
    /// A request made while one runs: kept, and done when the running one ends (Command Control Period twice within
    /// ten seconds dropped the second and left two voices; a code review on 17 Oct 2026).
    /// The kept request carries its caller's completion, run when it's done (a review, 14 Nov 2026: the uninstall's
    /// went unheard and it stopped). One replaced by a newer request is told so.
    private var pending: (apps: [String]?, hush: Bool, completion: (String) -> Void)?
    func set(apps: [String]?, hush: Bool = false, completion: @escaping (String) -> Void) {
        guard !running else {
            let replaced = pending?.completion
            pending = (apps, hush, completion); Log.info("activity: a request kept until the running one ends")
            replaced?("A newer request to change VoiceOver's settings replaced this one.")
            return
        }
        running = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // An archive left from last time would make the save sheet ask "Replace?" (16 Oct 2026): gone first.
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "voprefs" { try? FileManager.default.removeItem(at: f) }
        let since = Date()
        VoiceOverSettings.pointSaveSheet(at: folder)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: VoiceOverSettings.utilityBundleID) else { running = false; completion("VoiceOver Utility wasn't found."); return }
        Log.info("activity: \(apps == nil ? "removing" : "installing for \(apps!.count) apps"): exporting first")
        // A Utility already open may have a sheet up (a run that stopped halfway), and its Export is disabled then:
        // start it clean.
        VoiceOverSettings.quitUtility()
        // (A Utility quitting from the last run was opened again too soon and its Export never pressed: 16 Oct 2026.)
        retry(every: 0.3, first: 0.5, times: 15, { NSRunningApplication.runningApplications(withBundleIdentifier: VoiceOverSettings.utilityBundleID).isEmpty }) { _ in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        // 1. File > Export Preferences… once the Utility has its window, then Save in the sheet (it opens on our folder).
        retry(every: 0.5, first: 1.2, times: 20, { VoiceOverSettings.utilityHasWindow() && VoiceOverSettings.pressFileMenuItem(prefix: "Export Preferences") }) { [weak self] pressed in
            guard let self else { return }
            guard pressed else { self.end("VoiceOver Utility's Export command couldn't be pressed.", completion); return }
            self.retry(every: 0.2, first: 0.3, times: 25, { VoiceOverSettings.utilitySheet() != nil }) { sheet in
                guard sheet else { self.end("The save sheet didn't appear.", completion); return }
                // Pressed by accessibility; the press's own answer isn't trusted (it reported failure while the sheet
                // went on to ask "Replace?", 16 Oct 2026): the file's arrival is the proof.
                _ = VoiceOverSettings.pressSheetButton("Save")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if VoiceOverSettings.utilitySheetText().contains("already exists") { _ = VoiceOverSettings.pressSheetButton("Replace") } }
                self.retry(every: 0.3, first: 0.4, times: 30, { VoiceOverSettings.newestExport(in: self.folder, since: since) != nil }) { saved in
                    guard saved, let file = VoiceOverSettings.newestExport(in: self.folder, since: since) else { self.end("No settings file was saved.", completion); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.generateAndImport(from: file, apps: apps, hush: hush, completion: completion) }
                }
            }
        }
    }

    /// The export from before TurnOver's first install, kept so the person's own Activities can be put back exactly
    /// even if the marker is lost (their masks were once recorded as the hush's; a code review on 17 Oct 2026).
    private var originalURL: URL { folder.appendingPathComponent("original-export.plist") }
    private func originalMasks() -> [String: Int] {
        guard let data = try? Data(contentsOf: originalURL), let top = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let export = top["export"] as? [String: Any], let profiles = export["allProfiles"] as? [[String: Any]] else { return [:] }
        var out: [String: Int] = [:]
        for p in profiles { if let info = p["profileInfo"] as? [String: Any], let name = info["profileName"] as? String, let mask = (info["profileMask"] as? NSNumber)?.intValue { out[name] = mask } }
        return out
    }

    private func generateAndImport(from file: URL, apps: [String]?, hush: Bool, completion: @escaping (String) -> Void) {
        let m = marker
        if !m.installed, !FileManager.default.fileExists(atPath: originalURL.path) { try? FileManager.default.copyItem(at: file, to: originalURL) }
        let knownMasks = (m.masks?.isEmpty ?? true) ? originalMasks() : (m.masks ?? [:])
        // The person's own values, as the masks: from the marker, else the export from before the first install.
        let saved = VoiceOverActivity.decodeOriginals(m.originals)
        let knownOriginals = saved.isEmpty ? ((try? Data(contentsOf: originalURL)).map(VoiceOverActivity.originalValues(in:)) ?? [:]) : saved
        let out: URL
        let touchedNow: [String]
        let masksNow: [String: Int]
        let originalsNow: [String: [String: Any]]
        do {
            let r = try VoiceOverActivity.archive(try Data(contentsOf: file), apps: apps, touched: m.touched, hush: hush, masks: knownMasks, originals: knownOriginals)
            out = folder.appendingPathComponent("TurnOver Activity.voprefs")
            try r.data.write(to: out, options: .atomic)
            touchedNow = r.touched; masksNow = r.masks; originalsNow = r.originals
        } catch { end("The VoiceOver settings file couldn't be changed (\(error)).", completion); return }
        // 2. File > Import Preferences…, the path typed into the open panel, Open, and OK to "Are you sure".
        guard VoiceOverSettings.pressFileMenuItem(prefix: "Import Preferences") else { end("VoiceOver Utility's Import command couldn't be pressed.", completion); return }
        retry(every: 0.2, first: 0.4, times: 25, { VoiceOverSettings.utilitySheet() != nil }) { [weak self] panel in
            guard let self else { return }
            guard panel else { self.end("The open panel didn't appear.", completion); return }
            // The panel opens on our folder (the save sheet did): the archive's row is opened by accessibility.
            self.retry(every: 0.3, first: 0.3, times: 15, { VoiceOverSettings.openSheetRow(named: out.deletingPathExtension().lastPathComponent) }) { opened in
                guard opened else { _ = VoiceOverSettings.pressSheetButton("Cancel"); self.end("The archive wasn't found in the open panel.", completion); return }
                self.retry(every: 0.2, first: 0.3, times: 30, { VoiceOverSettings.utilitySheetText().contains("import") }) { alert in
                    guard alert else { self.end("VoiceOver Utility didn't ask to import.", completion); return }
                    _ = VoiceOverSettings.pressSheetButton("OK")   // (its answer isn't trusted either: the sheet going is)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        let still = VoiceOverSettings.utilitySheetText().contains("import")
                        Log.info("activity: import \(still ? "NOT confirmed: the question is still up" : "confirmed")")
                        if still { _ = VoiceOverSettings.pressSheetButton("Cancel") }
                        VoiceOverSettings.quitUtility()
                        if still { self.end("The import wasn't confirmed; VoiceOver is as it was.", completion); return }
                        self.save(Marker(installed: apps != nil, apps: apps ?? [], touched: touchedNow, hush: apps != nil ? hush : nil, masks: apps != nil ? masksNow : nil, recipe: VoiceOverActivity.recipe,
                                                 originals: apps != nil ? VoiceOverActivity.encode(originals: originalsNow) : nil))
                        try? FileManager.default.removeItem(at: file)
                        self.end(apps == nil ? "VoiceOver has every app again." : "VoiceOver is quiet in TurnOver's apps.", completion)
                    }
                }
            }
        }
    }

    /// VoiceOver's export alone, by accessibility (the settings copy; the person pressed nothing): the file, or nil.
    func export(completion: @escaping (URL?) -> Void) {
        guard !running else { completion(nil); return }
        running = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for f in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "voprefs" { try? FileManager.default.removeItem(at: f) }
        let since = Date()
        VoiceOverSettings.pointSaveSheet(at: folder)
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: VoiceOverSettings.utilityBundleID) else { running = false; completion(nil); return }
        let finish: (URL?) -> Void = { [weak self] file in
            VoiceOverSettings.quitUtility()
            self?.running = false
            Log.info("activity: export only \(file == nil ? "failed" : "done")")
            completion(file)
            self?.runPending()   // as end() does: a request kept while this ran (a review, 14 Nov 2026)
        }
        VoiceOverSettings.quitUtility()
        retry(every: 0.3, first: 0.5, times: 15, { NSRunningApplication.runningApplications(withBundleIdentifier: VoiceOverSettings.utilityBundleID).isEmpty }) { _ in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
        retry(every: 0.5, first: 1.2, times: 20, { VoiceOverSettings.utilityHasWindow() && VoiceOverSettings.pressFileMenuItem(prefix: "Export Preferences") }) { [weak self] pressed in
            guard let self, pressed else { finish(nil); return }
            self.retry(every: 0.2, first: 0.3, times: 25, { VoiceOverSettings.utilitySheet() != nil }) { sheet in
                guard sheet else { finish(nil); return }
                _ = VoiceOverSettings.pressSheetButton("Save")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { if VoiceOverSettings.utilitySheetText().contains("already exists") { _ = VoiceOverSettings.pressSheetButton("Replace") } }
                self.retry(every: 0.3, first: 0.4, times: 30, { VoiceOverSettings.newestExport(in: self.folder, since: since) != nil }) { saved in
                    guard saved, let file = VoiceOverSettings.newestExport(in: self.folder, since: since) else { finish(nil); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { finish(file) }
                }
            }
        }
    }

    private func end(_ text: String, _ completion: @escaping (String) -> Void) {
        running = false
        Log.info("activity: \(text)")
        completion(text)
        runPending()
    }

    private func runPending() {
        if let p = pending {
            pending = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.set(apps: p.apps, hush: p.hush, completion: p.completion) }
        }
    }

    private func retry(every: TimeInterval, first: TimeInterval, times: Int, _ test: @escaping () -> Bool, _ done: @escaping (Bool) -> Void) {
        var n = 0
        func go() {
            DispatchQueue.main.asyncAfter(deadline: .now() + (n == 0 ? first : every)) {
                n += 1
                if test() { done(true) } else if n < times { go() } else { done(false) }
            }
        }
        go()
    }

}
