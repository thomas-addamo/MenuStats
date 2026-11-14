import AppKit
import Combine
import SwiftUI

// MARK: - GPU (CPU tab)

/// GPU load, read every 2 s while the card is on screen. The Neural Engine has no counter an app can read.
struct GPUCard: View {
    @State private var stats: GPUStats? = GPUReader.sample()
    @State private var history: [Double] = []
    private let tick = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Card(title: "GPU e Neural Engine", trailing: stats?.name) {
            if let stats {
                HStack(alignment: .top) {
                    Hero(value: Format.percent(stats.utilization), caption: "Utilizzo GPU", accent: Palette.color(3))
                    Spacer()
                    StatGrid(items: [
                        ("Rendering", stats.renderer.map { Format.percent($0) } ?? "—"),
                        ("Tiling", stats.tiler.map { Format.percent($0) } ?? "—"),
                    ], columns: 1)
                    .frame(width: 120)
                }
                UsageBar(fraction: stats.utilization, color: Palette.color(3), height: 6)
                if history.count > 1 { Sparkline(values: history, color: Palette.color(3)).frame(height: 28) }
            } else {
                Text("Utilizzo della GPU non disponibile su questo Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("Neural Engine: macOS mostra il suo utilizzo solo a powermetrics, che richiede la password di amministratore.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onReceive(tick) { _ in
            stats = GPUReader.sample()
            if let value = stats?.utilization { history = Array((history + [value]).suffix(60)) }
        }
    }
}

/// Minimal line of recent values (0…1), for cards that keep their own short history.
struct Sparkline: View {
    var values: [Double]
    var color: Color

    var body: some View {
        GeometryReader { proxy in
            let step = proxy.size.width / CGFloat(max(values.count - 1, 1))
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - CGFloat(min(max(value, 0), 1))))
                    index == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
    }
}

// MARK: - Bluetooth accessories (Battery tab)

struct DeviceBatteriesCard: View {
    @StateObject private var monitor = DeviceBatteryMonitor()

    var body: some View {
        Card(title: "Dispositivi collegati", trailing: monitor.devices.isEmpty ? nil : "\(monitor.devices.count)") {
            if monitor.devices.isEmpty {
                HStack(spacing: 6) {
                    if !monitor.loaded { ProgressView().controlSize(.small) }
                    Text(monitor.loaded ? "Nessun accessorio collegato al Mac in questo momento." : "Cerco gli accessori collegati…")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(monitor.devices) { device in
                DeviceBatteryRow(device: device)
                if device.id != monitor.devices.last?.id { Divider().opacity(0.5) }
            }
            if monitor.bluetoothDenied {
                Button { Self.openBluetoothPrivacy() } label: {
                    Label("Consenti il Bluetooth a MenuStats per leggere la batteria di tastiere e mouse non Apple", systemImage: "exclamationmark.triangle.fill")
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            Text("Si vedono tutti gli accessori collegati a questo Mac, di qualsiasi marca e account. La batteria compare quando l'accessorio la comunica: alcuni modelli Bluetooth classici e quelli con ricevitore USB non lo fanno. L'iPhone non condivide la batteria con il Mac: per quella usa il widget Batterie o Dov'è.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    static func openBluetoothPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// One accessory: icon, name, what it is, and its battery. Earbuds get one gauge per bud and one for the case.
struct DeviceBatteryRow: View {
    var device: DeviceBattery

    private var details: String {
        [device.kind.label, device.maker, device.connection, device.firmware.map { "firmware \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: device.symbol)
                    .font(.system(size: 15)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.neutral))
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(details).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if device.levels.count == 1, let level = device.levels.first {
                    percentLabel(level)
                } else if device.levels.isEmpty {
                    Text("collegato").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.color(2))
                }
            }
            if device.levels.count == 1, let level = device.levels.first {
                UsageBar(fraction: level.percent, color: Self.color(level.percent), height: 5)
            } else if device.levels.count > 1 {
                HStack(spacing: 8) {
                    ForEach(device.levels, id: \.part) { level in
                        PartGauge(level: level, symbol: device.symbol(for: level.part))
                    }
                }
            } else {
                Text("Non comunica la batteria al Mac")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            if let lowest = device.lowest, lowest <= 0.1 {
                Label("Batteria quasi scarica: ricaricalo presto", systemImage: "battery.0percent")
                    .font(.system(size: 10)).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func percentLabel(_ level: DeviceBattery.Level) -> some View {
        HStack(spacing: 3) {
            if level.charging == true { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Palette.color(2)) }
            Text(Format.percent(level.percent)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(level.percent <= 0.2 ? Color.red : Color.primary)
        }
    }

    static func color(_ percent: Double) -> Color {
        percent <= 0.2 ? .red : percent <= 0.4 ? .orange : Palette.color(2)
    }
}

/// A ring with the part's icon in the middle and its percentage below: left bud, right bud, case.
private struct PartGauge: View {
    var level: DeviceBattery.Level
    var symbol: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Palette.neutral, lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat(min(max(level.percent, 0), 1)))
                    .stroke(DeviceBatteryRow.color(level.percent), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary)
            }
            .frame(width: 44, height: 44)
            Text(Format.percent(level.percent)).font(.system(size: 11.5, weight: .semibold)).monospacedDigit()
            Text(level.part.label ?? "").font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help("\(level.part.label ?? "Batteria"): \(Format.percent(level.percent))")
    }
}

// MARK: - Ping and speed test (Network tab)

struct NetworkToolsCard: View {
    @ObservedObject private var tools = NetworkTools.shared
    @AppStorage("ping.host") private var host = "1.1.1.1"

    var body: some View {
        Card(title: "Ping e velocità") {
            HStack(spacing: 6) {
                TextField("Indirizzo (es. 1.1.1.1)", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { tools.runPing(host: host) }
                Button { tools.runPing(host: host) } label: {
                    if tools.pinging { ProgressView().controlSize(.mini) } else { Text("Ping") }
                }
                .controlSize(.small)
                .disabled(tools.pinging)
            }
            if let ping = tools.ping, ping.average != nil {
                StatGrid(items: [
                    ("Medio", ping.average.map { String(format: "%.1f ms", $0) } ?? "—"),
                    ("Min / max", [ping.minimum, ping.maximum].compactMap { $0.map { String(format: "%.0f", $0) } }.joined(separator: " / ") + " ms"),
                    ("Pacchetti persi", ping.loss.map { Format.percent($0) } ?? "—"),
                ])
            }
            Divider()
            HStack {
                Button { tools.runSpeedTest() } label: {
                    Label(tools.testingSpeed ? "Test in corso (circa 20 s)…" : "Test di velocità", systemImage: "speedometer")
                }
                .controlSize(.small)
                .disabled(tools.testingSpeed)
                if tools.testingSpeed { ProgressView().controlSize(.mini) }
                Spacer()
                if let speed = tools.speed { Text(DateText.string(speed.date, "HH:mm")).font(.system(size: 10)).foregroundStyle(.tertiary) }
            }
            if let speed = tools.speed {
                HStack {
                    Hero(value: speed.download.map(Self.mbps) ?? "—", caption: "Download", accent: Palette.color(0))
                    Spacer()
                    Hero(value: speed.upload.map(Self.mbps) ?? "—", caption: "Upload", accent: Palette.color(1))
                    Spacer()
                }
                if let rpm = speed.responsiveness {
                    Text("Reattività: \(Int(rpm)) RPM (\(Self.responsivenessLabel(rpm)))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if let error = tools.error { Text(error).font(.system(size: 11)).foregroundStyle(.red) }
            Text("Usa gli strumenti di macOS (ping e networkQuality, server Apple). Il test scarica e invia qualche centinaio di MB.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func mbps(_ bits: Double) -> String {
        bits >= 1e9 ? String(format: "%.2f Gb/s", bits / 1e9) : String(format: "%.0f Mb/s", bits / 1e6)
    }

    private static func responsivenessLabel(_ rpm: Double) -> String {
        rpm >= 1000 ? "alta" : rpm >= 200 ? "media" : "bassa"
    }
}
