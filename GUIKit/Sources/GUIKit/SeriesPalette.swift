import SwiftUI

// MARK: - Categorical series palette
//
// Any app that colours a *set of peers* — customer classes, data series, tags,
// users, tracks — needs two things the DS signal colours cannot give it:
// arbitrarily many visually distinct hues, and a name for each one.
//
// This is deliberately separate from `DS.Color`'s four signal colours. A signal
// colour MEANS something (success, warning, danger, info); a series colour means
// only "this is a different one from that one". Reusing danger-red for series 1
// makes a chart say "error" when it means "class 1", which is why the two live
// in different namespaces and neither is spelled with the other's tokens.
//
// Override `colorProvider` / `labelProvider` at launch if your domain has its
// own names or brand hues; leave them alone for a sane default.

enum SeriesPalette {
    /// Fixed hues for the first eight series. Fixed rather than generated so
    /// that colours stay stable across releases: a saved document, a published
    /// screenshot and a printed figure must not change hue because someone
    /// added a ninth series.
    static let base: [Color] = [
        .red, .blue, .green, .orange, .purple, .cyan, .pink, .yellow,
    ]

    /// Host override for colour. Set once at launch if your domain owns a
    /// palette; nil uses `base` plus the golden-angle overflow below.
    @MainActor static var colorProvider: ((Int) -> Color)?

    /// Host override for the spoken/printed name of a series. Nil yields
    /// "Series 1", "Series 2", … — override to say "Class 1" or "Channel A".
    @MainActor static var labelProvider: ((Int) -> String)?

    /// Colour for any series index, however large.
    ///
    /// Indices past `base` are generated on a golden-angle walk of the hue
    /// wheel, which keeps *adjacent* indices far apart in hue — the property
    /// that matters, since adjacent series are what a reader compares. The
    /// saturation and brightness alternate slightly so a long run does not
    /// read as one flat band of pastels.
    @MainActor static func color(for index: Int) -> Color {
        if let colorProvider { return colorProvider(index) }
        if index < base.count { return base[index] }
        let overflow = index - base.count
        let hue = Double(overflow) * 0.61803398875   // golden angle, in turns
        let h = hue - floor(hue)
        let sat = overflow % 2 == 0 ? 0.72 : 0.88
        let val = overflow % 3 == 0 ? 0.82 : 0.95
        return Color(hue: h, saturation: sat, brightness: val)
    }

    /// Human-readable name for a series. Used as the VoiceOver label and as the
    /// badge's text, so it must read as a name, not as a sentence.
    @MainActor static func label(for index: Int) -> String {
        if let labelProvider { return labelProvider(index) }
        return "Series \(index + 1)"
    }
}
