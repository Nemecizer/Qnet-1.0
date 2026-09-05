import Foundation

// MARK: - Help linkage
//
// In the app GUIKit was extracted from, `HelpTopic` was a large domain enum —
// one case per analysis method — and the sheet called that app's help window
// directly. Neither belongs in a reusable kit, but the *affordance* does: the
// single most useful thing a dialog can offer a confused user is a button that
// opens the documentation at the right page, and a kit that drops it loses a
// real feature.
//
// So the kit keeps the seam and gives up the specifics. A topic is an opaque
// identifier plus the title to show; the host app decides what a topic means
// and how to present it.

/// A documentation destination a DS surface can link to.
///
/// Construct these wherever your help content is defined — typically one
/// `static let` per page, so call sites name a topic instead of spelling a
/// string, and a renamed page is a compile error rather than a dead link:
///
/// ```swift
/// extension HelpTopic {
///     static let exportOptions = HelpTopic("export-options", windowTitle: "Export Options")
///     static let runParameters = HelpTopic("run-parameters", windowTitle: "Run Parameters")
/// }
/// ```
struct HelpTopic: Hashable, Identifiable, Sendable {
    /// Stable identifier your presenter resolves to a page. Keep it stable
    /// across releases: it may end up in a saved window state or a URL.
    let id: String

    /// Human-readable page name. It is spoken by VoiceOver and appears in the
    /// help button's tooltip, so write it as the page's own title, not as a
    /// sentence.
    let windowTitle: String

    init(_ id: String, windowTitle: String) {
        self.id = id
        self.windowTitle = windowTitle
    }
}

/// The one hook a host app installs to make every `helpTopic:` in the kit live.
///
/// Set `show` once at launch. Until you do, help buttons are simply not drawn —
/// a sheet that declares a topic degrades to a sheet without a help button
/// rather than to a button that does nothing, because a control that visibly
/// does nothing is worse than an absent one.
///
/// ```swift
/// // In your App's init:
/// HelpPresenter.show = { topic in MyHelpWindow.show(topic: topic) }
/// ```
enum HelpPresenter {
    /// Presents the given topic. Called on the main actor from DS surfaces.
    @MainActor static var show: ((HelpTopic) -> Void)?

    /// True when a host has installed a presenter. DS surfaces consult this
    /// before drawing a help affordance.
    @MainActor static var isAvailable: Bool { show != nil }
}
