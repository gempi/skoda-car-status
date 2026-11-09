import SwiftUI

/// The charging plug and state, the overall lock state and whether the car is parked, one row each; rows the vehicle doesn't report are left out.
struct VehicleView: View {
    private let model = VehicleModel.shared

    private struct Row: Identifiable {
        var title: String
        var symbol: String
        var value: String
        /// nil for neutral states that are neither good nor bad.
        var isOK: Bool?
        var id: String { title }
    }

    private var rows: [Row] {
        var rows: [Row] = []
        if let plug = model.battery?.plugConnected {
            let text = plug ? "Connected" + (model.battery?.plugLocked == true ? " · cable locked" : "") : "Not connected"
            rows.append(Row(title: "Plug", symbol: "powerplug", value: text, isOK: nil))
        }
        if let battery = model.battery, let charging = Self.chargingValue(for: battery) {
            rows.append(Row(title: "Charging", symbol: battery.chargingState == .charging ? "bolt.fill" : "bolt",
                            value: charging, isOK: nil))
        }
        if let locks = model.vehicle?.locks, locks != .unknown {
            let locked = locks == .locked
            rows.append(Row(title: "Locks", symbol: locked ? "lock" : "lock.open",
                            value: locked ? "Locked" : "Unlocked", isOK: locked))
        }
        if let parking = model.parkingState, parking != .unknown {
            rows.append(Row(title: "Parking", symbol: "parkingsign",
                            value: parking == .parked ? "Parked" : "Driving", isOK: nil))
        }
        return rows
    }

    private static func chargingValue(for battery: SkodaAPI.Battery) -> String? {
        switch battery.chargingState {
        case .charging:
            guard let power = battery.chargePowerKw, power > 0 else { return "Charging" }
            return "\(power.formatted(.number.precision(.fractionLength(0...1)))) kW"
        case .conserving: return "Conserving"
        case .readyToCharge: return "Ready for charging"
        case .interrupted: return "Interrupted"
        case .discharging: return "Discharging"
        // Plugged / not plugged is the plug row.
        case .plugged, .notPlugged, .unknown: return nil
        }
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("Vehicle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    HStack(spacing: 8) {
                        Image(systemName: row.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 18)
                        Text(row.title)
                        Spacer(minLength: 8)
                        Text(row.value)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: row.isOK == false ? "exclamationmark.circle" : "checkmark")
                            .foregroundStyle(row.isOK == false ? Color.orange : Color.green)
                            .opacity(row.isOK == nil ? 0 : 1)
                            .accessibilityHidden(row.isOK == nil)
                            .frame(width: 14)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
