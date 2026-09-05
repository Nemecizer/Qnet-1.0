import Foundation

/// On-disk safety net for the in-canvas parameter editor. After every
/// node-parameter mutation (rename, distribution change, buffer size,
/// number of servers, station picture, per-class service distribution)
/// the editor records the affected node into a per-session JSON file
/// under the user's temp directory. Before the parameter editor opens
/// for any node, the cache is consulted and its entry (if newer than the
/// in-memory copy) is pasted back over the model — guaranteeing the user
/// always edits the most recent saved values, even if some upstream code
/// path has stale snapshots.
///
/// Scope: one cache file per `NetworkEditorModel` instance (i.e. one per
/// open tab in the current process). Cleared when a fresh document is
/// loaded into the editor (`loadNetwork(document:)`) or when `clear()` is
/// called explicitly. The OS sweeps `NSTemporaryDirectory()` so abandoned
/// files don't accumulate across reboots.
@MainActor
final class ParameterCache {
    /// Per-node parameter snapshot. Position, links, and id are NOT
    /// stored here; the cache is parameters-only so it doesn't fight
    /// drag/move operations or link rewiring tracked by the model.
    struct Overlay: Codable, Equatable {
        var name: String
        var bufferSize: Int
        var numberOfServers: Int
        var distribution: QueueDistribution
        var distributionParameters: String
        var serviceDistributions: [Int: ServiceDistributionConfig]
        var picture: StationPicture
        /// Wall-clock seconds since 1970, written every time the entry
        /// is recorded. Used by `apply(to:)` so we never overwrite a
        /// node whose in-memory state already matches.
        var recordedAt: TimeInterval

        init(from node: NetworkNode) {
            self.name = node.name
            self.bufferSize = node.bufferSize
            self.numberOfServers = node.numberOfServers
            self.distribution = node.distribution
            self.distributionParameters = node.distributionParameters
            self.serviceDistributions = node.serviceDistributions
            self.picture = node.picture
            self.recordedAt = Date().timeIntervalSince1970
        }

        /// Returns true if `node`'s parameter fields already match this
        /// overlay (so we can skip writing).
        func matches(_ node: NetworkNode) -> Bool {
            return name == node.name
                && bufferSize == node.bufferSize
                && numberOfServers == node.numberOfServers
                && distribution == node.distribution
                && distributionParameters == node.distributionParameters
                && serviceDistributions == node.serviceDistributions
                && picture == node.picture
        }

        /// Copies the overlay's parameter fields onto `node`. Leaves
        /// `id`, `kind`, `position` untouched.
        func apply(to node: inout NetworkNode) {
            node.name = name
            node.bufferSize = bufferSize
            node.numberOfServers = numberOfServers
            node.distribution = distribution
            node.distributionParameters = distributionParameters
            node.serviceDistributions = serviceDistributions
            node.picture = picture
        }
    }

    private let url: URL
    /// In-memory cache of the on-disk dictionary, kept so reads don't
    /// hit the filesystem for every node visit. Reloaded lazily.
    private var cached: [UUID: Overlay]?

    init(editorID: UUID) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("qnet-paramcache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        self.url = dir.appendingPathComponent("\(editorID.uuidString).json")
    }

    /// Persists the parameters of `node` to disk. No-op if the on-disk
    /// entry already matches (avoids redundant writes during typing).
    func record(_ node: NetworkNode) {
        var dict = loadDict()
        let overlay = Overlay(from: node)
        if let existing = dict[node.id], existing.matches(node) {
            return
        }
        dict[node.id] = overlay
        writeDict(dict)
    }

    /// Returns any stored overlay for `nodeID`, or nil if none.
    func overlay(for nodeID: UUID) -> Overlay? {
        return loadDict()[nodeID]
    }

    /// Removes the cache file entirely. Call on fresh document load.
    func clear() {
        cached = nil
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Internals

    private func loadDict() -> [UUID: Overlay] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([UUID: Overlay].self, from: data)
        else {
            cached = [:]
            return [:]
        }
        cached = dict
        return dict
    }

    private func writeDict(_ dict: [UUID: Overlay]) {
        cached = dict
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(dict) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
