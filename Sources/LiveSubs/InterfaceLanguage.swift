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

    /// The language the user picked here, or nil when the app follows the system.
    ///
    /// Read from the app's own domain only: `UserDefaults` falls back to the system's list
    /// for a key the app does not have, and then a pick could not be told apart from the
    /// system language.
    static var picked: String? {
        guard let list = defaults.persistentDomain(forName: domain)?["AppleLanguages"] as? [String],
              let first = list.first, !first.isEmpty else { return nil }
        return first
    }

    /// The system language, mapped to one the app ships in.
    ///
    /// Read from the global domain: `Locale.preferredLanguages` already carries the app's own
    /// pick, so it cannot tell the system apart from the choice made here.
    static var system: String {
        let list = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["AppleLanguages"] as? [String]
        return shipped(list?.first ?? "zh-Hans")
    }

    /// What the interface is drawn in right now: the pick when there is one, else the system.
    static var current: String { picked.map(shipped) ?? system }

    /// The title of the current language, for the settings row: the language itself, or the
    /// system language when the app follows it.
    static var currentTitle: String {
        guard let picked else { return L("跟随系统（\(title(of: system))）") }
        return title(of: shipped(picked))
    }

    /// The name of a language, as the menu offers it.
    static func title(of id: String) -> String {
        offered.first { $0.id == id }?.title ?? L("简体中文")
    }

    /// Picks a language. Returns false when the pick is the one already in use.
    @discardableResult
    static func choose(_ id: String) -> Bool {
        if id == "system" {
            // Removing the key hands the choice back to the system.
            guard picked != nil else { return false }
            defaults.removeObject(forKey: "AppleLanguages")
        } else {
            guard picked != id else { return false }
            defaults.set([id], forKey: "AppleLanguages")
        }
        return true
    }

    /// Where the pick is kept: the app's own defaults, under its own bundle id.
    ///
    /// A test points these at a suite of its own, because a test process has no bundle id.
    static var defaults: UserDefaults = .standard
    static var domain: String = Bundle.main.bundleIdentifier ?? ""

    /// Maps a language identifier ("zh-Hans-CN", "en-US") to one the interface ships in.
    private static func shipped(_ id: String) -> String {
        if id.hasPrefix("zh") { return "zh-Hans" }
        if id.hasPrefix("ja") { return "ja" }
        if id.hasPrefix("ko") { return "ko" }
        if id.hasPrefix("en") { return "en" }
        return "zh-Hans"
    }
}
