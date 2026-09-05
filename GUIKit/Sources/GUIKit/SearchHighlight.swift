import SwiftUI

/// The one search-hit treatment for text the user searched: every
/// case-insensitive occurrence of the query is washed in the accent tint
/// (`DS.Color.tintFill(DS.Color.accent)`). The Status pane's rows, the
/// AI transcript's prose, code wells and tool rows all call this, so a
/// hit looks the same in every searchable surface of the window.
extension AttributedString {
    func highlightingMatches(of query: String) -> AttributedString {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return self }
        var out = self
        var cursor = out.startIndex
        while cursor < out.endIndex,
              let range = out[cursor..<out.endIndex].range(of: q, options: [.caseInsensitive]) {
            out[range].backgroundColor = DS.Color.tintFill(DS.Color.accent)
            cursor = range.upperBound
        }
        return out
    }
}

extension String {
    /// `AttributedString(self)` with the query's occurrences highlighted.
    func highlightingMatches(of query: String) -> AttributedString {
        AttributedString(self).highlightingMatches(of: query)
    }
}
