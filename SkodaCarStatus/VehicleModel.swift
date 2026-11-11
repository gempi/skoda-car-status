import Foundation
import Observation

@MainActor @Observable
final class VehicleModel {
    private static var models: [String: VehicleModel] = [:]

    /// Each vehicle has its own model, so switching between vehicles shows cached data.
    static func model(for vin: String) -> VehicleModel {
        if let model = models[vin] { return model }
        let model = VehicleModel(vin: vin)
        models[vin] = model
        return model
    }

    /// The model of the vehicle the popover and the menu bar show; `nil` only when there are no vehicles.
    static var selected: VehicleModel? { CredentialsStore.shared.selectedVIN.map(model(for:)) }

    /// Call when a vehicle is removed: drops its state and any request in flight.
    static func forget(_ vin: String) {
        models.removeValue(forKey: vin)?.clear()
    }

    /// The rate limit is per VIN, so every vehicle is polled, not just the selected one.
    static func refreshAllIfStale() async {
        let store = CredentialsStore.shared
        // Here, once for all vehicles, not in each one's refresh.
        await store.retryFailedKeys()
        await withDiscardingTaskGroup { group in
            for vehicle in store.vehicles {
                // Looked up now, not in the task, which could run after the vehicle was removed and bring its model back.
                let model = model(for: vehicle.vin)
                group.addTask { await model.refreshIfStale() }
            }
        }
    }

    /// Seconds until the first vehicle is due for its next background poll.
    static func nextPollDelay() -> TimeInterval {
        CredentialsStore.shared.vehicles.map { model(for: $0.vin).nextPollDelay() }.min() ?? refreshInterval
    }

    /// With 20 requests/hour per VIN, neither opening the popover nor the background poll may refetch more often than this.
    private static let refreshInterval: TimeInterval = 900

    let vin: String

    private(set) var vehicle: SkodaAPI.Vehicle?
    /// Unlike `vehicle.parkingPosition`, this survives fetches made while the car is driving, when the API omits it.
    private(set) var parkingPosition: SkodaAPI.Position?
    private(set) var error: String?
    private(set) var isLoading = false
    /// When the data was last fetched successfully.
    private(set) var lastUpdated: Date?
    var battery: SkodaAPI.Battery? { vehicle?.battery }
    var chargingIssue: SkodaAPI.ChargingIssue? { vehicle?.chargingIssue }
    var vehicleName: String? { vehicle?.name }
    /// The name from the API, or the end of the VIN until the vehicle has been fetched.
    var displayName: String {
        if let name = vehicleName, !name.isEmpty { return name }
        return String(vin.suffix(6))
    }
    var licensePlate: String? { vehicle?.licensePlate }
    var renderURL: URL? { vehicle?.renderURL }
    var odometerKm: Int? { vehicle?.odometerKm }
    /// The current state, so it says whether the car is driving right now.
    var parkingState: SkodaAPI.ParkingState? { vehicle?.parkingState }
    var keyExpiresAt: Date? { vehicle?.keyExpiresAt }
    /// Set while the API asked us to wait; the view shows a live countdown to it.
    private(set) var retryNotBefore: Date?

    private var lastAttempt: Date?
    private var missedKey = false
    /// Bumped whenever the credentials change, so a response for the old credentials is discarded.
    private var generation = 0

    private init(vin: String) {
        self.vin = vin
    }

    /// Seconds until the next background poll: `refreshInterval` after the last attempt, or later if the API asked us to wait.
    func nextPollDelay() -> TimeInterval {
        var due = (lastAttempt ?? Date()).addingTimeInterval(Self.refreshInterval)
        if let retryNotBefore { due = max(due, retryNotBefore) }
        return max(due.timeIntervalSinceNow, 1)
    }

    func refreshIfStale() async {
        if let retryNotBefore, retryNotBefore > Date() { return }
        // A refresh that found no API key requested nothing, so once there is a key the next one doesn't wait.
        let keyArrived = missedKey && CredentialsStore.shared.vehicle(for: vin)?.apiKey.isEmpty == false
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.refreshInterval, !keyArrived { return }
        await refresh()
    }

    func refresh() async {
        guard !isLoading else { return }
        // Claim the request before the first await so overlapping triggers can't start two.
        isLoading = true
        let generation = generation
        let previousAttempt = lastAttempt
        lastAttempt = Date()
        defer { if generation == self.generation { isLoading = false } }

        let store = CredentialsStore.shared
        await store.loadIfNeeded()
        guard generation == self.generation else { return }
        guard let credentials = store.vehicle(for: vin) else { return wipe() }
        guard !credentials.apiKey.isEmpty else {
            // The key may exist but be unreadable.
            error = store.loadErrors[vin].map { "Couldn't read this vehicle's API key: \($0)" } ?? "No API key saved for this vehicle."
            missedKey = true
            return
        }
        missedKey = false

        if let retryNotBefore, retryNotBefore > Date() { return }

        do {
            let fetched = try await SkodaAPI.fetchVehicle(vin: credentials.vin, apiKey: credentials.apiKey)
            guard generation == self.generation else { return }
            adopt(fetched)
        } catch is CancellationError {
            if generation == self.generation { lastAttempt = previousAttempt }
        } catch let failure as SkodaAPI.Failure {
            guard generation == self.generation else { return }
            error = failure.message
            retryNotBefore = failure.retryAfter.map { Date().addingTimeInterval($0) }
        } catch {
            guard generation == self.generation else { return }
            self.error = error.localizedDescription
        }
    }

    /// Call when the credentials change and `fetched` came from a request made with the new ones (the settings connection test),
    /// so that request isn't repeated: drops all old state, then starts from the response.
    /// For the same vehicle the last parking position is kept, since the response omits it while the car is driving.
    func switchCredentials(adopting fetched: SkodaAPI.Vehicle, keepingParkingPosition: Bool) {
        let position = keepingParkingPosition ? parkingPosition : nil
        clear()
        lastAttempt = Date()
        adopt(fetched)
        if parkingPosition == nil { parkingPosition = position }
    }

    private func adopt(_ fetched: SkodaAPI.Vehicle) {
        vehicle = fetched
        if let position = fetched.parkingPosition { parkingPosition = position }
        error = nil
        lastUpdated = Date()
    }

    /// Call when the credentials change or are removed: drops all state, including rate-limit backoff, and any request in flight.
    func clear() {
        generation += 1
        isLoading = false
        wipe()
    }

    private func wipe() {
        vehicle = nil
        parkingPosition = nil
        error = nil
        lastUpdated = nil
        lastAttempt = nil
        retryNotBefore = nil
        missedKey = false
    }
}
