import Observation

/// Single source of truth for the saved credentials. Keychain access runs off the main actor.
@MainActor @Observable
final class CredentialsStore {
    static let shared = CredentialsStore()

    private(set) var saved = Credentials()
    private(set) var loadError: String?
    private(set) var isLoaded = false

    var needsSetup: Bool { isLoaded && loadError == nil && !saved.isComplete }

    private init() {
        Task { await reload() }
    }

    func reload() async {
        do {
            saved = try await Task.detached { try Credentials.load() }.value
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }

    /// Returns an error message, or `nil` on success. After a failure `saved` reflects what actually got stored.
    func save(_ credentials: Credentials) async -> String? {
        let credentials = credentials.normalized
        do {
            try await Task.detached { try credentials.save() }.value
            saved = credentials
            return nil
        } catch {
            await reload()
            return error.localizedDescription
        }
    }

    func reset() async -> String? {
        do {
            try await Task.detached { try Credentials.reset() }.value
            saved = Credentials()
            return nil
        } catch {
            await reload()
            return error.localizedDescription
        }
    }
}
