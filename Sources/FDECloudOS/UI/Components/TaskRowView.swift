import SwiftUI

struct TaskRowView: View {
    let task: FDETask

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(task.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 8)
                StateBadge(state: task.state)
            }

            HStack(spacing: 10) {
                Label("\(Int(task.riskScore))", systemImage: "exclamationmark.triangle")
                Label("\(Int(task.performanceScore))", systemImage: "speedometer")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}
