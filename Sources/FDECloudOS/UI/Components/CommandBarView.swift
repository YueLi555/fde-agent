import AppKit
import SwiftUI

struct CommandBarView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var store: AppStore
    @State private var editorHeight: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                AutoGrowingComposer(
                    text: $store.commandText,
                    height: $editorHeight,
                    focusRequestID: store.composerFocusRequestID,
                    isEnabled: store.selectedWorkspaceHasProjectScope,
                    onSubmit: store.submitCommand
                )
                .frame(height: editorHeight)

                if store.commandText.isEmpty {
                    Text(prompt)
                        .font(.body)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 2)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .accessibilityIdentifier("workspace.composer.multiline")
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
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("workspace.composer.send")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .animation(.easeOut(duration: 0.12), value: editorHeight)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                store.requestComposerFocus()
            }
        }
    }

    private var prompt: String {
        if !store.selectedWorkspaceHasProjectScope {
            return "Choose Legacy and Agent folders first…"
        }
        return store.isRunning ? "Reply or change direction…" : "Ask FDE to inspect, modify, or run code…"
    }
}

private struct AutoGrowingComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusRequestID: UUID
    let isEnabled: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 1, height: 5)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: .greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.scrollView = scrollView
        context.coordinator.recalculateHeight()
        DispatchQueue.main.async {
            guard isEnabled else { return }
            textView.window?.makeFirstResponder(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            context.coordinator.recalculateHeight()
        }
        textView.isEditable = isEnabled

        if context.coordinator.lastFocusRequestID != focusRequestID {
            context.coordinator.lastFocusRequestID = focusRequestID
            DispatchQueue.main.async {
                guard isEnabled else { return }
                textView.window?.makeFirstResponder(textView)
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoGrowingComposer
        weak var textView: NSTextView?
        weak var scrollView: NSScrollView?
        var lastFocusRequestID: UUID?

        init(parent: AutoGrowingComposer) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            parent.text = textView.string
            recalculateHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            let action = ComposerSubmissionPolicy.action(
                text: textView.string,
                shiftPressed: NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
                hasMarkedText: textView.hasMarkedText()
            )
            switch action {
            case .insertNewline, .ignore:
                return false
            case .submit:
                parent.onSubmit()
                return true
            }
        }

        func recalculateHeight() {
            guard let textView, let scrollView,
                  let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let font = textView.font ?? .systemFont(ofSize: NSFont.systemFontSize)
            let lineHeight = ceil(layoutManager.defaultLineHeight(for: font))
            let inset = textView.textContainerInset.height * 2
            let requiredHeight = ceil(layoutManager.usedRect(for: textContainer).height + inset)
            let minimumHeight = lineHeight + inset
            let maximumHeight = lineHeight * CGFloat(AutoGrowingComposerMetrics.maximumVisibleLines) + inset
            let resolvedHeight = min(max(requiredHeight, minimumHeight), maximumHeight)
            scrollView.hasVerticalScroller = requiredHeight > maximumHeight
            if abs(parent.height - resolvedHeight) > 0.5 {
                DispatchQueue.main.async {
                    self.parent.height = resolvedHeight
                }
            }
        }
    }
}
