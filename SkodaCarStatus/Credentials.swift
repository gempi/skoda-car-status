import Foundation

/// One vehicle's settings. The VIN is plain configuration and the API key is a secret; they are stored independently.
/// Each vehicle has its own key, since vehicles can belong to different Škoda accounts.
struct Credentials: Equatable, Sendable, Identifiable {
    private static let listKey = "vehicles"
    /// VINs of removed vehicles whose API key couldn't be deleted yet.
    private static let pendingDeletionsKey = "vinsWithKeyToDelete"

    var vin = ""
    var apiKey = ""

    var id: String { vin }

    static func isValidVIN(_ vin: String) -> Bool {
        vin.count == 17 && vin.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    var normalized: Credentials {
        Credentials(
            vin: vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// All saved vehicles in the order they were added. The list itself always loads; a vehicle whose key
    /// the Keychain couldn't give comes back without one, and `errors` says why, by VIN.
    @concurrent
    static func loadAll() async -> (vehicles: [Credentials], errors: [String: String]) {
        var vehicles = (UserDefaults.standard.stringArray(forKey: listKey) ?? []).map { Credentials(vin: $0) }
        var errors: [String: String] = [:]

        // What couldn't be deleted when its vehicle was removed is tried again; what still fails waits for the next load.
        deleteKeys()

        for index in vehicles.indices {
            do {
                vehicles[index].apiKey = try Keychain.get(.apiKey(vin: vehicles[index].vin)) ?? ""
            } catch {
                errors[vehicles[index].vin] = error.localizedDescription
            }
        }
        return (vehicles, errors)
    }

    static func saveList(_ vehicles: [Credentials]) {
        UserDefaults.standard.set(vehicles.isEmpty ? nil : vehicles.map(\.vin), forKey: listKey)
    }

    /// Stops at the first key that fails.
    @concurrent
    static func saveKeys(of vehicles: [Credentials]) async throws {
        for vehicle in vehicles {
            try Keychain.set(vehicle.apiKey, for: .apiKey(vin: vehicle.vin))
            // A vehicle that is added again mustn't lose its new key to a delete still waiting from when it was removed.
            // Only once the key is saved: if that fails, the old key is still there and still has to go.
            setPendingDeletions(pendingDeletions.filter { $0 != vehicle.vin })
        }
    }

    @concurrent
    static func deleteKey(vin: String) async throws {
        // Only its own key: another vehicle's that fails again isn't this removal's failure.
        if let failure = deleteKeys(adding: vin)[vin] { throw failure }
    }

    private static var pendingDeletions: [String] {
        UserDefaults.standard.stringArray(forKey: pendingDeletionsKey) ?? []
    }

    private static func setPendingDeletions(_ vins: [String]) {
        UserDefaults.standard.set(vins.isEmpty ? nil : vins, forKey: pendingDeletionsKey)
    }

    /// Deletes the key of `vin` and whatever earlier calls couldn't delete; what fails now is kept for the next call,
    /// which every load makes, so no key stays in the Keychain for good. Tries all of them and returns the failures, by VIN.
    @discardableResult
    private static func deleteKeys(adding vin: String? = nil) -> [String: any Error] {
        var pending = pendingDeletions
        if let vin, !pending.contains(vin) {
            pending.append(vin)
            // Recorded before the Keychain is asked: it can block on a prompt, and the app may quit meanwhile.
            setPendingDeletions(pending)
        }
        var failures: [String: any Error] = [:]
        pending.removeAll { vin in
            do {
                try Keychain.delete(.apiKey(vin: vin))
                return true
            } catch {
                failures[vin] = error
                return false
            }
        }
        setPendingDeletions(pending)
        return failures
    }
}
