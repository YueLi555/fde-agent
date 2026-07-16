import SwiftUI

struct IdentityPanel: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Account", systemImage: "person.crop.circle")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if let session = store.session {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.subject)
                        .font(.callout.weight(.medium))
                    Text(session.provider)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    store.clearSession()
                } label: {
                    Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                }
                .buttonStyle(.borderless)
            } else {
                Text("Signed out")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    store.createStubSession()
                } label: {
                    Label("Log In", systemImage: "key")
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
