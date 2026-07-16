import SwiftUI

struct LiveExecutionView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        let snapshot = store.liveExecutionSnapshot

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LiveMissionHeader(task: store.selectedTask, state: snapshot.state)
                LiveStateMachineView(state: snapshot.state)
                LiveActivityFeedView(feed: store.agentNarrationFeed)
                AgentActivityPanel(agents: snapshot.agents)

                if snapshot.state == .waitingApproval || !store.selectedTaskPendingApprovals.isEmpty {
                    ApprovalWaitingPanel(
                        approvals: store.selectedTaskPendingApprovals,
                        onApprove: store.approve,
                        onReject: store.reject
                    )
                }

                ExecutionArtifactPanel(artifacts: snapshot.artifacts)
                ExecutionTimelineView(events: store.selectedAgentSessionEvents)
                    .frame(minHeight: 320)
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct LiveMissionHeader: View {
    let task: FDETask?
    let state: LiveExecutionState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(task?.title ?? "No mission selected")
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(task?.rawInput ?? "Submit a mission to start live execution.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer()
                LiveStateBadge(state: state)
            }

            if let task {
                HStack(spacing: 18) {
                    CompactLiveMetric(label: "Risk", value: "\(Int(task.riskScore))")
                    CompactLiveMetric(label: "Failure", value: "\(Int(task.failureProbability * 100))%")
                    CompactLiveMetric(label: "FDE Score", value: "\(Int(task.performanceScore))")
                    CompactLiveMetric(label: "Plan Steps", value: "\(task.plan.count)")
                }
            }
        }
    }
}

private struct LiveStateMachineView: View {
    let state: LiveExecutionState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Streaming State")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(LiveExecutionState.allCases.enumerated()), id: \.element.id) { index, item in
                        StateMachineNode(
                            state: item,
                            isActive: item == state,
                            isComplete: index < activeIndex
                        )
                        if index < LiveExecutionState.allCases.count - 1 {
                            Rectangle()
                                .fill(index < activeIndex ? Color.accentColor : Color(nsColor: .separatorColor))
                                .frame(width: 28, height: 2)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var activeIndex: Int {
        LiveExecutionState.allCases.firstIndex(of: state) ?? 0
    }
}

private struct StateMachineNode: View {
    let state: LiveExecutionState
    let isActive: Bool
    let isComplete: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 24, height: 24)
                Image(systemName: isComplete ? "checkmark" : symbol)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(isActive || isComplete ? .white : .secondary)
            }
            Text(state.rawValue)
                .font(.caption2.weight(isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 92)
        }
    }

    private var fill: Color {
        if isActive { return .accentColor }
        if isComplete { return .green }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var symbol: String {
        switch state {
        case .idle: return "circle"
        case .understanding: return "brain.head.profile"
        case .planning: return "list.bullet.clipboard"
        case .waitingApproval: return "person.crop.circle.badge.questionmark"
        case .executing: return "terminal"
        case .verifying: return "checkmark.seal"
        case .blocked: return "exclamationmark.octagon"
        case .failed: return "xmark.octagon"
        case .completed: return "flag.checkered"
        }
    }
}

struct LiveActivityFeedView: View {
    let feed: AgentNarrationFeed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Live Work Trace", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if let sequence = feed.currentAction?.sequence {
                    Text("#\(sequence)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if feed.currentAction == nil && feed.completedActions.isEmpty && feed.nextAction == nil {
                ContentUnavailableView("No Activity", systemImage: "dot.radiowaves.left.and.right")
                    .frame(height: 120)
            } else {
                if let currentAction = feed.currentAction {
                    NarrationPrimaryCard(title: "Current Action", item: currentAction)
                }

                if !feed.completedActions.isEmpty {
                    NarrationSectionHeader(
                        title: "Completed Actions",
                        count: feed.completedActions.count
                    )
                    VStack(spacing: 8) {
                        ForEach(Array(feed.completedActions.suffix(6).reversed())) { item in
                            NarrationCompactRow(item: item)
                        }
                    }
                }

                if let nextAction = feed.nextAction {
                    NarrationPrimaryCard(title: "Next Action", item: nextAction)
                }

                if !feed.evidenceProduced.isEmpty {
                    NarrationSectionHeader(
                        title: "Evidence Produced",
                        count: feed.evidenceProduced.count
                    )
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 10)], spacing: 10) {
                        ForEach(Array(feed.evidenceProduced.suffix(6).reversed())) { evidence in
                            NarrationEvidenceCard(evidence: evidence)
                        }
                    }
                }
            }
        }
    }
}

private struct NarrationPrimaryCard: View {
    let title: String
    let item: AgentNarrationItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(item.kind.color.opacity(0.14))
                        .frame(width: 36, height: 36)
                    Image(systemName: item.agent?.symbol ?? item.kind.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(item.agent?.color ?? item.kind.color)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        NarrationStatusToken(status: item.status)
                    }
                    Text(item.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: 8) {
                NarrationKindToken(kind: item.kind)
                if let agent = item.agent {
                    Label(agent.rawValue, systemImage: agent.symbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(agent.color)
                }
                Spacer()
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.status == .active ? item.kind.color.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: 0.8)
        )
    }
}

private struct NarrationSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct NarrationCompactRow: View {
    let item: AgentNarrationItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.kind.symbol)
                .frame(width: 18)
                .foregroundStyle(item.kind.color)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer()
                    if let sequence = item.sequence {
                        Text("#\(sequence)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NarrationEvidenceCard: View {
    let evidence: AgentNarrationEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: evidence.kind.symbol)
                    .foregroundStyle(evidence.kind.color)
                Spacer()
                Text("#\(evidence.sequence)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(evidence.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
            if let detail = evidence.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NarrationKindToken: View {
    let kind: AgentNarrationKind

    var body: some View {
        Text(kind.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(kind.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(kind.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct NarrationStatusToken: View {
    let status: AgentNarrationStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(status.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AgentActivityPanel: View {
    let agents: [LiveAgentActivity]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent Activity")
                .font(.headline)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                ForEach(agents) { activity in
                    AgentActivityCard(activity: activity)
                }
            }
        }
    }
}

private struct AgentActivityCard: View {
    let activity: LiveAgentActivity

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                Image(systemName: activity.agent.symbol)
                    .foregroundStyle(activity.agent.color)
                    .frame(width: 18)
                Text(activity.agent.rawValue)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                StatusToken(status: activity.status)
            }

            Text(activity.workTrace)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let sequence = activity.lastEventSequence {
                Text("#\(sequence)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(activity.status == .active ? activity.agent.color.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: 0.7)
        )
    }
}

private struct ApprovalWaitingPanel: View {
    let approvals: [ApprovalRequest]
    let onApprove: (ApprovalRequest) -> Void
    let onReject: (ApprovalRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Waiting for human approval", systemImage: "person.crop.circle.badge.questionmark")
                .font(.headline)
                .foregroundStyle(.purple)

            if approvals.isEmpty {
                Text("Approval request is being prepared.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(approvals) { approval in
                    ApprovalRequestRow(
                        approval: approval,
                        onApprove: onApprove,
                        onReject: onReject
                    )
                }
            }
        }
        .padding(12)
        .background(Color.purple.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.purple.opacity(0.35), lineWidth: 0.8)
        )
    }
}

private struct ApprovalRequestRow: View {
    let approval: ApprovalRequest
    let onApprove: (ApprovalRequest) -> Void
    let onReject: (ApprovalRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(approval.action.capitalized)
                        .font(.callout.weight(.semibold))
                    Text(approval.resource)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer()
                Text(approval.riskLevel.rawValue.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            }

            if let reasons = approval.metadata["risk_reasons"], !reasons.isEmpty {
                Text(reasons)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                Button {
                    onReject(approval)
                } label: {
                    Label("Reject", systemImage: "xmark.shield")
                }
                Button {
                    onApprove(approval)
                } label: {
                    Label("Approve", systemImage: "checkmark.shield")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ExecutionArtifactPanel: View {
    let artifacts: [LiveExecutionArtifact]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Execution Artifacts")
                .font(.headline)

            if artifacts.isEmpty {
                ContentUnavailableView("No Artifacts", systemImage: "shippingbox")
                    .frame(height: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) {
                    ForEach(artifacts) { artifact in
                        ArtifactCard(artifact: artifact)
                    }
                }
            }
        }
    }
}

private struct ArtifactCard: View {
    let artifact: LiveExecutionArtifact

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: artifact.kind.symbol)
                .foregroundStyle(.secondary)
            Text(artifact.value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(artifact.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if let detail = artifact.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct LiveStateBadge: View {
    let state: LiveExecutionState

    var body: some View {
        Text(state.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch state {
        case .idle: return .secondary
        case .understanding: return .teal
        case .planning: return .blue
        case .waitingApproval: return .purple
        case .executing: return .orange
        case .verifying: return .indigo
        case .blocked: return .orange
        case .failed: return .red
        case .completed: return .green
        }
    }
}

private struct CompactLiveMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct StatusToken: View {
    let status: LiveAgentStatus

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var title: String {
        switch status {
        case .queued: return "Queued"
        case .active: return "Active"
        case .completed: return "Done"
        }
    }

    private var color: Color {
        switch status {
        case .queued: return .secondary
        case .active: return .accentColor
        case .completed: return .green
        }
    }
}

private extension AgentKind {
    var symbol: String {
        switch self {
        case .planner: return "list.bullet.clipboard"
        case .executor: return "gearshape.2"
        case .systemUnderstanding: return "brain.head.profile"
        case .recovery: return "shield.lefthalf.filled"
        case .policy: return "checklist.checked"
        }
    }

    var color: Color {
        switch self {
        case .planner: return .blue
        case .executor: return .orange
        case .systemUnderstanding: return .teal
        case .recovery: return .purple
        case .policy: return .indigo
        }
    }
}

private extension LiveExecutionArtifactKind {
    var symbol: String {
        switch self {
        case .executionPlan: return "list.bullet.rectangle"
        case .report: return "doc.text.magnifyingglass"
        case .policyUpdate: return "checklist.checked"
        case .discoveredDependency: return "point.3.connected.trianglepath.dotted"
        case .riskScore: return "exclamationmark.triangle"
        case .fdeScore: return "speedometer"
        }
    }
}

private extension AgentNarrationKind {
    var symbol: String {
        switch self {
        case .action: return "play.circle"
        case .observation: return "eye"
        case .decision: return "arrow.triangle.branch"
        case .result: return "checkmark.seal"
        }
    }

    var color: Color {
        switch self {
        case .action: return .blue
        case .observation: return .teal
        case .decision: return .purple
        case .result: return .green
        }
    }
}

private extension AgentNarrationStatus {
    var color: Color {
        switch self {
        case .active: return .accentColor
        case .completed: return .green
        case .upNext: return .secondary
        }
    }
}
