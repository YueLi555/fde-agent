import AppKit
import SwiftUI

struct CommandBarView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var store: AppStore
    @State private var editorHeight: CGFloat = 34
    @State private var isEditorFocused = false
    @State private var isHovering = false
    @State private var isSendHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: WorkspaceVisualStyle.Spacing.x8) {
            ZStack(alignment: .topLeading) {
                AutoGrowingComposer(
                    text: $store.commandText,
                    height: $editorHeight,
                    focusRequestID: store.composerFocusRequestID,
                    isEnabled: store.selectedWorkspaceHasProjectScope,
                    onSubmit: store.submitCommand,
                    onFocusChanged: { isEditorFocused = $0 }
                )
                .frame(height: editorHeight)

                if store.commandText.isEmpty {
                    Text(prompt)
                        .font(WorkspaceVisualStyle.Typography.body)
                        .foregroundStyle(WorkspaceVisualStyle.color(.textTertiary))
                        .padding(.leading, 3)
                        .padding(.top, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: editorHeight)
            .accessibilityIdentifier("workspace.composer.multiline")
            .layoutPriority(1)

            HStack(spacing: WorkspaceVisualStyle.Spacing.x8) {
                Spacer(minLength: 0)

                Button {
                    store.submitCommand()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(
                            store.canSubmitCommand
                                ? Color.white
                                : WorkspaceVisualStyle.color(.textTertiary)
                        )
                        .frame(width: 32, height: 32)
                        .background(sendButtonFill, in: Circle())
                        .overlay {
                            if !store.canSubmitCommand {
                                Circle()
                                    .stroke(WorkspaceVisualStyle.color(.borderSubtle), lineWidth: 0.7)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!store.canSubmitCommand)
                .help(store.isRunning ? "Send message" : "Ask FDE Agent")
                .accessibilityLabel("Send message")
                .accessibilityIdentifier("workspace.composer.send")
                .onHover { isSendHovering = $0 }
            }
            .frame(minHeight: 32)
        }
        .padding(.horizontal, WorkspaceVisualStyle.Spacing.x16)
        .padding(.top, WorkspaceVisualStyle.Spacing.x12)
        .padding(.bottom, WorkspaceVisualStyle.Spacing.x12)
        .background {
            RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.composer, style: .continuous)
                .fill(WorkspaceVisualStyle.color(.elevatedSurface))
                .overlay {
                    if isHovering && store.selectedWorkspaceHasProjectScope && !isEditorFocused {
                        RoundedRectangle(cornerRadius: WorkspaceVisualStyle.Radius.composer, style: .continuous)
                            .fill(WorkspaceVisualStyle.color(.controlSurfaceHover))
                    }
                }
        }
        // The composer is a floating surface, not a bordered text field. A small
        // neutral elevation change gives focus feedback without competing with the text.
        .shadow(
            color: .black.opacity(isEditorFocused ? 0.085 : 0.055),
            radius: isEditorFocused ? 8 : 5,
            y: isEditorFocused ? 2 : 1
        )
        .opacity(store.selectedWorkspaceHasProjectScope ? 1 : 0.76)
        .onHover { isHovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: editorHeight)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.10), value: isEditorFocused)
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

    private var sendButtonFill: Color {
        guard store.canSubmitCommand else {
            return WorkspaceVisualStyle.color(.controlSurface)
        }
        return WorkspaceVisualStyle.color(.accent).opacity(isSendHovering ? 0.86 : 1)
    }
}

private struct AutoGrowingComposer: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let focusRequestID: UUID
    let isEnabled: Bool
    let onSubmit: () -> Void
    let onFocusChanged: (Bool) -> Void

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
        scrollView.scrollerStyle = .overlay

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

        func textDidBeginEditing(_ notification: Notification) {
            parent.onFocusChanged(true)
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onFocusChanged(false)
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
