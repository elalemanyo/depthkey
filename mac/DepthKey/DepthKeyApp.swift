import SwiftUI

@main
struct DepthKeyApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        Window("DepthKey", id: "main") {
            ContentView(model: delegate.model, settings: delegate.model.settings)
        }
        .defaultSize(width: 1180, height: 600)
        .commands {
            CommandMenu("Effect") {
                EffectMenu(model: delegate.model, settings: delegate.model.settings)
            }
        }

        // Closing the window keeps DepthKey running here, so calls keep their camera.
        MenuBarExtra("DepthKey", systemImage: "person.crop.rectangle.fill") {
            MenuBarContent(model: delegate.model, settings: delegate.model.settings)
        }
    }
}

/// Background, cut-off and following, with shortcuts: in the Effect menu and the menu bar.
struct EffectMenu: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings

    private static let keys: [BackgroundMode: KeyEquivalent] = [.blur: "1", .color: "2", .image: "3", .video: "4", .depth: "5", .off: "0"]

    var body: some View {
        ForEach(BackgroundMode.allCases) { mode in
            Toggle(mode.label, isOn: Binding(get: { settings.mode == mode }, set: { if $0 { settings.mode = mode } }))
                .keyboardShortcut(Self.keys[mode]!, modifiers: .command)
        }
        Divider()
        Button("Cut-off Nearer") { model.nudgeCutoff(by: -0.05) }
            .keyboardShortcut("-", modifiers: .command)
        Button("Cut-off Farther") { model.nudgeCutoff(by: 0.05) }
            .keyboardShortcut("=", modifiers: .command)
        Button("Measure Cut-off") { model.autoCutoff() }
            .keyboardShortcut("r", modifiers: .command)
        Toggle("Follow My Face", isOn: $settings.followFace)
            .keyboardShortcut("f", modifiers: .command)
    }
}

private struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: Settings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show DepthKey") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Divider()
        EffectMenu(model: model, settings: settings)
        Divider()
        Text(model.virtualCameraConnected ? "Sending to OBS Virtual Camera" : "OBS Virtual Camera not found")
        Text(String(format: "Cut-off %.2f m", settings.cutoff))
        Divider()
        Button("Quit DepthKey") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { model.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { model.stop() }
    }
}
