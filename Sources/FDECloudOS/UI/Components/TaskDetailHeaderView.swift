import SwiftUI

struct TaskDetailHeaderView: View {
    let task: FDETask?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let task {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                        Text(task.rawInput)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Spacer()
                    StateBadge(state: task.state)
                }

                HStack(spacing: 18) {
                    CompactMetric(label: "Reality Risk", value: "\(Int(task.riskScore))")
                    CompactMetric(label: "Failure Probability", value: "\(Int(task.failureProbability * 100))%")
                    CompactMetric(label: "FDE Score", value: "\(Int(task.performanceScore))")
                    CompactMetric(label: "Plan Steps", value: "\(task.plan.count)")
                }
            } else {
                ContentUnavailableView(
                    "No Task Selected",
                    systemImage: "tray",
                    description: Text("Submit a command to create the first execution workflow.")
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct CompactMetric: View {
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
