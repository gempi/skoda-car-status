import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    private let store = CredentialsStore.shared
    @State private var credentials = Credentials()
    @State private var errorMessage: String?
    @State private var busy = false
    @State private var testTask: Task<Void, Never>?
    @State private var confirmingReset = false
    @State private var showKey = false
    @AppStorage(AppInfo.showBatteryInMenuBarKey) private var showBatteryInMenuBar = false

    private var vinHint: String? {
        let vin = credentials.normalized.vin
        return vin.isEmpty || Credentials.isValidVIN(vin) ? nil : "VIN must be 17 letters or digits"
    }

    private var canTest: Bool {
        let normalized = credentials.normalized
        return !busy && store.loadError == nil && Credentials.isValidVIN(normalized.vin) && !normalized.apiKey.isEmpty
    }

    private var canReset: Bool {
        !busy && (store.loadError != nil || store.saved != Credentials())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Text("\(AppInfo.name) reads your car’s data through the official Škoda Connect API. You need the car’s VIN and an API key.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("VIN") {
                        TextField("VIN", text: $credentials.vin, prompt: Text("TMBxxxxxxxxxxxxxx"))
                            .labelsHidden()
                            .font(.body.monospaced())
                            .multilineTextAlignment(.trailing)
                            .textContentType(.none)
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
                    LabeledContent("API key") {
                        Group {
                            if showKey {
                                TextField("API key", text: $credentials.apiKey, prompt: Text("Paste your API key"))
                            } else {
                                SecureField("API key", text: $credentials.apiKey, prompt: Text("Paste your API key"))
                            }
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

                Section {
                    Toggle("Show battery percentage in menu bar", isOn: $showBatteryInMenuBar)
                } footer: {
                    Text("Displays the charge level next to the icon.")
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
                Button("Reset", role: .destructive) { confirmingReset = true }
                    .disabled(!canReset)
                Spacer()
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(action: testConnection) {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Test connection")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canTest)
            }
            .controlSize(.large)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Remove your vehicle and API key?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive, action: reset)
        }
        .onAppear {
            credentials = store.saved
            Task { await store.reload() }
        }
        .onDisappear { testTask?.cancel() }
        .onChange(of: credentials.vin) { _, new in
            if new.count > 17 { credentials.vin = String(new.prefix(17)) }
        }
        .onChange(of: credentials) { errorMessage = nil }
        .onChange(of: store.saved) { old, new in
            if credentials == old { credentials = new }
        }
    }

    private func cancel() {
        testTask?.cancel()
        dismiss()
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

    private func reset() {
        Task {
            busy = true
            defer { busy = false }
            let error = await store.reset()
            // Even a failed reset removes the VIN, so the old vehicle's data must go either way.
            VehicleModel.shared.clear()
            if let error {
                errorMessage = error
            } else {
                credentials = store.saved
                errorMessage = nil
            }
        }
    }
}
