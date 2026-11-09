import SwiftUI

struct PopoverView: View {
    @Environment(\.openWindow) private var openWindow
    private let store = CredentialsStore.shared
    @State private var popoverWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let loadError = store.loadError {
                Text("Couldn't read your saved settings: \(loadError)")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)

                Divider().padding(.horizontal, 8)
            }

            if store.saved.isComplete {
                BatteryView()

                if VehicleModel.shared.vehicle != nil {
                    VehicleView()
                }

                if let position = VehicleModel.shared.parkingPosition {
                    ParkingMapView(position: position)
                }

                Divider().padding(.horizontal, 8)
            }

            if store.needsSetup {
                VStack(spacing: 8) {
                    Image(systemName: "car.side.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)

                    Text("No vehicle yet")
                        .font(.headline)

                    Text("Add your vehicle to see its battery and status.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    Button("Add Vehicle", action: openSettings)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .padding(.horizontal, 8)

                Divider().padding(.horizontal, 8)
            }

            MenuRow(title: "Settings…", key: ",", action: openSettings)

            if store.saved.isComplete {
                MenuRow(title: "Refresh...", key: "r", detail: VehicleModel.shared.lastUpdated, disabled: VehicleModel.shared.isLoading) {
                    Task { await VehicleModel.shared.refresh() }
                }
            }

            Divider().padding(.horizontal, 8)

            MenuRow(title: "Quit \(AppInfo.name)", key: "q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(8)
        .frame(width: 300)
        .background(WindowReader { popoverWindow = $0 })
        .onAppear { Task { await VehicleModel.shared.refreshIfStale() } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window === popoverWindow else { return }
            Task { await VehicleModel.shared.refreshIfStale() }
        }
    }

    private func openSettings() {
        openWindow(id: AppInfo.settingsWindowID)
        NSApp.activate()
        popoverWindow?.close()
    }
}

private struct MenuRow: View {
    let title: String
    var key: KeyEquivalent?
    var symbol: String?
    var detail: Date?
    var disabled = false
    let action: () -> Void
    @State private var hovering = false

    private static func ageText(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        return minutes < 1 ? "less than 1 min ago" : "\(minutes) min ago"
    }

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                if let detail {
                    TimelineView(.periodic(from: .now, by: 60)) { _ in
                        Text(Self.ageText(since: detail))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if let key {
                    Text("⌘" + String(key.character).uppercased()).foregroundStyle(.secondary)
                }
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.primary.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
        .optionalKeyboardShortcut(key)
        .disabled(disabled)
        .onHover { hovering = $0 }
    }
}

private extension View {
    @ViewBuilder
    func optionalKeyboardShortcut(_ key: KeyEquivalent?) -> some View {
        if let key { keyboardShortcut(key) } else { self }
    }
}

private struct WindowReader: NSViewRepresentable {
    let onChange: (NSWindow?) -> Void

    final class View: NSView {
        var onChange: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { onChange?(window) }
    }

    func makeNSView(context: Context) -> View {
        let view = View()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: View, context: Context) {
        view.onChange = onChange
    }
}
