import SwiftUI

struct ExecutionTimelineView: View {
    let events: [ExecutionEvent]
    @State private var mode: TimelinePresentationMode = .human

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Execution Timeline")
                    .font(.headline)
                Spacer()
                Picker("Timeline View", selection: $mode) {
                    ForEach(TimelinePresentationMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 220)
                Text("\(events.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            if events.isEmpty {
                ContentUnavailableView(
                    "Timeline Empty",
                    systemImage: "timeline.selection",
                    description: Text("Runtime events will stream here while execution runs.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(events) { event in
                            switch mode {
                            case .human:
                                HumanTimelineCard(item: LiveExecutionMapper.timelineItem(for: event))
                            case .developer:
                                DeveloperTimelineCard(event: event)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

private enum TimelinePresentationMode: String, CaseIterable, Identifiable {
    case human
    case developer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .human: return "Human View"
        case .developer: return "Developer Trace"
        }
    }
}

private struct HumanTimelineCard: View {
    let item: LiveExecutionTimelineItem

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(item.humanTitle)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("#\(item.sequence)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if let agent = item.agent {
                    Text(agent.rawValue)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(item.humanDetail)
                    .font(.callout)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch item.eventType {
        case .taskCreated: return "plus.circle"
        case .contextCompiled: return "brain.head.profile"
        case .planGenerated: return "list.bullet.clipboard"
        case .toolCalled: return "terminal"
        case .humanApprovalRequested: return "person.crop.circle.badge.questionmark"
        case .taskCompleted: return "flag.checkered"
        case .recoveryAttempted: return "arrow.clockwise.circle"
        case .authorizationDenied: return "lock.trianglebadge.exclamationmark"
        case .toolFailed, .connectorFailed, .nodeExecutionFailed, .workerTaskFailed: return "xmark.octagon"
        default: return "circle.dotted"
        }
    }

    private var color: Color {
        switch item.eventType {
        case .toolFailed, .connectorFailed, .authorizationDenied, .humanRejected, .nodeExecutionFailed, .workerTaskFailed:
            return .red
        case .taskCompleted, .policyUpdated, .humanApproved, .connectorExecuted, .nodeExecutionCompleted, .workerTaskCompleted:
            return .green
        case .humanApprovalRequested:
            return .purple
        default:
            return .accentColor
        }
    }
}

private struct DeveloperTimelineCard: View {
    let event: ExecutionEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(event.type.rawValue)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text("#\(event.sequence)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(event.summary)
                    .font(.callout)
                let trace = LiveExecutionMapper.timelineItem(for: event).developerTrace
                if !trace.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                        ForEach(trace) { field in
                            GridRow {
                                Text(field.key)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(field.value)
                                    .font(.caption2.monospaced())
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch event.type {
        case .taskCreated: return "plus.circle"
        case .contextCompiled: return "brain.head.profile"
        case .planGenerated: return "list.bullet.clipboard"
        case .stepExecuted: return "checkmark.circle"
        case .toolCalled: return "terminal"
        case .toolFailed: return "xmark.octagon"
        case .connectorCalled: return "externaldrive.connected.to.line.below"
        case .connectorDryRun: return "checkmark.seal"
        case .connectorExecuted: return "checkmark.seal.fill"
        case .connectorFailed: return "xmark.octagon.fill"
        case .recoveryAttempted: return "arrow.clockwise.circle"
        case .humanApprovalRequested: return "person.crop.circle.badge.questionmark"
        case .stateUpdated: return "arrow.triangle.2.circlepath"
        case .taskCompleted: return "flag.checkered"
        case .feedbackGenerated: return "quote.bubble"
        case .policyUpdated: return "checklist.checked"
        case .humanApproved: return "checkmark.shield"
        case .humanRejected: return "xmark.shield"
        case .sessionStarted: return "person.crop.circle.badge.checkmark"
        case .sessionEnded: return "person.crop.circle.badge.xmark"
        case .workspaceSwitched: return "rectangle.2.swap"
        case .authorizationDenied: return "lock.trianglebadge.exclamationmark"
        case .roleChanged: return "person.badge.shield.checkmark"
        case .routingDecisionMade: return "point.3.connected.trianglepath.dotted"
        case .nodeSelected: return "target"
        case .executionTargetAssigned: return "arrow.down.forward.circle"
        case .nodeExecutionStarted: return "play.circle"
        case .nodeExecutionCompleted: return "checkmark.circle.fill"
        case .nodeExecutionFailed: return "exclamationmark.octagon"
        case .executionDispatched: return "paperplane"
        case .executionReceived: return "tray.and.arrow.down"
        case .executionResponseReceived: return "tray.and.arrow.up"
        case .workerRegistered: return "desktopcomputer.and.arrow.down"
        case .workerTaskReceived: return "shippingbox.and.arrow.backward"
        case .workerTaskCompleted: return "checkmark.rectangle.stack"
        case .workerTaskFailed: return "xmark.rectangle.stack"
        case .userMessageReceived: return "message"
        case .userDecisionSelected: return "arrow.triangle.branch"
        case .userApprovalGranted: return "checkmark.shield"
        case .userApprovalRejected: return "xmark.shield"
        }
    }

    private var color: Color {
        event.type == .toolFailed || event.type == .connectorFailed || event.type == .authorizationDenied || event.type == .humanRejected || event.type == .workerTaskFailed || event.type == .userApprovalRejected
            ? .red
            : (event.type == .taskCompleted || event.type == .policyUpdated || event.type == .humanApproved || event.type == .connectorExecuted || event.type == .userApprovalGranted ? .green : .accentColor)
    }
}
