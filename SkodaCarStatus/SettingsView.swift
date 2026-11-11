import ServiceManagement
import SwiftUI

enum SettingsPane: Hashable {
    case general
    /// One vehicle's pane, by VIN.
    case vehicle(String)
}

/// Lets other views (the popover's "Add Vehicle") choose the pane the settings window shows.
@MainActor @Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selection: SettingsPane? = .general {
        didSet { record() }
    }
    var showingVehicleSheet = false
    /// Shown as an alert, since the pane of a removed vehicle is gone.
    var removeError: String?
    /// VINs of vehicles being removed: already gone from the sidebar, so they can't be opened again meanwhile.
    var removing: Set<String> = []

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

    /// Call when `pane`'s vehicle is removed: starts the history over, so it can't lead back to the pane,
    /// and shows `replacement` if the pane is still the one on screen.
    func replace(_ pane: SettingsPane, with replacement: SettingsPane) {
        let current = selection == pane ? replacement : selection ?? .general
        isNavigating = true
        history = [current]
        position = 0
        selection = current
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
    private let store = CredentialsStore.shared

    var body: some View {
        NavigationSplitView {
            List(selection: $router.selection) {
                SidebarRow(title: "General", symbol: "gearshape.fill", color: .gray)
                    .tag(SettingsPane.general)

                Section("Vehicles") {
                    ForEach(store.vehicles.filter { !router.removing.contains($0.vin) }) { vehicle in
                        SidebarRow(title: VehicleModel.model(for: vehicle.vin).displayName, symbol: "car.fill", color: .blue)
                            .tag(SettingsPane.vehicle(vehicle.vin))
                    }

                    Button { router.showingVehicleSheet = true } label: {
                        Label("Add Vehicle…", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            // A pane whose vehicle is gone falls back to General.
            if case .vehicle(let vin) = router.selection, let vehicle = store.vehicle(for: vin) {
                VehiclePane(vehicle: vehicle).id(vin)
            } else {
                GeneralPane()
            }
        }
        .sheet(isPresented: $router.showingVehicleSheet) { VehicleSheet() }
        .alert("Couldn't delete the API key from your Keychain", isPresented: Binding(
            get: { router.removeError != nil }, set: { if !$0 { router.removeError = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(router.removeError ?? "")
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
        .task { await store.reload() }
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

private struct VehiclePane: View {
    let vehicle: Credentials
    private let store = CredentialsStore.shared
    @State private var editing = false
    @State private var confirmingRemove = false
    @State private var removing = false

    private var model: VehicleModel { .model(for: vehicle.vin) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Name", value: model.vehicleName ?? "–")
                if let plate = model.licensePlate {
                    LabeledContent("Licence plate", value: plate)
                }
                LabeledContent("VIN", value: vehicle.vin)
                HStack {
                    Button("Remove…", role: .destructive) { confirmingRemove = true }
                        .disabled(removing)
                    Spacer()
                    Button("Edit…") { editing = true }
                        .disabled(removing)
                }
            }

            if let error = store.loadErrors[vehicle.vin] {
                Section {
                    Text(error).foregroundStyle(.red)
                    Button("Try Again") { Task { await store.reload() } }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(model.displayName)
        .sheet(isPresented: $editing) { VehicleSheet(editing: vehicle) }
        .confirmationDialog("Remove \(model.displayName) and its API key?", isPresented: $confirmingRemove) {
            Button("Remove Vehicle", role: .destructive, action: remove)
        }
    }

    private func remove() {
        guard !removing else { return }
        removing = true
        let vin = vehicle.vin
        let router = SettingsRouter.shared
        // Before the vehicle is gone, so the window doesn't sit on a pane that no longer exists while the Keychain is busy.
        router.replace(.vehicle(vin), with: store.neighbour(of: vin, excluding: router.removing).map(SettingsPane.vehicle) ?? .general)
        router.removing.insert(vin)
        Task {
            // Only a failure is recorded, so removing another vehicle meanwhile can't hide it.
            if let error = await store.remove(vin: vin) { router.removeError = error }
            VehicleModel.forget(vin)
            router.removing.remove(vin)
        }
    }
}

/// Adds a vehicle, or changes the API key of `editing` when given. The VIN identifies a vehicle, so it can't be edited.
private struct VehicleSheet: View {
    var editing: Credentials?

    @Environment(\.dismiss) private var dismiss
    private let store = CredentialsStore.shared
    @State private var credentials = Credentials()
    /// The key a new vehicle's field starts with: the selected vehicle's, since most vehicles share one account.
    @State private var prefilledKey = ""
    @State private var prefilledFrom = ""
    @State private var applyKeyToOthers = true
    @State private var errorMessage: String?
    @State private var busy = false
    /// Set once the vehicle is saved; the sheet is still on screen while it closes.
    @State private var saved = false
    @State private var testTask: Task<Void, Never>?
    @State private var showKey = false

    /// Not while saving or after it, when the vehicle found in the store is the one this sheet has just added.
    private var isDuplicate: Bool {
        editing == nil && !busy && !saved && store.vehicle(for: credentials.normalized.vin) != nil
    }

    private var vinHint: String? {
        let vin = credentials.normalized.vin
        if isDuplicate { return "This vehicle has already been added" }
        return vin.isEmpty || Credentials.isValidVIN(vin) ? nil : "VIN must be 17 letters or digits"
    }

    private var keyChanged: Bool { credentials.normalized.apiKey != editing?.apiKey }

    /// The other vehicles saved with the key this one had: replacing a key in MyŠkoda breaks all of them.
    private var othersWithOldKey: [Credentials] {
        guard let editing, !editing.apiKey.isEmpty, keyChanged else { return [] }
        return store.vehicles.filter { $0.vin != editing.vin && $0.apiKey == editing.apiKey }
    }

    private var canSave: Bool {
        let normalized = credentials.normalized
        guard !busy, store.isLoaded, !normalized.apiKey.isEmpty else { return false }
        if let editing { return normalized != editing }
        return Credentials.isValidVIN(normalized.vin) && !isDuplicate
    }

    private var keyFooter: String {
        if !prefilledKey.isEmpty, credentials.apiKey == prefilledKey {
            return "Same key as \(prefilledFrom). Replace it if this vehicle is in another Škoda account."
        }
        return "In the MyŠkoda app under Profile / Smart Home. This key will be saved in your Keychain."
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if let editing {
                        LabeledContent("VIN", value: editing.vin)
                    } else {
                        LabeledContent("VIN") {
                            TextField("VIN", text: $credentials.vin, prompt: Text("TMBxxxxxxxxxxxxxx"))
                                .labelsHidden()
                                .font(.body.monospaced())
                                .multilineTextAlignment(.trailing)
                                .autocorrectionDisabled()
                        }
                    }
                } footer: {
                    if let vinHint {
                        Text(vinHint).foregroundStyle(.red)
                    } else if editing == nil {
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

                    let others = othersWithOldKey
                    if !others.isEmpty {
                        Toggle("Also use for ^[\(others.count) other vehicle](inflect: true) with the old key",
                               isOn: $applyKeyToOthers)
                    }
                } footer: {
                    Text(keyFooter)
                }

                if let errorMessage {
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
                Button(action: save) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(editing == nil ? "Test & Add" : "Test & Save")
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
        .onAppear {
            prefilledKey = editing == nil ? store.selected?.apiKey ?? "" : ""
            prefilledFrom = VehicleModel.selected?.displayName ?? ""
            credentials = editing ?? Credentials(apiKey: prefilledKey)
        }
        .onDisappear { testTask?.cancel() }
        .onChange(of: credentials.vin) { _, new in
            // Trimmed first, so whitespace pasted along with a VIN doesn't push its last characters out.
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.count > 17 { credentials.vin = String(trimmed.prefix(17)) }
        }
        .onChange(of: credentials) { errorMessage = nil }
    }

    private func save() {
        let normalized = credentials.normalized
        let others = applyKeyToOthers ? othersWithOldKey.map(\.vin) : []
        guard !busy else { return }
        // Claimed before the task starts, so a second trigger can't start another.
        busy = true
        testTask = Task {
            errorMessage = nil
            defer { busy = false }
            // The key replaces the other vehicles' too, so it is tested with each of them, not just this one.
            typealias Outcome = Result<SkodaAPI.Vehicle, any Error>
            let vins = [normalized.vin] + others
            let outcomes = await withTaskGroup(of: (String, Outcome).self) { group in
                for vin in vins {
                    group.addTask {
                        do {
                            return (vin, .success(try await SkodaAPI.fetchVehicle(vin: vin, apiKey: normalized.apiKey)))
                        } catch {
                            return (vin, .failure(error))
                        }
                    }
                }
                var outcomes: [String: Outcome] = [:]
                for await (vin, outcome) in group { outcomes[vin] = outcome }
                return outcomes
            }
            guard !Task.isCancelled else { return }
            var fetched: [String: SkodaAPI.Vehicle] = [:]
            // This vehicle first, so its own failure is the one shown.
            for vin in vins {
                switch outcomes[vin] {
                case .success(let vehicle)?:
                    fetched[vin] = vehicle
                case .failure(let error)?:
                    errorMessage = vin == normalized.vin
                        ? error.localizedDescription
                        : "The key doesn't work for \(VehicleModel.model(for: vin).displayName): \(error.localizedDescription)"
                    return
                case nil:
                    return
                }
            }
            let error = await store.save(normalized, alsoApplyingKeyTo: others)
            // Before the error is handled: a save that failed part-way has still given some vehicles the new key.
            for (vin, vehicle) in fetched where store.vehicle(for: vin)?.apiKey == normalized.apiKey {
                VehicleModel.model(for: vin).switchCredentials(adopting: vehicle, keepingParkingPosition: editing != nil)
            }
            if let error {
                errorMessage = error
                return
            }
            // Cancelled too late to stop the save: the vehicle is added, but nothing switches to it.
            if editing == nil, !Task.isCancelled {
                store.select(normalized.vin)
                SettingsRouter.shared.selection = .vehicle(normalized.vin)
            }
            saved = true
            dismiss()
        }
    }
}
