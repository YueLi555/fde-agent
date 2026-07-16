import SwiftUI

struct ConnectorPanel: View {
    let statuses: [ConnectorStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Enterprise Connectors")
                .font(.headline)
                .padding(.horizontal, 16)

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(statuses) { status in
                        ConnectorRow(status: status)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 10)
    }
}

private struct ConnectorRow: View {
    let status: ConnectorStatus

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 22)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(status.displayName)
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text(status.state.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(color)
                }
                Text(status.lastSyncSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var icon: String {
        switch status.id {
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "gmail": return "envelope"
        case "notion": return "doc.richtext"
        case "slack": return "number"
        default: return "link"
        }
    }

    private var color: Color {
        switch status.state {
        case .ready: return .green
        case .needsOAuth: return .orange
        case .degraded: return .red
        case .disconnected: return .secondary
        }
    }
}
