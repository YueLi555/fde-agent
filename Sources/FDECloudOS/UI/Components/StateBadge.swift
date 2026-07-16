import SwiftUI

struct StateBadge: View {
    let state: TaskState

    var body: some View {
        Text(state.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }

    private var color: Color {
        switch state {
        case .created: return .secondary
        case .planned: return .blue
        case .running: return .orange
        case .waiting: return .purple
        case .pendingApproval: return .purple
        case .blocked: return .orange
        case .failed: return .red
        case .completed: return .green
        case .replayed: return .teal
        }
    }
}
