import AppKit
import SwiftUI

struct AgentWorkspaceEmptyConversationView: View {
    @EnvironmentObject private var store: AppStore

    private let suggestions = [
        "Inspect a customer system",
        "Assess an AI integration",
        "Propose an isolated patch",
        "Review production readiness"
    ]

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "sparkles")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(Color.accentColor)
            Text("What are you working on?")
                .font(.title2.weight(.semibold))
            Text("Start with a question or choose a safe workspace action.")
                .font(.callout)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        store.commandText = suggestion
                        store.requestComposerFocus()
                    } label: {
                        HStack {
                            Text(suggestion)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.left")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
        .accessibilityIdentifier("workspace.emptyConversation")
    }
}

struct StructuredAgentResponseView: View {
    let response: StructuredAgentResponse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(response.title)
                    .font(.headline)
                Spacer()
                Text(response.status.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.10), in: Capsule())
            }

            ForEach(response.sections) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.kind.rawValue)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(section.content)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.20), lineWidth: 0.7)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent response, \(response.title), \(response.status.rawValue)")
    }

    private var statusColor: Color {
        switch response.status {
        case .working: return .blue
        case .needsInput: return .purple
        case .warning: return .orange
        case .completed: return .green
        case .informational: return .secondary
        }
    }
}

enum ArtifactViewerTab: String, CaseIterable, Identifiable {
    case file = "File"
    case diff = "Unified Diff"
    case metadata = "Metadata"
    case evidence = "Evidence"
    case exactBinding = "Exact Binding"

    var id: String { rawValue }
}

private struct ArtifactViewerRequest: Identifiable {
    let card: ArtifactFileCardModel
    let initialTab: ArtifactViewerTab

    var id: String { "\(card.id):\(initialTab.rawValue)" }
}

struct ArtifactFileCardsView: View {
    let cards: [ArtifactFileCardModel]
    @State private var viewerRequest: ArtifactViewerRequest?
    @State private var hoveredCardID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(cards.filter { ArtifactPathAuthority.isValidatedRelativePath($0.relativePath) }) { card in
                artifactCard(card)
            }
        }
        .sheet(item: $viewerRequest) { request in
            AppOwnedArtifactViewer(card: request.card, initialTab: request.initialTab)
        }
    }

    private func artifactCard(_ card: ArtifactFileCardModel) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                Text(card.relativePath)
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .foregroundStyle(WorkspaceVisualStyle.color(.textPrimary))
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Text(card.status.rawValue)
                    .font(WorkspaceVisualStyle.Typography.label)
                    .foregroundStyle(fileStatusColor(card.status))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(fileStatusColor(card.status).opacity(0.09), in: Capsule())
            }

            Text(card.purpose)
                .font(WorkspaceVisualStyle.Typography.metadata)
                .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: WorkspaceVisualStyle.Spacing.x12) {
                Label(card.language, systemImage: "chevron.left.forwardslash.chevron.right")
                Label(card.safeSource.rawValue, systemImage: sourceSymbol(card.safeSource))
                if let additions = card.additions {
                    Text("+\(additions)")
                        .monospacedDigit()
                        .foregroundStyle(WorkspaceVisualStyle.color(.success))
                }
                if let deletions = card.deletions {
                    Text("−\(deletions)")
                        .monospacedDigit()
                        .foregroundStyle(WorkspaceVisualStyle.color(.danger))
                }
            }
            .font(.caption2)
            .foregroundStyle(WorkspaceVisualStyle.color(.textTertiary))

            HStack(spacing: WorkspaceVisualStyle.Spacing.x12) {
                Button("Open File") {
                    guard ArtifactPathAuthority.isValidatedRelativePath(card.relativePath) else { return }
                    viewerRequest = ArtifactViewerRequest(card: card, initialTab: .file)
                }
                Button("View Diff") {
                    guard ArtifactPathAuthority.isValidatedRelativePath(card.relativePath) else { return }
                    viewerRequest = ArtifactViewerRequest(card: card, initialTab: .diff)
                }
                .disabled(card.unifiedDiff == nil)
                Button("Copy Relative Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.relativePath, forType: .string)
                }
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
            .opacity(hoveredCardID == card.id ? 1 : 0.78)
        }
        .padding(WorkspaceVisualStyle.Spacing.x12)
        .background(
            WorkspaceVisualStyle.color(.elevatedSurface),
            in: RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.artifactCard, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.artifactCard, style: .continuous)
                .stroke(WorkspaceVisualStyle.color(.borderSubtle), lineWidth: 0.7)
        }
        .onHover { isHovered in
            hoveredCardID = isHovered ? card.id : nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(card.status.rawValue) file, \(card.relativePath)")
        .accessibilityIdentifier("artifact.fileCard")
    }

    private func fileStatusColor(_ status: ArtifactFileStatus) -> Color {
        switch status {
        case .added: return WorkspaceVisualStyle.color(.success)
        case .modified: return WorkspaceVisualStyle.color(.warning)
        case .deleted: return WorkspaceVisualStyle.color(.danger)
        case .virtual: return WorkspaceVisualStyle.color(.accent)
        }
    }

    private func sourceSymbol(_ source: ArtifactSafeSource) -> String {
        switch source {
        case .legacyReadOnly: return "lock"
        case .safeSandbox: return "shippingbox"
        case .virtualArtifact: return "doc.badge.gearshape"
        }
    }
}

private struct AppOwnedArtifactViewer: View {
    let card: ArtifactFileCardModel
    @State private var selectedTab: ArtifactViewerTab
    @Environment(\.dismiss) private var dismiss

    init(card: ArtifactFileCardModel, initialTab: ArtifactViewerTab) {
        self.card = card
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: WorkspaceVisualStyle.Spacing.x12) {
                Image(systemName: "doc.text")
                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                VStack(alignment: .leading, spacing: 3) {
                    Text(validatedRelativePath)
                        .font(.system(.headline, design: .monospaced))
                        .lineLimit(2)
                    Text("\(card.safeSource.rawValue) · \(card.status.rawValue)")
                        .font(WorkspaceVisualStyle.Typography.metadata)
                        .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, WorkspaceVisualStyle.Spacing.x16)
            .padding(.vertical, WorkspaceVisualStyle.Spacing.x12)
            .background(WorkspaceVisualStyle.color(.elevatedSurface))

            Picker("Artifact viewer", selection: $selectedTab) {
                ForEach(ArtifactViewerTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, WorkspaceVisualStyle.Spacing.x16)
            .padding(.vertical, WorkspaceVisualStyle.Spacing.x8)
            .background(WorkspaceVisualStyle.color(.elevatedSurface))

            Divider()

            if ArtifactPathAuthority.isValidatedRelativePath(card.relativePath) {
                Group {
                    switch selectedTab {
                    case .file:
                        codePane(card.content)
                    case .diff:
                        if let unifiedDiff = card.unifiedDiff {
                            UnifiedDiffPane(card: card, unifiedDiff: unifiedDiff)
                        } else {
                            ContentUnavailableView(
                                "No Unified Diff",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text("No Unified Diff is available for this virtual artifact.")
                            )
                        }
                    case .metadata:
                        detailPane(card.metadata)
                    case .evidence:
                        evidencePane
                    case .exactBinding:
                        detailPane(card.exactBinding)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "Invalid artifact path",
                    systemImage: "lock.trianglebadge.exclamationmark",
                    description: Text("This app-owned viewer accepts validated relative artifact paths only.")
                )
            }
        }
        .frame(minWidth: 720, idealWidth: 980, minHeight: 520, idealHeight: 700)
        .background(WorkspaceVisualStyle.color(.primarySurface))
        .accessibilityIdentifier("artifact.appOwnedViewer")
    }

    private var validatedRelativePath: String {
        ArtifactPathAuthority.isValidatedRelativePath(card.relativePath)
            ? card.relativePath
            : "Unavailable artifact"
    }

    private func codePane(_ content: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content)
                .font(WorkspaceVisualStyle.Typography.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(WorkspaceVisualStyle.Spacing.x16)
        }
        .background(WorkspaceVisualStyle.color(.primarySurface))
    }

    private func detailPane(_ items: [ArtifactMetadataItem]) -> some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                ForEach(items) { item in
                    GridRow {
                        Text(item.label)
                            .foregroundStyle(.secondary)
                        Text(item.value)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
        }
    }

    private var evidencePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if card.evidence.isEmpty {
                    Text("No additional evidence references were attached to this file.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(card.evidence, id: \.self) { evidence in
                        Label(evidence, systemImage: "checkmark.shield")
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(18)
        }
    }
}

private struct UnifiedDiffPane: View {
    let card: ArtifactFileCardModel
    let presentation: UnifiedDiffPresentation
    @State private var isFileExpanded = true
    @State private var expandedCollapsedSections: Set<Int> = []

    init(card: ArtifactFileCardModel, unifiedDiff: String) {
        self.card = card
        presentation = UnifiedDiffPresentation(unifiedDiff)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: WorkspaceVisualStyle.Spacing.x12) {
                Text("Unified Diff")
                    .font(WorkspaceVisualStyle.Typography.label)
                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                Spacer()
                changeCount("+\(additions)", color: WorkspaceVisualStyle.color(.success))
                changeCount("−\(deletions)", color: WorkspaceVisualStyle.color(.danger))
            }
            .padding(.horizontal, WorkspaceVisualStyle.Spacing.x16)
            .padding(.vertical, WorkspaceVisualStyle.Spacing.x8)
            .background(WorkspaceVisualStyle.color(.elevatedSurface))

            Divider()

            Button {
                isFileExpanded.toggle()
            } label: {
                HStack(spacing: WorkspaceVisualStyle.Spacing.x8) {
                    Image(systemName: isFileExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WorkspaceVisualStyle.color(.textTertiary))
                        .frame(width: 12)
                    Image(systemName: "doc.text")
                        .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                    Text(card.relativePath)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: WorkspaceVisualStyle.Spacing.x16)
                    changeCount("+\(additions)", color: WorkspaceVisualStyle.color(.success))
                    changeCount("−\(deletions)", color: WorkspaceVisualStyle.color(.danger))
                    Text(card.status.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                }
                .padding(.horizontal, WorkspaceVisualStyle.Spacing.x16)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(card.relativePath), \(additions) additions, \(deletions) deletions")
            .accessibilityValue(isFileExpanded ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("artifact.diff.fileHeader")

            Divider()

            if isFileExpanded {
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(presentation.displayRows()) { row in
                            displayRow(row)
                        }
                    }
                    .frame(minWidth: 900, maxWidth: .infinity, alignment: .topLeading)
                }
                .background(WorkspaceVisualStyle.color(.primarySurface))
                .accessibilityIdentifier("artifact.diff.body")
            }
        }
    }

    private var additions: Int { card.additions ?? presentation.additionCount }
    private var deletions: Int { card.deletions ?? presentation.deletionCount }

    private func changeCount(_ value: String, color: Color) -> some View {
        Text(value)
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func displayRow(_ row: UnifiedDiffDisplayRow) -> some View {
        switch row {
        case let .line(line):
            diffLine(line)
        case let .collapsed(section):
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    if expandedCollapsedSections.contains(section.id) {
                        expandedCollapsedSections.remove(section.id)
                    } else {
                        expandedCollapsedSections.insert(section.id)
                    }
                } label: {
                    HStack(spacing: WorkspaceVisualStyle.Spacing.x8) {
                        Color.clear.frame(width: 91, height: 1)
                        Image(systemName: expandedCollapsedSections.contains(section.id)
                            ? "chevron.up" : "ellipsis")
                            .font(.caption2.weight(.semibold))
                        Text(expandedCollapsedSections.contains(section.id)
                            ? "Collapse \(section.hiddenLineCount) unchanged lines"
                            : "\(section.hiddenLineCount) unchanged lines")
                            .font(.caption.monospaced())
                        Spacer()
                    }
                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                    .padding(.horizontal, WorkspaceVisualStyle.Spacing.x8)
                    .frame(minWidth: 900, minHeight: 24, alignment: .leading)
                    .background(WorkspaceVisualStyle.color(.controlSurface))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("artifact.diff.collapsedContext")

                if expandedCollapsedSections.contains(section.id) {
                    ForEach(section.lines) { line in
                        diffLine(line)
                    }
                }
            }
        }
    }

    private func diffLine(_ line: UnifiedDiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            lineNumber(line.oldLineNumber)
            lineNumber(line.newLineNumber)
            Rectangle()
                .fill(WorkspaceVisualStyle.color(.borderSubtle))
                .frame(width: 1, height: 22)
            Text(line.content.isEmpty ? " " : line.content)
                .font(WorkspaceVisualStyle.Typography.diff)
                .foregroundStyle(diffTextColor(line.kind))
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, WorkspaceVisualStyle.Spacing.x8)
        }
        .frame(minWidth: 900, minHeight: 22, alignment: .leading)
        .background(diffBackground(line.kind))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(diffAccessibilityLabel(line))
    }

    private func lineNumber(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(size: 11, design: .monospaced).monospacedDigit())
            .foregroundStyle(WorkspaceVisualStyle.color(.textTertiary))
            .frame(width: 44, alignment: .trailing)
            .padding(.trailing, 5)
            .textSelection(.enabled)
    }

    private func diffBackground(_ kind: UnifiedDiffLineKind) -> Color {
        switch kind {
        case .added: return WorkspaceVisualStyle.color(.diffAddedBackground)
        case .removed: return WorkspaceVisualStyle.color(.diffRemovedBackground)
        case .hunk: return WorkspaceVisualStyle.color(.controlSurface)
        default: return .clear
        }
    }

    private func diffTextColor(_ kind: UnifiedDiffLineKind) -> Color {
        switch kind {
        case .added: return WorkspaceVisualStyle.color(.diffAddedText)
        case .removed: return WorkspaceVisualStyle.color(.diffRemovedText)
        case .header, .metadata: return WorkspaceVisualStyle.color(.textSecondary)
        case .hunk: return WorkspaceVisualStyle.color(.accent)
        case .context: return WorkspaceVisualStyle.color(.textPrimary)
        }
    }

    private func diffAccessibilityLabel(_ line: UnifiedDiffLine) -> String {
        let old = line.oldLineNumber.map { "old line \($0)" }
        let new = line.newLineNumber.map { "new line \($0)" }
        let location = [old, new].compactMap { $0 }.joined(separator: ", ")
        return [line.kind.rawValue, location, line.content]
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
}

private enum WorkspaceInspectorSection: String, CaseIterable, Identifiable {
    case artifacts = "Artifacts"
    case previousRuns = "Previous Runs"
    case evidence = "Evidence"
    case activity = "Activity"

    var id: String { rawValue }
}

struct WorkspaceInspectorView: View {
    @EnvironmentObject private var store: AppStore
    @State private var section: WorkspaceInspectorSection = .artifacts
    @State private var previousRunsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $section) {
                ForEach(WorkspaceInspectorSection.allCases) { item in
                    Text(item.rawValue).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            ScrollView {
                Group {
                    switch section {
                    case .artifacts: artifacts
                    case .previousRuns: previousRuns
                    case .evidence: evidence
                    case .activity: activity
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(12)
            }
        }
        .background(WorkspaceVisualStyle.color(.sidebarSurface))
        .accessibilityIdentifier("workspace.rightInspector")
    }

    @ViewBuilder
    private var artifacts: some View {
        if let summary = store.selectedMissionPresentation?.current {
            VStack(alignment: .leading, spacing: 12) {
                inspectorCard("Assessment", value: summary.goal, symbol: "magnifyingglass")
                if let patch = summary.candidatePatch {
                    inspectorCard(
                        "Candidate Patch",
                        value: "\(patch.filesChanged) file(s) · +\(patch.additions) −\(patch.deletions)",
                        symbol: "hammer"
                    )
                }
                if let plan = summary.generatedTestPlan {
                    inspectorCard(
                        "Generated Test Plan",
                        value: "\(plan.scenarioCount) scenario(s) · \(plan.status.rawValue)",
                        symbol: "checklist"
                    )
                }
                if let artifact = summary.generatedTestArtifact {
                    inspectorCard(
                        "Generated Test Artifact",
                        value: "\(artifact.currentRevision?.virtualFiles.count ?? 0) virtual file(s)",
                        symbol: "doc.badge.gearshape"
                    )
                }
                if let report = summary.productionReadinessReport {
                    inspectorCard(
                        "Production Readiness Report",
                        value: report.overallResult?.rawValue ?? "Available",
                        symbol: "gauge.with.dots.needle.bottom.50percent"
                    )
                }
                if let plan = summary.aiEvalPlan {
                    inspectorCard(
                        "AI Eval Plan",
                        value: "Revision \(plan.currentRevision?.revision ?? 0)",
                        symbol: "chart.bar.doc.horizontal"
                    )
                }
                if let run = summary.evalRun {
                    inspectorCard(
                        "Controlled Eval Run / Results",
                        value: run.currentState?.rawValue ?? "Prepared",
                        symbol: "testtube.2"
                    )
                }

                artifactAdvancementAction(summary)

                if !store.selectedArtifactFileCards.isEmpty {
                    Divider()
                    Text("Files")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ArtifactFileCardsView(cards: store.selectedArtifactFileCards)
                }

                DisclosureGroup("Advanced details") {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(summary.exactDetails) { detail in
                            Text("\(detail.label): \(detail.value)")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                }
            }
        } else {
            ContentUnavailableView("No artifacts yet", systemImage: "tray")
        }
    }

    @ViewBuilder
    private func artifactAdvancementAction(_ summary: MissionSummary) -> some View {
        if summary.primaryAction == .continueToTestReview,
           let patch = summary.candidatePatch {
            Button("Prepare Generated Test Plan") {
                store.prepareGeneratedTestPlan(patch)
            }
        } else if summary.primaryAction == .reviewProposedTests,
                  summary.generatedTestArtifact == nil {
            Button("Prepare Generated Test Artifact") {
                store.reviewProposedTests(summary) { _ in }
            }
        } else if summary.postReadyAction == .reviewProductionReadiness {
            Button("Prepare Production Readiness Review") {
                store.reviewProductionReadiness(summary)
            }
        }
    }

    @ViewBuilder
    private var previousRuns: some View {
        if let runs = store.selectedMissionPresentation?.previousRuns, !runs.isEmpty {
            DisclosureGroup(isExpanded: $previousRunsExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(runs) { run in
                        inspectorCardSurface {
                            HStack(alignment: .top, spacing: WorkspaceVisualStyle.Spacing.x12) {
                                inspectorIcon("clock.arrow.circlepath")
                                VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x4) {
                                    Text(run.title)
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(WorkspaceVisualStyle.color(.textPrimary))
                                    Text(run.finalOutcome)
                                        .font(WorkspaceVisualStyle.Typography.metadata)
                                        .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                                    Text("Read-only Mission history")
                                        .font(.caption2)
                                        .foregroundStyle(WorkspaceVisualStyle.color(.textTertiary))
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Mission-based Previous Runs (\(runs.count))")
                    .font(.callout.weight(.semibold))
            }
        } else {
            ContentUnavailableView("No previous runs", systemImage: "clock.arrow.circlepath")
        }
    }

    @ViewBuilder
    private var evidence: some View {
        if let summary = store.selectedMissionPresentation?.current {
            let revision = summary.evalRun?.currentRevision
            VStack(alignment: .leading, spacing: 12) {
                inspectorMetric("Summarized evidence", value: store.selectedAgentSession?.evidence.count ?? 0)
                inspectorMetric("Candidate Patch evidence", value: summary.candidatePatch?.evidenceCount ?? 0)
                inspectorMetric("Fixture result count", value: revision?.scenarioExecutions.flatMap(\.results).count ?? 0)
                inspectorMetric("Metric result count", value: revision?.metricResults.count ?? 0)

                if let blocker = summary.lineageFailureReason
                    ?? summary.controlledEvalRestorationFailureReason
                    ?? store.selectedConversationActivity?.metadata.blockerReason {
                    inspectorCard("Blocker", value: blocker, symbol: "exclamationmark.triangle")
                }
                if let unknowns = summary.generatedTestPlan?.remainingUnknowns, !unknowns.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Unknowns")
                            .font(.caption.weight(.semibold))
                        ForEach(unknowns, id: \.self) { unknown in
                            Text("• \(unknown)")
                                .font(.caption)
                        }
                    }
                }
            }
        } else {
            ContentUnavailableView("No evidence yet", systemImage: "tray")
        }
    }

    @ViewBuilder
    private var activity: some View {
        let events = Array(store.selectedAgentSessionEvents.suffix(40).reversed())
        if store.selectedConversationScope?.hasLinkedMission != true || events.isEmpty {
            ContentUnavailableView("No activity yet", systemImage: "waveform.path.ecg")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { event in
                    inspectorCardSurface {
                        HStack(alignment: .top, spacing: WorkspaceVisualStyle.Spacing.x12) {
                            inspectorIcon("waveform.path.ecg")
                            VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x8) {
                                Text(StructuredAgentResponseProjector.normalizedPresentationText(event.summary))
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(WorkspaceVisualStyle.color(.textPrimary))
                                Text(event.type.rawValue.replacingOccurrences(of: "_", with: " ").localizedCapitalized)
                                    .font(WorkspaceVisualStyle.Typography.metadata)
                                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                                DisclosureGroup("Exact activity details") {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("Event: \(event.id.uuidString.lowercased())")
                                        Text("Sequence: \(event.sequence)")
                                        if let taskID = event.taskID {
                                            Text("Mission: \(taskID.uuidString.lowercased())")
                                        }
                                    }
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func inspectorCard(_ title: String, value: String, symbol: String) -> some View {
        inspectorCardSurface {
            HStack(alignment: .top, spacing: WorkspaceVisualStyle.Spacing.x12) {
                inspectorIcon(symbol)
                VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(WorkspaceVisualStyle.color(.textPrimary))
                    Text(value)
                        .font(WorkspaceVisualStyle.Typography.metadata)
                        .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func inspectorCardSurface<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(WorkspaceVisualStyle.Spacing.x12)
            .background(
                WorkspaceVisualStyle.color(.elevatedSurface),
                in: RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.artifactCard, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.artifactCard, style: .continuous)
                    .stroke(WorkspaceVisualStyle.color(.borderSubtle).opacity(0.7), lineWidth: 0.6)
            }
            .shadow(color: .black.opacity(0.025), radius: 3, y: 1)
    }

    private func inspectorIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
            .frame(width: 28, height: 28)
            .background(
                WorkspaceVisualStyle.color(.controlSurface),
                in: RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.control, style: .continuous)
            )
    }

    private func inspectorMetric(_ title: String, value: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }
}

private enum WorkspaceHumanActionTarget {
    case candidate(ApprovalRequest)
    case generatedTest(GeneratedTestArtifact)
    case readiness(ProductionReadinessReport)
    case evalPlan(AIEvalPlan)
    case evalExecution(EvalRun)
    case authorizedEvalExecution(MissionSummary)
    case evalAuthorization(MissionSummary)
    case evalResults(EvalRun)
    case evalResultAuthorization(MissionSummary)
    case generic(ApprovalRequest)
    case undo(MissionSummary)
}

private struct WorkspaceHumanAction {
    var descriptor: HumanActionDescriptor
    var target: WorkspaceHumanActionTarget
}

struct HumanActionBar: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDecision: HumanReviewDecision?
    @State private var reviewNote = ""
    @State private var isSubmitting = false

    var body: some View {
        Group {
            if let action = currentAction {
                actionBar(action)
                    .onChange(of: action.descriptor.id) { _, _ in resetForm() }
            }
        }
    }

    private func actionBar(_ action: WorkspaceHumanAction) -> some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x16) {
            HStack(alignment: .center, spacing: WorkspaceVisualStyle.Spacing.x8) {
                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                Text("Human review")
                    .font(WorkspaceVisualStyle.Typography.messageTitle)
                Spacer()
                Text(action.descriptor.status)
                    .font(WorkspaceVisualStyle.Typography.label)
                    .foregroundStyle(WorkspaceVisualStyle.color(.accent))
                    .padding(.horizontal, WorkspaceVisualStyle.Spacing.x8)
                    .padding(.vertical, 4)
                    .background(WorkspaceVisualStyle.color(.accent).opacity(0.08), in: Capsule())
            }

            HStack(alignment: .firstTextBaseline, spacing: WorkspaceVisualStyle.Spacing.x16) {
                VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x4) {
                    Text(action.descriptor.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(WorkspaceVisualStyle.color(.textPrimary))
                    Text(action.descriptor.scope)
                        .font(WorkspaceVisualStyle.Typography.metadata)
                        .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: WorkspaceVisualStyle.Spacing.x12)
                if let revision = action.descriptor.revision {
                    Text("Revision \(revision)")
                        .font(WorkspaceVisualStyle.Typography.metadata)
                        .foregroundStyle(WorkspaceVisualStyle.color(.textTertiary))
                        .fixedSize()
                }
            }

            if action.descriptor.isReadOnly {
                Label("This decision is finalized and read-only.", systemImage: "lock")
                    .font(.callout)
                    .foregroundStyle(WorkspaceVisualStyle.color(.textSecondary))
                    .padding(.top, WorkspaceVisualStyle.Spacing.x4)
            } else {
                VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x8) {
                    TextField("Optional review note…", text: $reviewNote, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, WorkspaceVisualStyle.Spacing.x12)
                        .padding(.vertical, 9)
                        .background(
                            WorkspaceVisualStyle.color(.controlSurface),
                            in: RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.control, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.control, style: .continuous)
                                .stroke(WorkspaceVisualStyle.color(.borderSubtle), lineWidth: 0.7)
                        }
                        .disabled(isSubmitting)
                        .accessibilityIdentifier("humanAction.reviewNote")

                    if let selectedDecision {
                        selectedDecisionAction(action, decision: selectedDecision)
                    } else {
                        primaryDecisionActions(action)
                    }
                }
            }
        }
        .padding(WorkspaceVisualStyle.Spacing.x16)
        .background(
            WorkspaceVisualStyle.color(.elevatedSurface),
            in: RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.humanReview, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.humanReview, style: .continuous)
                .stroke(WorkspaceVisualStyle.color(.borderSubtle), lineWidth: 0.75)
        }
        .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: selectedDecision)
        .accessibilityIdentifier("workspace.humanActionBar")
    }

    @ViewBuilder
    private func primaryDecisionActions(_ action: WorkspaceHumanAction) -> some View {
        HStack(alignment: .center, spacing: WorkspaceVisualStyle.Spacing.x12) {
            if action.descriptor.decisions.contains(.approve) {
                Button {
                    submit(action, decision: .approve)
                } label: {
                    decisionButtonLabel("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!action.descriptor.canSubmit(decision: .approve, note: reviewNote) || isSubmitting)
                .accessibilityLabel(isSubmitting ? "Submitting approval" : "Approve")
                .accessibilityIdentifier("humanAction.approve")
            }

            let secondaryDecisions = action.descriptor.decisions.filter { $0 != .approve }
            if !secondaryDecisions.isEmpty {
                Menu {
                    ForEach(secondaryDecisions) { decision in
                        if decision == .reject {
                            Button(role: .destructive) {
                                selectedDecision = decision
                            } label: {
                                Label(decision.rawValue, systemImage: decisionSymbol(decision))
                            }
                        } else {
                            Button {
                                selectedDecision = decision
                            } label: {
                                Label(decision.rawValue, systemImage: decisionSymbol(decision))
                            }
                        }
                    }
                } label: {
                    Label("More options", systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderedButton)
                .disabled(isSubmitting)
                .accessibilityLabel("More review options")
                .accessibilityIdentifier("humanAction.secondaryDecisionMenu")
            }
            Spacer(minLength: 0)
        }
    }

    private func selectedDecisionAction(
        _ action: WorkspaceHumanAction,
        decision: HumanReviewDecision
    ) -> some View {
        HStack(alignment: .center, spacing: WorkspaceVisualStyle.Spacing.x12) {
            VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x4) {
                Label(decision.rawValue, systemImage: decisionSymbol(decision))
                    .font(WorkspaceVisualStyle.Typography.label)
                    .foregroundStyle(decision == .reject
                        ? WorkspaceVisualStyle.color(.danger)
                        : WorkspaceVisualStyle.color(.textSecondary))
                if decision == .requestChanges,
                   reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Add a note describing the requested change.")
                        .font(WorkspaceVisualStyle.Typography.metadata)
                        .foregroundStyle(WorkspaceVisualStyle.color(.warning))
                }
            }
            Spacer(minLength: 0)
            Button("Cancel") {
                selectedDecision = nil
            }
            .buttonStyle(.borderless)
            .disabled(isSubmitting)
            .accessibilityIdentifier("humanAction.secondaryDecision.cancel")
            Button {
                submit(action, decision: decision)
            } label: {
                decisionButtonLabel(decision.rawValue, systemImage: decisionSymbol(decision))
            }
            .buttonStyle(.borderedProminent)
            .tint(decision == .reject ? WorkspaceVisualStyle.color(.danger) : nil)
            .disabled(!action.descriptor.canSubmit(decision: decision, note: reviewNote) || isSubmitting)
            .accessibilityLabel(isSubmitting ? "Submitting decision" : decision.rawValue)
            .accessibilityIdentifier("humanAction.submitDecision")
        }
    }

    private func decisionButtonLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: WorkspaceVisualStyle.Spacing.x8) {
            Text(title)
            if isSubmitting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
            }
        }
        .frame(minWidth: 112)
    }

    private func decisionSymbol(_ decision: HumanReviewDecision) -> String {
        switch decision {
        case .approve: return "checkmark"
        case .requestChanges: return "arrow.uturn.backward"
        case .reject: return "xmark"
        }
    }

    private var currentAction: WorkspaceHumanAction? {
        guard let selectedSession = store.selectedAgentSession,
              ![
                  AgentInteractionState.draft,
                  .idle,
                  .responding,
                  .waitingForUser,
                  .blocked,
                  .blockedProvider,
                  .blockedPermission,
                  .failed
              ].contains(selectedSession.interactionState),
              let summary = store.selectedMissionPresentation?.current,
              store.isMissionSummaryBoundToSelectedConversation(summary) else {
            return nil
        }
        var actions: [WorkspaceHumanAction] = []
        let decisions = HumanReviewDecision.allCases

        if let run = summary.evalRun,
           store.evalResultsReviewEligibility(run).isAvailable {
            actions.append(.init(
                descriptor: descriptor(
                    id: "eval-results:\(run.runID)",
                    domain: .controlledEvalResult,
                    title: "Review Controlled Eval results",
                    scope: "Fixture results, metrics, failures, and evidence",
                    revision: run.currentRevision?.revision,
                    status: run.currentState?.rawValue ?? "Awaiting review",
                    decisions: decisions
                ),
                target: .evalResults(run)
            ))
        } else if summary.controlledEvalResultReviewEligibility?.state == .currentAuthorizationReview
                    || summary.controlledEvalResultReviewEligibility?.state == .reauthorizationReview {
            actions.append(.init(
                descriptor: descriptor(
                    id: "eval-result-authorization:\(summary.missionID)",
                    domain: .controlledEvalResult,
                    title: "Authorize Controlled Eval result review",
                    scope: "Exact current-session result-review authority",
                    revision: summary.evalRun?.currentRevision?.revision,
                    status: "Authorization required",
                    decisions: [.approve]
                ),
                target: .evalResultAuthorization(summary)
            ))
        }

        if let run = summary.evalRun,
           store.controlledEvalExecutionReviewEligibility(run).isAvailable {
            actions.append(.init(
                descriptor: descriptor(
                    id: "eval-execution:\(run.runID)",
                    domain: .controlledEvalExecution,
                    title: "Authorize Controlled Eval execution",
                    scope: "Approved fixtures under the existing controlled policy",
                    revision: run.currentRevision?.revision,
                    status: "Execution authorization required",
                    decisions: [.approve]
                ),
                target: .evalExecution(run)
            ))
        } else if summary.controlledEvalEligibility?.state == .finalExecutionReview {
            actions.append(.init(
                descriptor: descriptor(
                    id: "authorized-eval-execution:\(summary.missionID)",
                    domain: .controlledEvalExecution,
                    title: "Confirm authorized Controlled Eval execution",
                    scope: "Single-use exact execution authorization",
                    revision: nil,
                    status: "Final confirmation required",
                    decisions: [.approve]
                ),
                target: .authorizedEvalExecution(summary)
            ))
        } else if summary.controlledEvalEligibility?.state == .currentAuthorizationReview
                    || summary.controlledEvalEligibility?.state == .reauthorizationReview {
            actions.append(.init(
                descriptor: descriptor(
                    id: "eval-authorization:\(summary.missionID)",
                    domain: .controlledEvalExecution,
                    title: "Authorize Controlled Eval execution review",
                    scope: "Exact current-session execution authority",
                    revision: nil,
                    status: "Authorization required",
                    decisions: [.approve]
                ),
                target: .evalAuthorization(summary)
            ))
        }

        if let report = summary.productionReadinessReport,
           store.productionReadinessReviewEligibility(report).isAvailable {
            actions.append(.init(
                descriptor: descriptor(
                    id: "readiness:\(report.reportID)",
                    domain: .productionReadiness,
                    title: "Review Production Readiness Report",
                    scope: "Readiness findings, gates, blockers, and unknowns",
                    revision: report.currentRevision?.revision,
                    status: "Awaiting decision",
                    decisions: decisions
                ),
                target: .readiness(report)
            ))
        }

        if let plan = summary.aiEvalPlan,
           store.aiEvalPlanReviewEligibility(plan).isAvailable {
            actions.append(.init(
                descriptor: descriptor(
                    id: "eval-plan:\(plan.planID)",
                    domain: .aiEvalPlan,
                    title: "Review AI Eval Plan",
                    scope: "Proposed fixtures, metrics, thresholds, and limitations",
                    revision: plan.currentRevision?.revision,
                    status: "Awaiting decision",
                    decisions: decisions
                ),
                target: .evalPlan(plan)
            ))
        }

        if let artifact = summary.generatedTestArtifact,
           let revision = artifact.currentRevision,
           store.generatedTestArtifactReviewEligibility(artifact).isAvailable {
            actions.append(.init(
                descriptor: descriptor(
                    id: "generated-test:\(revision.id)",
                    domain: .generatedTest,
                    title: "Review Generated Test Artifact",
                    scope: "Virtual test files only; nothing is written or executed",
                    revision: revision.revision,
                    status: artifact.reviewState(for: revision.revision).rawValue,
                    decisions: decisions
                ),
                target: .generatedTest(artifact)
            ))
        }

        if let approval = summary.candidatePatchApproval,
           store.candidatePatchReviewEligibility(approval) {
            actions.append(.init(
                descriptor: descriptor(
                    id: "candidate-patch:\(approval.id)",
                    domain: .candidatePatch,
                    title: summary.title,
                    scope: "Candidate Patch scope inside the validated Safe Sandbox",
                    revision: summary.candidatePatch?.planRevision,
                    status: approval.state.rawValue,
                    decisions: decisions
                ),
                target: .candidate(approval)
            ))
        }

        for approval in store.selectedTaskPendingApprovals
        where approval.targetKind != .candidatePatchPlan {
            actions.append(.init(
                descriptor: descriptor(
                    id: "approval:\(approval.id)",
                    domain: .genericApproval,
                    title: approval.action,
                    scope: approval.resource,
                    revision: nil,
                    status: approval.state.rawValue,
                    decisions: [.approve, .reject]
                ),
                target: .generic(approval)
            ))
        }

        if summary.undoEligible {
            actions.append(.init(
                descriptor: descriptor(
                    id: "undo:\(summary.missionID)",
                    domain: .undo,
                    title: "Undo this run",
                    scope: "Exact revert and cleanup workflow; audit history is preserved",
                    revision: summary.candidatePatch?.planRevision,
                    status: "Confirmation available",
                    decisions: [.approve]
                ),
                target: .undo(summary)
            ))
        }

        guard let highest = HumanActionBarProjector.highestPriority(
            in: actions.map(\.descriptor)
        ) else { return nil }
        return actions.first { $0.descriptor.id == highest.id }
    }

    private func descriptor(
        id: String,
        domain: HumanActionDomain,
        title: String,
        scope: String,
        revision: Int?,
        status: String,
        decisions: [HumanReviewDecision]
    ) -> HumanActionDescriptor {
        HumanActionDescriptor(
            id: id,
            domain: domain,
            title: title,
            scope: scope,
            revision: revision,
            status: status,
            decisions: decisions,
            isEligible: true,
            isInFlight: isSubmitting,
            isFinalized: false
        )
    }

    private func submit(_ action: WorkspaceHumanAction, decision: HumanReviewDecision) {
        guard action.descriptor.canSubmit(decision: decision, note: reviewNote),
              !isSubmitting,
              actionIsStillBoundToSelectedConversation(action) else { return }
        isSubmitting = true
        let note = reviewNote.trimmingCharacters(in: .whitespacesAndNewlines)

        switch action.target {
        case let .candidate(approval):
            switch decision {
            case .approve: store.approve(approval)
            case .requestChanges: store.requestCandidatePatchChanges(approval, revisionInstructions: note)
            case .reject: store.reject(approval)
            }
        case let .generatedTest(artifact):
            switch decision {
            case .approve: store.approveGeneratedTestArtifact(artifact)
            case .requestChanges: store.requestGeneratedTestArtifactChanges(artifact, instructions: note)
            case .reject: store.rejectGeneratedTestArtifact(artifact)
            }
        case let .readiness(report):
            store.reviewReadinessReport(report, decision: readinessDecision(decision), instructions: note.nilIfEmpty)
        case let .evalPlan(plan):
            store.reviewAIEvalPlan(plan, decision: readinessDecision(decision), instructions: note.nilIfEmpty)
        case let .evalExecution(run):
            store.confirmControlledEvalExecution(run)
        case let .authorizedEvalExecution(summary):
            store.confirmAuthorizedControlledEvalExecution(summary)
        case let .evalAuthorization(summary):
            store.prepareControlledEvalExecution(summary)
        case let .evalResults(run):
            store.reviewEvalResults(run, decision: evalResultDecision(decision), instructions: note.nilIfEmpty)
        case let .evalResultAuthorization(summary):
            store.prepareControlledEvalResultReview(summary)
        case let .generic(approval):
            decision == .approve ? store.approve(approval) : store.reject(approval)
        case let .undo(summary):
            store.openMissionUndoConfirmation(summary)
        }
    }

    private func actionIsStillBoundToSelectedConversation(_ action: WorkspaceHumanAction) -> Bool {
        switch action.target {
        case let .candidate(approval), let .generic(approval):
            return store.isApprovalBoundToSelectedConversation(approval)
        case let .undo(summary),
             let .authorizedEvalExecution(summary),
             let .evalAuthorization(summary),
             let .evalResultAuthorization(summary):
            return store.isMissionSummaryBoundToSelectedConversation(summary)
        case let .generatedTest(artifact):
            return store.isGeneratedTestArtifactBoundToSelectedConversation(artifact)
        case let .readiness(report):
            return store.selectedConversationScope?.containsMissionTask(report.sourceBinding.missionRunID) == true
        case let .evalPlan(plan):
            return store.selectedConversationScope?.containsMissionTask(
                plan.sourceBinding.readinessSourceBinding.missionRunID
            ) == true
        case let .evalExecution(run), let .evalResults(run):
            return store.selectedConversationScope?.containsMissionTask(run.request.authority.missionRunID) == true
        }
    }

    private func readinessDecision(_ decision: HumanReviewDecision) -> ProductionReadinessReviewDecisionKind {
        switch decision {
        case .approve: return .approvePlan
        case .requestChanges: return .requestChanges
        case .reject: return .reject
        }
    }

    private func evalResultDecision(_ decision: HumanReviewDecision) -> EvalRunReviewDecisionKind {
        switch decision {
        case .approve: return .approveResults
        case .requestChanges: return .requestChanges
        case .reject: return .rejectResults
        }
    }

    private func resetForm() {
        selectedDecision = nil
        reviewNote = ""
        isSubmitting = false
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
