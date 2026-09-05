// Version pinned for the Qnet 0.90.34 source distribution.
// Rebuilding the application does not increment this version.

enum AppVersion {
    /// User-requested release version.
    static let version = "0.90.34"

    /// Build wall-clock in MM.DD.YYYY.HHMM (24-h local time).
    static let buildTimestamp = "09.04.2026.1534"

    /// Concatenated identifier shown in About / Changelog windows.
    static let fullVersion = "\(version).\(buildTimestamp)"
}
