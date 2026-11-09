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

    static func load() throws -> Credentials {
        Credentials(
            vin: UserDefaults.standard.string(forKey: vinKey) ?? "",
            apiKey: try Keychain.get(.apiKey) ?? ""
        )
    }

    func save() throws {
        UserDefaults.standard.set(vin.isEmpty ? nil : vin, forKey: Self.vinKey)
        try Keychain.set(apiKey, for: .apiKey)
    }

    static func reset() throws {
        UserDefaults.standard.removeObject(forKey: vinKey)
        try Keychain.delete(.apiKey)
    }
}
