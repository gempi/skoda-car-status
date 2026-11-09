import SwiftUI

enum AppInfo {
    static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Car Status for Škoda"
    static let settingsWindowID = "settings"
    static let showBatteryInMenuBarKey = "showBatteryInMenuBar"
}

@main
struct SkodaCarStatusApp: App {
    init() {
        // Poll in the background, measured from the last attempt, so any other refresh (popover open, manual, wake) pushes the next poll out.
        Task {
            while !Task.isCancelled {
                await VehicleModel.shared.refreshIfStale()
                try? await Task.sleep(for: .seconds(VehicleModel.shared.nextPollDelay()))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // The network is often not back yet right at wake.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                await VehicleModel.shared.refreshIfStale()
            }
        }
    }

    @AppStorage(AppInfo.showBatteryInMenuBarKey) private var showBatteryInMenuBar = false

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
        } label: {
            Image("MenuBarIcon")
            if showBatteryInMenuBar, let percent = VehicleModel.shared.battery?.percent {
                Text(" \(percent)%")
            }
        }
        .menuBarExtraStyle(.window)

        Window("Settings", id: AppInfo.settingsWindowID) {
            SettingsView()
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)
    }
}
