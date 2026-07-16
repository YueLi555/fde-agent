import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ZStack {
            VisualEffectView()
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("FDE Agent", systemImage: "sparkles")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 8) {
                        ProjectScopeRow(
                            title: "Legacy",
                            path: store.selectedWorkspaceProjectRoot,
                            buttonTitle: store.selectedWorkspaceProjectRoot == nil ? "Choose Legacy" : "Change Legacy",
                            action: store.chooseProjectDirectory
                        )

                        ProjectScopeRow(
                            title: "Agent",
                            path: store.selectedWorkspaceAgentProjectRoot,
                            buttonTitle: store.selectedWorkspaceAgentProjectRoot == nil ? "Choose Agent" : "Change Agent",
                            action: store.chooseAgentProjectDirectory
                        )
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Dialog")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(store.agentSessions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)

                    if store.agentSessions.isEmpty {
                        Text("Start by sending a message.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    } else {
                        List(selection: Binding(
                            get: { store.selectedAgentSessionID },
                            set: { store.selectAgentSession($0) }
                        )) {
                            ForEach(store.agentSessions) { session in
                                AgentSessionRow(session: session)
                                    .tag(Optional(session.sessionID))
                            }
                        }
                        .listStyle(.sidebar)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)

                IdentityPanel()
                    .padding(14)
            }
        }
    }
}

private struct ProjectScopeRow: View {
    let title: String
    let path: String?
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let path {
                Text(path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Button {
                action()
            } label: {
                Label(buttonTitle, systemImage: "folder")
            }
            .controlSize(.small)
            .help("Choose the \(title) code folder.")
        }
    }
}

private struct AgentSessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.userGoal)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: session.currentState.sidebarSymbol)
                    .foregroundStyle(session.currentState.sidebarColor)
            }
            Text(session.currentState.sidebarTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private extension AgentState {
    var sidebarTitle: String {
        switch self {
        case .idle: return "Idle"
        case .understanding: return "Understanding"
        case .planning: return "Planning"
        case .executing: return "Executing"
        case .waitingApproval: return "Waiting approval"
        case .recovering: return "Recovering"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var sidebarSymbol: String {
        switch self {
        case .idle: return "circle"
        case .understanding: return "brain.head.profile"
        case .planning: return "list.bullet.clipboard"
        case .executing: return "terminal"
        case .waitingApproval: return "checkmark.shield"
        case .recovering: return "arrow.triangle.2.circlepath"
        case .blocked: return "exclamationmark.octagon"
        case .completed: return "checkmark.seal"
        case .failed: return "xmark.octagon"
        }
    }

    var sidebarColor: Color {
        switch self {
        case .idle: return .secondary
        case .understanding, .planning: return .accentColor
        case .executing: return .blue
        case .waitingApproval: return .purple
        case .recovering: return .orange
        case .blocked: return .orange
        case .completed: return .green
        case .failed: return .red
        }
    }
}
