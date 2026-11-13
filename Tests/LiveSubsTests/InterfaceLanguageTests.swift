import Foundation
import Testing
@testable import LiveSubs

/// The interface language: which language the app's own menus and pages are drawn in.
///
/// The pick lives in the app's own defaults domain, and macOS reads it from there when the app
/// opens. These tests pin the part that was wrong: the pick has to be read from *this* app's
/// domain, because `UserDefaults` falls back to the system's list for a key the app does not
/// have — and then a pick cannot be told apart from the system language.
///
/// The tests share one defaults suite, so they take their turns.
@Suite(.serialized) struct InterfaceLanguageTests {
    /// The suite the pick is kept in while the test runs.
    private static let suite = "com.wquguru.cicada.tests.interface-language"
    /// The key the pick is written to.
    private static let key = "AppleLanguages"

    /// Points the app's own store at a suite of the test's own, for as long as the test runs.
    private func withStore(_ check: () -> Void) {
        let before = (InterfaceLanguage.defaults, InterfaceLanguage.domain)
        defer { (InterfaceLanguage.defaults, InterfaceLanguage.domain) = before }
        let defaults = UserDefaults(suiteName: Self.suite)!
        InterfaceLanguage.defaults = defaults
        InterfaceLanguage.domain = Self.suite
        check()
    }

    /// Writes a pick and reads it back the way the app does.
    private func withPick(_ pick: String?, _ check: (String?) -> Void) {
        withStore {
            if let pick { InterfaceLanguage.defaults.set([pick], forKey: Self.key) }
            else { InterfaceLanguage.defaults.removeObject(forKey: Self.key) }
            check(InterfaceLanguage.picked)
        }
    }

    @Test func aPickIsReadFromTheAppsOwnDomain() {
        withPick("ja") { picked in
            #expect(picked == "ja")
        }
    }

    @Test func noPickReadsAsNone() {
        withPick(nil) { picked in
            #expect(picked == nil)
        }
    }

    /// The bug this file exists for: the pick used to be read through `UserDefaults`, which
    /// falls back to the system's list. With no pick in the app's own domain that fallback
    /// made the system language look like a pick.
    @Test func thePickIsNotTakenFromTheSystemsList() {
        let system = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?[Self.key] as? [String]
        withPick(nil) { picked in
            // Nothing in the app's own domain: there is no pick, whatever the system says.
            #expect(picked == nil)
            if let first = system?.first { #expect(first != picked) }
        }
    }

    /// The system language is the system's, whatever the app has pinned: the interface pick
    /// must not drag the translation target with it.
    @Test func theSystemLanguageDoesNotFollowTheInterfacePick() {
        let system = systemLanguages()
        withPick("ja") { _ in
            #expect(systemLanguages() == system)
        }
    }
}
