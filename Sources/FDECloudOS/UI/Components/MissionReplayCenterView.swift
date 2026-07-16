import SwiftUI

struct MissionReplayCenterView: View {
    let timeline: MissionReplayTimeline
    let validationStatus: String

    @State private var selectedEventID: UUID?
    @State private var agentFilter: String?
    @State private var stageFilter: MissionReplayStage?

    private var filter: MissionReplayTimelineFilter {
        MissionReplayTimelineFilter(agentName: agentFilter, stage: stageFilter)
    }

    private var filteredEvents: [MissionReplayTimelineEvent] {
        timeline.events(matching: filter)
    }

    private var selectedEvent: MissionReplayTimelineEvent? {
        if let selectedEventID,
           let event = filteredEvents.first(where: { $0.id == selectedEventID }) {
            return event
        }
        return filteredEvents.first
    }

    private var selectedIndex: Int? {
        guard let selectedEvent else { return nil }
        return filteredEvents.firstIndex(where: { $0.id == selectedEvent.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            if timeline.events.isEmpty {
                ContentUnavailableView(
                    "No Mission Replay",
                    systemImage: "timeline.selection",
                    description: Text("Select or run a mission to reconstruct the replay timeline.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                controls
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()

                HSplitView {
                    eventList
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 360)

                    ScrollView {
                        MissionReplayEventDetailView(event: selectedEvent)
                            .padding(16)
                            .frame(maxWidth: 760, alignment: .topLeading)
                            .frame(maxWidth: .infinity, alignment: .top)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            MissionReplayOutcomeStoryView(story: timeline.outcomeStory)
                            MissionReplayAgentDecisionsView(decisions: timeline.agentDecisionVisualizations)
                            MissionReplayAuditView(auditGaps: timeline.auditGaps, validationStatus: validationStatus)
                        }
                        .padding(14)
                    }
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
                    .background(Color(nsColor: .underPageBackgroundColor))
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: selectFirstAvailableEvent)
        .onChange(of: filteredEvents.map(\.id)) { _, _ in
            selectFirstAvailableEvent()
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "timeline.selection")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text("Mission Replay Center")
                    .font(.title3.weight(.semibold))
                Text(timeline.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text("\(filteredEvents.count) / \(timeline.events.count)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text("events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button {
                stepBackward()
            } label: {
                Image(systemName: "chevron.left")
            }
            .help("Step backward")
            .disabled(selectedIndex == nil || selectedIndex == 0)

            Button {
                stepForward()
            } label: {
                Image(systemName: "chevron.right")
            }
            .help("Step forward")
            .disabled(selectedIndex == nil || selectedIndex == filteredEvents.count - 1)

            Divider()
                .frame(height: 20)

            Picker("Agent", selection: $agentFilter) {
                Text("All Agents").tag(Optional<String>.none)
                ForEach(timeline.agents, id: \.self) { agent in
                    Text(agent).tag(Optional(agent))
                }
            }
            .frame(maxWidth: 190)
            .help("Filter by agent")

            Picker("Stage", selection: $stageFilter) {
                Text("All Stages").tag(Optional<MissionReplayStage>.none)
                ForEach(MissionReplayStage.allCases) { stage in
                    Text(stage.displayName).tag(Optional(stage))
                }
            }
            .frame(maxWidth: 190)
            .help("Filter by stage")

            Spacer()

            if let selectedIndex {
                Text("Step \(selectedIndex + 1) of \(filteredEvents.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private var eventList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if filteredEvents.isEmpty {
                    ContentUnavailableView(
                        "No Matching Events",
                        systemImage: "line.3.horizontal.decrease.circle",
                        description: Text("Adjust the agent or stage filter.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                } else {
                    ForEach(filteredEvents) { event in
                        Button {
                            selectedEventID = event.id
                        } label: {
                            MissionReplayEventRow(
                                event: event,
                                isSelected: selectedEvent?.id == event.id
                            )
                        }
                        .buttonStyle(.plain)
                        .help("Jump to this replay event")
                    }
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func selectFirstAvailableEvent() {
        guard !filteredEvents.isEmpty else {
            selectedEventID = nil
            return
        }
        if let selectedEventID,
           filteredEvents.contains(where: { $0.id == selectedEventID }) {
            return
        }
        selectedEventID = filteredEvents.first?.id
    }

    private func stepForward() {
        guard let selectedIndex else { return }
        let nextIndex = min(selectedIndex + 1, filteredEvents.count - 1)
        selectedEventID = filteredEvents[nextIndex].id
    }

    private func stepBackward() {
        guard let selectedIndex else { return }
        let previousIndex = max(selectedIndex - 1, 0)
        selectedEventID = filteredEvents[previousIndex].id
    }
}

private struct MissionReplayEventRow: View {
    let event: MissionReplayTimelineEvent
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.stage.symbol)
                .foregroundStyle(event.stage.color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(event.stage.displayName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(event.stage.color)
                    Text("#\(event.sequence)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(event.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(event.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let agentName = event.agentName {
                    Label(agentName, systemImage: "person.crop.circle.badge.checkmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
    }
}

private struct MissionReplayEventDetailView: View {
    let event: MissionReplayTimelineEvent?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let event {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(event.stage.displayName, systemImage: event.stage.symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(event.stage.color)
                        Spacer()
                        Text("Sequence \(event.sequence)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Text(event.title)
                        .font(.title3.weight(.semibold))
                    Text(event.summary)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)

                    if let timestamp = event.timestamp {
                        Label(timestamp.formatted(date: .abbreviated, time: .standard), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let agentName = event.agentName {
                        Label(agentName, systemImage: "person.crop.circle.badge.checkmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .replayPanelStyle()

                if let decision = event.decisionVisualization {
                    MissionReplayDecisionDetailView(decision: decision)
                }

                MissionReplayEvidenceListView(evidence: event.evidence)
            } else {
                ContentUnavailableView("No Event Selected", systemImage: "timeline.selection")
                    .frame(maxWidth: .infinity, minHeight: 320)
            }
        }
    }
}

private struct MissionReplayDecisionDetailView: View {
    let decision: MissionReplayAgentDecisionVisualization

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent Decision", systemImage: "person.2.badge.gearshape")
                .font(.headline)

            ReplayStoryRow(title: "Selected Agent", value: decision.agentName)
            ReplayStoryRow(title: "Why Selected", value: decision.selectedBecause)

            if let confidence = decision.confidence {
                ReplayStoryRow(title: "Confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
            }

            ReplayListSection(title: "Supporting Evidence", values: decision.supportingEvidence)
            ReplayListSection(title: "Alternatives", values: decision.alternatives)
        }
        .replayPanelStyle()
    }
}

private struct MissionReplayEvidenceListView: View {
    let evidence: [MissionReplayEventEvidence]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Evidence", systemImage: "checklist.checked")
                .font(.headline)

            if evidence.isEmpty {
                Text("No additional evidence attached to this event.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(evidence) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            Text(item.source)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(item.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .replayPanelStyle()
    }
}

private struct MissionReplayOutcomeStoryView: View {
    let story: MissionReplayOutcomeStory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Outcome Story", systemImage: "doc.text.magnifyingglass")
                .font(.headline)

            ReplayStoryRow(title: "Problem", value: story.problem)
            ReplayStoryRow(title: "Investigation", value: story.investigation)
            ReplayStoryRow(title: "Solution", value: story.solution)
            ReplayStoryRow(title: "Evidence", value: story.evidence)
            ReplayStoryRow(title: "Impact", value: story.impact)
        }
        .replayPanelStyle()
    }
}

private struct MissionReplayAgentDecisionsView: View {
    let decisions: [MissionReplayAgentDecisionVisualization]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent Selection", systemImage: "person.2.badge.gearshape")
                .font(.headline)

            if decisions.isEmpty {
                Text("No agent selection decisions reconstructed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(decisions) { decision in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(decision.agentName)
                                .font(.caption.weight(.semibold))
                            Spacer()
                            if let confidence = decision.confidence {
                                Text(confidence.formatted(.percent.precision(.fractionLength(0))))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text(decision.selectedBecause)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(9)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .replayPanelStyle()
    }
}

private struct MissionReplayAuditView: View {
    let auditGaps: [String]
    let validationStatus: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Replay Integrity", systemImage: auditGaps.isEmpty ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(auditGaps.isEmpty ? .green : .orange)

            Text(validationStatus)
                .font(.caption)
                .foregroundStyle(.secondary)

            if auditGaps.isEmpty {
                Text("Audit replay contains the required mission records.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(auditGaps, id: \.self) { gap in
                    Label(gap, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .replayPanelStyle()
    }
}

private struct ReplayStoryRow: View {
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

private struct ReplayListSection: View {
    let title: String
    let values: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if values.isEmpty {
                Text("None recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values, id: \.self) { value in
                    Label(value, systemImage: "checkmark.circle")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private extension View {
    func replayPanelStyle() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private extension MissionReplayStage {
    var symbol: String {
        switch self {
        case .userGoal: return "target"
        case .discovery: return "magnifyingglass"
        case .teamFormation: return "person.3"
        case .agentProposals: return "bubble.left.and.text.bubble.right"
        case .conflicts: return "exclamationmark.triangle"
        case .decisions: return "arrow.triangle.branch"
        case .approvals: return "checkmark.shield"
        case .executions: return "terminal"
        case .evidence: return "checklist.checked"
        case .outcome: return "flag.checkered"
        }
    }

    var color: Color {
        switch self {
        case .userGoal: return .accentColor
        case .discovery: return .blue
        case .teamFormation: return .indigo
        case .agentProposals: return .purple
        case .conflicts: return .orange
        case .decisions: return .teal
        case .approvals: return .mint
        case .executions: return .cyan
        case .evidence: return .green
        case .outcome: return .pink
        }
    }
}
