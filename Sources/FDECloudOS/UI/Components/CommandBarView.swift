import SwiftUI

struct CommandBarView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 10) {
            TextField(prompt, text: $store.commandText)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .disabled(!store.selectedWorkspaceHasProjectScope)
                .onTapGesture {
                    requestInputFocus()
                }
                .onSubmit { store.submitCommand() }
                .layoutPriority(1)

            Button {
                store.submitCommand()
            } label: {
                Image(systemName: store.isRunning ? "arrow.up.message.fill" : "paperplane.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!store.canSubmitCommand)
            .help(store.isRunning ? "Send message" : "Ask FDE Agent")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            requestInputFocus()
        }
        .onAppear {
            requestInputFocus()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                requestInputFocus()
            }
        }
    }

    private var prompt: String {
        if !store.selectedWorkspaceHasProjectScope {
            return "Choose Legacy and Agent folders first..."
        }
        return store.isRunning ? "Reply or change direction..." : "Ask FDE to inspect, modify, or run code..."
    }

    private func requestInputFocus() {
        guard store.selectedWorkspaceHasProjectScope else { return }
        DispatchQueue.main.async {
            isFocused = true
        }
    }
}
