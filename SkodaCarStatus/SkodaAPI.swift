import Foundation

/// Client for the MyŠkoda Public API (https://public.api.connect.skoda-auto.cz/docs).
enum SkodaAPI {
    static let apiKeyHeader = "X-API-Key"

    static let baseURL = URL(string: "https://public.api.connect.skoda-auto.cz")!

    enum ChargingState: Equatable, Sendable {
        case charging, conserving, readyToCharge, interrupted, discharging
        case plugged, notPlugged
        case unknown
    }

    struct Battery: Equatable, Sendable {
        var percent: Int?
        var rangeKm: Int?
        var chargingState: ChargingState
        var chargePowerKw: Double?
        var plugConnected: Bool?
        var plugLocked: Bool?
    }

    /// Raw values are the API's `status.overall.locked` (`YES`/`NO`).
    enum LockState: String, Equatable, TolerantEnum {
        case locked = "YES", unlocked = "NO"
        case unknown
    }

    enum ParkingState: String, Equatable, TolerantEnum {
        case parked = "PARKED", inMotion = "IN_MOTION"
        case unknown
    }

    /// Why the response has no charging part, from the `CHARGING_*` entries of its `errors` list.
    enum ChargingIssue: Sendable {
        case unsupported, disabled, unavailable
    }

    struct Position: Hashable, Sendable {
        var latitude: Double
        var longitude: Double
    }

    /// Everything one vehicle request returns. A part the API left out is nil (`locks` is `.unknown`).
    struct Vehicle: Sendable {
        var name: String?
        var licensePlate: String?
        var renderURL: URL?
        var odometerKm: Int?
        var battery: Battery?
        var chargingIssue: ChargingIssue?
        var locks: LockState = .unknown
        var parkingPosition: Position?
        var parkingState: ParkingState?
        /// The API has no overall timestamp, only one per section, so this is the newest of them.
        var capturedAt: Date?
        var keyExpiresAt: Date?
    }

    struct Failure: LocalizedError, Sendable {
        var message: String
        var retryAfter: TimeInterval?
        var errorDescription: String? { message }
    }

    static func fetchVehicle(vin: String, apiKey: String) async throws -> Vehicle {
        let (data, http) = try await send(vin: vin, apiKey: apiKey)
        guard let decoded = try? decoder.decode(VehicleResponse.self, from: data) else {
            throw Failure(message: "Couldn't read the vehicle data.")
        }
        let expiry = http.value(forHTTPHeaderField: "X-API-Key-Expires-At").flatMap(parseDate)
        return Vehicle(decoded, keyExpiresAt: expiry)
    }

    private static func send(vin: String, apiKey: String) async throws -> (Data, HTTPURLResponse) {
        guard Credentials.isValidVIN(vin) else { throw Failure(message: "Invalid VIN.") }
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/vehicles/\(vin)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "include", value: "info,charging,status,odometer,parkingPosition")]
        guard let url = components?.url else { throw Failure(message: "Invalid API address.") }

        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(apiKey, forHTTPHeaderField: apiKeyHeader)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw Failure(message: "Can't reach the Škoda service.")
        }
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "Unexpected response.")
        }
        guard http.statusCode == 200 else { throw failure(for: http, body: data) }
        return (data, http)
    }
}
