import AppKit
import SwiftUI

@MainActor
private final class AppActivationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.activateMainWindow()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.activateMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.activateMainWindow()
        return true
    }

    static func activateMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor in
            await Task.yield()
            let mainWindow = NSApp.windows.first { window in
                window.title == "FDE Agent" && window.canBecomeKey
            } ?? NSApp.windows.first { window in
                window.canBecomeKey && window.isVisible && !window.isMiniaturized
            }

            mainWindow?.makeKeyAndOrderFront(nil)
        }
    }
}

@main
struct FDECloudOSApp: App {
    @NSApplicationDelegateAdaptor(AppActivationDelegate.self) private var appActivationDelegate
    @StateObject private var store: AppStore

    init() {
        _store = StateObject(wrappedValue: AppStore.makeLive())
    }

    var body: some Scene {
        WindowGroup("FDE Agent") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 860, minHeight: 640)
                .onAppear {
                    AppActivationDelegate.activateMainWindow()
                }
        }
        .commands {
            CommandMenu("FDE") {
                Button("Send Message") {
                    store.submitCommand()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!store.selectedWorkspaceHasProjectScope)
            }
        }
    }
}
