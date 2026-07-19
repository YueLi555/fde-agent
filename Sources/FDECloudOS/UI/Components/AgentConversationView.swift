import AppKit
import Foundation
import SwiftUI

struct AgentConversationView: View {
    let session: AgentSession
    let events: [ExecutionEvent]
    var activity: AgentConversationActivity? = nil
    var candidatePatchAssets: [CandidatePatchActivitySnapshot] = []
    var generatedTestAssets: [GeneratedTestActivitySnapshot] = []
    var generatedTestArtifactAssets: [GeneratedTestArtifact] = []
    var productionReadinessReports: [ProductionReadinessReport] = []
    var aiEvalPlans: [AIEvalPlan] = []
    var productionReadinessRestoreFailure: String? = nil
    var controlledEvalRuns: [EvalRun] = []
    var controlledEvalRestoreFailure: String? = nil
    var controlledEvalSessionAuthority: ControlledEvalSessionAuthority? = nil
    var controlledEvalExecutionAuthorizations: [ControlledEvalExecutionAuthorization] = []
    var controlledEvalResultReviewAuthorizations: [ControlledEvalResultReviewAuthorization] = []
    let approvals: [ApprovalRequest]
    var showsHeader = true
    var showsMissionPresentation = true
    var fileArtifacts: [ArtifactFileCardModel] = []
    let onApprove: (ApprovalRequest) -> Void
    let onReject: (ApprovalRequest) -> Void
    var onRequestChanges: ((ApprovalRequest, String) -> Void)? = nil
    let onSelectOption: (UUID, String) -> Void
    var onCandidatePatchRevert: ((CandidatePatchActivitySnapshot) -> Void)? = nil
    var onCandidatePatchDestroySandbox: ((CandidatePatchActivitySnapshot) -> Void)? = nil
    var onPlanGeneratedTests: ((CandidatePatchActivitySnapshot) -> Void)? = nil
    var onGenerateTestArtifact: ((GeneratedTestActivitySnapshot) -> Void)? = nil
    var onReviewProposedTests: MissionGeneratedTestReviewAction? = nil
    var generatedTestPlanGenerationEligibility: ((GeneratedTestActivitySnapshot) -> GeneratedTestPlanGenerationEligibility)? = nil
    var onRequestGeneratedTestArtifactChanges: ((GeneratedTestArtifact, String) -> Void)? = nil
    var onRejectGeneratedTestArtifact: ((GeneratedTestArtifact) -> Void)? = nil
    var onApproveGeneratedTestArtifact: ((GeneratedTestArtifact) -> Void)? = nil
    var candidatePatchReviewEligibility: ((ApprovalRequest) -> Bool)? = nil
    var generatedTestArtifactReviewEligibility: ((GeneratedTestArtifact) -> GeneratedTestArtifactReviewEligibility)? = nil
    var onReviewProductionReadiness: ((MissionSummary) -> Void)? = nil
    var productionReadinessReviewEligibility: ((ProductionReadinessReport) -> ProductionReadinessReviewEligibility)? = nil
    var aiEvalPlanReviewEligibility: ((AIEvalPlan) -> ProductionReadinessReviewEligibility)? = nil
    var onReviewReadinessReport: ((ProductionReadinessReport, ProductionReadinessReviewDecisionKind, String?) -> Void)? = nil
    var onReviewAIEvalPlan: ((AIEvalPlan, ProductionReadinessReviewDecisionKind, String?) -> Void)? = nil
    var onPrepareControlledEvalExecution: ((MissionSummary) -> Void)? = nil
    var controlledEvalExecutionReviewEligibility: ((EvalRun) -> ProductionReadinessReviewEligibility)? = nil
    var onConfirmControlledEvalExecution: ((EvalRun) -> Void)? = nil
    var onConfirmAuthorizedControlledEvalExecution: ((MissionSummary) -> Void)? = nil
    var onPrepareControlledEvalResultReview: ((MissionSummary) -> Void)? = nil
    var evalResultsReviewEligibility: ((EvalRun) -> ProductionReadinessReviewEligibility)? = nil
    var onReviewEvalResults: ((EvalRun, EvalRunReviewDecisionKind, String?) -> Void)? = nil
    var missionCleanupStates: [MissionCleanupState] = []
    var onUndoMission: ((MissionSummary) -> Void)? = nil
    var onRetryMissionCleanup: ((MissionSummary) -> Void)? = nil
    @State private var showsWorkDetails = false

    private var displayItems: [AgentConversationDisplayItem] {
        AgentConversationWorkUnitAdapter.displayItems(
            conversation: session.conversation,
            events: events
        )
    }

    private var workStatusCards: [AgentConversationWorkUnitCard] {
        AgentConversationWorkUnitAdapter.workStatusCards(
            conversation: session.conversation,
            events: events
        )
    }

    private var missionPresentation: MissionPresentationState {
        MissionPresentationProjector.project(
            session: session,
            activity: activity,
            candidatePatches: candidatePatchAssets,
            generatedTestPlans: generatedTestAssets,
            generatedTestArtifacts: generatedTestArtifactAssets,
            approvals: approvals,
            cleanupStates: missionCleanupStates,
            productionReadinessReports: productionReadinessReports,
            aiEvalPlans: aiEvalPlans,
            phase3ARestorationFailure: productionReadinessRestoreFailure,
            evalRuns: controlledEvalRuns,
            controlledEvalRestorationFailure: controlledEvalRestoreFailure,
            controlledEvalSessionAuthority: controlledEvalSessionAuthority,
            controlledEvalExecutionAuthorizations: controlledEvalExecutionAuthorizations,
            controlledEvalResultReviewAuthorizations: controlledEvalResultReviewAuthorizations
        )
    }

    private var conciseDisplayItems: [AgentConversationDisplayItem] {
        let hasMissionAssets = !candidatePatchAssets.isEmpty
            || !generatedTestAssets.isEmpty
            || !generatedTestArtifactAssets.isEmpty
        return AgentConversationWorkUnitAdapter.conciseDisplayItems(
            from: displayItems,
            hasMissionAssets: hasMissionAssets
        )
    }

    private var workDetailDisplayItems: [AgentConversationDisplayItem] {
        let conciseIDs = Set(conciseDisplayItems.map(\.id))
        return displayItems.filter { !conciseIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline) {
                    Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                        .font(.headline)
                    Spacer()
                    Text(session.interactionState.conversationTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(session.interactionState.conversationColor)
                }
            }

            VStack(spacing: 14) {
                ForEach(conciseDisplayItems) { item in
                    AgentConversationDisplayRow(
                        item: item,
                        onSelectOption: onSelectOption
                    )
                }

                if showsMissionPresentation {
                    MissionPresentationView(
                        state: missionPresentation,
                        candidatePatchReviewEligibility: candidatePatchReviewEligibility,
                        generatedTestPlanGenerationEligibility: generatedTestPlanGenerationEligibility,
                        generatedTestArtifactReviewEligibility: generatedTestArtifactReviewEligibility,
                        onApproveCandidatePatch: onApprove,
                        onRejectCandidatePatch: onReject,
                        onRequestCandidatePatchChanges: onRequestChanges,
                        onPlanGeneratedTests: onPlanGeneratedTests,
                        onGenerateTestArtifact: onGenerateTestArtifact,
                        onReviewProposedTests: onReviewProposedTests,
                        onRequestGeneratedTestArtifactChanges: onRequestGeneratedTestArtifactChanges,
                        onRejectGeneratedTestArtifact: onRejectGeneratedTestArtifact,
                        onApproveGeneratedTestArtifact: onApproveGeneratedTestArtifact,
                        onReviewProductionReadiness: onReviewProductionReadiness,
                        productionReadinessReviewEligibility: productionReadinessReviewEligibility,
                        aiEvalPlanReviewEligibility: aiEvalPlanReviewEligibility,
                        onReviewReadinessReport: onReviewReadinessReport,
                        onReviewAIEvalPlan: onReviewAIEvalPlan,
                        onPrepareControlledEvalExecution: onPrepareControlledEvalExecution,
                        controlledEvalExecutionReviewEligibility: controlledEvalExecutionReviewEligibility,
                        onConfirmControlledEvalExecution: onConfirmControlledEvalExecution,
                        onConfirmAuthorizedControlledEvalExecution: onConfirmAuthorizedControlledEvalExecution,
                        onPrepareControlledEvalResultReview: onPrepareControlledEvalResultReview,
                        evalResultsReviewEligibility: evalResultsReviewEligibility,
                        onReviewEvalResults: onReviewEvalResults,
                        onUndoRun: onUndoMission,
                        onRetryCleanup: onRetryMissionCleanup,
                        onShowWorkDetails: { showsWorkDetails = true }
                    )
                }

                if !fileArtifacts.isEmpty {
                    ArtifactFileCardsView(cards: fileArtifacts)
                }
            }

            if showsMissionPresentation && (activity?.kind.isVisible == true
                || !workStatusCards.isEmpty
                || !workDetailDisplayItems.isEmpty) {
                DisclosureGroup(isExpanded: $showsWorkDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(workDetailDisplayItems) { item in
                            AgentConversationDisplayRow(
                                item: item,
                                onSelectOption: onSelectOption
                            )
                        }
                        if let activity, activity.kind.isVisible {
                            AgentConversationActivityRow(
                                activity: activity,
                                projectedCandidatePatchIDs: Set(candidatePatchAssets.map(\.assetID)),
                                projectedGeneratedTestIDs: Set(generatedTestAssets.map(\.assetID)),
                                onCandidatePatchRevert: nil,
                                onCandidatePatchDestroySandbox: nil,
                                onPlanGeneratedTests: nil
                            )
                        }
                        if !workStatusCards.isEmpty {
                            AgentConversationWorkStatusCard(cards: workStatusCards)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    Label("Show work details", systemImage: "list.bullet.rectangle")
                        .font(.callout.weight(.semibold))
                }
            }

            let nonMissionApprovals = approvals.filter { $0.targetKind != .candidatePatchPlan }
            if showsMissionPresentation && !nonMissionApprovals.isEmpty {
                AgentConversationApprovalView(
                    approvals: nonMissionApprovals,
                    onApprove: onApprove,
                    onReject: onReject,
                    onRequestChanges: onRequestChanges
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .onAppear {
            showsWorkDetails = false
        }
        .onChange(of: activity?.kind.isTerminal) { _, isTerminal in
            if isTerminal == true { showsWorkDetails = false }
        }
    }

    // Kept as a non-rendered compatibility projection for exact Phase 2D.2B
    // view contracts. The active surface above presents these authorities only
    // through MissionPresentationView.
    @ViewBuilder
    private var retainedDetailedAssetProjection: some View {
        ForEach(generatedTestAssets, id: \.assetID) { snapshot in
            GeneratedTestPlanStatusCard(
                snapshot: snapshot,
                onGenerateArtifact: onGenerateTestArtifact,
                generationEligibility: generatedTestPlanGenerationEligibility?(snapshot)
                    ?? .unavailable("The exact Generated Test Plan action authority is unavailable.")
            )
        }
        ForEach(generatedTestArtifactAssets) { artifact in
            GeneratedTestArtifactCard(
                artifact: artifact,
                onRequestChanges: onRequestGeneratedTestArtifactChanges,
                onReject: onRejectGeneratedTestArtifact,
                onApprove: onApproveGeneratedTestArtifact,
                reviewEligibility: generatedTestArtifactReviewEligibility?(artifact)
                    ?? .unavailable("The exact Generated Test Artifact review authority is unavailable.")
            )
        }
    }
}

private struct AgentConversationActivityRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let activity: AgentConversationActivity
    let projectedCandidatePatchIDs: Set<String>
    let projectedGeneratedTestIDs: Set<String>
    let onCandidatePatchRevert: ((CandidatePatchActivitySnapshot) -> Void)?
    let onCandidatePatchDestroySandbox: ((CandidatePatchActivitySnapshot) -> Void)?
    let onPlanGeneratedTests: ((CandidatePatchActivitySnapshot) -> Void)?
    @State private var pulses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.14))
                        .frame(width: 26, height: 26)
                    if activity.kind.isTerminal {
                        Image(systemName: terminalSymbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(tint)
                    } else {
                        HStack(spacing: 2) {
                            ForEach(0..<3, id: \.self) { index in
                                Circle()
                                    .fill(tint.opacity(dotOpacity(index)))
                                    .frame(width: 3, height: 3)
                            }
                        }
                    }
                }

                Text(activity.label)
                    .font(.callout)
                    .foregroundStyle(activity.kind.isTerminal ? AnyShapeStyle(tint) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 48)
            }

            if let assessment = activity.metadata.aiAssessment {
                AIAssessmentStatusCard(assessment: assessment)
            }

            if let sandbox = activity.metadata.sandbox {
                SandboxStatusCard(snapshot: sandbox)
            }

            if let candidatePatch = activity.metadata.candidatePatch,
               !projectedCandidatePatchIDs.contains(candidatePatch.assetID) {
                CandidatePatchStatusCard(
                    snapshot: candidatePatch,
                    onRevert: onCandidatePatchRevert,
                    onDestroySandbox: onCandidatePatchDestroySandbox,
                    onPlanGeneratedTests: activity.metadata.generatedTest == nil
                        ? onPlanGeneratedTests
                        : nil
                )
            }

            if let generatedTest = activity.metadata.generatedTest,
               !projectedGeneratedTestIDs.contains(generatedTest.assetID) {
                GeneratedTestPlanStatusCard(snapshot: generatedTest, onGenerateArtifact: nil)
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Agent activity: \(activity.label)")
        .accessibilityAddTraits(activity.kind.isAnimated ? .updatesFrequently : [])
        .onAppear { updatePulse() }
        .onChange(of: activity.kind) { _, _ in updatePulse() }
        .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    private var tint: Color {
        switch activity.kind {
        case .failed: return .red
        case .blocked, .sandboxCreationBlocked, .candidatePatchBlocked,
             .generatedTestClarificationRequired, .generatedTestPlanningBlocked: return .orange
        case .partial: return .teal
        case .completed, .sandboxReady, .candidatePatchReady, .candidatePatchReverted, .sandboxDestroyed,
             .generatedTestPlanReviewReady: return .green
        default: return .accentColor
        }
    }

    private var terminalSymbol: String {
        switch activity.kind {
        case .failed: return "xmark"
        case .blocked, .sandboxCreationBlocked, .candidatePatchBlocked,
             .generatedTestClarificationRequired, .generatedTestPlanningBlocked: return "exclamationmark"
        case .partial: return "circle.lefthalf.filled"
        case .completed, .sandboxReady, .candidatePatchReady, .candidatePatchReverted, .sandboxDestroyed,
             .generatedTestPlanReviewReady: return "checkmark"
        default: return "circle.fill"
        }
    }

    private func dotOpacity(_ index: Int) -> Double {
        guard activity.shouldAnimate(reduceMotion: reduceMotion) else { return 0.58 }
        let highlighted = pulses ? 2 : 0
        return index == highlighted ? 0.86 : 0.28
    }

    private func updatePulse() {
        guard activity.shouldAnimate(reduceMotion: reduceMotion) else {
            pulses = false
            return
        }
        withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
            pulses = true
        }
    }
}

private struct CandidatePatchStatusCard: View {
    let snapshot: CandidatePatchActivitySnapshot
    let onRevert: ((CandidatePatchActivitySnapshot) -> Void)?
    let onDestroySandbox: ((CandidatePatchActivitySnapshot) -> Void)?
    let onPlanGeneratedTests: ((CandidatePatchActivitySnapshot) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Candidate Patch")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 116), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                metric("Patch ID", abbreviated(snapshot.patchID), color: .accentColor)
                metric("Plan ID", abbreviated(snapshot.planID), color: .accentColor)
                metric("Revision", snapshot.planRevision.map(String.init) ?? "—", color: .secondary)
                metric("Artifact", abbreviated(snapshot.candidatePatchArtifactSHA256), color: .accentColor)
                metric("Sandbox ID", abbreviated(snapshot.sandboxID), color: .accentColor)
                metric(
                    "Status",
                    snapshot.projectionState?.rawValue
                        ?? snapshot.status?.rawValue.uppercased()
                        ?? "PLANNING",
                    color: statusColor
                )
                metric("Files planned", String(snapshot.filesPlanned), color: .secondary)
                metric("Files changed", String(snapshot.filesChanged), color: .secondary)
                metric("Add / delete", "+\(snapshot.additions) / -\(snapshot.deletions)", color: .secondary)
                metric("Risk", snapshot.risk?.rawValue ?? "UNKNOWN", color: riskColor)
                metric("Evidence", String(snapshot.evidenceCount), color: .secondary)
                metric("Source", snapshot.sourceIntegrity?.rawValue.uppercased() ?? "UNKNOWN", color: sourceColor)
                metric("Approval", snapshot.approvalState?.rawValue ?? "PENDING", color: .purple)
            }

            DisclosureGroup("Exact details") {
                VStack(alignment: .leading, spacing: 7) {
                    exactDetail("Patch ID", snapshot.patchID)
                    exactDetail("Source Candidate Patch task ID", snapshot.sourceCandidatePatchTaskID)
                    exactDetail("Plan ID", snapshot.planID)
                    exactDetail("Plan revision", snapshot.planRevision.map(String.init))
                    exactDetail("Manifest ID", snapshot.manifestID)
                    exactDetail(
                        "Candidate Patch artifact SHA-256",
                        snapshot.candidatePatchArtifactSHA256,
                        truncatesVisibleValue: true
                    )
                    exactDetail("Sandbox ID", snapshot.sandboxID)
                    exactDetail("Source snapshot ID", snapshot.sourceSnapshotID)
                    exactDetail("Canonical Legacy root", snapshot.canonicalLegacyRoot)
                    exactDetail("Capability ID", snapshot.capabilityID)
                    exactDetail("Capability label", snapshot.capabilityDisplayLabel)
                    exactDetail("Assessment ID", snapshot.assessmentID)
                    exactDetail("Validation-test-plan digest", snapshot.validationTestPlanSHA256)
                    exactDetail("Unified Diff SHA-256", snapshot.unifiedDiffSHA256)
                    exactDetail(
                        "Lifecycle status",
                        snapshot.projectionState?.rawValue ?? snapshot.status?.rawValue.uppercased()
                    )
                    exactDetail("Approval status", snapshot.approvalState?.rawValue)
                    exactDetail("Files planned", String(snapshot.filesPlanned))
                    exactDetail("Files changed", String(snapshot.filesChanged))
                    exactDetail("Source integrity", snapshot.sourceIntegrity?.rawValue.uppercased())
                }
                .padding(.top, 4)
            }
            .font(.caption)

            if canPlanGeneratedTests {
                Button {
                    onPlanGeneratedTests?(snapshot)
                } label: {
                    Label("Prepare Generated Test Plan", systemImage: "checklist")
                }
                .buttonStyle(.borderedProminent)
                .disabled(snapshot.exactGeneratedTestSourceBinding == nil || onPlanGeneratedTests == nil)
                .accessibilityIdentifier("generatedTests.plan.exactPatch")
                if let reason = snapshot.generatedTestActionUnavailableReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("generatedTests.plan.bindingUnavailable")
                }
            }
            if canRevert, let onRevert {
                Button {
                    onRevert(snapshot)
                } label: {
                    Label("Revert Candidate Patch", systemImage: "arrow.uturn.backward.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("candidatePatch.revert.openConfirmation")
            }
            if canDestroySandbox, let onDestroySandbox {
                Button(role: .destructive) {
                    onDestroySandbox(snapshot)
                } label: {
                    Label("Destroy reverted Sandbox", systemImage: "trash")
                }
                .accessibilityIdentifier("candidatePatch.destroySandbox.openConfirmation")
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("candidatePatch.asset.\(snapshot.assetID)")
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .reviewReady, .applied, .reverted: .green
        case .rejected, .invalid, .stale: .orange
        default: .accentColor
        }
    }

    private var canRevert: Bool {
        snapshot.projectionState == .patchReady
            || snapshot.projectionState == .revertConfirmationRequired
            || snapshot.status == .reviewReady
            || snapshot.status == .applied
    }

    private var canPlanGeneratedTests: Bool {
        snapshot.projectionState == .patchReady || snapshot.status == .reviewReady
    }

    private var canDestroySandbox: Bool {
        guard snapshot.projectionState != .sandboxDestroyed else { return false }
        return snapshot.projectionState == .reverted
            || snapshot.projectionState == .sandboxDestructionConfirmationRequired
            || snapshot.status == .reverted
    }

    private var riskColor: Color {
        switch snapshot.risk {
        case .high: .red
        case .medium: .orange
        default: .green
        }
    }

    private var sourceColor: Color {
        snapshot.sourceIntegrity == .unchanged ? .green : .orange
    }

    private func abbreviated(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value.count > 12 ? "\(value.prefix(12))…" : value
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).foregroundStyle(color).lineLimit(1)
        }
    }

    @ViewBuilder
    private func exactDetail(
        _ label: String,
        _ value: String?,
        truncatesVisibleValue: Bool = false
    ) -> some View {
        let fullValue = value?.isEmpty == false ? value! : "—"
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 166, alignment: .leading)
            Text(truncatesVisibleValue ? abbreviated(value) : fullValue)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if fullValue != "—" {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(fullValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy full \(label)")
                .accessibilityLabel("Copy full \(label)")
            }
        }
    }
}

private struct GeneratedTestPlanStatusCard: View {
    let snapshot: GeneratedTestActivitySnapshot
    let onGenerateArtifact: ((GeneratedTestActivitySnapshot) -> Void)?
    var generationEligibility: GeneratedTestPlanGenerationEligibility = .unavailable(
        "The exact Generated Test Plan action authority is unavailable."
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Generated Test Plan")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 128), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                generatedTestMetric("Patch ID", abbreviated(snapshot.patchID))
                generatedTestMetric("Artifact", abbreviated(snapshot.candidatePatchArtifactSHA256))
                generatedTestMetric("Sandbox ID", abbreviated(snapshot.sandboxID))
                generatedTestMetric("Snapshot", abbreviated(snapshot.sourceSnapshotID))
                generatedTestMetric("Capability", snapshot.capabilityID ?? "UNKNOWN")
                generatedTestMetric("Assessment", abbreviated(snapshot.assessmentID))
                generatedTestMetric("Validation items", String(snapshot.validationPlanItemCount))
                generatedTestMetric("Framework", snapshot.framework ?? "UNKNOWN")
                generatedTestMetric("Test location", snapshot.testLocation ?? "UNKNOWN")
                generatedTestMetric("Scenarios", String(snapshot.scenarioCount))
                generatedTestMetric("Status", snapshot.status.rawValue)
            }
            if !snapshot.proposedTestPaths.isEmpty {
                Text("Proposed paths: \(snapshot.proposedTestPaths.joined(separator: ", "))")
                    .font(.caption)
                    .textSelection(.enabled)
            }
            if !snapshot.remainingUnknowns.isEmpty {
                Text("Remaining unknowns: \(snapshot.remainingUnknowns.joined(separator: " · "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
            if snapshot.framework == nil && snapshot.testLocation == nil {
                Text("No grounded framework was found. No grounded test location was found.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            DisclosureGroup("Exact Plan binding") {
                VStack(alignment: .leading, spacing: 5) {
                    generatedTestExact("Projection key", snapshot.assetID)
                    generatedTestExact("Planning task ID", snapshot.planningTaskID)
                    generatedTestExact("Generated Test Plan ID", snapshot.generatedTestPlanID)
                    generatedTestExact("Plan revision", snapshot.generatedTestPlanRevision.map(String.init))
                    generatedTestExact("Plan SHA-256", snapshot.generatedTestPlanSHA256)
                    generatedTestExact("Source binding SHA-256", snapshot.generatedTestSourceBindingSHA256)
                    generatedTestExact("Source Candidate Patch task ID", snapshot.sourceCandidatePatchTaskID)
                    generatedTestExact("Candidate Patch ID", snapshot.patchID)
                    generatedTestExact("Candidate Patch artifact", snapshot.candidatePatchArtifactSHA256)
                    generatedTestExact("Sandbox ID", snapshot.sandboxID)
                    generatedTestExact("Source snapshot", snapshot.sourceSnapshotID)
                }
                .padding(.top, 4)
            }
            .font(.caption)
            Text("No test files were created. Test syntax was not verified. Build was not executed. Tests were not executed. Behavioral correctness was not verified.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Phase 2D.3 is unavailable.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
            if snapshot.status == .testPlanReviewReady {
                Button {
                    onGenerateArtifact?(snapshot)
                } label: {
                    Label("Generate Reviewable Virtual Test Files", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!generationEligibility.isAvailable || onGenerateArtifact == nil)
                .accessibilityIdentifier("generatedTests.artifact.generate")
                if let unavailableReason = generationEligibility.unavailableReason {
                    Text(unavailableReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("generatedTests.artifact.generate.unavailableReason")
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("generatedTests.plan.status")
    }

    private func generatedTestMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private func abbreviated(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value.count > 12 ? "\(value.prefix(12))…" : value
    }

    private func generatedTestExact(_ label: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 184, alignment: .leading)
            Text(value ?? "UNAVAILABLE")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SandboxStatusCard: View {
    let snapshot: SandboxActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sandbox Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 116), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                metric("Sandbox ID", abbreviated(snapshot.sandboxID), color: .accentColor)
                metric("Source Snapshot", abbreviated(snapshot.sourceSnapshotID), color: .accentColor)
                metric("Status", snapshot.status?.rawValue.uppercased() ?? "VALIDATING", color: statusColor)
                metric("Included", String(snapshot.includedFileCount), color: .secondary)
                metric("Excluded", String(snapshot.excludedItemCount), color: .secondary)
                metric("Integrity", snapshot.integrityStatus.rawValue.uppercased(), color: integrityColor)
                metric("Source", sourceStatus, color: sourceColor)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .ready: .green
        case .invalid, .tainted, .stale: .orange
        default: .accentColor
        }
    }

    private var integrityColor: Color {
        switch snapshot.integrityStatus {
        case .passed: .green
        case .failed: .red
        case .notValidated: .secondary
        }
    }

    private var sourceStatus: String {
        sandboxSourceStatus(for: snapshot)
    }

    private var sourceColor: Color {
        sandboxSourceColor(for: snapshot)
    }

    private func abbreviated(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return value.count > 12 ? "\(value.prefix(12))…" : value
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}

func sandboxSourceStatus(for snapshot: SandboxActivitySnapshot) -> String {
    switch snapshot.sourceUnchanged {
    case .some(true): "UNCHANGED"
    case .some(false): "CHANGED"
    case .none: "UNKNOWN"
    }
}

func sandboxSourceColor(for snapshot: SandboxActivitySnapshot) -> Color {
    switch snapshot.sourceUnchanged {
    case .some(true): .green
    case .some(false): .orange
    case .none: .secondary
    }
}

private struct AIAssessmentStatusCard: View {
    let assessment: AIAssessmentActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assessment Status")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 116), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                metric("AI Capability", assessment.capability, color: .accentColor)
                metric("Mission State", assessment.missionState.rawValue, color: .accentColor)
                metric("Compatibility", assessment.compatibility?.rawValue ?? "ANALYZING", color: compatibilityColor)
                metric("Risk", assessment.risk?.rawValue ?? "UNKNOWN", color: riskColor)
                metric("Blockers", assessment.blockerCount.map(String.init) ?? "—", color: .orange)
                metric("Evidence", "\(assessment.evidenceCount) items", color: .secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
        }
        .accessibilityElement(children: .combine)
    }

    private func metric(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(2)
        }
    }

    private var compatibilityColor: Color {
        switch assessment.compatibility {
        case .yes: return .green
        case .partial: return .orange
        case .no: return .red
        case nil: return .secondary
        }
    }

    private var riskColor: Color {
        switch assessment.risk {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case nil: return .secondary
        }
    }
}

private struct AgentConversationDisplayRow: View {
    let item: AgentConversationDisplayItem
    let onSelectOption: (UUID, String) -> Void

    var body: some View {
        switch item.content {
        case let .message(message):
            AgentConversationMessageRow(
                message: message,
                onSelectOption: { optionID in
                    onSelectOption(message.id, optionID)
                }
            )
        case let .streamingResponse(response):
            AgentStreamingMarkdownResponseRow(response: response)
        }
    }
}

private struct AgentConversationMessageRow: View {
    let message: AgentMessage
    let onSelectOption: (String) -> Void

    var body: some View {
        HStack(alignment: .top) {
            if message.sender == .user {
                Spacer(minLength: 48)
            }

            HStack(alignment: .top, spacing: 10) {
                if message.sender != .user {
                    ZStack {
                        Circle()
                            .fill(message.type.tint.opacity(0.14))
                            .frame(width: 30, height: 30)
                        Image(systemName: message.type.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(message.type.tint)
                    }
                }

                VStack(alignment: .leading, spacing: message.sender == .user ? WorkspaceVisualStyle.Spacing.x8 : 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(message.sender == .user ? "You" : "Agent")
                            .font(WorkspaceVisualStyle.Typography.label)
                            .foregroundStyle(
                                message.sender == .user
                                    ? WorkspaceVisualStyle.color(.textSecondary)
                                    : message.type.tint
                            )
                        if message.sender != .user {
                            Text(message.type.title)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(message.type.tint.opacity(0.8))
                        }
                        if message.relatedArtifactID != nil {
                            Image(systemName: "paperclip")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    if message.sender == .agent {
                        StructuredAgentResponseView(
                            response: StructuredAgentResponseProjector.response(for: message)
                        )
                    } else {
                        Text(message.content)
                            .font(WorkspaceVisualStyle.Typography.body)
                            .foregroundStyle(WorkspaceVisualStyle.color(.textPrimary))
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !message.options.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(message.options) { option in
                                Button {
                                    onSelectOption(option.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: message.selectedOptionID == option.id ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(message.selectedOptionID == option.id ? .green : .secondary)
                                        Text(option.title)
                                            .font(.callout.weight(.semibold))
                                        Spacer(minLength: 0)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                                .disabled(message.selectedOptionID != nil)
                                .padding(8)
                                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(message.selectedOptionID == option.id ? Color.green.opacity(0.6) : Color(nsColor: .separatorColor), lineWidth: 0.7)
                                )
                            }
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .padding(message.sender == .user ? WorkspaceVisualStyle.Spacing.x16 : 10)
            .frame(maxWidth: 620, alignment: .leading)
            .background(
                messageBubbleBackground,
                in: RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.artifactCard, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.artifactCard, style: .continuous)
                    .stroke(messageStrokeColor, lineWidth: message.sender == .user ? 0 : 0.7)
            )
            .shadow(
                color: message.sender == .user ? .black.opacity(0.025) : .clear,
                radius: 3,
                y: 1
            )

            if message.sender != .user {
                Spacer(minLength: 48)
            }
        }
    }

    private var messageBubbleBackground: Color {
        if message.sender == .user {
            return WorkspaceVisualStyle.color(.controlSurface)
        }
        return message.type.bubbleBackground
    }

    private var messageStrokeColor: Color {
        if message.sender == .user {
            return .clear
        }
        return message.type.tint.opacity(0.18)
    }
}

private struct AgentStreamingMarkdownResponseRow: View {
    let response: AgentConversationStreamingResponse

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AgentAvatar(tint: response.messageType.tint, symbol: response.messageType.symbol)

            StructuredAgentResponseView(
                response: StructuredAgentResponseProjector.response(for: AgentMessage(
                    id: UUID(uuidString: response.id) ?? UUID(),
                    sender: .agent,
                    type: response.messageType,
                    content: response.markdown,
                    relatedEventID: response.chunks.reversed().compactMap(\.relatedEventID).first,
                    relatedArtifactID: response.relatedArtifactID
                ))
            )

            Spacer(minLength: 48)
        }
    }
}

private struct AgentAvatar: View {
    let tint: Color
    let symbol: String

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(0.10))
                .frame(width: 26, height: 26)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
        }
        .padding(.top, 1)
    }
}

private struct AgentMarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(markdownBlocks.enumerated()), id: \.offset) { _, block in
                if block.containsBulletLine {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(block.lines) { line in
                            if line.isBullet {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Circle()
                                        .fill(Color.secondary.opacity(0.65))
                                        .frame(width: 4, height: 4)
                                    Text(attributedMarkdown(line.content))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            } else {
                                Text(attributedMarkdown(line.content))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                } else {
                    Text(attributedMarkdown(block.content))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var markdownBlocks: [MarkdownBlock] {
        MarkdownBlock.blocks(from: markdown)
    }

    private func attributedMarkdown(_ value: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        return (try? AttributedString(markdown: value, options: options)) ?? AttributedString(value)
    }
}

private struct MarkdownBlock {
    var content: String

    var containsBulletLine: Bool {
        lines.contains { $0.isBullet }
    }

    var lines: [MarkdownLine] {
        content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .compactMap { index, rawLine in
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { return nil }
                if line.hasPrefix("- ") || line.hasPrefix("* ") {
                    return MarkdownLine(
                        id: index,
                        content: String(line.dropFirst(2)),
                        isBullet: true
                    )
                }
                return MarkdownLine(
                    id: index,
                    content: line,
                    isBullet: false
                )
            }
    }

    static func blocks(from markdown: String) -> [MarkdownBlock] {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        return normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map(MarkdownBlock.init(content:))
    }
}

private struct MarkdownLine: Identifiable {
    let id: Int
    var content: String
    var isBullet: Bool
}

private struct AgentConversationWorkStatusCard: View {
    let cards: [AgentConversationWorkUnitCard]
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let currentCard {
                HStack(alignment: .center, spacing: 10) {
                    Circle()
                        .fill(currentCard.status.tint)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Work Status")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(currentCard.title)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 12)

                    if let metricsSummary {
                        Text(metricsSummary)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    AgentWorkUnitStatusToken(status: currentCard.status)
                }
            }

            DisclosureGroup(isExpanded: $showsDetails) {
                VStack(alignment: .leading, spacing: 12) {
                    if let currentCard {
                        Text(currentCard.narration)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .textSelection(.enabled)
                    }

                    if !toolsUsed.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("Tools", systemImage: "terminal")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            FlowChipGroup(values: toolsUsed)
                        }
                    }

                    if let evidenceSummary {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Evidence", systemImage: "paperclip")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(evidenceSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(cards) { card in
                            AgentWorkUnitMetadataRow(card: card)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }
                .padding(.top, 6)
            } label: {
                Label(showsDetails ? "Hide details" : "Show details", systemImage: "rectangle.stack")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 680, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor).opacity(0.38), lineWidth: 0.7)
        )
        .animation(.easeInOut(duration: 0.2), value: currentCard?.id)
        .animation(.easeInOut(duration: 0.2), value: metricsSummary)
    }

    private var currentCard: AgentConversationWorkUnitCard? {
        if let active = cards.last(where: {
            $0.status == .active
                || $0.status == .planned
                || $0.status == .waitingApproval
                || $0.status == .blocked
                || $0.status == .partial
        }) {
            return active
        }
        return cards.last(where: { card in
            card.kind == .result && card.rawEvents.contains { $0.eventType == .taskCompleted }
        })
        ?? cards.last(where: { $0.kind == .result })
        ?? cards.last
    }

    private var toolsUsed: [String] {
        unique(cards.flatMap(\.toolsUsed))
    }

    private var metricsSummary: String? {
        var values: [String] = []
        let explored = Set(cards.flatMap(\.metrics.filesExplored)).count
        let modified = Set(cards.flatMap(\.metrics.filesModified)).count
        let commands = cards.reduce(0) { $0 + $1.metrics.commandsRun }
        let tests = cards.reduce(0) { $0 + $1.metrics.testsPassed }
        let recovered = cards.reduce(0) { $0 + $1.metrics.errorsRecovered }
        if explored > 0 { values.append("\(explored) explored") }
        if modified > 0 { values.append("\(modified) modified") }
        if commands > 0 { values.append("\(commands) commands") }
        if tests > 0 { values.append("\(tests) tests passed") }
        if recovered > 0 { values.append("\(recovered) recovered") }
        return values.isEmpty ? nil : values.joined(separator: " · ")
    }

    private var evidenceSummary: String? {
        cards.reversed().compactMap(\.evidenceSummary).first
    }

    private func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { value in
            let key = value.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }
}

private struct AgentWorkUnitMetadataRow: View {
    let card: AgentConversationWorkUnitCard

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: card.agent?.conversationSymbol ?? card.kind.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(card.agent?.conversationTint ?? card.kind.tint)
                    .frame(width: 16)
                Text(card.kind.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(card.title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                AgentWorkUnitStatusToken(status: card.status)
            }

            if !card.completedSteps.isEmpty {
                Text(card.completedSteps.prefix(3).joined(separator: " / "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if !card.rawEvents.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(card.rawEvents) { event in
                            AgentRawEventRow(event: event)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("\(card.rawEvents.count) raw events")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AgentWorkUnitStatusToken: View {
    let status: AgentWorkUnitStatus

    var body: some View {
        Text(status.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(status.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct FlowChipGroup: View {
    let values: [String]
    private let columns = [GridItem(.adaptive(minimum: 130), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(Array(values.prefix(4)), id: \.self) { value in
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.32), lineWidth: 0.7)
                    )
            }
        }
    }
}

private struct AgentRawEventRow: View {
    let event: AgentConversationRawEventRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("#\(event.sequence)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(event.eventType.rawValue)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let detail = event.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .textSelection(.enabled)
    }
}

private struct AgentConversationApprovalView: View {
    let approvals: [ApprovalRequest]
    let onApprove: (ApprovalRequest) -> Void
    let onReject: (ApprovalRequest) -> Void
    let onRequestChanges: ((ApprovalRequest, String) -> Void)?
    @State private var revisionInstructions: [UUID: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Approval Request", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.purple)

            ForEach(approvals) { approval in
                VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(approval.action.capitalized)
                            .font(.callout.weight(.semibold))
                        Text(AgentPresentationSanitizer.safeContent(approval.resource, fallback: "Action requires approval"))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                        if let plan = approval.metadata["candidate_patch_plan_summary"],
                           !plan.isEmpty {
                            ScrollView {
                                Text(plan)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                            }
                            .frame(maxHeight: 240)
                            .padding(.top, 4)
                        }
                    }
                    Spacer()
                    Button {
                        onReject(approval)
                    } label: {
                        Label("Reject", systemImage: "xmark.shield")
                    }
                    .accessibilityLabel("Reject Candidate Patch plan")
                    .accessibilityIdentifier(
                        approval.targetKind == .candidatePatchPlan
                            ? "candidatePatch.reject"
                            : "approval.reject"
                    )
                    Button {
                        onApprove(approval)
                    } label: {
                        Label("Approve", systemImage: "checkmark.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Approve Candidate Patch plan")
                    .accessibilityIdentifier(
                        approval.targetKind == .candidatePatchPlan
                            ? "candidatePatch.approve.openConfirmation"
                            : "approval.approve"
                    )
                    .focusable(approval.targetKind != .candidatePatchPlan)
                }
                    if approval.targetKind == .candidatePatchPlan, let onRequestChanges {
                        HStack(spacing: 8) {
                            TextField(
                                "Describe the required Candidate Patch revision",
                                text: Binding(
                                    get: { revisionInstructions[approval.id, default: ""] },
                                    set: { revisionInstructions[approval.id] = $0 }
                                )
                            )
                            Button {
                                onRequestChanges(
                                    approval,
                                    revisionInstructions[approval.id, default: ""]
                                )
                            } label: {
                                Label("Request changes", systemImage: "pencil.and.list.clipboard")
                            }
                            .accessibilityLabel("Request Candidate Patch plan changes")
                            .accessibilityIdentifier("candidatePatch.requestChanges")
                            .disabled(
                                revisionInstructions[approval.id, default: ""]
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                    .isEmpty
                            )
                        }
                    }
                }
                .padding(10)
                .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.purple.opacity(0.35), lineWidth: 0.8)
                )
            }
        }
    }
}

private extension AgentMessageType {
    var title: String {
        switch self {
        case .text: return "Message"
        case .progressUpdate: return "Progress"
        case .planUpdate: return "Plan"
        case .question: return "Question"
        case .decisionRequest: return "Decision"
        case .warning: return "Warning"
        case .artifact: return "Artifact"
        case .userRequest: return "User"
        case .agentStatus: return "Agent"
        case .observation: return "Observation"
        case .actionUpdate: return "Action"
        case .decision: return "Decision"
        case .evidence: return "Evidence"
        case .result: return "Result"
        case .approvalRequest: return "Approval"
        }
    }

    var symbol: String {
        switch self {
        case .text: return "text.bubble"
        case .progressUpdate: return "dot.radiowaves.left.and.right"
        case .planUpdate: return "list.bullet.clipboard"
        case .question: return "questionmark.bubble"
        case .decisionRequest: return "arrow.triangle.branch"
        case .warning: return "exclamationmark.triangle"
        case .artifact: return "doc.richtext"
        case .userRequest: return "person.fill"
        case .agentStatus: return "brain.head.profile"
        case .observation: return "eye"
        case .actionUpdate: return "bolt.horizontal"
        case .decision: return "arrow.triangle.branch"
        case .evidence: return "paperclip"
        case .result: return "checkmark.seal"
        case .approvalRequest: return "checkmark.shield"
        }
    }

    var tint: Color {
        switch self {
        case .text: return .accentColor
        case .progressUpdate: return .blue
        case .planUpdate: return .purple
        case .question: return .orange
        case .decisionRequest: return .purple
        case .warning: return .red
        case .artifact: return .teal
        case .userRequest: return .accentColor
        case .agentStatus: return .secondary
        case .observation: return .blue
        case .actionUpdate: return .orange
        case .decision: return .purple
        case .evidence: return .teal
        case .result: return .green
        case .approvalRequest: return .purple
        }
    }

    var bubbleBackground: Color {
        switch self {
        case .userRequest, .text:
            return Color.accentColor.opacity(0.08)
        default:
            return Color(nsColor: .controlBackgroundColor)
        }
    }
}

private extension AgentWorkUnitKind {
    var title: String {
        switch self {
        case .request: return "Request"
        case .understanding: return "Understanding"
        case .planning: return "Planning"
        case .execution: return "Execution"
        case .approval: return "Approval"
        case .recovery: return "Recovery"
        case .policy: return "Policy"
        case .result: return "Result"
        case .system: return "System"
        }
    }

    var symbol: String {
        switch self {
        case .request: return "text.bubble"
        case .understanding: return "brain.head.profile"
        case .planning: return "list.bullet.clipboard"
        case .execution: return "terminal"
        case .approval: return "checkmark.shield"
        case .recovery: return "shield.lefthalf.filled"
        case .policy: return "checklist.checked"
        case .result: return "checkmark.seal"
        case .system: return "gearshape"
        }
    }

    var tint: Color {
        switch self {
        case .request: return .accentColor
        case .understanding: return .teal
        case .planning: return .blue
        case .execution: return .orange
        case .approval: return .purple
        case .recovery: return .indigo
        case .policy: return .indigo
        case .result: return .green
        case .system: return .secondary
        }
    }
}

private extension AgentWorkUnitStatus {
    var title: String {
        switch self {
        case .planned: return "Planned"
        case .active: return "Active"
        case .waitingApproval: return "Waiting"
        case .blocked: return "Blocked"
        case .partial: return "Partial"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    var tint: Color {
        switch self {
        case .planned: return .blue
        case .active: return .accentColor
        case .waitingApproval: return .purple
        case .blocked: return .orange
        case .partial: return .teal
        case .completed: return .green
        case .failed: return .red
        }
    }

    var strokeColor: Color {
        switch self {
        case .planned: return .blue.opacity(0.7)
        case .active: return .accentColor
        case .waitingApproval: return .purple
        case .blocked: return .orange
        case .partial: return .teal
        case .completed: return Color(nsColor: .separatorColor)
        case .failed: return .red
        }
    }
}

private extension AgentKind {
    var conversationSymbol: String {
        switch self {
        case .planner: return "list.bullet.clipboard"
        case .executor: return "gearshape.2"
        case .systemUnderstanding: return "brain.head.profile"
        case .recovery: return "shield.lefthalf.filled"
        case .policy: return "checklist.checked"
        }
    }

    var conversationTint: Color {
        switch self {
        case .planner: return .blue
        case .executor: return .orange
        case .systemUnderstanding: return .teal
        case .recovery: return .purple
        case .policy: return .indigo
        }
    }
}

extension AgentInteractionState {
    var conversationTitle: String {
        switch self {
        case .draft: return "Draft"
        case .idle: return "Idle"
        case .responding: return "Responding"
        case .understanding: return "Understanding"
        case .planning: return "Planning"
        case .working: return "Working"
        case .running: return "Running"
        case .waitingForUser: return "Waiting For User"
        case .waitingForApproval: return "Waiting For Approval"
        case .verifying: return "Verifying"
        case .blocked: return "Blocked"
        case .blockedProvider: return "Provider Unavailable"
        case .blockedPermission: return "Permission Required"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var conversationColor: Color {
        switch self {
        case .draft: return .secondary
        case .idle: return .secondary
        case .responding: return .accentColor
        case .understanding, .planning: return .accentColor
        case .working, .running: return .blue
        case .waitingForUser, .waitingForApproval: return .purple
        case .verifying: return .teal
        case .blocked, .blockedProvider, .blockedPermission: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }

    var conversationSymbol: String {
        switch self {
        case .draft: return "square.and.pencil"
        case .idle: return "circle"
        case .responding: return "ellipsis.bubble"
        case .understanding: return "brain.head.profile"
        case .planning: return "list.bullet.clipboard"
        case .working: return "terminal"
        case .running: return "terminal.fill"
        case .waitingForUser: return "person.crop.circle.badge.questionmark"
        case .waitingForApproval: return "checkmark.shield"
        case .verifying: return "checkmark.magnifyingglass"
        case .blocked: return "exclamationmark.octagon"
        case .blockedProvider: return "network.slash"
        case .blockedPermission: return "lock.trianglebadge.exclamationmark"
        case .completed: return "checkmark.seal"
        case .failed: return "xmark.octagon"
        }
    }
}

extension AgentConversationActivity {
    var conversationTitle: String {
        switch kind {
        case .idle: return "Idle"
        case .thinking: return "Thinking"
        case .preparingTask, .compilingContext: return "Understanding"
        case .planning, .repairingPlan, .validatingPlan, .preparingCandidatePatch,
             .preparingGeneratedTestPlan: return "Planning"
        case .waitingCandidatePatchApproval: return "Waiting For Approval"
        case .inspectingProject, .listingDirectory, .searchingFiles, .searchingCode,
             .readingFile, .analyzingEvidence, .validatingLegacySource,
             .confirmingCanonicalLegacyRoot, .checkingLocalSourceAvailability, .creatingSourceSnapshot,
             .creatingIsolatedSandbox, .copyingApprovedSourceFiles, .excludingSensitiveFiles,
             .destroyingSandbox, .applyingCandidatePatch, .revertingCandidatePatch,
             .resolvingGeneratedTestEnvironment: return "Working"
        case .verifyingFileHashes, .checkingPathContainment, .confirmingSourceIsolation,
             .confirmingOriginalLegacyUnchanged, .finalizingSandboxAcceptance, .buildingUnifiedDiff:
            return "Verifying"
        case .candidatePatchReady: return "Candidate Patch Ready"
        case .candidatePatchReverted: return "Candidate Patch Reverted"
        case .sandboxDestroyed: return "Sandbox Destroyed"
        case .generatedTestPlanReviewReady: return "Generated Test Plan Ready"
        case .generatedTestClarificationRequired: return "Clarification Required"
        case .candidatePatchBlocked, .generatedTestPlanningBlocked: return "Blocked"
        case .sandboxReady: return "Sandbox Ready"
        case .sandboxCreationBlocked: return "Blocked"
        case .preparingFinalAnswer, .preparingPartialAnswer: return "Verifying"
        case .retryingProvider: return "Retrying"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        case .partial: return "Partial"
        case .completed: return scope == .normalChat ? "Idle" : "Completed"
        }
    }

    var conversationColor: Color {
        switch kind {
        case .idle: return .secondary
        case .thinking, .preparingTask, .compilingContext, .planning, .repairingPlan, .validatingPlan,
             .preparingCandidatePatch, .preparingGeneratedTestPlan:
            return .accentColor
        case .waitingCandidatePatchApproval:
            return .purple
        case .inspectingProject, .listingDirectory, .searchingFiles, .searchingCode,
             .readingFile, .analyzingEvidence, .validatingLegacySource,
             .confirmingCanonicalLegacyRoot, .checkingLocalSourceAvailability, .creatingSourceSnapshot,
             .creatingIsolatedSandbox, .copyingApprovedSourceFiles, .excludingSensitiveFiles,
             .destroyingSandbox, .applyingCandidatePatch, .revertingCandidatePatch,
             .resolvingGeneratedTestEnvironment:
            return .blue
        case .preparingFinalAnswer, .preparingPartialAnswer, .verifyingFileHashes,
             .checkingPathContainment, .confirmingSourceIsolation,
             .confirmingOriginalLegacyUnchanged, .finalizingSandboxAcceptance, .buildingUnifiedDiff:
            return .teal
        case .sandboxReady, .candidatePatchReady, .candidatePatchReverted, .sandboxDestroyed,
             .generatedTestPlanReviewReady:
            return .green
        case .sandboxCreationBlocked, .candidatePatchBlocked,
             .generatedTestClarificationRequired, .generatedTestPlanningBlocked:
            return .orange
        case .retryingProvider:
            return .purple
        case .blocked:
            return .orange
        case .failed:
            return .red
        case .partial:
            return .teal
        case .completed:
            return scope == .normalChat ? .secondary : .green
        }
    }
}
