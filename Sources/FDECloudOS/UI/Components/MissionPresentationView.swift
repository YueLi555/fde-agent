import AppKit
import SwiftUI

struct MissionPresentationView: View {
    let state: MissionPresentationState
    let candidatePatchReviewEligibility: ((ApprovalRequest) -> Bool)?
    let generatedTestPlanGenerationEligibility: ((GeneratedTestActivitySnapshot) -> GeneratedTestPlanGenerationEligibility)?
    let generatedTestArtifactReviewEligibility: ((GeneratedTestArtifact) -> GeneratedTestArtifactReviewEligibility)?
    let onApproveCandidatePatch: (ApprovalRequest) -> Void
    let onRejectCandidatePatch: (ApprovalRequest) -> Void
    let onRequestCandidatePatchChanges: ((ApprovalRequest, String) -> Void)?
    let onPlanGeneratedTests: ((CandidatePatchActivitySnapshot) -> Void)?
    let onGenerateTestArtifact: ((GeneratedTestActivitySnapshot) -> Void)?
    let onReviewProposedTests: MissionGeneratedTestReviewAction?
    let onRequestGeneratedTestArtifactChanges: ((GeneratedTestArtifact, String) -> Void)?
    let onRejectGeneratedTestArtifact: ((GeneratedTestArtifact) -> Void)?
    let onApproveGeneratedTestArtifact: ((GeneratedTestArtifact) -> Void)?
    let onUndoRun: ((MissionSummary) -> Void)?
    let onRetryCleanup: ((MissionSummary) -> Void)?
    let onShowWorkDetails: () -> Void

    @State private var reviewTarget: MissionReviewTarget?
    @State private var showsFileWorkspace = false
    @State private var showsHistory = false
    @State private var showsAdvancedDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            currentRun
            previousRuns
        }
        .sheet(item: $reviewTarget) { target in
            MissionUnifiedReviewSheet(
                target: target,
                candidateReviewEligibility: candidateReviewEligibility,
                artifactReviewEligibility: artifactReviewEligibility,
                onApproveCandidatePatch: { approval in
                    reviewTarget = nil
                    onApproveCandidatePatch(approval)
                },
                onRejectCandidatePatch: { approval in
                    reviewTarget = nil
                    onRejectCandidatePatch(approval)
                },
                onRequestCandidatePatchChanges: { approval, instructions in
                    reviewTarget = nil
                    onRequestCandidatePatchChanges?(approval, instructions)
                },
                onApproveArtifact: { artifact in
                    reviewTarget = nil
                    onApproveGeneratedTestArtifact?(artifact)
                },
                onRejectArtifact: { artifact in
                    reviewTarget = nil
                    onRejectGeneratedTestArtifact?(artifact)
                },
                onRequestArtifactChanges: { artifact, instructions in
                    reviewTarget = nil
                    onRequestGeneratedTestArtifactChanges?(artifact, instructions)
                },
                onOpenFiles: {
                    reviewTarget = nil
                    DispatchQueue.main.async { showsFileWorkspace = true }
                },
                onCancel: { reviewTarget = nil }
            )
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showsFileWorkspace) {
            if let artifact = state.current.generatedTestArtifact {
                GeneratedTestFileWorkspace(artifact: artifact)
            }
        }
    }

    private var currentRun: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current Run")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(state.current.title)
                        .font(.title3.weight(.semibold))
                    Text(state.current.goal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 16)
                Menu {
                    if state.current.generatedTestArtifact != nil {
                        Button("Open generated test files") {
                            showsFileWorkspace = true
                        }
                    }
                    Button("View audit trail") {
                        showsAdvancedDetails = true
                    }
                    if state.current.undoEligible,
                       state.current.cleanup == nil || state.current.cleanup?.phase == .partialFailure {
                        Divider()
                        Button("Undo this run", role: .destructive) {
                            onUndoRun?(state.current)
                        }
                        .disabled(
                            onUndoRun == nil
                                || state.current.cleanup?.freezesMissionActions == true
                                || !state.current.undoEligible
                        )
                        .accessibilityIdentifier("mission.current.undo")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .help("More mission actions")
                .accessibilityLabel("More mission actions")
                .accessibilityIdentifier("mission.current.more")
            }

            MissionProgressView(items: state.current.progress)

            VStack(alignment: .leading, spacing: 5) {
                Text(state.current.result)
                    .font(.callout.weight(.semibold))
                    .accessibilityIdentifier("mission.current.stage")
                Text(state.current.safetySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Phase 2D.3 is unavailable. Ready never means tests passed, runtime verified, or deployment ready.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if let cleanup = state.current.cleanup, cleanup.phase == .partialFailure {
                MissionPartialCleanupView(cleanup: cleanup)
            }

            if let action = state.current.primaryAction {
                Button {
                    perform(action)
                } label: {
                    Label(action.label, systemImage: primaryActionSymbol(action))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryActionDisabled(action))
                .accessibilityIdentifier(
                    action == .retryCleanup
                        ? "mission.current.cleanup.retry"
                        : "mission.current.primaryAction"
                )
            }

            Button {
                showsAdvancedDetails.toggle()
            } label: {
                HStack {
                    Text("Advanced details")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Image(systemName: showsAdvancedDetails ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mission.current.advanced.toggle")
            .accessibilityValue(showsAdvancedDetails ? "Expanded" : "Collapsed")
            if showsAdvancedDetails {
                MissionExactDetailsView(details: state.current.exactDetails)
                    .padding(.top, 7)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 0.8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mission.current.card")
        .onAppear {
            showsAdvancedDetails = state.advancedDetailsExpandedByDefault
        }
        .onChange(of: state.current.missionID) { _, _ in
            showsAdvancedDetails = state.advancedDetailsExpandedByDefault
            reviewTarget = nil
            showsFileWorkspace = false
        }
    }

    private var previousRuns: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                showsHistory.toggle()
            } label: {
                HStack {
                    Text("Previous Runs (\(state.previousRuns.count))")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Image(systemName: showsHistory ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mission.history.toggle")
            .accessibilityValue(showsHistory ? "Expanded" : "Collapsed")
            if showsHistory {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(state.previousRuns) { entry in
                    MissionHistoryRow(entry: entry)
                }
            }
            .padding(.top, 8)
            .accessibilityIdentifier("mission.history.list")
            }
        }
        .onAppear {
            showsHistory = state.previousRunsExpandedByDefault
        }
        .onChange(of: state.current.missionID) { _, _ in
            showsHistory = false
        }
    }

    private var candidateReviewEligibility: Bool {
        state.current.cleanup?.freezesMissionActions != true
            && state.current.candidatePatchApproval.map {
                candidatePatchReviewEligibility?($0) ?? false
            } == true
    }

    private var artifactReviewEligibility: GeneratedTestArtifactReviewEligibility {
        guard state.current.cleanup?.freezesMissionActions != true,
              let artifact = state.current.generatedTestArtifact else {
            return .unavailable("This mission is currently locked for cleanup.")
        }
        return generatedTestArtifactReviewEligibility?(artifact)
            ?? .unavailable("The exact Generated Test Artifact review authority is unavailable.")
    }

    private func perform(_ action: MissionPrimaryAction) {
        switch action {
        case .reviewProposedChange:
            if let approval = state.current.candidatePatchApproval {
                reviewTarget = .candidatePatch(approval, state.current)
            }
        case .continueToTestReview:
            if state.current.generatedTestArtifact == nil,
               let plan = state.current.generatedTestPlan {
                let eligibility = generatedTestPlanGenerationEligibility?(plan)
                    ?? .unavailable("The exact Generated Test Plan authority is unavailable.")
                if eligibility.isAvailable { onGenerateTestArtifact?(plan) }
            } else if state.current.generatedTestPlan == nil,
                      let patch = state.current.candidatePatch {
                onPlanGeneratedTests?(patch)
            }
        case .reviewProposedTests:
            onReviewProposedTests?(state.current) { artifact in
                guard let artifact else { return }
                reviewTarget = .generatedTestArtifact(artifact, state.current)
            }
        case .retryCleanup:
            onRetryCleanup?(state.current)
        case .assessSystem, .continueAssessment, .reviewFindings, .resolveBlocker:
            onShowWorkDetails()
        }
    }

    private func primaryActionDisabled(_ action: MissionPrimaryAction) -> Bool {
        if state.current.cleanup?.freezesMissionActions == true, action != .retryCleanup { return true }
        switch action {
        case .reviewProposedChange:
            return !candidateReviewEligibility
        case .reviewProposedTests:
            guard onReviewProposedTests != nil else { return true }
            if state.current.generatedTestArtifact != nil {
                return !artifactReviewEligibility.isAvailable
            }
            guard let plan = state.current.generatedTestPlan else { return true }
            return !(generatedTestPlanGenerationEligibility?(plan).isAvailable ?? false)
        case .continueToTestReview:
            if let plan = state.current.generatedTestPlan {
                return !(generatedTestPlanGenerationEligibility?(plan).isAvailable ?? false)
            }
            return state.current.candidatePatch?.exactGeneratedTestSourceBinding == nil
                || onPlanGeneratedTests == nil
        case .retryCleanup:
            return state.current.cleanup?.needsRetry != true || onRetryCleanup == nil
        default:
            return false
        }
    }

    private func primaryActionSymbol(_ action: MissionPrimaryAction) -> String {
        switch action {
        case .reviewProposedChange, .reviewProposedTests, .reviewFindings: return "doc.text.magnifyingglass"
        case .continueToTestReview: return "arrow.right.circle"
        case .retryCleanup: return "arrow.clockwise"
        case .resolveBlocker: return "exclamationmark.triangle"
        case .assessSystem, .continueAssessment: return "waveform.path.ecg"
        }
    }
}

private struct MissionProgressView: View {
    let items: [MissionProgressItem]

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                VStack(spacing: 5) {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(item.status))
                            .foregroundStyle(color(item.status))
                        if index < items.count - 1 {
                            Rectangle()
                                .fill(connectorColor(item.status))
                                .frame(height: 1)
                        }
                    }
                    Text(item.stage.title)
                        .font(.caption2.weight(item.status == .active || item.status == .needsReview ? .semibold : .regular))
                        .foregroundStyle(item.status == .pending ? .tertiary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mission.current.stage")
    }

    private func symbol(_ status: MissionProgressStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .active: return "circle.inset.filled"
        case .complete: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.circle.fill"
        case .needsReview: return "eye.circle.fill"
        }
    }

    private func color(_ status: MissionProgressStatus) -> Color {
        switch status {
        case .pending: return .secondary.opacity(0.45)
        case .active: return .accentColor
        case .complete: return .green
        case .blocked: return .orange
        case .needsReview: return .purple
        }
    }

    private func connectorColor(_ status: MissionProgressStatus) -> Color {
        status == .complete ? .green.opacity(0.7) : Color(nsColor: .separatorColor)
    }
}

private struct MissionPartialCleanupView: View {
    let cleanup: MissionCleanupState

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Cleanup partially completed")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
            cleanupRow(cleanup.candidatePatchReverted, "Candidate Patch reverted")
            cleanupRow(cleanup.legacyVerifiedUnchanged, "Original Legacy unchanged")
            cleanupRow(cleanup.sandboxDestroyed, "Temporary Sandbox destroyed")
            if let failure = cleanup.failureReason {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func cleanupRow(_ complete: Bool, _ label: String) -> some View {
        Label(label, systemImage: complete ? "checkmark" : "exclamationmark")
            .font(.caption)
            .foregroundStyle(complete ? .green : .orange)
    }
}

private struct MissionHistoryRow: View {
    let entry: MissionHistoryEntry
    @State private var showsDetails = false
    @State private var showsAdvancedDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                showsDetails.toggle()
                if !showsDetails { showsAdvancedDetails = false }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.title)
                            .font(.callout.weight(.semibold))
                        Text(entry.finalOutcome)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let completedAt = entry.completedAt {
                        Text(completedAt, style: .date)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: showsDetails ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("mission.history.item.toggle")
            .accessibilityValue(showsDetails ? "Expanded" : "Collapsed")
            if showsDetails {
            VStack(alignment: .leading, spacing: 5) {
                historyDetail("Patch lifecycle", entry.patchLifecycle)
                historyDetail("Artifact review", entry.artifactReviewOutcome)
                historyDetail("Cleanup", entry.cleanupOutcome)
                if !entry.timeline.isEmpty {
                    Divider().padding(.vertical, 3)
                    Text("Mission timeline")
                        .font(.caption.weight(.semibold))
                    ForEach(entry.timeline) { event in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(event.title)
                                .font(.caption.weight(.semibold))
                            Text(event.outcome)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            MissionExactDetailsView(details: event.exactDetails)
                        }
                        .padding(.vertical, 3)
                    }
                }
                Button {
                    showsAdvancedDetails.toggle()
                } label: {
                    HStack {
                        Text("Advanced details")
                        Spacer()
                        Image(systemName: showsAdvancedDetails ? "chevron.down" : "chevron.right")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.caption)
                .accessibilityIdentifier("mission.history.advanced.toggle")
                .accessibilityValue(showsAdvancedDetails ? "Expanded" : "Collapsed")
                if showsAdvancedDetails {
                    MissionExactDetailsView(details: entry.exactDetails)
                        .padding(.top, 4)
                }
            }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mission.history.item")
    }

    private func historyDetail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 104, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
        .font(.caption)
    }
}

private struct MissionExactDetailsView: View {
    let details: [MissionExactDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(details) { detail in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(detail.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 178, alignment: .leading)
                    Text(detail.value)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(detail.value, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy full \(detail.label)")
                }
            }
        }
    }
}

private enum MissionReviewChoice: String, CaseIterable, Identifiable {
    case approve
    case requestChanges
    case reject

    var id: String { rawValue }
    var label: String {
        switch self {
        case .approve: return "Approve"
        case .requestChanges: return "Request changes"
        case .reject: return "Reject"
        }
    }
}

private enum MissionReviewTarget: Identifiable {
    case candidatePatch(ApprovalRequest, MissionSummary)
    case generatedTestArtifact(GeneratedTestArtifact, MissionSummary)

    var id: String {
        switch self {
        case let .candidatePatch(approval, _): return "candidate:\(approval.id.uuidString)"
        case let .generatedTestArtifact(artifact, _): return "artifact:\(artifact.artifactID.uuidString)"
        }
    }
}

private struct MissionUnifiedReviewSheet: View {
    let target: MissionReviewTarget
    let candidateReviewEligibility: Bool
    let artifactReviewEligibility: GeneratedTestArtifactReviewEligibility
    let onApproveCandidatePatch: (ApprovalRequest) -> Void
    let onRejectCandidatePatch: (ApprovalRequest) -> Void
    let onRequestCandidatePatchChanges: (ApprovalRequest, String) -> Void
    let onApproveArtifact: (GeneratedTestArtifact) -> Void
    let onRejectArtifact: (GeneratedTestArtifact) -> Void
    let onRequestArtifactChanges: (GeneratedTestArtifact, String) -> Void
    let onOpenFiles: () -> Void
    let onCancel: () -> Void

    @State private var choice: MissionReviewChoice?
    @State private var instructions = ""
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Label(title, systemImage: "doc.text.magnifyingglass")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Exact revision \(revision)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .font(.callout)

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow { Text("Affected files").foregroundStyle(.secondary); Text(affectedFiles) }
                GridRow { Text("Risk").foregroundStyle(.secondary); Text(risk) }
                GridRow { Text("Safety boundary").foregroundStyle(.secondary); Text(safetyBoundary) }
            }
            .font(.callout)

            if case .generatedTestArtifact = target {
                Button("Open generated test workspace", action: onOpenFiles)
                    .accessibilityIdentifier("mission.fileWorkspace.open")
            }

            DisclosureGroup("Technical details") {
                MissionExactDetailsView(details: exactDetails)
                    .padding(.top, 6)
            }
            .font(.caption)

            Divider()

            Text("Decision")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(MissionReviewChoice.allCases) { option in
                Button {
                    choice = option
                } label: {
                    HStack {
                        Image(systemName: choice == option ? "largecircle.fill.circle" : "circle")
                        Text(option.label)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || !isEligible)
                .accessibilityIdentifier(accessibilityIdentifier(option))
            }

            if choice == .requestChanges {
                TextField("Describe the exact changes needed", text: $instructions, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mission.review.instructions")
            }

            if case .generatedTestArtifact = target {
                Text("Approval does not create or execute test files. Phase 2D.3 is unavailable.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            } else {
                Text("Approval continues to the exact Candidate Patch confirmation step. The change remains isolated to the Safe Sandbox.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.purple)
            }

            if let unavailableReason {
                Text(unavailableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(finalButtonLabel) {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit)
                .accessibilityIdentifier("mission.review.continue")
            }
        }
        .padding(20)
        .frame(width: 640)
        .accessibilityIdentifier("mission.review.open")
        .onExitCommand(perform: onCancel)
    }

    private var title: String {
        switch target {
        case .candidatePatch: return "Review proposed change"
        case .generatedTestArtifact: return "Review proposed tests"
        }
    }

    private var summary: String {
        switch target {
        case let .candidatePatch(approval, _):
            return AgentPresentationSanitizer.safeContent(approval.resource, fallback: "Review the exact proposed Candidate Patch plan.")
        case let .generatedTestArtifact(artifact, _):
            let files = artifact.currentRevision?.virtualFiles.count ?? 0
            let scenarios = artifact.currentRevision?.scenarioBindings.count ?? 0
            return "Review \(scenarios) scenarios across \(files) read-only virtual \(files == 1 ? "file" : "files")."
        }
    }

    private var revision: String {
        switch target {
        case let .candidatePatch(approval, _): return approval.metadata["plan_revision"] ?? "—"
        case let .generatedTestArtifact(artifact, _): return artifact.currentRevision.map { String($0.revision) } ?? "—"
        }
    }

    private var affectedFiles: String {
        switch target {
        case let .candidatePatch(approval, _):
            let paths = candidateAffectedPaths(approval)
            return paths.isEmpty
                ? (approval.metadata["files_planned"] ?? "0") + " planned"
                : paths.joined(separator: ", ")
        case let .generatedTestArtifact(artifact, _):
            return artifact.currentRevision?.virtualFiles.map(\.proposedRelativePath).joined(separator: ", ") ?? "None"
        }
    }

    private var risk: String {
        switch target {
        case let .candidatePatch(approval, _): return approval.riskLevel.rawValue.uppercased()
        case let .generatedTestArtifact(artifact, _): return artifact.currentRevision?.risk.rawValue ?? "UNKNOWN"
        }
    }

    private var safetyBoundary: String {
        switch target {
        case .candidatePatch: return "Safe Sandbox only; original Legacy unchanged"
        case .generatedTestArtifact: return "Virtual only; not written, compiled, or executed"
        }
    }

    private var exactDetails: [MissionExactDetail] {
        switch target {
        case let .candidatePatch(_, summary), let .generatedTestArtifact(_, summary):
            return summary.exactDetails
        }
    }

    private var isEligible: Bool {
        switch target {
        case .candidatePatch: return candidateReviewEligibility
        case .generatedTestArtifact: return artifactReviewEligibility.isAvailable
        }
    }

    private var unavailableReason: String? {
        switch target {
        case .candidatePatch:
            return candidateReviewEligibility ? nil : "This exact Candidate Patch review is no longer current."
        case .generatedTestArtifact:
            return artifactReviewEligibility.unavailableReason
        }
    }

    private var finalButtonLabel: String {
        switch choice {
        case .approve: return "Approve exact change"
        case .requestChanges: return "Submit change request"
        case .reject: return "Reject proposal"
        case nil: return "Choose a decision"
        }
    }

    private var canSubmit: Bool {
        guard isEligible, !isSubmitting, let choice else { return false }
        return choice != .requestChanges
            || !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func accessibilityIdentifier(_ option: MissionReviewChoice) -> String {
        switch option {
        case .approve: return "mission.review.choice.approve"
        case .requestChanges: return "mission.review.choice.requestChanges"
        case .reject: return "mission.review.choice.reject"
        }
    }

    private func candidateAffectedPaths(_ approval: ApprovalRequest) -> [String] {
        guard let markdown = approval.metadata["candidate_patch_plan_summary"],
              let scope = markdown.components(separatedBy: "## Proposed file scope").last?
                .components(separatedBy: "## Blockers addressed").first else {
            return []
        }
        return scope.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- `"),
                  let closing = line.dropFirst(3).firstIndex(of: "`") else {
                return nil
            }
            return String(line.dropFirst(3)[..<closing])
        }
    }

    private func submit() {
        guard canSubmit, let choice else { return }
        isSubmitting = true
        switch (target, choice) {
        case let (.candidatePatch(approval, _), .approve): onApproveCandidatePatch(approval)
        case let (.candidatePatch(approval, _), .requestChanges):
            onRequestCandidatePatchChanges(approval, instructions)
        case let (.candidatePatch(approval, _), .reject): onRejectCandidatePatch(approval)
        case let (.generatedTestArtifact(artifact, _), .approve): onApproveArtifact(artifact)
        case let (.generatedTestArtifact(artifact, _), .requestChanges):
            onRequestArtifactChanges(artifact, instructions)
        case let (.generatedTestArtifact(artifact, _), .reject): onRejectArtifact(artifact)
        }
    }
}
