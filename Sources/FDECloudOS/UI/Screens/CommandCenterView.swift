import SwiftUI

struct CommandCenterView: View {
    var body: some View {
        AgentWorkspaceView()
            .frame(minWidth: 680)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}
