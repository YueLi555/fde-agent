import SwiftUI

struct ReplayViewer: View {
    let frames: [ReplayFrame]
    let missionReplay: MissionReplay?
    @State private var selectedIndex = 0.0
    @State private var isPlaying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Deterministic Replay")
                    .font(.headline)
                Spacer()
                Button {
                    isPlaying.toggle()
                } label: {
                    Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                }
                .disabled(frames.isEmpty)
            }
            .padding(.horizontal, 16)

            if frames.isEmpty {
                ContentUnavailableView(
                    "No Replay Frames",
                    systemImage: "memories",
                    description: Text("Select or run a task to inspect the event-sourced replay.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let frame = frames[currentIndex]
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if frames.count > 1 {
                            Slider(value: $selectedIndex, in: 0...Double(frames.count - 1), step: 1)
                        } else {
                            ProgressView(value: 1)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Frame #\(frame.sequence)")
                                    .font(.title3.weight(.semibold))
                                Spacer()
                                if let state = frame.state {
                                    StateBadge(state: state)
                                }
                            }
                            Text(frame.title)
                                .font(.callout)
                            HStack(spacing: 18) {
                                Label("\(frame.graphNodeCount) nodes", systemImage: "circle.hexagongrid")
                                Label("\(frame.graphEdgeCount) edges", systemImage: "arrow.triangle.branch")
                                Label(frame.timestamp.formatted(date: .abbreviated, time: .standard), systemImage: "clock")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(14)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

                        MissionReplaySummaryView(replay: missionReplay)
                    }
                    .padding(16)
                }
            }
        }
        .padding(.top, 10)
        .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
            guard isPlaying, !frames.isEmpty else { return }
            if currentIndex >= frames.count - 1 {
                isPlaying = false
                selectedIndex = Double(frames.count - 1)
            } else {
                selectedIndex += 1
            }
        }
        .onChange(of: frames.count) { _, count in
            selectedIndex = min(selectedIndex, Double(max(0, count - 1)))
        }
    }

    private var currentIndex: Int {
        min(max(0, Int(selectedIndex.rounded())), max(0, frames.count - 1))
    }
}

private struct MissionReplaySummaryView: View {
    let replay: MissionReplay?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Audit Replay", systemImage: "checklist.checked")
                    .font(.headline)
                Spacer()
                if let replay {
                    Label(replay.isAuditComplete ? "Complete" : "Gaps", systemImage: replay.isAuditComplete ? "checkmark.seal" : "exclamationmark.triangle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(replay.isAuditComplete ? .green : .orange)
                }
            }

            if let replay {
                Text(replay.userObjective)
                    .font(.callout.weight(.semibold))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ReplayMetricTile(title: "Decisions", value: "\(replay.agentDecisions.count)")
                    ReplayMetricTile(title: "States", value: "\(replay.stateTransitions.count)")
                    ReplayMetricTile(title: "Approvals", value: "\(replay.approvals.count)")
                    ReplayMetricTile(title: "Evidence", value: "\(replay.evidence.count)")
                }

                if !replay.auditGaps.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Audit gaps")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(replay.auditGaps, id: \.self) { gap in
                            Label(gap, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                if let latestAction = replay.actions.last {
                    ReplayDetailRow(title: "Latest action", value: latestAction.summary)
                }
                if let outcome = replay.outcome {
                    ReplayDetailRow(title: "Outcome", value: outcome.summary)
                }
            } else {
                Text("Run or select a task to reconstruct objective, decisions, approvals, actions, evidence, and outcome.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReplayMetricTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ReplayDetailRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
