import Foundation

/// The one place the numeric suffix of a node name is parsed.
///
/// Every exporter numbers stations, sources and buffers by the digits in
/// their name ("S2" → 2, "Src10" → 10), and the solvers return ρ / Γ /
/// mean vectors in exactly that order. That rule used to be
/// re-implemented as a private `sourceIndex` / `stationIndex` in each of
/// `QNAExporter`, `SRBMExporter`, `BNASRBMExporter`, `NetworkExporter`,
/// `BNANetworkExporter` and `NetworkEditorModel` — ten identical bodies
/// that had to stay in lockstep or the flag-bar popover would label a
/// solver result with the wrong station. They all call this now.
///
/// `sortIndex` keeps the historical behaviour of those copies exactly:
/// a name with no digits sorts last (`Int.max`). `numericSuffix` is the
/// honest form — it returns nil for such a name so callers that *label*
/// a result vector can tell that the order is not well defined.
enum NodeNaming {

    /// The digit run inside a node name, or nil when there is none
    /// ("CPU", "Disk"). "S2" → 2, "Src10" → 10. Identical to the
    /// `Int(name.drop(while: { !$0.isNumber }))` the exporters used, so
    /// no existing file changes its export order.
    static func numericSuffix(_ name: String) -> Int? {
        Int(name.drop(while: { !$0.isNumber }))
    }

    /// Sort key used by every exporter: names without digits sort last,
    /// preserving the pre-existing ordering byte for byte.
    static func sortIndex(_ name: String) -> Int {
        numericSuffix(name) ?? Int.max
    }

    /// True when `names` do NOT determine a unique export order: some
    /// name carries no numeric suffix, or two names carry the same one.
    /// A caller that labels an index-aligned solver vector must fall back
    /// to positional names ("S1 … Sn") in that case rather than print a
    /// confident, possibly wrong, name against a number.
    static func orderIsAmbiguous(_ names: [String]) -> Bool {
        let suffixes = names.map(numericSuffix)
        if suffixes.contains(where: { $0 == nil }) { return true }
        return Set(suffixes.compactMap { $0 }).count != names.count
    }
}
