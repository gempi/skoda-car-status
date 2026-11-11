import Foundation
import Observation

/// Single source of truth for the saved vehicles and which one is selected. Keychain access runs off the main actor.
@MainActor @Observable
final class CredentialsStore {
    static let shared = CredentialsStore()

    private static let selectedVINKey = "selectedVIN"

    /// In the order they were added.
    private(set) var vehicles: [Credentials] = []
    /// The vehicle the popover and the menu bar show; `nil` only when there are no vehicles.
    private(set) var selectedVIN: String?
    /// Why a vehicle's API key couldn't be read from the Keychain, by VIN.
    private(set) var loadErrors: [String: String] = [:]
    private(set) var isLoaded = false
    /// The last reload or list change. Each one waits for the one before it, so none works from a list another is about to replace.
    private var pending: Task<Void, Never>?

    var selected: Credentials? { vehicle(for: selectedVIN) }
    var needsSetup: Bool { isLoaded && vehicles.isEmpty }

    private init() {
        Task { await reload() }
    }

    func vehicle(for vin: String?) -> Credentials? {
        vehicles.first { $0.vin == vin }
    }

    func reload() async {
        await serially(reloading: true) {}
    }

    /// Waits for a load already under way instead of starting another. Loads again while a key couldn't be read,
    /// so a Keychain that was still locked at launch doesn't leave the vehicles without keys until the app restarts.
    func loadIfNeeded() async {
        await serially(reloading: !loadErrors.isEmpty) {}
    }

    /// The vehicle that takes `vin`'s place when it is removed: the next one, or the previous one if it is the last.
    /// `removed` are vehicles on their way out, which can't take its place.
    func neighbour(of vin: String, excluding removed: Set<String> = []) -> String? {
        let remaining = vehicles.map(\.vin).filter { $0 == vin || !removed.contains($0) }
        guard let index = remaining.firstIndex(of: vin), remaining.count > 1 else { return nil }
        return remaining[index == remaining.count - 1 ? index - 1 : index + 1]
    }

    private func load() async {
        let loaded = await Credentials.loadAll()
        vehicles = loaded.vehicles
        loadErrors = loaded.errors
        select(selectedVIN ?? UserDefaults.standard.string(forKey: Self.selectedVINKey))
        isLoaded = true
    }

    /// Every operation starts from the stored list: it is loaded first if it never was, or if `reloading`.
    /// Saving writes the whole list, so it must never be the empty one from before the first load.
    private func serially<Result: Sendable>(reloading: Bool = false, _ operation: @escaping () async -> Result) async -> Result {
        let previous = pending
        let task = Task {
            await previous?.value
            if reloading || !self.isLoaded { await self.load() }
            return await operation()
        }
        pending = Task { _ = await task.value }
        return await task.value
    }

    /// Falls back to the first vehicle when `vin` isn't a saved one.
    func select(_ vin: String?) {
        selectedVIN = vehicle(for: vin)?.vin ?? vehicles.first?.vin
        UserDefaults.standard.set(selectedVIN, forKey: Self.selectedVINKey)
    }

    /// Adds the vehicle, or replaces the saved one with the same VIN. `others` are VINs of vehicles that get the same API key.
    /// Returns an error message, or `nil` on success. After a failure `vehicles` reflects what actually got stored.
    func save(_ credentials: Credentials, alsoApplyingKeyTo others: [String] = []) async -> String? {
        let credentials = credentials.normalized
        return await serially {
            do {
                // The keys first: if one fails, the list isn't saved with a vehicle that has no key. This vehicle's key last:
                // if another one fails, this vehicle still has its old key and saving again repeats the whole change.
                try await Credentials.saveKeys(of: others.map { Credentials(vin: $0, apiKey: credentials.apiKey) } + [credentials])
                if self.vehicle(for: credentials.vin) == nil { self.vehicles.append(credentials) }
                for index in self.vehicles.indices
                where self.vehicles[index].vin == credentials.vin || others.contains(self.vehicles[index].vin) {
                    self.vehicles[index].apiKey = credentials.apiKey
                }
                Credentials.saveList(self.vehicles)
                self.select(self.selectedVIN)
                // Their keys are known now, whatever went wrong reading them.
                for vin in [credentials.vin] + others { self.loadErrors[vin] = nil }
                return nil
            } catch {
                await self.load()
                return error.localizedDescription
            }
        }
    }

    /// Returns an error message if the API key couldn't be deleted; the vehicle is removed either way,
    /// so a locked keychain can't make removing impossible, and the key is deleted by a later load.
    func remove(vin: String) async -> String? {
        await serially {
            let neighbour = self.neighbour(of: vin)
            self.vehicles.removeAll { $0.vin == vin }
            self.loadErrors[vin] = nil
            Credentials.saveList(self.vehicles)
            if self.selectedVIN == vin { self.select(neighbour) }
            do {
                try await Credentials.deleteKey(vin: vin)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
    }
}
