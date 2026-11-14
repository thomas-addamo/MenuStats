import AppKit
import IOBluetooth
import IOKit
import IOKit.hid

/// macOS's own signals that an accessory connected or went away: classic Bluetooth (headphones, speakers) through
/// IOBluetooth, keyboards, mice and controllers (Bluetooth and Bluetooth LE) through the HID devices appearing and
/// disappearing in IOKit. Nothing is polled. Shared by the menu bar announcements and the Battery tab's list.
final class AccessoryEvents: NSObject {
    static let shared = AccessoryEvents()
    /// Posted on the main queue for any connection or disconnection; `userInfo["connected"]` names a new device.
    static let changed = Notification.Name("MenuStats.accessoriesChanged")

    private var started = false
    private var bluetoothNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private var hidPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    /// Devices already there when listening began: not news for the announcements.
    private(set) var startedAt = Date()

    func start() {
        guard !started else { return }
        started = true
        startedAt = Date()
        bluetoothNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        watchHID()
    }

    @objc private func bluetoothConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let name = device.name ?? ""
        if let address = device.addressString {
            disconnectNotifications[address]?.unregister()
            disconnectNotifications[address] = device.register(forDisconnectNotification: self,
                                                               selector: #selector(bluetoothDisconnected(_:device:)))
        }
        post(connected: name.isEmpty ? nil : name)
    }

    @objc private func bluetoothDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString { disconnectNotifications.removeValue(forKey: address)?.unregister() }
        post(connected: nil)
    }

    private func watchHID() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        hidPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let added: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<AccessoryEvents>.fromOpaque(context).takeUnretainedValue().drain(iterator, added: true)
        }
        let removed: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            Unmanaged<AccessoryEvents>.fromOpaque(context).takeUnretainedValue().drain(iterator, added: false)
        }
        if IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"), added,
                                            context, &addedIterator) == KERN_SUCCESS {
            drain(addedIterator, added: true, initial: true) // arms it; these were already connected
        }
        if IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOHIDDevice"), removed,
                                            context, &removedIterator) == KERN_SUCCESS {
            drain(removedIterator, added: false, initial: true)
        }
    }

    private func drain(_ iterator: io_iterator_t, added: Bool, initial: Bool = false) {
        var names: [String] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            let transport = (IORegistryEntryCreateCFProperty(service, kIOHIDTransportKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String)?.lowercased() ?? ""
            guard transport.contains("bluetooth") || transport.contains("btle") || transport.contains("usb") else { continue }
            let name = IORegistryEntryCreateCFProperty(service, kIOHIDProductKey as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            names.append(transport.contains("usb") ? "" : (name ?? ""))
        }
        guard !initial, !names.isEmpty else { return }
        if added {
            for name in Set(names) { post(connected: name.isEmpty ? nil : name) }
        } else {
            post(connected: nil)
        }
    }

    private func post(connected name: String?) {
        NotificationCenter.default.post(name: Self.changed, object: self, userInfo: name.map { ["connected": $0] })
    }
}

/// Announces in the menu bar the accessories that connect to the Mac (AirPods, headphones, keyboards, mice,
/// controllers), with their battery, the same way the calendar announces events.
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
    private var lastAnnounced: [String: Date] = [:]
    private var waiting: Set<String> = []
    private var observer: NSObjectProtocol?
    private let queue = DispatchQueue(label: "MenuStats.deviceAlerts", qos: .utility)
    private let bluetoothLE = BluetoothLEBatteryReader()

    func start(settings: Settings) {
        self.settings = settings
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: AccessoryEvents.changed, object: nil, queue: .main) { [weak self] note in
            if let name = note.userInfo?["connected"] as? String { self?.connected(name: name) }
        }
        AccessoryEvents.shared.start()
    }

    // MARK: Announcing

    /// A device connected: wait for its battery, then announce it once.
    private func connected(name: String, now: Date = Date()) {
        guard let settings, settings.deviceAlerts,
              now.timeIntervalSince(AccessoryEvents.shared.startedAt) > Self.startupQuiet else { return }
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
