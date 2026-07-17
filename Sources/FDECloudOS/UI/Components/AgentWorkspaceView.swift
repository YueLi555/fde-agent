import SwiftUI

struct AgentWorkspaceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if !store.selectedWorkspaceHasProjectScope {
                    ScrollView {
                        ProjectSelectionRequiredView(
                            legacyProjectRoot: store.selectedWorkspaceProjectRoot,
                            agentProjectRoot: store.selectedWorkspaceAgentProjectRoot,
                            onChooseLegacyProject: store.chooseProjectDirectory,
                            onChooseAgentProject: store.chooseAgentProjectDirectory
                        )
                        .frame(maxWidth: 700)
                        .padding(24)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                } else if let session = store.selectedAgentSession {
                    workspaceShell(session: session)
                } else {
                    AgentEmptyState()
                        .padding(24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            CommandBarView()
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(item: $store.candidatePatchApprovalConfirmation) { confirmation in
            CandidatePatchApprovalConfirmationView(
                confirmation: confirmation,
                isConfirming: store.isConfirmingCandidatePatchApproval,
                onConfirm: { store.confirmCandidatePatchApproval(confirmation) },
                onCancel: store.cancelCandidatePatchApprovalConfirmation
            )
            .interactiveDismissDisabled()
        }
        .sheet(item: $store.candidatePatchRevertConfirmation) { confirmation in
            CandidatePatchRevertConfirmationView(
                confirmation: confirmation,
                isConfirming: store.isConfirmingCandidatePatchRevert,
                onConfirm: { store.confirmCandidatePatchRevert(confirmation) },
                onCancel: store.cancelCandidatePatchRevertConfirmation
            )
            .interactiveDismissDisabled()
        }
        .sheet(item: $store.candidatePatchDestructionConfirmation) { confirmation in
            CandidatePatchSandboxDestructionConfirmationView(
                confirmation: confirmation,
                isConfirming: store.isConfirmingCandidatePatchDestruction,
                onConfirm: { store.confirmCandidatePatchDestruction(confirmation) },
                onCancel: store.cancelCandidatePatchDestructionConfirmation
            )
            .interactiveDismissDisabled()
        }
    }

    @ViewBuilder
    private func workspaceShell(session: AgentSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FDE Agent")
                            .font(.title2.weight(.semibold))
                        Text(session.userGoal)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 16)

                    Text(store.selectedConversationActivity?.conversationTitle ?? session.interactionState.conversationTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(store.selectedConversationActivity?.conversationColor ?? session.interactionState.conversationColor)
                }

                AgentConversationView(
                    session: session,
                    events: store.selectedAgentSessionEvents,
                    activity: store.selectedConversationActivity,
                    approvals: store.selectedTaskPendingApprovals,
                    showsHeader: false,
                    onApprove: store.approve,
                    onReject: store.reject,
                    onRequestChanges: store.requestCandidatePatchChanges,
                    onSelectOption: store.selectDecision,
                    onCandidatePatchRevert: store.openCandidatePatchRevertConfirmation,
                    onCandidatePatchDestroySandbox: store.openCandidatePatchDestructionConfirmation
                )
            }
            .frame(maxWidth: 780, alignment: .topLeading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

private struct CandidatePatchApprovalConfirmationView: View {
    let confirmation: CandidatePatchApprovalConfirmation
    let isConfirming: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm Candidate Patch Approval", systemImage: "checkmark.shield")
                .font(.title3.weight(.semibold))

            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    Text("Plan")
                        .foregroundStyle(.secondary)
                    Text("\(confirmation.shortPlanID)…")
                        .font(.body.monospaced())
                }
                GridRow {
                    Text("Revision")
                        .foregroundStyle(.secondary)
                    Text("\(confirmation.planRevision)")
                        .font(.body.monospacedDigit())
                }
                GridRow {
                    Text("Capability")
                        .foregroundStyle(.secondary)
                    Text(confirmation.capability)
                        .font(.body.monospaced())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Affected relative paths")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(confirmation.affectedRelativePaths, id: \.self) { path in
                    Text("• \(path)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }

            Label(
                "This change applies only inside the validated Safe Sandbox.",
                systemImage: "shippingbox.and.arrow.backward"
            )
            .font(.callout.weight(.semibold))
            .foregroundStyle(.purple)

            Text("Build, Test, Git, and Deployment remain disabled.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    onCancel()
                }
                .accessibilityIdentifier("candidatePatch.approve.cancel")

                Button {
                    onConfirm()
                } label: {
                    Label("Confirm Approval", systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(.borderedProminent)
                .focusable(false)
                .disabled(isConfirming)
                .accessibilityIdentifier("candidatePatch.approve.confirm")
            }
        }
        .padding(22)
        .frame(width: 560)
        .onExitCommand(perform: onCancel)
    }
}

private struct CandidatePatchRevertConfirmationView: View {
    let confirmation: CandidatePatchRevertConfirmation
    let isConfirming: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm Candidate Patch Revert", systemImage: "arrow.uturn.backward.circle")
                .font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow { Text("Patch ID").foregroundStyle(.secondary); Text(confirmation.binding.patchID.rawValue).font(.body.monospaced()) }
                GridRow { Text("Plan revision").foregroundStyle(.secondary); Text(String(confirmation.binding.planRevision)).font(.body.monospacedDigit()) }
                GridRow { Text("Sandbox ID").foregroundStyle(.secondary); Text(confirmation.binding.sandboxID.rawValue).font(.body.monospaced()) }
            }
            revertFileList(title: "Files to restore", values: confirmation.filesToRestore)
            revertFileList(title: "Patch-created files to remove", values: confirmation.filesToRemove)
            Label("Original Legacy remains unchanged.", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
            Label("The complete audit record will be preserved.", systemImage: "doc.text.magnifyingglass")
            Text("Sandbox destruction is a separate explicit confirmed action.")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("candidatePatch.revert.cancel")
                Button(action: onConfirm) {
                    Label("Confirm Revert", systemImage: "arrow.uturn.backward.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(isConfirming)
                .accessibilityIdentifier("candidatePatch.revert.confirm")
            }
        }
        .padding(22)
        .frame(width: 660)
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder
    private func revertFileList(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if values.isEmpty {
                Text("None").font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    Text("• \(value)").font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }
}

private struct CandidatePatchSandboxDestructionConfirmationView: View {
    let confirmation: CandidatePatchSandboxDestructionConfirmation
    let isConfirming: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Confirm Sandbox Destruction", systemImage: "trash")
                .font(.title3.weight(.semibold))
            Text("Patch \(confirmation.binding.patchID.rawValue)")
                .font(.body.monospaced())
                .textSelection(.enabled)
            Text("Sandbox \(confirmation.binding.sandboxID.rawValue)")
                .font(.body.monospaced())
                .textSelection(.enabled)
            Label("The Candidate Patch is already REVERTED.", systemImage: "checkmark.shield")
                .foregroundStyle(.green)
            Label("Sandbox destruction is permanent.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text("This separate action destroys only the exact bound reverted Sandbox. The original Legacy remains unchanged, all audit records are preserved outside the Sandbox, and no other Patch or Sandbox is affected.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .accessibilityIdentifier("candidatePatch.destroySandbox.cancel")
                Button("Destroy Sandbox", role: .destructive, action: onConfirm)
                    .disabled(isConfirming)
                    .accessibilityIdentifier("candidatePatch.destroySandbox.confirm")
            }
        }
        .padding(22)
        .frame(width: 620)
        .onExitCommand(perform: onCancel)
    }
}

private struct ProjectSelectionRequiredView: View {
    let legacyProjectRoot: String?
    let agentProjectRoot: String?
    let onChooseLegacyProject: () -> Void
    let onChooseAgentProject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose Code Folders")
                    .font(.title3.weight(.semibold))
                Text("Select the legacy codebase and the agent codebase, then tell FDE what to inspect, modify, or run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    onChooseLegacyProject()
                } label: {
                    Label(legacyProjectRoot == nil ? "Choose Legacy" : "Change Legacy", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    onChooseAgentProject()
                } label: {
                    Label(agentProjectRoot == nil ? "Choose Agent" : "Change Agent", systemImage: "folder.badge.gearshape")
                }
            }

            ProjectScopeStatusLine(title: "Legacy", path: legacyProjectRoot)
            ProjectScopeStatusLine(title: "Agent", path: agentProjectRoot)
        }
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
        .agentPanelStyle()
    }
}

private struct ProjectScopeStatusLine: View {
    let title: String
    let path: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: path == nil ? "circle" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.green))
                .frame(width: 14)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(path ?? "not selected")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct MissionContextPanel: View {
    let session: AgentSession
    let workspace: Workspace?
    let timeline: AgentTimeline
    let events: [AgentWorkspaceEvent]
    let graphNodes: [SystemGraphNode]
    let diagnostics: ContextCompilerDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Mission Context", systemImage: "target")
                    .font(.headline)
                Text(timeline.missionTitle)
                    .font(.title3.weight(.semibold))
                    .lineLimit(4)
                AgentStateToken(stage: timeline.currentActivity?.stage ?? .understanding, text: timeline.semanticProgress)
            }
            .agentPanelStyle()

            ContextSection(title: "Goal", symbol: "scope") {
                Text(session.userGoal)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ContextSection(title: "System Context", symbol: "server.rack") {
                ContextKeyValue(label: "Workspace", value: workspace?.displayName ?? session.workspaceContext.workspaceName)
                ContextKeyValue(label: "Runtime", value: session.runtimeTaskID?.uuidString ?? "not linked")
                ContextKeyValue(label: "Files scanned", value: "\(diagnostics.filesScanned)")
                if let localProjectRoot = session.workspaceContext.localProjectRoot {
                    ContextKeyValue(label: "Legacy", value: localProjectRoot)
                }
                if let localAgentProjectRoot = session.workspaceContext.localAgentProjectRoot {
                    ContextKeyValue(label: "Agent", value: localAgentProjectRoot)
                }
            }

            ContextSection(title: "Connected Systems", symbol: "point.3.connected.trianglepath.dotted") {
                if connectedSystems.isEmpty {
                    Text("No connected systems detected yet.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    TagCloud(values: connectedSystems)
                }
            }

            ContextSection(title: "Memory", symbol: "archivebox") {
                if diagnostics.enterpriseMemory.isEmpty {
                    Text("No matched enterprise memory yet.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(diagnostics.enterpriseMemory.allEntries.prefix(4)) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(entry.summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private var connectedSystems: [String] {
        let graphSystems = graphNodes
            .filter { $0.type == .api || $0.type == .app }
            .map(\.title)
        let evidenceSystems = events
            .flatMap(\.evidence)
            .filter { $0.kind == .systemContext }
            .flatMap { $0.detail.split(separator: "|").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let enterpriseSystems = diagnostics.enterpriseSystemGraph.detectedSystems
        return unique((graphSystems + evidenceSystems + enterpriseSystems).filter { !$0.isEmpty }).prefixArray(8)
    }
}

private struct ContextSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .agentPanelStyle()
    }
}

private struct ContextKeyValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

private struct TagCloud: View {
    let values: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Text(value)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
}

private struct AgentTimelinePanel: View {
    let timeline: AgentTimeline

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Live Agent Timeline")
                        .font(.title2.weight(.semibold))
                    Text(timeline.semanticProgress)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                AgentStateToken(stage: timeline.currentActivity?.stage ?? .understanding, text: timeline.currentActivity?.status.label ?? "Idle")
            }

            if let currentActivity = timeline.currentActivity {
                CurrentActivityCard(entry: currentActivity)
            }

            if timeline.entries.isEmpty {
                ContentUnavailableView("No Runtime Activity", systemImage: "waveform.path.ecg")
                    .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(timeline.entries.enumerated()), id: \.element.id) { index, entry in
                        AgentTimelineEntryRow(
                            entry: entry,
                            isFirst: index == 0,
                            isLast: index == timeline.entries.count - 1
                        )
                    }
                }
            }
        }
        .agentPanelStyle()
    }
}

private struct CurrentActivityCard: View {
    let entry: AgentTimelineEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(entry.stage.color.opacity(0.14))
                    .frame(width: 44, height: 44)
                Image(systemName: entry.stage.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(entry.stage.color)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Now")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(entry.title)
                    .font(.headline)
                Text(entry.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(entry.stage.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(entry.stage.color.opacity(0.28), lineWidth: 0.8)
        )
    }
}

private struct AgentTimelineEntryRow: View {
    let entry: AgentTimelineEntry
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Rectangle()
                    .fill(isFirst ? Color.clear : Color(nsColor: .separatorColor))
                    .frame(width: 1, height: 12)
                ZStack {
                    Circle()
                        .fill(entry.status.color.opacity(0.16))
                        .frame(width: 30, height: 30)
                    Image(systemName: entry.status.symbol(fallback: entry.stage.symbol))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(entry.status.color)
                }
                Rectangle()
                    .fill(isLast ? Color.clear : Color(nsColor: .separatorColor))
                    .frame(width: 1)
                    .frame(minHeight: 46)
            }
            .frame(width: 34)

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(entry.stage.title, systemImage: entry.stage.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(entry.stage.color)
                    Spacer()
                    Text(entry.status.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(entry.status.color)
                }
                Text(entry.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Text(entry.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !entry.evidence.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(entry.evidence.prefix(3)) { evidence in
                            Label(evidence.title, systemImage: evidence.kind.symbol)
                                .font(.caption2.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                                .help(evidence.detail)
                        }
                    }
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 4)
        }
    }
}

private struct AgentPlanDecisionPanel: View {
    let session: AgentSession
    let onApprovePlan: () -> Void
    let onModifyPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Decisions", systemImage: "list.bullet.clipboard")
                    .font(.headline)
                Spacer()
                Text(session.planApprovalStatus.planLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.planApprovalStatus.statusColor)
            }

            if session.currentPlan.isEmpty {
                Text("The agent will create a plan after understanding the mission.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(session.currentPlan.enumerated()), id: \.element.id) { index, step in
                        PlanStepRow(step: step, index: index, isActive: index == activeStepIndex)
                    }
                }
            }

            HStack(spacing: 8) {
                Button {
                    onApprovePlan()
                } label: {
                    Label("Approve Plan", systemImage: "checkmark.circle")
                }
                .disabled(!canApprovePlan)

                Button {
                    onModifyPlan()
                } label: {
                    Label("Modify", systemImage: "slider.horizontal.3")
                }
                .disabled(!canChangePlan)

                Spacer()
            }
        }
        .agentPanelStyle()
    }

    private var canChangePlan: Bool {
        !session.currentPlan.isEmpty
            && session.interactionState != .completed
            && session.interactionState != .failed
    }

    private var canApprovePlan: Bool {
        !session.currentPlan.isEmpty
            && session.interactionState != .failed
            && session.planApprovalStatus != .approved
    }

    private var activeStepIndex: Int {
        switch session.interactionState {
        case .idle, .understanding:
            return 0
        case .planning:
            return min(1, max(session.currentPlan.count - 1, 0))
        case .working, .waitingForUser, .waitingForApproval:
            return min(2, max(session.currentPlan.count - 1, 0))
        case .verifying:
            return max(session.currentPlan.count - 1, 0)
        case .blocked:
            return min(2, max(session.currentPlan.count - 1, 0))
        case .completed:
            return session.currentPlan.count
        case .failed:
            return min(2, max(session.currentPlan.count - 1, 0))
        }
    }
}

private struct PlanStepRow: View {
    let step: PlanStep
    let index: Int
    let isActive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index + 1)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(isActive ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(isActive ? Color.accentColor : Color(nsColor: .controlBackgroundColor), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(step.title)
                    .font(.callout.weight(isActive ? .semibold : .regular))
                    .lineLimit(2)
                Text(step.intent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if step.requiresApproval {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.purple)
                    .help("Requires approval")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentControlsPanel: View {
    let timeline: AgentTimeline
    let approvals: [ApprovalRequest]
    let onApprove: (ApprovalRequest) -> Void
    let onModify: (ApprovalRequest) -> Void
    let onReject: (ApprovalRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Approval Center", systemImage: "checkmark.shield")
                    .font(.headline)
                Spacer()
                Text("\(approvals.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(approvals.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.purple))
            }

            if approvals.isEmpty,
               let current = timeline.currentActivity,
               current.requiresUserAction {
                AgentNeedsInputCard(entry: current)
            } else if approvals.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(.green)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Approval queue clear")
                            .font(.callout.weight(.semibold))
                        Text("The agent can continue until a risk gate or information gap appears.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(approvals) { approval in
                    AgentApprovalCard(
                        approval: approval,
                        onApprove: { onApprove(approval) },
                        onModify: { onModify(approval) },
                        onReject: { onReject(approval) }
                    )
                }
            }
        }
        .agentPanelStyle()
    }
}

private struct AgentRiskCard: View {
    let task: FDETask?
    let events: [ExecutionEvent]
    let approvals: [ApprovalRequest]
    let replay: MissionReplay?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Risk Card", systemImage: "exclamationmark.shield")
                    .font(.headline)
                Spacer()
                Text(currentRisk.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(currentRisk.color)
            }

            HStack(spacing: 8) {
                RiskMetricTile(title: "Approvals", value: "\(approvalCount)")
                RiskMetricTile(title: "Denied", value: "\(denialCount)")
                RiskMetricTile(title: "Audit", value: replay?.isAuditComplete == true ? "OK" : "Open")
            }

            if let policy = latestPolicyDecision {
                Label(policy.rawValue.replacingOccurrences(of: "_", with: " ").uppercased(), systemImage: policy == .denied ? "xmark.octagon" : "checkmark.shield")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(policy == .denied ? .red : .secondary)
            }

            Text(riskDetail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .agentPanelStyle()
    }

    private var currentRisk: RiskSeverity {
        let approvalRisks = approvals.map(\.riskLevel)
        let eventRisks = events.compactMap { event in
            (event.payload["risk_assessment_level"] ?? event.payload["risk_level"]).flatMap(RiskSeverity.init(rawValue:))
        }
        return (approvalRisks + eventRisks).max { $0.governanceRank < $1.governanceRank }
            ?? riskFromTask
    }

    private var riskFromTask: RiskSeverity {
        guard let task else { return .low }
        if task.riskScore >= 85 { return .critical }
        if task.riskScore >= 60 { return .high }
        if task.riskScore >= 30 { return .medium }
        return .low
    }

    private var approvalCount: Int {
        max(approvals.count, replay?.approvals.count ?? 0)
    }

    private var denialCount: Int {
        events.filter { $0.type == .authorizationDenied }.count
    }

    private var latestPolicyDecision: PolicyDecisionStatus? {
        events.reversed().compactMap { $0.payload["policy_decision"].flatMap(PolicyDecisionStatus.init(rawValue:)) }.first
    }

    private var riskDetail: String {
        if let reason = events.reversed().compactMap({ event in
            event.payload["policy_reasons"]?.nilIfBlank
                ?? event.payload["risk_assessment_reasons"]?.nilIfBlank
                ?? event.payload["risk_reasons"]?.nilIfBlank
        }).first {
            return reason
        }
        if currentRisk == .low {
            return "No elevated governance signals recorded for the current mission."
        }
        return "Governance signals are present; review approvals and replay evidence before continuing."
    }
}

private struct AgentPerformanceCard: View {
    let summary: AgentBenchmarkSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Agent Performance", systemImage: "chart.xyaxis.line")
                    .font(.headline)
                Spacer()
                Text("\(summary.missionCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                RiskMetricTile(title: "Success", value: percent(summary.successRate))
                RiskMetricTile(title: "Recovery", value: percent(summary.recoveryRate))
            }
            HStack(spacing: 8) {
                RiskMetricTile(title: "Approvals", value: percent(summary.approvalEfficiency))
                RiskMetricTile(title: "Quality", value: "\(Int(summary.averageQualityScore.rounded()))")
            }

            if summary.commonFailurePatterns.isEmpty {
                Text("No recurring failure patterns recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Common failure patterns")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(summary.commonFailurePatterns.prefix(3), id: \.self) { pattern in
                        Label(pattern, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .agentPanelStyle()
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct AgentCapabilityReportCard: View {
    let report: AgentCapabilityReport

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Agent Capability Report", systemImage: "checklist.checked")
                    .font(.headline)
                Spacer()
                Text("\(report.passedScenarioCount)/\(report.scenarioCount)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(report.passedScenarioCount == report.scenarioCount && report.scenarioCount > 0 ? .green : .secondary)
            }

            HStack(spacing: 8) {
                RiskMetricTile(title: "Score", value: "\(Int(report.overallScore.rounded()))")
                RiskMetricTile(title: "Safety", value: percent(report.safetyCompliance))
            }
            HStack(spacing: 8) {
                RiskMetricTile(title: "Clarify", value: percent(report.clarificationQuality))
                RiskMetricTile(title: "Outcome", value: percent(report.outcomeQuality))
            }

            let visibleIssues = report.commonSafetyViolations.isEmpty ? report.capabilityGaps : report.commonSafetyViolations
            if visibleIssues.isEmpty {
                Text("No benchmark gaps detected in the current workspace trace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.commonSafetyViolations.isEmpty ? "Capability gaps" : "Safety violations")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(visibleIssues.prefix(3), id: \.self) { item in
                        Label(item, systemImage: report.commonSafetyViolations.isEmpty ? "circle.dashed" : "xmark.octagon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .agentPanelStyle()
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct EngineeringActivityPanel: View {
    let activity: EngineeringActivitySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Engineering Activity", systemImage: "wrench.and.screwdriver")
                    .font(.headline)
                Spacer()
                Text(activity.currentStage?.shortTitle ?? "Idle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(activity.riskLevel.color)
            }

            HStack(spacing: 8) {
                RiskMetricTile(title: "Files", value: "\(activity.filesInspected.count)")
                RiskMetricTile(title: "Changes", value: "\(activity.changesProposed.count)")
            }
            HStack(spacing: 8) {
                RiskMetricTile(title: "Tests", value: activity.testsRunning ? "Running" : "Idle")
                RiskMetricTile(title: "Risk", value: activity.riskLevel.rawValue.uppercased())
            }

            activitySection(
                title: "Files inspected",
                emptyText: "No files inspected yet.",
                systemImage: "doc.text.magnifyingglass",
                items: activity.filesInspected
            )
            activitySection(
                title: "Changes proposed",
                emptyText: "No active code change plan.",
                systemImage: "square.and.pencil",
                items: activity.changesProposed
            )
            activitySection(
                title: "Validation",
                emptyText: "No validation results recorded.",
                systemImage: "checkmark.seal",
                items: activity.validationResults
            )
        }
        .agentPanelStyle()
    }

    @ViewBuilder
    private func activitySection(
        title: String,
        emptyText: String,
        systemImage: String,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.prefix(4)), id: \.self) { item in
                    Label(item, systemImage: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct AgentTeamPanel: View {
    let snapshot: AgentTeamSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Agent Team", systemImage: "person.3.sequence")
                    .font(.headline)
                Spacer()
                Text(snapshot.requiresHumanLeadReview ? "Lead Review" : snapshot.status.shortTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.requiresHumanLeadReview ? .orange : .secondary)
            }

            HStack(spacing: 8) {
                RiskMetricTile(title: "Active", value: "\(snapshot.activeAgents.count)")
                RiskMetricTile(title: "Progress", value: "\(Int((snapshot.progress * 100).rounded()))%")
            }

            if snapshot.activeAgents.isEmpty {
                Text("No active agents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(snapshot.activeAgents.prefix(5)) { agent in
                        AgentTeamMemberRow(agent: agent)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Findings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(snapshot.findings.prefix(4), id: \.self) { finding in
                    Label(finding, systemImage: "checkmark.seal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .agentPanelStyle()
    }
}

private struct AgentTeamMemberRow: View {
    let agent: AgentTeamMemberSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: agent.roleID.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(agent.roleID.displayName)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(agent.status.shortTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: agent.progress)
                    .controlSize(.small)
                Text(agent.responsibility)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let finding = agent.findings.first {
                    Text(finding)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TeamIntelligencePanel: View {
    let snapshot: TeamIntelligenceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Team Intelligence", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                Text("\(Int((snapshot.confidence * 100).rounded()))%")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(snapshot.confidence >= 0.7 ? .green : .orange)
            }

            activitySection(
                title: "Why selected",
                emptyText: "No selection rationale available.",
                systemImage: "checkmark.circle",
                items: snapshot.selectionReasons
            )

            if !snapshot.selectedAgents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Confidence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ForEach(snapshot.selectedAgents.prefix(4)) { agent in
                        HStack(spacing: 8) {
                            Image(systemName: agent.roleID.symbol)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.roleID.displayName)
                                    .font(.caption.weight(.semibold))
                                Text(agent.selectedBecause)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Text("\(Int((agent.confidence * 100).rounded()))%")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            activitySection(
                title: "Disagreements",
                emptyText: "No disagreements recorded.",
                systemImage: "exclamationmark.triangle",
                items: snapshot.disagreements
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Final decision")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.finalDecision)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .agentPanelStyle()
    }

    @ViewBuilder
    private func activitySection(
        title: String,
        emptyText: String,
        systemImage: String,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text(emptyText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(4), id: \.self) { item in
                    Label(item, systemImage: systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

private struct RiskMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentApprovalCard: View {
    let approval: ApprovalRequest
    let onApprove: () -> Void
    let onModify: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Agent found", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(approval.resource)
                .font(.callout.weight(.semibold))
                .lineLimit(3)
                .textSelection(.enabled)

            HStack {
                Text("Risk")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(approval.riskLevel.rawValue.uppercased())
                    .font(.caption.weight(.bold))
                    .foregroundStyle(approval.riskLevel.color)
            }

            HStack(spacing: 8) {
                Button {
                    onApprove()
                } label: {
                    Label("Approve", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(
                    approval.targetKind == .candidatePatchPlan
                        ? "candidatePatch.approve.openConfirmation"
                        : "approval.approve"
                )
                .focusable(approval.targetKind != .candidatePatchPlan)

                Button {
                    onModify()
                } label: {
                    Label("Modify", systemImage: "slider.horizontal.3")
                }

                Button(role: .destructive) {
                    onReject()
                } label: {
                    Label("Reject", systemImage: "xmark.circle")
                }
                .accessibilityIdentifier(
                    approval.targetKind == .candidatePatchPlan
                        ? "candidatePatch.reject"
                        : "approval.reject"
                )
            }
        }
        .padding(12)
        .background(approval.riskLevel.color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(approval.riskLevel.color.opacity(0.28), lineWidth: 0.8)
        )
    }
}

private struct AgentNeedsInputCard: View {
    let entry: AgentTimelineEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Agent needs information", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(entry.summary)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Text("Reply in the command bar to continue.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.28), lineWidth: 0.8)
        )
    }
}

private struct OutcomeSummaryPanel: View {
    let outcome: OutcomeRecord?
    let goal: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Outcome Summary", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                if let outcome {
                    Text(outcome.finalState == .complete ? "Complete" : "Stopped")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(outcome.finalState == .complete ? .green : .orange)
                }
            }

            if let outcome {
                OutcomeSection(title: "Goal", value: outcome.objective)
                OutcomeSection(title: "Result", value: outcome.achievedOutcome)
                OutcomeSection(title: "Impact", value: outcome.impactSummary)

                if !outcome.evidence.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Evidence")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(outcome.evidence.prefix(4)) { evidence in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: evidence.kind.symbol)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(evidence.title)
                                        .font(.caption.weight(.semibold))
                                    Text(evidence.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                }

                if !outcome.metricsBefore.isEmpty || !outcome.metricsAfter.isEmpty {
                    OutcomeMetricsStrip(before: outcome.metricsBefore, after: outcome.metricsAfter)
                }

                if !outcome.followUpRecommendations.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Next recommendations")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(outcome.followUpRecommendations.prefix(3), id: \.self) { recommendation in
                            Label(recommendation, systemImage: "arrow.right.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                OutcomeSection(title: "Goal", value: goal)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hourglass")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("Outcome will be extracted when the mission reaches a completed or failed terminal state.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .agentPanelStyle()
    }
}

private struct OutcomeSection: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OutcomeMetricsStrip: View {
    let before: [OutcomeMetric]
    let after: [OutcomeMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Metrics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                OutcomeMetricColumn(title: "Before", metrics: before)
                OutcomeMetricColumn(title: "After", metrics: after)
            }
        }
    }
}

private struct OutcomeMetricColumn: View {
    let title: String
    let metrics: [OutcomeMetric]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if metrics.isEmpty {
                Text("Not recorded")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(metrics.prefix(3)) { metric in
                    Text("\(metric.name): \(metric.value)\(metric.unit.map { " \($0)" } ?? "")")
                        .font(.caption2)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentEvidenceControlPanel: View {
    let session: AgentSession
    let events: [AgentWorkspaceEvent]
    let graphNodeCount: Int
    let logCount: Int
    let reportCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Evidence")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], spacing: 8) {
                EvidenceSourceTile(title: "System graph", value: "\(graphNodeCount)", symbol: "point.3.connected.trianglepath.dotted")
                EvidenceSourceTile(title: "Runtime logs", value: "\(logCount)", symbol: "doc.text.magnifyingglass")
                EvidenceSourceTile(title: "Reports", value: "\(reportCount)", symbol: "chart.bar.doc.horizontal")
                EvidenceSourceTile(title: "Artifacts", value: "\(session.artifacts.count)", symbol: "shippingbox")
            }

            let recentEvidence = events.flatMap(\.evidence).suffix(8).reversed()
            if recentEvidence.isEmpty {
                ContentUnavailableView("No Evidence", systemImage: "tray")
                    .frame(minHeight: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(recentEvidence), id: \.id) { evidence in
                        AgentEvidenceRow(evidence: evidence)
                    }
                }
            }
        }
        .agentPanelStyle()
    }
}

private struct EvidenceSourceTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.callout.weight(.semibold).monospacedDigit())
                Text(title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentEvidenceRow: View {
    let evidence: AgentWorkspaceEvidence

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: evidence.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                Text(evidence.title)
                    .font(.caption.weight(.semibold))
                Text(evidence.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(9)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct AgentArtifactIntelligencePanel: View {
    let artifacts: [AgentArtifact]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Artifacts", systemImage: "shippingbox")
                    .font(.headline)
                Spacer()
                Text("\(artifacts.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if artifacts.isEmpty {
                ContentUnavailableView("No Artifacts", systemImage: "shippingbox")
                    .frame(minHeight: 120)
            } else {
                VStack(spacing: 8) {
                    ForEach(artifacts.sorted { $0.createdAt > $1.createdAt }.prefix(6)) { artifact in
                        AgentArtifactCard(artifact: artifact)
                    }
                }
            }
        }
        .agentPanelStyle()
    }
}

private struct AgentArtifactCard: View {
    let artifact: AgentArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: artifact.type.symbol)
                    .foregroundStyle(artifact.approvalStatus.statusColor)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(artifact.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Text(artifact.type.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(artifact.approvalStatus.statusLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(artifact.approvalStatus.statusColor)
            }

            Text(artifact.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.7)
        )
    }
}

private struct AgentRiskChangePanel: View {
    let events: [AgentWorkspaceEvent]
    let approvals: [ApprovalRequest]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Risks + Changes", systemImage: "exclamationmark.triangle")
                .font(.headline)

            if risks.isEmpty && changes.isEmpty {
                Text("No risk gates or configuration changes recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(risks.prefix(4), id: \.self) { risk in
                    Label(risk, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                ForEach(changes.prefix(4), id: \.self) { change in
                    Label(change, systemImage: "slider.horizontal.3")
                        .font(.caption)
                        .foregroundStyle(.teal)
                }
            }
        }
        .agentPanelStyle()
    }

    private var risks: [String] {
        let approvalRisks = approvals.map { "\($0.riskLevel.rawValue.uppercased()): \($0.action)" }
        let eventRisks = events
            .flatMap(\.evidence)
            .filter { $0.kind == .risk }
            .map { "\($0.title): \($0.detail)" }
        return unique(approvalRisks + eventRisks)
    }

    private var changes: [String] {
        events
            .filter { $0.stage == .adapting || $0.stage == .completed }
            .flatMap(\.evidence)
            .filter { $0.kind == .artifact || $0.kind == .adaptation }
            .map { "\($0.title): \($0.detail)" }
    }
}

private struct AgentPrimaryConversationPanel: View {
    let session: AgentSession
    let events: [ExecutionEvent]
    let approvals: [ApprovalRequest]
    let onApprove: (ApprovalRequest) -> Void
    let onReject: (ApprovalRequest) -> Void
    let onSelectOption: (UUID, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Conversation", systemImage: "text.bubble")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(session.interactionState.conversationTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.interactionState.conversationColor)
            }

            AgentConversationView(
                session: session,
                events: events,
                approvals: approvals,
                showsHeader: false,
                onApprove: onApprove,
                onReject: onReject,
                onSelectOption: onSelectOption
            )
        }
        .frame(minHeight: 260, alignment: .topLeading)
        .agentPanelStyle()
    }
}

private struct AgentEmptyState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("Ask FDE to work on the code")
                .font(.title3.weight(.semibold))
            Text("Use the input box below. FDE will inspect the selected Legacy and Agent folders.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentStateToken: View {
    let stage: AgentWorkspaceStage
    let text: String

    var body: some View {
        Label(text, systemImage: stage.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(stage.color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(stage.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AgentPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
            )
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(width: width, subviews: subviews)
        return CGSize(width: width, height: rows.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var origin = bounds.origin
        for row in rows(width: bounds.width, subviews: subviews) {
            origin.x = bounds.minX
            for element in row.elements {
                element.subview.place(
                    at: CGPoint(x: origin.x, y: origin.y),
                    proposal: ProposedViewSize(element.size)
                )
                origin.x += element.size.width + spacing
            }
            origin.y += row.height + spacing
        }
    }

    private func rows(width: CGFloat, subviews: Subviews) -> [FlowRow] {
        var rows: [FlowRow] = []
        var current = FlowRow()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.width == 0 ? size.width : current.width + spacing + size.width
            if width > 0, nextWidth > width, !current.elements.isEmpty {
                rows.append(current)
                current = FlowRow()
            }
            current.append(subview: subview, size: size, spacing: spacing)
        }

        if !current.elements.isEmpty {
            rows.append(current)
        }
        return rows
    }
}

private struct FlowRow {
    var elements: [(subview: LayoutSubview, size: CGSize)] = []
    var width: CGFloat = 0
    var height: CGFloat = 0

    mutating func append(subview: LayoutSubview, size: CGSize, spacing: CGFloat) {
        if !elements.isEmpty {
            width += spacing
        }
        elements.append((subview, size))
        width += size.width
        height = max(height, size.height)
    }
}

private extension View {
    func agentPanelStyle() -> some View {
        modifier(AgentPanelModifier())
    }
}

private extension AgentWorkspaceStage {
    var title: String {
        switch self {
        case .understanding: return "Understanding"
        case .planning: return "Planning"
        case .ready: return "Ready"
        case .deciding: return "Deciding"
        case .executing: return "Executing"
        case .observing: return "Observing"
        case .verifying: return "Verifying"
        case .adapting: return "Adapting"
        case .waitingHuman: return "Waiting"
        case .blocked: return "Blocked"
        case .failed: return "Failed"
        case .completed: return "Completed"
        }
    }

    var symbol: String {
        switch self {
        case .understanding: return "brain.head.profile"
        case .planning: return "list.bullet.clipboard"
        case .ready: return "checklist"
        case .deciding: return "arrow.triangle.branch"
        case .executing: return "gearshape.2"
        case .observing: return "eye"
        case .verifying: return "checkmark.shield"
        case .adapting: return "arrow.triangle.2.circlepath"
        case .waitingHuman: return "pause.circle"
        case .blocked: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon"
        case .completed: return "checkmark.seal"
        }
    }

    var color: Color {
        switch self {
        case .understanding: return .teal
        case .planning: return .indigo
        case .ready: return .blue
        case .deciding: return .cyan
        case .executing: return .blue
        case .observing: return .mint
        case .verifying: return .purple
        case .adapting: return .orange
        case .waitingHuman: return .purple
        case .blocked: return .orange
        case .failed: return .red
        case .completed: return .green
        }
    }
}

private extension AgentWorkspaceEventStatus {
    var label: String {
        switch self {
        case .queued: return "Queued"
        case .active: return "Active"
        case .completed: return "Done"
        case .failed: return "Failed"
        case .waitingHuman: return "Waiting"
        }
    }

    var color: Color {
        switch self {
        case .queued: return .secondary
        case .active: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .waitingHuman: return .purple
        }
    }

    func symbol(fallback: String) -> String {
        switch self {
        case .queued: return "circle"
        case .active: return fallback
        case .completed: return "checkmark"
        case .failed: return "xmark"
        case .waitingHuman: return "pause"
        }
    }
}

private extension AgentWorkspaceEvidenceKind {
    var symbol: String {
        switch self {
        case .runtimeEvent: return "waveform.path.ecg"
        case .decision: return "arrow.triangle.branch"
        case .toolExecution: return "terminal"
        case .observation: return "eye"
        case .adaptation: return "arrow.triangle.2.circlepath"
        case .approval: return "checkmark.shield"
        case .artifact: return "doc.richtext"
        case .risk: return "exclamationmark.triangle"
        case .systemContext: return "point.3.connected.trianglepath.dotted"
        }
    }
}

private extension OutcomeEvidenceKind {
    var symbol: String {
        switch self {
        case .completion: return "checkmark.seal"
        case .execution: return "terminal"
        case .observation: return "eye"
        case .failure: return "exclamationmark.triangle"
        case .artifact: return "doc.richtext"
        case .approval: return "checkmark.shield"
        case .environment: return "point.3.connected.trianglepath.dotted"
        }
    }
}

private extension AgentArtifactType {
    var title: String {
        switch self {
        case .report: return "Report"
        case .codePatch: return "Code Patch"
        case .configChange: return "Config Change"
        case .apiMapping: return "API Mapping"
        case .incidentReport: return "Incident Report"
        case .customerSummary: return "Customer Summary"
        }
    }

    var symbol: String {
        switch self {
        case .report: return "doc.richtext"
        case .codePatch: return "chevron.left.forwardslash.chevron.right"
        case .configChange: return "gearshape.2"
        case .apiMapping: return "point.3.connected.trianglepath.dotted"
        case .incidentReport: return "exclamationmark.bubble"
        case .customerSummary: return "person.text.rectangle"
        }
    }
}

private extension AgentArtifactApprovalStatus {
    var planLabel: String {
        switch self {
        case .notRequired: return "No Approval"
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        }
    }

    var statusLabel: String {
        switch self {
        case .notRequired: return "No Approval"
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .rejected: return "Rejected"
        }
    }

    var statusColor: Color {
        switch self {
        case .notRequired: return .secondary
        case .pending: return .purple
        case .approved: return .green
        case .rejected: return .red
        }
    }
}

private extension RiskSeverity {
    var color: Color {
        switch self {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .critical: return .pink
        }
    }
}

private extension EngineeringLoopStage {
    var shortTitle: String {
        switch self {
        case .inspect: return "Inspect"
        case .planChange: return "Plan"
        case .approvalRequest: return "Approval"
        case .modify: return "Modify"
        case .runValidation: return "Validate"
        case .observeFailure: return "Observe"
        case .repair: return "Repair"
        case .validateAgain: return "Recheck"
        case .completed: return "Done"
        }
    }
}

private extension AgentDelegationStatus {
    var shortTitle: String {
        switch self {
        case .proposed: return "Proposed"
        case .approved: return "Approved"
        case .inProgress: return "Active"
        case .completed: return "Done"
        case .blocked: return "Blocked"
        case .overridden: return "Overridden"
        }
    }
}

private extension AgentSubMissionStatus {
    var shortTitle: String {
        switch self {
        case .queued: return "Queued"
        case .active: return "Active"
        case .completed: return "Done"
        case .blocked: return "Blocked"
        case .overridden: return "Overridden"
        }
    }
}

private extension AgentRoleID {
    var symbol: String {
        switch self {
        case .fdeLeadAgent: return "person.crop.circle.badge.checkmark"
        case .codeInvestigationAgent: return "curlybraces.square"
        case .securityAgent: return "lock.shield"
        case .infrastructureAgent: return "server.rack"
        case .dataAgent: return "chart.bar.xaxis"
        case .documentationAgent: return "doc.text"
        }
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for value in values {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
        seen.insert(normalized)
        result.append(normalized)
    }
    return result
}

private extension Array {
    func prefixArray(_ maxLength: Int) -> [Element] {
        Array(prefix(maxLength))
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
