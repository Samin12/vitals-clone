import SwiftUI
import AppKit

@main
struct VitalsCloneApp: App {
    @State private var store = MonitorStore()

    init() {
        if CommandLine.arguments.contains("--dump") { SelfTest.run() }
        // LSUIElement equivalent: menu-bar only, no Dock icon.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        Window("Vitals", id: "main") {
            MainWindowView().environment(store)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1300, height: 800)

        MenuBarExtra {
            MenuBarView().environment(store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// "An icon, a figure or a graph": pulse icon + CPU and MEM figures, like Vitals' default item.
struct MenuBarLabel: View {
    let store: MonitorStore
    var body: some View {
        let s = store.system
        let strained = s.memoryPressure >= 0.8 || s.cpuTotal >= 0.9
        HStack(spacing: 4) {
            Image(systemName: strained ? "exclamationmark.triangle.fill" : "waveform.path.ecg")
            Text("CPU \(pct(s.cpuTotal))  MEM \(pct(Double(s.memoryUsed) / Double(max(s.memoryTotal, 1))))").monospacedDigit()
        }
    }
}
