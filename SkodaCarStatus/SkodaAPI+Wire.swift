import Foundation

/// The spec lists the allowed values in field descriptions and says new ones may appear, so every enum has an `unknown` fallback.
protocol TolerantEnum: RawRepresentable, Decodable, Sendable where RawValue == String {
    static var unknown: Self { get }
}

extension TolerantEnum {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? .unknown
    }
}

extension SkodaAPI {
    /// Only the charging entries of `VehicleError.type` matter here.
    enum VehicleErrorType: String, TolerantEnum {
        case chargingUnsupported = "CHARGING_UNSUPPORTED"
        case chargingDisabled = "CHARGING_DISABLED"
        case chargingUnavailable = "CHARGING_UNAVAILABLE"
        case unknown

        var chargingIssue: ChargingIssue? {
            switch self {
            case .chargingUnsupported: .unsupported
            case .chargingDisabled: .disabled
            case .chargingUnavailable: .unavailable
            case .unknown: nil
            }
        }
    }

    enum ChargeState: String, TolerantEnum {
        case connectCable = "CONNECT_CABLE"
        case charging = "CHARGING"
        case conserving = "CONSERVING"
        case readyForCharging = "READY_FOR_CHARGING"
        case discharging = "DISCHARGING"
        case chargingInterrupted = "CHARGING_INTERRUPTED"
        case unknown
    }

    enum PlugConnectionState: String, TolerantEnum {
        case connected = "CONNECTED", disconnected = "DISCONNECTED"
        case unknown
    }

    enum PlugLockState: String, TolerantEnum {
        case locked = "LOCKED", unlocked = "UNLOCKED"
        case unknown
    }

    struct VehicleResponse: Decodable {
        var vehicle: Vehicle?
        var errors: [VehicleError]?

        struct VehicleError: Decodable {
            var type: VehicleErrorType
        }

        struct Vehicle: Decodable {
            var name: String?
            var licensePlate: String?
            var renderUrl: String?
            var charging: Charging?
            var status: Status?
            var odometer: Odometer?
            var parkingPosition: ParkingPosition?
        }

        /// Absent while the car is driving.
        struct ParkingPosition: Decodable {
            var gpsCoordinates: Coordinates?
            var state: ParkingState?

            struct Coordinates: Decodable {
                var latitude: Double?
                var longitude: Double?
            }
        }

        struct Odometer: Decodable {
            var mileageInKm: Int?
            var carCapturedTimestamp: Date?

            private enum CodingKeys: String, CodingKey {
                case mileageInKm, carCapturedTimestamp
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                mileageInKm = try container.decodeIfPresent(Int.self, forKey: .mileageInKm)
                carCapturedTimestamp = container.decodeLenientDate(forKey: .carCapturedTimestamp)
            }
        }

        struct Status: Decodable {
            var overall: Overall?
            var carCapturedTimestamp: Date?

            private enum CodingKeys: String, CodingKey {
                case overall, carCapturedTimestamp
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                overall = try container.decodeIfPresent(Overall.self, forKey: .overall)
                carCapturedTimestamp = container.decodeLenientDate(forKey: .carCapturedTimestamp)
            }

            struct Overall: Decodable {
                var locked: LockState?
            }
        }

        struct Charging: Decodable {
            var status: Status?
            var carCapturedTimestamp: Date?

            private enum CodingKeys: String, CodingKey {
                case status, carCapturedTimestamp
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                status = try container.decodeIfPresent(Status.self, forKey: .status)
                carCapturedTimestamp = container.decodeLenientDate(forKey: .carCapturedTimestamp)
            }

            struct Status: Decodable {
                var state: ChargeState?
                var plugConnectionState: PlugConnectionState?
                var plugLockState: PlugLockState?
                var chargePowerInKw: Double?
                var battery: Battery?

                struct Battery: Decodable {
                    var stateOfChargeInPercent: Int?
                    var remainingCruisingRangeInMeters: Int?
                }
            }
        }
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: string))
            }
            return date
        }
        return decoder
    }()

    private static let isoWithFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let iso = Date.ISO8601FormatStyle()

    /// Accepts ISO 8601 with or without fractional seconds. The spec's own example (`2021-06-01T12:00Z`) has no seconds at all,
    /// which the standard styles reject, so those get `:00` added first.
    static func parseDate(_ string: String) -> Date? {
        let normalized = string.replacing(/T(\d{2}:\d{2})(?=Z|[+-]\d{2}:\d{2}$)/) { "T\($0.1):00" }
        return (try? isoWithFractionalSeconds.parse(normalized)) ?? (try? iso.parse(normalized))
    }
}

private extension KeyedDecodingContainer {
    /// A malformed timestamp must not hide the valid values next to it.
    func decodeLenientDate(forKey key: Key) -> Date? {
        (try? decodeIfPresent(Date.self, forKey: key)) ?? nil
    }
}

extension SkodaAPI.Vehicle {
    init(_ response: SkodaAPI.VehicleResponse, keyExpiresAt: Date?) {
        let vehicle = response.vehicle
        let timestamps = [vehicle?.charging?.carCapturedTimestamp,
                          vehicle?.status?.carCapturedTimestamp,
                          vehicle?.odometer?.carCapturedTimestamp].compactMap { $0 }
        self.init(
            name: vehicle?.name,
            licensePlate: vehicle?.licensePlate,
            renderURL: vehicle?.renderUrl.flatMap(URL.init(string:)).flatMap(Self.safeRenderURL),
            odometerKm: vehicle?.odometer?.mileageInKm,
            battery: vehicle?.charging.map(SkodaAPI.Battery.init),
            chargingIssue: response.errors?.lazy.compactMap(\.type.chargingIssue).first,
            locks: vehicle?.status?.overall?.locked ?? .unknown,
            parkingPosition: vehicle?.parkingPosition?.gpsCoordinates.flatMap(SkodaAPI.Position.init),
            parkingState: vehicle?.parkingPosition?.state,
            capturedAt: timestamps.max(),
            keyExpiresAt: keyExpiresAt
        )
    }

    /// Only https render URLs are loaded.
    private static func safeRenderURL(_ url: URL) -> URL? {
        url.scheme == "https" ? url : nil
    }
}

private extension SkodaAPI.Battery {
    init(_ charging: SkodaAPI.VehicleResponse.Charging) {
        let status = charging.status
        self.init(
            percent: status?.battery?.stateOfChargeInPercent,
            rangeKm: status?.battery?.remainingCruisingRangeInMeters.map { Int((Double($0) / 1000).rounded()) },
            chargingState: Self.chargingState(state: status?.state, plug: status?.plugConnectionState),
            chargePowerKw: status?.chargePowerInKw,
            plugConnected: status?.plugConnectionState.flatMap { $0 == .unknown ? nil : $0 == .connected },
            plugLocked: status?.plugLockState.flatMap { $0 == .unknown ? nil : $0 == .locked }
        )
    }

    /// An omitted `state` is unknown, never a specific state (the spec says it happens in everyday situations, e.g. plugged in
    /// without a charging process), so only the plug state is read. `chargeType` is not used: it doesn't say charging is running.
    static func chargingState(
        state: SkodaAPI.ChargeState?,
        plug: SkodaAPI.PlugConnectionState?
    ) -> SkodaAPI.ChargingState {
        switch state {
        case .charging: return .charging
        case .conserving: return .conserving
        case .readyForCharging: return .readyToCharge
        case .chargingInterrupted: return .interrupted
        case .discharging: return .discharging
        case .connectCable: return .notPlugged
        case .unknown: return .unknown
        case nil:
            switch plug {
            case .connected: return .plugged
            case .disconnected: return .notPlugged
            case .unknown, nil: return .unknown
            }
        }
    }
}

private extension SkodaAPI.Position {
    init?(_ coordinates: SkodaAPI.VehicleResponse.ParkingPosition.Coordinates) {
        guard let latitude = coordinates.latitude, let longitude = coordinates.longitude,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        self.init(latitude: latitude, longitude: longitude)
    }
}
