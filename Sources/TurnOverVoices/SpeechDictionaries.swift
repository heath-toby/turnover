// SPDX-License-Identifier: GPL-3.0-or-later
// Speech dictionaries (NVDA's: a voice's, then the default; 14 Nov 2026, Oliver: "in NVDA's style"), shared by
// TurnOver, which reads them as it speaks, and the Settings window, which edits them. Here because both use it: which
// files there are and in what order they apply, and the pronunciations made in System Settings (Accessibility, Read &
// Speak, Pronunciation), which TurnOver uses after its own.
//
// Three kinds of dictionary, each a text file of `word = say` lines in ~/Library/Application Support/TurnOver:
//     pronunciations.txt                          the default: every voice and language
//     pronunciations/language-de.txt              one language's, by its base code
//     pronunciations/voice-<identifier>.txt       one voice's
// Applied as NVDA does: the voice's, then the language's, then the default; each to the text the one before left.
//
// The words in System Settings' list can be names from the user's contacts: they are never logged or printed, only
// counted (privacy, 14 Nov 2026).
import Foundation

public enum SpeechDictionaries {
    public enum Scope: Hashable, Sendable {
        case standard
        case language(String)
        case voice(String)

        /// The scope as text, for the TurnOver menu to ask the Settings window for it: "default", "language-de",
        /// "voice-com.apple.voice.premium.en-GB.Malcolm".
        public var id: String {
            switch self {
            case .standard: return "default"
            case .language(let code): return "language-" + SpeechDictionaries.baseLanguage(code)
            case .voice(let identifier): return "voice-" + identifier
            }
        }
        public init?(id: String) {
            if id == "default" { self = .standard }
            else if id.hasPrefix("language-"), id.count > 9 { self = .language(String(id.dropFirst(9))) }
            else if id.hasPrefix("voice-"), id.count > 6 { self = .voice(String(id.dropFirst(6))) }
            else { return nil }
        }
    }

    /// "en-GB" → "en".
    public static func baseLanguage(_ code: String) -> String {
        String(code.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
    }

    /// TurnOver's folder in Application Support.
    public static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TurnOver", isDirectory: true)
    }

    /// A dictionary's file, relative to TurnOver's folder. A voice's identifier keeps letters, digits, dots and dashes;
    /// anything else (the colon of "external:af_heart", a slash) becomes an underscore, so it is always one file name.
    public static func fileName(_ scope: Scope) -> String {
        func safe(_ s: String) -> String {
            String(String.UnicodeScalarView(s.unicodeScalars.map { c -> Unicode.Scalar in
                c.isASCII && (CharacterSet.alphanumerics.contains(c) || c == "." || c == "-") ? c : "_"
            }))
        }
        switch scope {
        case .standard: return "pronunciations.txt"
        case .language(let code): return "pronunciations/language-\(safe(baseLanguage(code))).txt"
        case .voice(let identifier): return "pronunciations/voice-\(safe(identifier)).txt"
        }
    }
    public static func fileURL(_ scope: Scope, in folder: URL = SpeechDictionaries.folder) -> URL {
        folder.appendingPathComponent(fileName(scope))
    }

    /// The dictionaries for an utterance, in the order they apply: the voice's, the language's, the default.
    public static func scopes(voice: String?, language: String?) -> [Scope] {
        var out: [Scope] = []
        if let voice, !voice.isEmpty { out.append(.voice(voice)) }
        if let language, !baseLanguage(language).isEmpty { out.append(.language(language)) }
        out.append(.standard)
        return out
    }

    // MARK: System Settings' pronunciations

    /// System Settings' list: com.apple.SpeakSelection, key CustomPronunciationSubstitutions, an NSKeyedArchiver
    /// archive of an array of TTSSubstitution objects (macOS 27.2, 14 Nov 2026). Read only, never written.
    public static var systemPreferencesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.SpeakSelection.plist")
    }
    public static let systemPreferencesKey = "CustomPronunciationSubstitutions"

    public struct SystemEntry: Equatable, Sendable {
        public var original: String
        public var replacement: String?
        /// The pronunciation in IPA, when it was given as sounds (Listen, or typed phonemes).
        public var phonemes: String?
        public var active: Bool
        public var ignoreCase: Bool
        /// Language codes ("en-GB"); empty for every language.
        public var languages: [String]
        /// Voice identifiers; empty for every voice.
        public var voiceIds: [String]
        public var appliesToAllApps: Bool
        public var bundleIdentifiers: [String]
        public init(original: String, replacement: String? = nil, phonemes: String? = nil, active: Bool = true, ignoreCase: Bool = true,
                    languages: [String] = [], voiceIds: [String] = [], appliesToAllApps: Bool = true, bundleIdentifiers: [String] = []) {
            self.original = original; self.replacement = replacement; self.phonemes = phonemes; self.active = active; self.ignoreCase = ignoreCase
            self.languages = languages; self.voiceIds = voiceIds; self.appliesToAllApps = appliesToAllApps; self.bundleIdentifiers = bundleIdentifiers
        }
        /// Whether it is used for speech in this voice and language, in this app. A language matches by its base
        /// ("en-GB" for an en-US voice too): the list's languages are the Mac's, the voice's may be another dialect.
        public func applies(voice: String?, language: String?, app: String?) -> Bool {
            guard active, !original.isEmpty else { return false }
            if !languages.isEmpty {
                guard let language, languages.contains(where: { baseLanguage($0) == baseLanguage(language) }) else { return false }
            }
            if !voiceIds.isEmpty {
                guard let voice, voiceIds.contains(voice) else { return false }
            }
            if !appliesToAllApps, !bundleIdentifiers.isEmpty {
                guard let app, bundleIdentifiers.contains(app) else { return false }
            }
            return true
        }
    }

    /// The entries of System Settings' preferences file (its whole contents); nil if it can't be read as one.
    public static func systemEntries(fromPreferences data: Data) -> [SystemEntry]? {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        guard let archive = plist[systemPreferencesKey] as? Data else { return [] }
        return systemEntries(fromArchive: archive)
    }

    /// The entries of the archived list; nil if it can't be decoded. Unknown classes inside become empty objects
    /// (a later macOS adding one doesn't lose the rest), and a failure is an error, never an exception.
    public static func systemEntries(fromArchive data: Data) -> [SystemEntry]? {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        u.requiresSecureCoding = false
        u.decodingFailurePolicy = .setErrorAndReturn
        u.setClass(SystemPronunciationRecord.self, forClassName: "TTSSubstitution")
        let stand = UnknownClassStandIn()
        u.delegate = stand
        let root = try? u.decodeTopLevelObject(forKey: NSKeyedArchiveRootObjectKey)
        u.finishDecoding()
        guard let list = root as? NSArray else { return nil }
        return list.compactMap { ($0 as? SystemPronunciationRecord)?.entry }
    }
}

/// A TTSSubstitution, as decoded (and, for the tests, archived under that name). Read with the keys System Settings
/// writes: originalString, replacementString, phonemes, active, ignoreCase, languages, voiceIds, appliesToAllApps,
/// bundleIdentifiers (uuid and replacementRange are not needed).
@objc(TOSystemPronunciationRecord)
public final class SystemPronunciationRecord: NSObject, NSCoding {
    public var originalString: String?
    public var replacementString: String?
    public var phonemes: String?
    public var active = true
    public var ignoreCase = true
    public var languages: [String] = []
    public var voiceIds: [String] = []
    public var appliesToAllApps = true
    public var bundleIdentifiers: [String] = []

    public override init() { super.init() }

    public required init?(coder: NSCoder) {
        func string(_ key: String) -> String? { (coder.decodeObject(forKey: key) as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func strings(_ key: String) -> [String] {
            switch coder.decodeObject(forKey: key) {
            case let set as NSSet: return set.allObjects.compactMap { $0 as? String }
            case let array as NSArray: return array.compactMap { $0 as? String }
            case let one as String: return one.isEmpty ? [] : [one]
            default: return []
            }
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool { coder.containsValue(forKey: key) ? coder.decodeBool(forKey: key) : fallback }
        originalString = string("originalString")
        replacementString = string("replacementString")
        phonemes = string("phonemes")
        active = bool("active", true)
        ignoreCase = bool("ignoreCase", true)
        languages = strings("languages")
        voiceIds = strings("voiceIds")
        appliesToAllApps = bool("appliesToAllApps", true)
        bundleIdentifiers = strings("bundleIdentifiers")
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(originalString, forKey: "originalString")
        coder.encode(replacementString, forKey: "replacementString")
        coder.encode(phonemes, forKey: "phonemes")
        coder.encode(active, forKey: "active")
        coder.encode(ignoreCase, forKey: "ignoreCase")
        coder.encode(NSSet(array: languages), forKey: "languages")
        coder.encode(voiceIds.isEmpty ? nil : NSSet(array: voiceIds), forKey: "voiceIds")
        coder.encode(appliesToAllApps, forKey: "appliesToAllApps")
        coder.encode(bundleIdentifiers.isEmpty ? nil : NSSet(array: bundleIdentifiers), forKey: "bundleIdentifiers")
        coder.encode(NSUUID(), forKey: "uuid")
    }

    var entry: SpeechDictionaries.SystemEntry? {
        guard let originalString else { return nil }
        return SpeechDictionaries.SystemEntry(original: originalString, replacement: replacementString, phonemes: phonemes, active: active,
                                              ignoreCase: ignoreCase, languages: languages, voiceIds: voiceIds,
                                              appliesToAllApps: appliesToAllApps, bundleIdentifiers: bundleIdentifiers)
    }
}

/// Whatever the archive holds that isn't known here, decoded as nothing.
@objc(TOUnknownArchivedObject)
final class UnknownArchivedObject: NSObject, NSCoding {
    override init() { super.init() }
    required init?(coder: NSCoder) { super.init() }
    func encode(with coder: NSCoder) {}
}

final class UnknownClassStandIn: NSObject, NSKeyedUnarchiverDelegate {
    func unarchiver(_ unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String, originalClasses classNames: [String]) -> AnyClass? {
        UnknownArchivedObject.self
    }
}
