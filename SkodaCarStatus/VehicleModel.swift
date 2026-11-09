import Foundation
import Observation

@MainActor @Observable
final class VehicleModel {
    static let shared = VehicleModel()

    /// With 20 requests/hour per VIN, neither opening the popover nor the background poll may refetch more often than this.
    private static let refreshInterval: TimeInterval = 900

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
    var licensePlate: String? { vehicle?.licensePlate }
    var renderURL: URL? { vehicle?.renderURL }
    var odometerKm: Int? { vehicle?.odometerKm }
    /// The current state, so it says whether the car is driving right now.
    var parkingState: SkodaAPI.ParkingState? { vehicle?.parkingState }
    var keyExpiresAt: Date? { vehicle?.keyExpiresAt }
    /// Set while the API asked us to wait; the view shows a live countdown to it.
    private(set) var retryNotBefore: Date?

    private var lastAttempt: Date?
    /// Bumped whenever the credentials change, so a response for the old credentials is discarded.
    private var generation = 0

    private init() {}

    /// Seconds until the next background poll: `refreshInterval` after the last attempt, or later if the API asked us to wait.
    func nextPollDelay() -> TimeInterval {
        var due = (lastAttempt ?? Date()).addingTimeInterval(Self.refreshInterval)
        if let retryNotBefore { due = max(due, retryNotBefore) }
        return max(due.timeIntervalSinceNow, 1)
    }

    func refreshIfStale() async {
        if let retryNotBefore, retryNotBefore > Date() { return }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.refreshInterval { return }
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
        if !store.isLoaded { await store.reload() }
        guard generation == self.generation else { return }
        let credentials = store.saved
        guard credentials.isComplete else { return wipe() }

        if let retryNotBefore, retryNotBefore > Date() { return }

        do {
            let fetched = try await SkodaAPI.fetchVehicle(vin: credentials.vin, apiKey: credentials.apiKey)
            guard generation == self.generation else { return }
            vehicle = fetched
            if let position = fetched.parkingPosition { parkingPosition = position }
            error = nil
            lastUpdated = Date()
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
    }
}
