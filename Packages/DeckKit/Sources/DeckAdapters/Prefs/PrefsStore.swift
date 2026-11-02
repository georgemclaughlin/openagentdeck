//
//  PrefsStore.swift · DeckAdapters/Prefs
//
//  The deck's own preferences, persisted. The one place that knows the
//  `UserDefaults` suite name and the themes-folder path, mirroring how the
//  config adapter owns the `~/.claude` path. That keeps "the deck never
//  writes to `~/.claude`" provable by the absence of the path elsewhere, and
//  keeps prefs out of the config adapter, whose blast radius is the user's
//  Claude Code files.
//
//  Hermetic by construction: every function takes the suite, tests pass a
//  throwaway. The value crossing this boundary is `DeckPrefs`, whose codec
//  is the core's — this file knows how to reach disk, not what a preference
//  means.
//

import Foundation
import DeckCore

public enum PrefsStore {

    /// The one suite name. Not `~/.claude`, not the config adapter's domain.
    public static let suiteName = "com.openagentdeck.prefs"
    static let key = "deckPrefs"

    /// The production suite. Provided here so the app target never names
    /// `UserDefaults` itself, which lets a scan for that symbol cover
    /// everything but this directory.
    public static var standard: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    /// A hermetic suite for tests, created here so no other module ever
    /// names `UserDefaults`.
    public static func throwaway() -> UserDefaults {
        UserDefaults(suiteName: "test-\(UUID().uuidString)") ?? .standard
    }

    public static func load(from defaults: UserDefaults) -> DeckPrefs {
        guard let data = defaults.data(forKey: key),
              let json = JSONValue.parse(data) else { return .firstRun }
        return DeckPrefs.decode(json)
    }

    public static func save(_ prefs: DeckPrefs, to defaults: UserDefaults) {
        defaults.set(data(from: prefs.encoded()), forKey: key)
    }

    // JSONValue → bytes, locally: the core's renderer belongs to the config
    // writer, and sharing it would couple two adapters through a formatting
    // detail.
    static func data(from value: JSONValue) -> Data {
        (try? JSONSerialization.data(withJSONObject: foundation(value),
                                     options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func foundation(_ value: JSONValue) -> Any {
        switch value {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map(foundation)
        case .object(let o): return o.mapValues(foundation)
        }
    }
}
