import SwiftUI
import AppKit

@main
struct SpartanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("Spartan", systemImage: "text.viewfinder") {
            MenuBarView(coordinator: .shared)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // No Dock icon even when run as a bare binary (bundled runs get this
        // from LSUIElement).
        NSApp.setActivationPolicy(.accessory)
        AppCoordinator.shared.start()
    }
}
