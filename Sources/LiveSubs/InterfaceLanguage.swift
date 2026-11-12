import AppKit
import Foundation

/// The language the app's own interface is drawn in. macOS reads this from the `AppleLanguages`
/// key in the app's own defaults, so the app follows the system until the user picks a language
/// here; a pick survives, and takes effect the next time the app opens (the running copy keeps
/// the strings it loaded).
enum InterfaceLanguage {
    /// The languages the interface ships in, in the order they are offered.
    static let offered: [(id: String, title: String)] = [
        ("system", L("跟随系统")),
        ("zh-Hans", L("简体中文")),
        ("en", L("English")),
        ("ja", L("日本語")),
        ("ko", L("한국어")),
    ]

    /// What the interface is drawn in right now: the pick when there is one, else the system.
    static var current: String {
        // The key holds an array; `string(forKey:)` reads nothing for one, so ask for the array.
        if let picked = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first,
           !picked.isEmpty { return picked }
        return system
    }

    /// The system language, mapped to one the app ships in.
    static var system: String {
        let first = Locale.preferredLanguages.first ?? "zh-Hans"
        if first.hasPrefix("zh") { return "zh-Hans" }
        if first.hasPrefix("ja") { return "ja" }
        if first.hasPrefix("ko") { return "ko" }
        if first.hasPrefix("en") { return "en" }
        return "zh-Hans"
    }

    /// The title of the current language, for the settings row.
    static var currentTitle: String {
        offered.first { $0.id == current }?.title ?? L("跟随系统")
    }

    /// Picks a language. Returns false when the pick is the one already in use.
    @discardableResult
    static func choose(_ id: String) -> Bool {
        guard id != current else { return false }
        let defaults = UserDefaults.standard
        if id == "system" {
            // Removing the key hands the choice back to the system.
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            defaults.set([id], forKey: "AppleLanguages")
        }
        return true
    }
}
