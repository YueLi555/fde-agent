import SwiftUI

struct IntelligenceView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Outcome Tracking")
                    .font(.headline)

                if let outcome = store.latestOutcome {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        MetricTile(title: "FDE Score", value: "\(Int(outcome.fdePerformanceScore))", symbol: "speedometer")
                        MetricTile(title: "Success", value: percent(outcome.taskSuccessRate), symbol: "checkmark.seal")
                        MetricTile(title: "Retry", value: percent(outcome.retryRate), symbol: "arrow.clockwise")
                        MetricTile(title: "Human", value: percent(outcome.humanInterventionRate), symbol: "person.crop.circle")
                        MetricTile(title: "Integration", value: percent(outcome.integrationSuccessScore), symbol: "link")
                    }
                } else {
                    ContentUnavailableView("No Metrics", systemImage: "chart.line.uptrend.xyaxis")
                        .frame(height: 180)
                }

                Divider()

                Text("Field Feedback Intelligence")
                    .font(.headline)

                if store.feedback.isEmpty {
                    ContentUnavailableView("No Feedback", systemImage: "lightbulb")
                        .frame(height: 180)
                } else {
                    ForEach(store.feedback) { item in
                        FeedbackCard(item: item)
                    }
                }
            }
            .padding(16)
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct FeedbackCard: View {
    let item: FeedbackInsight

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(item.kind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(item.title)
                .font(.callout.weight(.semibold))
            Text(item.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
