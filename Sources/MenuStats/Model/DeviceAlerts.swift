import AppKit
import IOBluetooth
import IOKit
import IOKit.hid

/// Announces in the menu bar the accessories that connect to the Mac (AirPods, headphones, keyboards, mice,
/// controllers), with their battery, the same way the calendar announces events. macOS tells MenuStats when a device
/// connects: classic Bluetooth (headphones, speakers) through IOBluetooth, keyboards, mice and controllers (Bluetooth
/// and Bluetooth LE) through the HID devices appearing in IOKit. Nothing is polled while nothing connects.
final class DeviceAlerts: NSObject, ObservableObject {
    struct Banner: Equatable {
        var id = UUID()
        var devices: [DeviceBattery]
        var secondsPerDevice: Double
    }

    @Published private(set) var pending: Banner?

    /// Connections in the first seconds are the devices already there at launch: not news.
    static let startupQuiet: TimeInterval = 8
    /// A device that drops and comes back within this time (AirPods taken out of the ear) isn't announced again.
    static let reconnectQuiet: TimeInterval = 90
    /// AirPods and some mice report their battery a few seconds after connecting.
    static let batteryDelay: TimeInterval = 4

    private weak var settings: Settings?
    private var startedAt = Date()
    private var lastAnnounced: [String: Date] = [:]
    private var waiting: Set<String> = []
    private var bluetoothNotification: IOBluetoothUserNotification?
    private var hidPort: IONotificationPortRef?
    private var hidIterator: io_iterator_t = 0
    private let queue = DispatchQueue(label: "MenuStats.deviceAlerts", qos: .utility)
    private let bluetoothLE = BluetoothLEBatteryReader()

    func start(settings: Settings) {
        self.settings = settings
        startedAt = Date()
        guard bluetoothNotification == nil else { return }
        bluetoothNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        watchHID()
    }

    // MARK: Sources

    @objc private func bluetoothConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard let name = device.name, !name.isEmpty else { return }
        connected(name: name)
    }

    private func watchHID() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        hidPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<DeviceAlerts>.fromOpaque(context).takeUnretainedValue().drainHID(iterator)
        }
        guard IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), callback,
                                               context, &hidIterator) == KERN_SUCCESS else { return }
        drainHID(hidIterator) // arms the notification; these are the devices already connected
    }

    private func drainHID(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            let transport = (IORegistryEntryCreateCFProperty(service, kIOHIDTransportKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String)?.lowercased() ?? ""
            guard transport.contains("bluetooth") || transport.contains("btle"),
                  let name = IORegistryEntryCreateCFProperty(service, kIOHIDProductKey as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String, !name.isEmpty else { continue }
            connected(name: name)
        }
    }

    // MARK: Announcing

    /// A device connected: wait for its battery, then announce it once.
    private func connected(name: String, now: Date = Date()) {
        guard let settings, settings.deviceAlerts, now.timeIntervalSince(startedAt) > Self.startupQuiet else { return }
        let key = name.lowercased()
        // Both sources report the same keyboard: one announcement.
        guard !waiting.contains(key) else { return }
        if let last = lastAnnounced[key], now.timeIntervalSince(last) < Self.reconnectQuiet { return }
        waiting.insert(key)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.batteryDelay) { [weak self] in
            self?.readAndAnnounce(name: name)
        }
    }

    private func readAndAnnounce(name: String) {
        bluetoothLE.read { [weak self] levels, _ in
            self?.queue.async {
                let all = DeviceBatteryReader.sample(bluetoothLE: levels)
                let device = Self.match(name: name, in: all)
                    ?? DeviceBattery(name: name, kind: DeviceBattery.kind(minorType: nil, name: name), maker: nil,
                                     connection: "Bluetooth", firmware: nil, levels: [])
                DispatchQueue.main.async { self?.announce(device, key: name.lowercased()) }
            }
        }
    }

    private func announce(_ device: DeviceBattery, key: String) {
        waiting.remove(key)
        lastAnnounced[key] = Date()
        guard let settings, settings.deviceAlerts else { return }
        show([device], settings: settings)
    }

    /// The reader's entry for a name macOS gave: same name, or one containing the other ("Magic Mouse" / "Mouse di Thomas" no).
    static func match(name: String, in devices: [DeviceBattery]) -> DeviceBattery? {
        let wanted = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return devices.first { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) == wanted }
    }

    func show(_ devices: [DeviceBattery], settings: Settings) {
        if var current = pending {
            current.devices += devices.filter { device in !current.devices.contains { $0.id == device.id } }
            pending = current
            return
        }
        pending = Banner(devices: devices, secondsPerDevice: Double(max(settings.deviceAlertSeconds, 2)))
    }

    /// "Prova avviso": the first connected accessory, or an example.
    func preview(settings: Settings) {
        queue.async { [weak self] in
            let device = DeviceBatteryReader.sample().first { !$0.levels.isEmpty }
                ?? DeviceBattery(name: "AirPods Pro", kind: .headphones, maker: "Apple", connection: "Bluetooth", firmware: nil,
                                 levels: [.init(part: .left, percent: 0.9), .init(part: .right, percent: 0.85),
                                          .init(part: .chargingCase, percent: 0.6)])
            DispatchQueue.main.async { self?.show([device], settings: settings) }
        }
    }

    func finished(_ banner: Banner) {
        if pending?.id == banner.id { pending = nil }
    }
}

/// How a connected accessory looks in the menu bar: its icon, its name, and a pill with the battery.
enum DeviceBannerContent {
    static func make(_ device: DeviceBattery) -> EventBannerContent {
        let lowest = device.lowest
        let color: NSColor = lowest.map { $0 <= 0.2 ? .systemRed : $0 <= 0.4 ? .systemOrange : .systemGreen } ?? .systemBlue
        return EventBannerContent(title: device.name, when: batteryText(device), place: nil, minutes: nil,
                                  progress: lowest ?? 1, color: color, hasMeeting: false, symbol: device.symbol)
    }

    /// "collegato · 85%", "S 100% · D 98% · custodia 76%" or just "collegato".
    static func batteryText(_ device: DeviceBattery) -> String {
        func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
        switch device.levels.count {
        case 0: return "collegato"
        case 1: return "collegato · " + percent(device.levels[0].percent) + (device.levels[0].charging == true ? " ⚡︎" : "")
        default:
            return device.levels.map { level in
                switch level.part {
                case .main: percent(level.percent)
                case .left: "S " + percent(level.percent)
                case .right: "D " + percent(level.percent)
                case .chargingCase: "custodia " + percent(level.percent)
                }
            }.joined(separator: " · ")
        }
    }
}
