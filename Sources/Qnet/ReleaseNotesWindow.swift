import SwiftUI
import AppKit

/// "Release Notes" — the typeset presentation of `Changelog.entries`.
/// Data stays in Changelog.swift; this file owns only presentation.
struct ReleaseNotesView: View {
    let windowRef: WindowRef?

    @State private var copied = false
    /// Shipped releases the reader has opened. The window opens on the
    /// current release alone — twenty-five fully expanded entries is
    /// fifteen thousand words of history in front of the one thing the
    /// reader came for.
    @State private var expandedIDs: Set<UUID> = []

    private var shippedEntries: [Changelog.Entry] { Array(Changelog.entries.dropFirst()) }

    private var allExpanded: Bool {
        !shippedEntries.isEmpty && expandedIDs.count >= shippedEntries.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Non-scrolling bar: the Copy control stays reachable however
            // long the changelog grows (same treatment as HelpTopicDetail).
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xl) {
                    header
                    // A frozen top entry means the running build has no
                    // in-development slot. That is a maintainer's mistake,
                    // and the instruction to fix it (prepend an entry with
                    // timestamp: nil) is Swift, not something a user can act
                    // on — so the banner is a debug-build aid only. A
                    // shipped build in that state simply shows the last
                    // release as current; `Changelog.topEntryMatchesAppVersion`
                    // is still the assertion the maintainer can grep for.
                    #if DEBUG
                    if !Changelog.topEntryMatchesAppVersion {
                        mismatchWarning
                    }
                    #endif
                    ForEach(Array(Changelog.entries.enumerated()), id: \.element.id) { idx, entry in
                        if idx == 0 {
                            ReleaseNotesEntryView(entry: entry, isCurrent: true)
                        } else {
                            DisclosureGroup(isExpanded: expansion(of: entry.id)) {
                                ReleaseNotesEntryView(entry: entry, isCurrent: false,
                                                      showsHeader: false)
                                    .padding(.top, DS.Spacing.s)
                            } label: {
                                collapsedLabel(entry)
                            }
                            .accessibilityLabel("Version \(entry.version), \(BuildStamp.humanReadable(entry.timestamp ?? AppVersion.buildTimestamp))")
                        }
                        if idx < Changelog.entries.count - 1 {
                            DSRule()
                        }
                    }
                }
                .padding(DS.Spacing.xl)
                .frame(maxWidth: DS.Layout.readingMeasure + 2 * DS.Spacing.xl, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.Color.fieldBackground)
        .frame(minWidth: DS.Layout.Window.auxMinWidth,
               minHeight: DS.Layout.Window.auxMinHeight)
    }

    /// Header row of a collapsed, shipped release.
    private func collapsedLabel(_ entry: Changelog.Entry) -> some View {
        let stamp = entry.timestamp ?? AppVersion.buildTimestamp
        return HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text("Version \(entry.version)")
                .font(DS.Font.labelEmphasis)
                .monospacedDigit()
            Text("—")
                .foregroundStyle(DS.Color.textTertiary)
            Text(BuildStamp.humanReadable(stamp))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.textSecondary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func expansion(of id: UUID) -> Binding<Bool> {
        Binding(
            get: { expandedIDs.contains(id) },
            set: { open in
                if open { expandedIDs.insert(id) } else { expandedIDs.remove(id) }
            }
        )
    }

    private var topBar: some View {
        HStack(spacing: DS.Spacing.s) {
            Label("\(Changelog.entries.count) releases", systemImage: DS.Symbol.versionHistory)
                .font(DS.Font.chrome)
                .foregroundStyle(DS.Color.textSecondary)
                .monospacedDigit()
                .accessibilityLabel("\(Changelog.entries.count) releases listed")
            if !shippedEntries.isEmpty {
                Button(allExpanded ? "Collapse All" : "Expand All") {
                    withAnimation(DS.Motion.standard) {
                        expandedIDs = allExpanded ? [] : Set(shippedEntries.map(\.id))
                    }
                }
                .buttonStyle(.link)
                .help(allExpanded
                      ? "Collapse every shipped release again"
                      : "Open every shipped release below the current one")
                .accessibilityLabel(allExpanded ? "Collapse all releases" : "Expand all releases")
            }
            Spacer()
            Button {
                copyCurrentEntry()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? DS.Symbol.checkmark : DS.Symbol.copy)
                    .frame(minWidth: DS.Layout.buttonMinWidth)
            }
            .controlSize(.regular)
            .help("Copy this release's notes as plain text — the entry at the top only, not the whole history")
            .accessibilityLabel(copied ? "Copied current release notes" : "Copy current release notes")
            .dsAnimation(DS.Motion.quick, value: copied)
        }
        // The one chrome for a bar above scrolling content; the horizontal
        // inset matches the page text below it.
        .dsChromeBar(.bottom, horizontal: DS.Spacing.xl, vertical: DS.Spacing.s)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text("Release Notes")
                .font(DS.Font.largeTitle)
                .accessibilityAddTraits(.isHeader)
            Text("Qnet \(AppVersion.version)")
                .font(DS.Font.title3)
                .foregroundStyle(DS.Color.textSecondary)
                .monospacedDigit()
        }
    }

    /// Debug builds only (see the `#if DEBUG` at the call site).
    private var mismatchWarning: some View {
        Label {
            Text("Debug build note: the newest entry below is frozen, so this build (\(AppVersion.fullVersion)) has no in-development entry. Prepend one with timestamp: nil in Changelog.swift before the next release.")
                .font(DS.Font.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: DS.Symbol.warning)
                .foregroundStyle(DS.Color.warningText)
        }
        .padding(DS.Spacing.s + DS.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(DS.Color.tintFill(DS.Color.warning))
        )
    }

    private func copyCurrentEntry() {
        guard let entry = Changelog.entries.first else { return }
        let text = ReleaseNotesEntryView.plainText(entry: entry)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

struct ReleaseNotesEntryView: View {
    let entry: Changelog.Entry
    let isCurrent: Bool
    /// False inside a DisclosureGroup, whose label already prints the
    /// version and the date.
    var showsHeader: Bool = true

    /// For the live in-development entry (timestamp == nil) both the
    /// version and the build stamp track the running binary.
    private var isLive: Bool { entry.timestamp == nil }
    private var displayedVersion: String { isLive ? AppVersion.version : entry.version }
    private var stamp: String { entry.timestamp ?? AppVersion.buildTimestamp }

    static func plainText(entry: Changelog.Entry) -> String {
        let isLive = entry.timestamp == nil
        let version = isLive ? AppVersion.version : entry.version
        let stamp = entry.timestamp ?? AppVersion.buildTimestamp
        var s = "Qnet \(version) — \(BuildStamp.humanReadable(stamp)) (build \(version).\(stamp))\n\n"
        for note in entry.notes { s += "• \(note)\n" }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s + DS.Spacing.xs) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s + DS.Spacing.xs) {
                    Text("Version \(displayedVersion)")
                        .font(DS.Font.sheetTitle)
                        .monospacedDigit()
                        .accessibilityAddTraits(.isHeader)
                    if isCurrent {
                        DSBadge(text: isLive ? "In development" : "Current",
                                tint: DS.Color.accent, emphasis: .tinted)
                            .accessibilityLabel(isLive ? "In development" : "Current release")
                    }
                }
                Text(BuildStamp.humanReadable(stamp))
                    .font(DS.Font.subheadline)
                    .foregroundStyle(DS.Color.textSecondary)
                    .monospacedDigit()
                    .help("Build \(displayedVersion).\(stamp)")
            }

            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                ForEach(Array(entry.notes.enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                        Text("•")
                            .foregroundStyle(DS.Color.textSecondary)
                            .frame(width: DS.Layout.bulletWidth, alignment: .trailing)
                        Text(note)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, DS.Spacing.xs)
        }
        .textSelection(.enabled)
    }
}

// MARK: - Window

@MainActor
enum ReleaseNotesWindow {
    private static var retained: NSWindow?

    static func show() {
        if let w = retained {
            AuxiliaryWindow.present(w)
            return
        }
        let window = AuxiliaryWindow.make(
            id: "release-notes",
            title: "Release Notes",
            contentSize: DS.Layout.Window.auxContent,
            minSize: DS.Layout.Window.auxMin,
            fullScreenAuxiliary: true,
            frameKey: "QnetReleaseNotesWindow"
        ) { ref in
            ReleaseNotesView(windowRef: ref)
        }
        retained = window
        AuxiliaryWindow.present(window)
    }
}
