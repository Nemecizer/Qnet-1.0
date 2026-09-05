import Foundation

// MARK: - Host configuration
//
// The three or four places the kit needs to know your app's name are gathered
// here, so adopting GUIKit is one assignment rather than a find-and-replace
// across twenty files.
//
// Everything has a working default. You can ship without touching this; you
// just get windows whose saved-frame keys say "App" instead of your app's name.
// Set it once, early — before any window is created — because these values end
// up in UserDefaults keys and NSWindow identifiers, and changing them later
// orphans the frames your users have already positioned.
//
// ```swift
// @main struct MyApp: App {
//     init() { GUIKitConfig.applicationName = "Cartograph" }
//     // ...
// }
// ```

enum GUIKitConfig {
    /// Short, code-safe application name. Used to namespace window autosave
    /// keys and AppKit window identifiers, so two apps built on this kit on the
    /// same Mac never collide in `UserDefaults`.
    ///
    /// Letters and digits only — it is embedded in defaults keys and reverse-DNS
    /// style identifiers. "My App 2" works but reads badly in a defaults dump;
    /// "MyApp2" is better.
    nonisolated(unsafe) static var applicationName: String = "App"

    /// Lowercased form used for AppKit identifier prefixes (`<app>.aux.`).
    static var identifierNamespace: String {
        applicationName.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Environment variable that makes the kit print its keyboard-shortcut
    /// audit at launch. Derived from the app name so two kit-based apps in one
    /// shell do not trip each other's diagnostics.
    static var menuAuditEnvironmentKey: String {
        applicationName.uppercased().filter { $0.isLetter || $0.isNumber } + "_MENU_AUDIT"
    }

    /// UserDefaults key for a saved window frame, given a stable window id.
    static func frameKey(for id: String) -> String {
        "\(applicationName)Window.\(id)"
    }
}
