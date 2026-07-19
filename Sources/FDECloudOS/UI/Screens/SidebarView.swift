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

                    Button {
                        store.createNewChat()
                    } label: {
                        Label("New Chat", systemImage: "plus")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("workspace.newChat")

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Workspace")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(store.selectedWorkspace?.displayName ?? "No workspace selected")
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                    }

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
                        Text("Conversations")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(store.selectedWorkspaceAgentSessions.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)

                    if store.selectedWorkspaceAgentSessions.isEmpty {
                        Text("Start by sending a message.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    } else {
                        List(selection: Binding(
                            get: { store.selectedAgentSessionID },
                            set: { store.selectAgentSession($0) }
                        )) {
                            ForEach(store.selectedWorkspaceAgentSessions) { session in
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
    @EnvironmentObject private var store: AppStore
    let session: AgentSession

    private var status: AgentInteractionState {
        store.conversationStatus(for: session.sessionID) ?? .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(session.displayTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Image(systemName: status.conversationSymbol)
                    .foregroundStyle(status.conversationColor)
            }
            Text(status.conversationTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
