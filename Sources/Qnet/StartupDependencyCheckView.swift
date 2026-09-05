import AppKit
import SwiftUI

/// Launch-time dependency report.  Checks run one at a time so the active
/// package is visible instead of the window appearing only after all work has
/// completed.  The sheet never installs or changes anything itself.
struct StartupDependencyCheckView: View {
    @ObservedObject var checker: StartupDependencyChecker
    let onContinue: () -> Void
    @State private var copiedCommands = false

    private var headerSubtitle: String {
        if let current = checker.currentRequirement {
            return "Checking \(current.name)…"
        }
        if checker.hasRun {
            return checker.attentionCount == 0
                ? "Every checked dependency is ready."
                : "\(checker.attentionCount) item\(checker.attentionCount == 1 ? "" : "s") need attention."
        }
        return "Preparing the package checklist…"
    }

    private var commandText: String {
        ([checker.brewInstallCommand].compactMap { $0 }
            + checker.supplementalInstallCommands)
            .joined(separator: "\n")
    }

    private var hasBundledAttention: Bool {
        checker.items.contains { item in
            item.requirement.scope == .bundled && item.status.needsAttention
        }
    }

    var body: some View {
        DSSheet(size: .tall) {
            DSSheetHeader("Qnet Startup Check", subtitle: headerSubtitle) {
                DSSheetSymbolGlyph(
                    fill: DS.Color.tintFill(DS.Color.info),
                    systemImage: DS.Symbol.testSet,
                    tint: DS.Color.infoText
                )
            }
        } content: {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                progressSummary
                ScrollView {
                    LazyVStack(spacing: DS.Spacing.s) {
                        ForEach(checker.items) { item in
                            StartupDependencyRow(item: item)
                        }
                    }
                }
                if checker.hasRun && checker.attentionCount > 0 {
                    installGuidance
                }
            }
            .padding(DS.Spacing.l)
            .background(DS.Color.surface)
        } footer: {
            DSSheetFooter(
                cancelTitle: "Recheck",
                confirmTitle: "Continue",
                canConfirm: !checker.isRunning,
                cancelHelp: "Check every dependency again",
                confirmHelp: "Close the startup check and use Qnet",
                blockedHelp: "Wait for the dependency checks to finish",
                onCancel: {
                    guard !checker.isRunning else { return }
                    Task { await checker.rerun() }
                },
                onConfirm: onContinue
            ) {
                Text(footerSummary)
                    .font(DS.Font.caption)
                    .foregroundStyle(footerTint)
                    .lineLimit(2)
            }
            .disabled(checker.isRunning)
        }
        .interactiveDismissDisabled(checker.isRunning)
        .task { await checker.runIfNeeded() }
    }

    private var footerSummary: String {
        if checker.isRunning { return "Checking packages…" }
        if checker.attentionCount == 0 {
            return "\(checker.availableCount) of \(checker.items.count) checks passed."
        }
        return "\(checker.availableCount) ready; \(checker.attentionCount) need attention. Optional items do not prevent Qnet from opening."
    }

    private var footerTint: Color {
        if checker.isRunning { return DS.Color.textSecondary }
        return checker.attentionCount == 0 ? DS.Color.successText : DS.Color.warningText
    }

    private var progressSummary: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            Group {
                if checker.isRunning {
                    ProgressView()
                        .controlSize(.small)
                } else if checker.hasRun && checker.attentionCount == 0 {
                    Image(systemName: DS.Symbol.success)
                        .foregroundStyle(DS.Color.successText)
                } else if checker.hasRun {
                    Image(systemName: DS.Symbol.warning)
                        .foregroundStyle(DS.Color.warningText)
                } else {
                    Image(systemName: DS.Symbol.info)
                        .foregroundStyle(DS.Color.infoText)
                }
            }
            .font(DS.Font.headline)
            .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if let current = checker.currentRequirement {
                    Text("Checking \(current.name)…")
                        .font(DS.Font.sectionTitle)
                    if let previous = lastCheckedItem {
                        Label(
                            "Just checked: \(previous.requirement.name)",
                            systemImage: previous.status.isAvailable
                                ? DS.Symbol.success : DS.Symbol.warning
                        )
                            .font(DS.Font.caption)
                            .foregroundStyle(
                                previous.status.isAvailable
                                    ? DS.Color.successText : DS.Color.warningText
                            )
                    }
                } else if checker.hasRun {
                    Text(checker.attentionCount == 0 ? "Startup check complete" : "Startup check complete with notes")
                        .font(DS.Font.sectionTitle)
                    Text("Green checkmarks identify packages and bundled components that are ready.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                } else {
                    Text("Preparing checks…")
                        .font(DS.Font.sectionTitle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.subtleFill)
        )
        .accessibilityElement(children: .combine)
    }

    private var lastCheckedItem: StartupDependencyItem? {
        guard let id = checker.lastCheckedID else { return nil }
        return checker.items.first(where: { $0.id == id })
    }

    private var installGuidance: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(guidanceTitle)
                .font(DS.Font.sectionTitle)
            Text(installExplanation)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if !commandText.isEmpty {
                HStack(alignment: .top, spacing: DS.Spacing.s) {
                    ScrollView(.horizontal) {
                        Text(commandText)
                            .font(DS.Font.monoCallout)
                            .textSelection(.enabled)
                            .padding(DS.Spacing.s)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .fill(DS.Color.fieldBackground)
                    )

                    Button {
                        copyCommands()
                    } label: {
                        Label(
                            copiedCommands ? "Copied" : "Copy",
                            systemImage: copiedCommands ? DS.Symbol.checkmark : DS.Symbol.copy
                        )
                    }
                    .help("Copy the install commands")
                }
            }

            if checker.homebrewIsMissing {
                Text("Homebrew itself is missing. Install it from brew.sh before running the brew command.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warningText)
            }
            if !checker.supplementalInstallCommands.isEmpty {
                Text("CVXPY is a Python package rather than a Homebrew formula; its Python command is shown separately above.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            if hasBundledAttention {
                Text("For a packaged app, install commands prepare a source rebuild; they cannot add a library to the existing signed Qnet.app.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warningText)
            }
        }
        .padding(DS.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.tintFill(DS.Color.warning))
        )
    }

    private var installExplanation: String {
        if hasBundledAttention && commandText.isEmpty {
            return "This Qnet.app is incomplete or contains a component that cannot launch. Rebuild or reinstall the app; a Homebrew command cannot repair an existing signed bundle."
        }
        if checker.brewInstallCommand != nil && !checker.supplementalInstallCommands.isEmpty {
            return "Open Terminal and run the Homebrew and Python commands shown below. Optional rows only unlock the method named in that row. Relaunch Qnet after installation."
        }
        if checker.brewInstallCommand != nil {
            return "Open Terminal and run the Homebrew command shown below. Optional rows only unlock the method named in that row. Relaunch Qnet after installation."
        }
        return "Open Terminal and run the Python command shown below. This optional package only unlocks the method named in its row. Relaunch Qnet after installation."
    }

    private var guidanceTitle: String {
        hasBundledAttention && commandText.isEmpty
            ? "Repair this Qnet app"
            : "Install missing packages"
    }

    private func copyCommands() {
        guard !commandText.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(commandText, forType: .string)
        copiedCommands = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copiedCommands = false
        }
    }
}

private struct StartupDependencyRow: View {
    let item: StartupDependencyItem
    @DSAccessibility private var a11y

    var body: some View {
        HStack(alignment: .top, spacing: DS.Spacing.m) {
            statusIcon
                .frame(width: DS.Layout.iconButtonWidth, height: DS.Layout.controlHeight)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(item.requirement.name)
                        .font(DS.Font.sectionTitle)
                    scopeBadge
                    Spacer(minLength: 0)
                }
                Text(item.requirement.summary)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(statusText)
                    .font(DS.Font.caption)
                    .foregroundStyle(statusTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(isChecking ? DS.Color.selectionFill(a11y.contrast) : DS.Color.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(
                    isChecking ? DS.Color.accentStroke : DS.Color.controlBorder(a11y.contrast),
                    lineWidth: DS.Stroke.hairline(a11y.contrast)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.requirement.name), \(item.requirement.scope.rawValue), \(statusText)")
        .dsAnimation(DS.Motion.quick, value: item.status)
    }

    private var isChecking: Bool {
        if case .checking = item.status { return true }
        return false
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.status {
        case .pending:
            Image(systemName: DS.Symbol.pending)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.textTertiary(a11y.contrast))
        case .checking:
            ProgressView()
                .controlSize(.small)
        case .available:
            Image(systemName: DS.Symbol.success)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.successText)
        case .missing:
            Image(systemName: item.requirement.scope == .optional ? DS.Symbol.warning : DS.Symbol.failure)
                .font(DS.Font.headline)
                .foregroundStyle(item.requirement.scope == .optional ? DS.Color.warningText : DS.Color.dangerText)
        case .timedOut:
            Image(systemName: DS.Symbol.warning)
                .font(DS.Font.headline)
                .foregroundStyle(DS.Color.warningText)
        }
    }

    @ViewBuilder
    private var scopeBadge: some View {
        switch item.requirement.scope {
        case .runtime:
            DSBadge(text: item.requirement.scope.rawValue)
        case .optional:
            DSBadge(text: item.requirement.scope.rawValue,
                    tint: DS.Color.warning, emphasis: .tinted)
        case .bundled:
            DSBadge(text: item.requirement.scope.rawValue,
                    tint: DS.Color.info, emphasis: .tinted)
        case .developer:
            DSBadge(text: item.requirement.scope.rawValue)
        }
    }

    private var statusText: String {
        switch item.status {
        case .pending: return "Waiting to be checked."
        case .checking: return "Checking now…"
        case .available(let detail): return detail
        case .missing(let detail): return "Missing — \(detail)"
        case .timedOut(let detail): return "Check timed out — \(detail)"
        }
    }

    private var statusTextColor: Color {
        switch item.status {
        case .available: return DS.Color.successText
        case .missing:
            return item.requirement.scope == .optional
                ? DS.Color.warningText : DS.Color.dangerText
        case .timedOut: return DS.Color.warningText
        case .pending, .checking: return DS.Color.textSecondary
        }
    }
}
