import SwiftUI

struct BatteryView: View {
    private let model = VehicleModel.shared

    @ViewBuilder
    private func errorText(_ error: String) -> some View {
        if let until = model.retryNotBefore, until > .now {
            // Re-render when the wait is over so the countdown disappears.
            TimelineView(.explicit([until])) { context in
                if context.date < until {
                    Text("\(error) Retry in \(Text(timerInterval: context.date...until, countsDown: true, showsHours: false))")
                        .font(.callout).foregroundStyle(.red)
                } else {
                    Text(error).font(.callout).foregroundStyle(.red)
                }
            }
        } else {
            Text(error).font(.callout).foregroundStyle(.red)
        }
    }

    private var noDataText: String {
        switch model.chargingIssue {
        case .unsupported: "This vehicle doesn't support charging data"
        case .disabled: "Charging data is disabled in MyŠkoda"
        case .unavailable: "Charging data couldn't be retrieved right now"
        case nil: "No battery data for this vehicle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.error {
                errorText(error)
            }
            if model.battery == nil && model.isLoading {
                ProgressView().controlSize(.small)
            } else if let battery = model.battery {
                card(for: battery)
                if battery.percent == nil && battery.rangeKm == nil {
                    caption("No battery data for this vehicle")
                }
            } else if model.error == nil {
                caption(noDataText)
            }

            if let expiry = model.keyExpiresAt, let text = Self.expiryText(for: expiry) {
                caption(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    private func card(for battery: SkodaAPI.Battery) -> some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                // The render sits behind the top section, pushed a third out of the popover and running up to its border
                // (the window clips it); the text stays on the left.
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            // A blank stands in for missing text so the block keeps its height, and the render with it.
                            Text(model.vehicleName ?? " ").font(.title3).lineLimit(1)
                            let details = [model.licensePlate.flatMap { $0.isEmpty ? nil : $0 },
                                           model.odometerKm.map { "\($0.formatted()) km" }].compactMap { $0 }
                            Text(details.isEmpty ? " " : details.joined(separator: " · "))
                                .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if let capturedAt = model.vehicle?.capturedAt {
                            Label("\(capturedAt.formatted(.dateTime.day().month(.abbreviated))) \(capturedAt.formatted(date: .omitted, time: .shortened))",
                                  systemImage: "arrow.clockwise")
                                .labelStyle(TightLabelStyle())
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(battery.percent.map { "\($0)" } ?? "–")
                            .font(.system(size: 54, weight: .regular))
                        if battery.percent != nil {
                            Text("%").font(.title.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 3)
                .background {
                    GeometryReader { proxy in
                        let drop = proxy.size.height * Self.renderDrop
                        render
                            .frame(height: proxy.size.height * Self.renderScale)
                            .fixedSize(horizontal: true, vertical: false)
                            .visualEffect { content, image in content.offset(x: image.size.width / 3 + 15, y: drop) }
                            .frame(width: proxy.size.width + Self.edgeInset, height: proxy.size.height, alignment: .bottomTrailing)
                    }
                }

                if let km = battery.rangeKm {
                    Text("\(km) km \(Text("estimated range").foregroundStyle(.secondary))")
                        .padding(.bottom, 2)
                }

                if let percent = battery.percent {
                    ChargeBar(fraction: Double(percent) / 100,
                              color: Self.barColor(for: percent),
                              isCharging: battery.chargingState == .charging)
                        .frame(height: 8)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The car's render; the plain car symbol stands in while it loads, when there is none, or if it fails to load.
    private var render: some View {
        AsyncImage(url: model.renderURL) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "car.side.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Horizontal space between the card and the popover's border: this view's padding plus the popover's.
    private static let edgeInset: CGFloat = 16

    /// The render has transparent margins, so it's drawn taller than the text block for the car itself to match its height.
    private static let renderScale: CGFloat = 1.3

    /// How far below the text block the render's bottom edge sits, as a fraction of the block's height; unchanged from when the scale was 1.5.
    private static let renderDrop: CGFloat = 0.25

    private func caption(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }

    private static func barColor(for percent: Int) -> Color {
        switch percent {
        case ...10: .red
        case ...20: .orange
        default: .green
        }
    }

    /// Only returns text once the key is within a week of expiring.
    private static func expiryText(for expiry: Date) -> String? {
        let remaining = expiry.timeIntervalSinceNow
        guard remaining < 7 * 86400 else { return nil }
        guard remaining > 0 else { return "API key expired" }
        guard remaining >= 86400 else { return "API key expires today" }
        let days = Int((remaining / 86400).rounded(.up))
        return "API key expires in \(days) day\(days == 1 ? "" : "s")"
    }
}

/// A capsule progress bar; while charging, a highlight sweeps across the filled part.
private struct ChargeBar: View {
    let fraction: Double
    let color: Color
    let isCharging: Bool

    private let bandFraction = 0.4
    private let minBandWidth: CGFloat = 24
    private let highlightOpacity = 0.6
    private let sweepDuration = 1.6

    var body: some View {
        GeometryReader { proxy in
            let fillWidth = proxy.size.width * min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color)
                    .frame(width: fillWidth)
                    .overlay(alignment: .leading) {
                        if isCharging { sweep(in: fillWidth) }
                    }
                    .clipShape(Capsule())
            }
        }
    }

    private func sweep(in fillWidth: CGFloat) -> some View {
        let band = max(fillWidth * bandFraction, minBandWidth)
        return LinearGradient(colors: [.clear, .white.opacity(highlightOpacity), .clear], startPoint: .leading, endPoint: .trailing)
            .frame(width: band)
            // From fully off the left edge to fully off the right edge of the fill, then snap back.
            .phaseAnimator([false, true]) { content, atEnd in
                content.offset(x: atEnd ? fillWidth : -band)
            } animation: { atEnd in
                atEnd ? .linear(duration: sweepDuration) : nil
            }
    }
}

/// Icon and title with less space between them than the default, the icon scaled down to the height of the text.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
