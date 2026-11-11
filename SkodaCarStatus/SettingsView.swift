import ServiceManagement
import SwiftUI

enum SettingsPane: Hashable {
    case general, cars
}

/// Lets other views (the popover's "Add Vehicle") choose the pane the settings window shows.
@MainActor @Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selection: SettingsPane? = .general {
        didSet { record() }
    }
    var showingCarSheet = false

    private var history: [SettingsPane] = [.general]
    private var position = 0
    private var isNavigating = false

    var canGoBack: Bool { position > 0 }
    var canGoForward: Bool { position < history.count - 1 }

    private init() {}

    func goBack() { go(to: position - 1) }
    func goForward() { go(to: position + 1) }

    private func go(to index: Int) {
        guard history.indices.contains(index) else { return }
        isNavigating = true
        position = index
        selection = history[index]
        isNavigating = false
    }

    private func record() {
        guard !isNavigating, let selection, selection != history[position] else { return }
        history.removeSubrange((position + 1)...)
        history.append(selection)
        position += 1
    }
}

struct SettingsView: View {
    @Bindable private var router = SettingsRouter.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $router.selection) {
                SidebarRow(title: "General", symbol: "gearshape.fill", color: .gray)
                    .tag(SettingsPane.general)

                SidebarRow(title: "Cars", symbol: "car.fill", color: .blue)
                    .tag(SettingsPane.cars)
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            switch router.selection ?? .general {
            case .general: GeneralPane()
            case .cars: CarsPane()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { router.goBack() }
                    .disabled(!router.canGoBack)
                Button("Forward", systemImage: "chevron.right") { router.goForward() }
                    .disabled(!router.canGoForward)
            }
        }
        .frame(minWidth: 620, maxWidth: .infinity, minHeight: 400, maxHeight: .infinity)
        .background(DockPresence())
        .onAppear { Task { await CredentialsStore.shared.reload() } }
    }
}

/// A menu-bar-only app has no Dock icon or Cmd+Tab entry, so its window would be lost behind other apps.
/// While the settings window exists the app is a regular one, so you can switch away to copy a VIN or key.
private struct DockPresence: NSViewRepresentable {
    final class View: NSView {
        private var closeObserver: Any?

        override func viewDidMoveToWindow() {
            guard let window else {
                closeObserver.map(NotificationCenter.default.removeObserver)
                closeObserver = nil
                return
            }
            guard closeObserver == nil else { return }
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            }
            closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
        }
    }

    func makeNSView(context: Context) -> View { View() }
    func updateNSView(_ view: View, context: Context) {}
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

private struct GeneralPane: View {
    @AppStorage(AppInfo.showBatteryInMenuBarKey) private var showBatteryInMenuBar = false
    @State private var launchAtLogin = false
    @State private var launchError: String?
    @State private var needsApproval = false

    /// `.requiresApproval` means the item is registered but switched off in System Settings, so it still counts as on here.
    private var launchServiceEnabled: Bool {
        [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != launchServiceEnabled else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = launchServiceEnabled
        needsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show battery percentage in menu bar", isOn: $showBatteryInMenuBar)
            } footer: {
                Text("Displays the charge level next to the icon.")
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
            } footer: {
                if let launchError {
                    Text(launchError).foregroundStyle(.red)
                } else if needsApproval {
                    HStack {
                        Text("Allow Skoda Car Status under Login Items in System Settings.")
                        Button("Open Settings") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = launchServiceEnabled
            needsApproval = SMAppService.mainApp.status == .requiresApproval
        }
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        .navigationTitle("General")
    }
}

private struct CarsPane: View {
    @Bindable private var router = SettingsRouter.shared
    private let store = CredentialsStore.shared
    @State private var confirmingRemove = false
    @State private var removeError: String?
    @State private var removing = false

    var body: some View {
        Group {
            if store.saved.isComplete {
                Form {
                    Section {
                        LabeledContent("Name", value: VehicleModel.shared.vehicleName ?? "–")
                        if let plate = VehicleModel.shared.licensePlate {
                            LabeledContent("Licence plate", value: plate)
                        }
                        LabeledContent("VIN", value: store.saved.vin)
                        HStack {
                            Button("Remove…", role: .destructive) { confirmingRemove = true }
                                .disabled(removing)
                            Spacer()
                            Button("Edit…") { router.showingCarSheet = true }
                                .disabled(removing)
                        }
                    } footer: {
                        Text("Only one car is supported for now.")
                    }

                    if let error = store.loadError ?? removeError {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView {
                    Label("No Car Yet", systemImage: "car")
                } description: {
                    if let error = store.loadError ?? removeError {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Add your car to see its battery and status.")
                    }
                } actions: {
                    Button("Add Car…") { router.showingCarSheet = true }
                        .buttonStyle(.borderedProminent)
                    if store.loadError != nil {
                        Button("Try Again") { Task { await store.reload() } }
                    }
                    if store.loadError != nil || store.saved != Credentials() {
                        Button("Remove Saved Data…", role: .destructive) { confirmingRemove = true }
                            .disabled(removing)
                    }
                }
            }
        }
        .onChange(of: router.showingCarSheet) { removeError = nil }
        .navigationTitle("Cars")
        .toolbar {
            ToolbarItem {
                Button("Add Car", systemImage: "plus") { router.showingCarSheet = true }
                    .disabled(store.saved.isComplete)
                    .help(store.saved.isComplete ? "Only one car is supported for now" : "Add Car")
            }
        }
        .sheet(isPresented: $router.showingCarSheet) { CarSheet() }
        .confirmationDialog("Remove your car and API key?", isPresented: $confirmingRemove) {
            Button("Remove Car", role: .destructive, action: remove)
        }
    }

    private func remove() {
        guard !removing else { return }
        Task {
            removing = true
            removeError = nil
            defer { removing = false }
            removeError = await store.reset()
            // Even a failed reset removes the VIN, so the old vehicle's data must go either way.
            VehicleModel.shared.clear()
        }
    }
}

/// Adds the car, or edits it when one is already saved.
private struct CarSheet: View {
    @Environment(\.dismiss) private var dismiss
    private let store = CredentialsStore.shared
    @State private var credentials = Credentials()
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var testTask: Task<Void, Never>?
    @State private var showKey = false

    private var isEditing: Bool { store.saved.isComplete }

    private var vinHint: String? {
        let vin = credentials.normalized.vin
        return vin.isEmpty || Credentials.isValidVIN(vin) ? nil : "VIN must be 17 letters or digits"
    }

    private var canSave: Bool {
        let normalized = credentials.normalized
        return !busy && store.loadError == nil && Credentials.isValidVIN(normalized.vin)
            && !normalized.apiKey.isEmpty && normalized != store.saved
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent("VIN") {
                        TextField("VIN", text: $credentials.vin, prompt: Text("TMBxxxxxxxxxxxxxx"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    if let vinHint {
                        Text(vinHint).foregroundStyle(.red)
                    } else {
                        Text("In the MyŠkoda app under vehicle details, or on your registration document.")
                    }
                }

                Section {
                    HStack {
                        Text("API key")
                        Spacer()
                        // Both fields stay in the hierarchy so toggling doesn't change the sheet's size mid-layout.
                        ZStack {
                            TextField("API key", text: $credentials.apiKey, prompt: Text("Paste your API key"))
                                .opacity(showKey ? 1 : 0)
                                .disabled(!showKey)
                            SecureField("API key", text: $credentials.apiKey, prompt: Text("Paste your API key"))
                                .opacity(showKey ? 0 : 1)
                                .disabled(showKey)
                        }
                        .labelsHidden()
                        .font(.callout.monospaced())
                        .multilineTextAlignment(.trailing)
                        .lineLimit(1)
                        .autocorrectionDisabled()

                        Button(showKey ? "Hide" : "Show") { showKey.toggle() }
                            .controlSize(.small)
                    }
                } footer: {
                    Text("In the MyŠkoda app under Profile / Smart Home. This key will be saved in your Keychain.")
                }

                if let error = store.loadError {
                    Section { Text(error).foregroundStyle(.red) }
                } else if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel") {
                    testTask?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(action: testConnection) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(isEditing ? "Test & Save" : "Test & Add")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { credentials = store.saved }
        .onDisappear { testTask?.cancel() }
        .onChange(of: credentials.vin) { _, new in
            if new.count > 17 { credentials.vin = String(new.prefix(17)) }
        }
        .onChange(of: credentials) { errorMessage = nil }
        .onChange(of: store.saved) { old, new in
            if credentials == old { credentials = new }
        }
    }

    private func testConnection() {
        let normalized = credentials.normalized
        testTask = Task {
            busy = true
            errorMessage = nil
            defer { busy = false }
            let fetched: SkodaAPI.Vehicle
            do {
                fetched = try await SkodaAPI.fetchVehicle(vin: normalized.vin, apiKey: normalized.apiKey)
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
                return
            }
            guard !Task.isCancelled else { return }
            let sameVehicle = store.saved.vin == normalized.vin
            if let error = await store.save(normalized) {
                errorMessage = error
            } else {
                credentials = store.saved
                VehicleModel.shared.switchCredentials(adopting: fetched, keepingParkingPosition: sameVehicle)
                dismiss()
            }
        }
    }
}
