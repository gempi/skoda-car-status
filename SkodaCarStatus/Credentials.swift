import Foundation

/// The VIN is plain configuration and the API key is a secret; they are stored and saved independently.
struct Credentials: Equatable, Sendable {
    private static let vinKey = "vin"

    var vin = ""
    var apiKey = ""

    static func isValidVIN(_ vin: String) -> Bool {
        vin.count == 17 && vin.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    var isComplete: Bool { !vin.isEmpty && !apiKey.isEmpty }

    var normalized: Credentials {
        Credentials(
            vin: vin.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @concurrent
    static func load() async throws -> Credentials {
        Credentials(
            vin: UserDefaults.standard.string(forKey: vinKey) ?? "",
            apiKey: try Keychain.get(.apiKey) ?? ""
        )
    }

    @concurrent
    func save() async throws {
        // The key first: if it fails, the old VIN stays and the pair isn't half-saved.
        try Keychain.set(apiKey, for: .apiKey)
        UserDefaults.standard.set(vin.isEmpty ? nil : vin, forKey: Self.vinKey)
    }

    @concurrent
    static func reset() async throws {
        // The VIN goes even if the Keychain fails, so a locked keychain can't make a reset impossible.
        defer { UserDefaults.standard.removeObject(forKey: vinKey) }
        try Keychain.delete(.apiKey)
    }
}
