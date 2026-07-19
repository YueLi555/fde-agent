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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(cards) { card in
                artifactCard(card)
            }
        }
        .sheet(item: $viewerRequest) { request in
            AppOwnedArtifactViewer(card: request.card, initialTab: request.initialTab)
        }
    }

    private func artifactCard(_ card: ArtifactFileCardModel) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "doc.text")
                    .foregroundStyle(Color.accentColor)
                Text(card.relativePath)
                    .font(.callout.weight(.semibold).monospaced())
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                Text(card.status.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(fileStatusColor(card.status))
            }

            Text(card.purpose)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Label(card.language, systemImage: "chevron.left.forwardslash.chevron.right")
                Label(card.safeSource.rawValue, systemImage: sourceSymbol(card.safeSource))
                if let additions = card.additions, let deletions = card.deletions {
                    Text("+\(additions) −\(deletions)")
                        .monospacedDigit()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button("Open file") {
                    guard ArtifactPathAuthority.isValidatedRelativePath(card.relativePath) else { return }
                    viewerRequest = ArtifactViewerRequest(card: card, initialTab: .file)
                }
                Button("View diff") {
                    guard ArtifactPathAuthority.isValidatedRelativePath(card.relativePath) else { return }
                    viewerRequest = ArtifactViewerRequest(card: card, initialTab: .diff)
                }
                .disabled(card.unifiedDiff == nil)
                Button("Copy relative path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(card.relativePath, forType: .string)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.7)
        )
        .accessibilityIdentifier("artifact.fileCard")
    }

    private func fileStatusColor(_ status: ArtifactFileStatus) -> Color {
        switch status {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .virtual: return .purple
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
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(card.relativePath)
                        .font(.headline.monospaced())
                    Text("\(card.safeSource.rawValue) · \(card.status.rawValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Picker("Artifact viewer", selection: $selectedTab) {
                ForEach(ArtifactViewerTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch selectedTab {
                case .file:
                    codePane(card.content)
                case .diff:
                    codePane(card.unifiedDiff ?? "No Unified Diff is available for this virtual artifact.")
                case .metadata:
                    detailPane(card.metadata)
                case .evidence:
                    evidencePane
                case .exactBinding:
                    detailPane(card.exactBinding)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 760, minHeight: 520)
        .accessibilityIdentifier("artifact.appOwnedViewer")
    }

    private func codePane(_ content: String) -> some View {
        ScrollView([.vertical, .horizontal]) {
            Text(content)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
        }
        .background(Color(nsColor: .textBackgroundColor))
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
        .background(Color(nsColor: .controlBackgroundColor))
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
                        VStack(alignment: .leading, spacing: 4) {
                            Text(run.title)
                                .font(.callout.weight(.semibold))
                            Text(run.finalOutcome)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("Read-only Mission history")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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

    private var evidence: some View {
        let summary = store.selectedMissionPresentation?.current
        let revision = summary?.evalRun?.currentRevision
        return VStack(alignment: .leading, spacing: 12) {
            inspectorMetric("Summarized evidence", value: store.selectedAgentSession?.evidence.count ?? 0)
            inspectorMetric("Candidate Patch evidence", value: summary?.candidatePatch?.evidenceCount ?? 0)
            inspectorMetric("Fixture result count", value: revision?.scenarioExecutions.flatMap(\.results).count ?? 0)
            inspectorMetric("Metric result count", value: revision?.metricResults.count ?? 0)

            if let blocker = summary?.lineageFailureReason
                ?? summary?.controlledEvalRestorationFailureReason
                ?? store.selectedConversationActivity?.metadata.blockerReason {
                inspectorCard("Blocker", value: blocker, symbol: "exclamationmark.triangle")
            }
            if let unknowns = summary?.generatedTestPlan?.remainingUnknowns, !unknowns.isEmpty {
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
    }

    @ViewBuilder
    private var activity: some View {
        let events = Array(store.selectedAgentSessionEvents.suffix(40).reversed())
        if events.isEmpty {
            ContentUnavailableView("No activity yet", systemImage: "waveform.path.ecg")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(StructuredAgentResponseProjector.normalizedPresentationText(event.summary))
                            .font(.callout.weight(.semibold))
                        Text(event.type.rawValue.replacingOccurrences(of: "_", with: " ").localizedCapitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                    .padding(10)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func inspectorCard(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: symbol)
                .font(.callout.weight(.semibold))
            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label("Human review", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.headline)
                Spacer()
                Text(action.descriptor.status)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
            }

            Text(action.descriptor.title)
                .font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Text(action.descriptor.scope)
                if let revision = action.descriptor.revision {
                    Text("Revision \(revision)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if action.descriptor.isReadOnly {
                Label("This decision is finalized and read-only.", systemImage: "lock")
                    .font(.callout)
            } else {
                Picker("Decision", selection: $selectedDecision) {
                    Text("Choose…").tag(Optional<HumanReviewDecision>.none)
                    ForEach(action.descriptor.decisions) { decision in
                        Text(decision.rawValue).tag(Optional(decision))
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("humanAction.decisionPicker")

                TextField("Optional review note", text: $reviewNote, axis: .vertical)
                    .lineLimit(1...3)
                    .accessibilityIdentifier("humanAction.reviewNote")

                HStack {
                    if selectedDecision == .requestChanges,
                       reviewNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Add a note describing the requested change.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Submit decision") {
                        submit(action)
                    }
                    .buttonStyle(.borderedProminent)
                    .focusable(false)
                    .disabled(!action.descriptor.canSubmit(
                        decision: selectedDecision,
                        note: reviewNote
                    ) || isSubmitting)
                    .accessibilityIdentifier("humanAction.submitDecision")
                }
            }
        }
        .padding(14)
        .background(Color.purple.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.purple.opacity(0.32), lineWidth: 0.8)
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityIdentifier("workspace.humanActionBar")
    }

    private var currentAction: WorkspaceHumanAction? {
        guard let summary = store.selectedMissionPresentation?.current else { return nil }
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

    private func submit(_ action: WorkspaceHumanAction) {
        guard action.descriptor.canSubmit(decision: selectedDecision, note: reviewNote),
              let decision = selectedDecision,
              !isSubmitting else { return }
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
