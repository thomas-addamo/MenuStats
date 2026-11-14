import CoreBluetooth
import Foundation
import IOKit

/// A Bluetooth (or USB) accessory connected to the Mac, with its battery when the accessory shares it.
/// AirPods and Beats report each bud and the case separately.
struct DeviceBattery: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case keyboard, mouse, trackpad, headphones, speaker, gamepad, pen, other

        var label: String {
            switch self {
            case .keyboard: "Tastiera"
            case .mouse: "Mouse"
            case .trackpad: "Trackpad"
            case .headphones: "Cuffie"
            case .speaker: "Altoparlante"
            case .gamepad: "Controller"
            case .pen: "Penna"
            case .other: "Accessorio"
            }
        }
    }

    enum Part: Int, Equatable, Comparable {
        case main, left, right, chargingCase

        var label: String? {
            switch self {
            case .main: nil
            case .left: "Sinistro"
            case .right: "Destro"
            case .chargingCase: "Custodia"
            }
        }

        static func < (a: Part, b: Part) -> Bool { a.rawValue < b.rawValue }
    }

    struct Level: Equatable {
        var part: Part
        /// 0…1.
        var percent: Double
        var charging: Bool? = nil
    }

    var name: String
    var kind: Kind
    var maker: String?
    /// "Bluetooth", "Bluetooth LE" or "USB".
    var connection: String?
    var firmware: String?
    var levels: [Level]
    var id: String { name }

    /// The lowest level, for sorting and warnings.
    var lowest: Double? { levels.map(\.percent).min() }
    var isAirPods: Bool { name.lowercased().contains("airpods") || name.lowercased().contains("beats") }

    var symbol: String { Self.symbol(name: name, kind: kind) }

    static func symbol(name: String, kind: Kind) -> String {
        let text = name.lowercased()
        if text.contains("airpods max") { return "airpodsmax" }
        if text.contains("airpods pro") { return "airpodspro" }
        if text.contains("airpods") { return "airpods" }
        if text.contains("beats") { return "beats.headphones" }
        if text.contains("magic mouse") { return "magicmouse" }
        switch kind {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .headphones: return "headphones"
        case .speaker: return "hifispeaker"
        case .gamepad: return "gamecontroller"
        case .pen: return "applepencil"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    /// The icon of one part of AirPods-like earbuds.
    func symbol(for part: Part) -> String {
        let pro = name.lowercased().contains("pro")
        switch part {
        case .main: return symbol
        case .left: return pro ? "airpodpro.left" : "airpod.left"
        case .right: return pro ? "airpodpro.right" : "airpod.right"
        case .chargingCase: return pro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase"
        }
    }

    static func kind(minorType: String?, name: String) -> Kind {
        let text = ((minorType ?? "") + " " + name).lowercased()
        if text.contains("keyboard") || text.contains("tastiera") { return .keyboard }
        if text.contains("trackpad") { return .trackpad }
        if text.contains("mouse") || text.contains("pointing") || text.contains("mx master") || text.contains("mx anywhere") { return .mouse }
        if text.contains("headphone") || text.contains("headset") || text.contains("airpods") || text.contains("beats")
            || text.contains("cuffie") || text.contains("buds") { return .headphones }
        if text.contains("speaker") || text.contains("altoparlante") || text.contains("audio") { return .speaker }
        if text.contains("gamepad") || text.contains("controller") || text.contains("joystick") { return .gamepad }
        if text.contains("pen") || text.contains("stylus") { return .pen }
        return .other
    }

    /// Bluetooth SIG / USB vendor identifiers of the usual accessory makers.
    static func maker(vendorID: String?) -> String? {
        guard let vendorID, let value = Int(vendorID.lowercased().replacingOccurrences(of: "0x", with: ""), radix: 16) else { return nil }
        let makers: [Int: String] = [
            0x004C: "Apple", 0x05AC: "Apple", 0x046D: "Logitech", 0x01DA: "Logitech", 0x045E: "Microsoft", 0x0006: "Microsoft",
            0x1532: "Razer", 0x054C: "Sony", 0x012D: "Sony", 0x04E8: "Samsung", 0x0075: "Samsung", 0x0057: "Harman (JBL)",
            0x0ECB: "JBL", 0x009E: "Bose", 0x00CC: "Beats", 0x1915: "Nordic", 0x0A5C: "Broadcom", 0x05D6: "Zebra",
            0x03E0: "Actions", 0x0B05: "ASUS", 0x17EF: "Lenovo", 0x413C: "Dell", 0x03F0: "HP", 0x2717: "Xiaomi",
            0x038F: "Xiaomi", 0x0499: "Ruuvi", 0x1BCF: "Sunplus", 0x258A: "SINO WEALTH", 0x248A: "Maxxter",
            0x3434: "Keychron", 0x05E3: "Genesys", 0x0D8C: "C-Media", 0x2DC8: "8BitDo", 0x057E: "Nintendo",
        ]
        return makers[value]
    }
}

/// Where MenuStats finds accessory batteries, all read-only:
/// - the IORegistry: Apple's Magic Keyboard, Mouse and Trackpad (and some others) publish `BatteryPercent`;
/// - `system_profiler SPBluetoothDataType`: every connected device, with the levels of AirPods and Beats (about a
///   second, so it runs off the main thread and only while the Battery tab is open);
/// - Bluetooth LE's standard Battery Service, read over CoreBluetooth: how keyboards and mice of other makers
///   (Logitech, Microsoft, Keychron…) report it, whoever's Apple account they belong to.
/// iPhone and iPad batteries aren't shared with the Mac over Bluetooth.
enum DeviceBatteryReader {
    /// Everything connected now, devices without a known battery included (they show as connected).
    static func sample(bluetoothLE: [String: Double] = [:]) -> [DeviceBattery] {
        let profiler = runProfiler().map(parseProfiler) ?? []
        return merge(profiler: profiler, registry: registryBatteries(), bluetoothLE: bluetoothLE)
    }

    /// Joins the three sources by name: the profiler gives the list and the details, the others add the levels
    /// it misses. A registry or LE battery with no profiler entry (a USB-connected Magic Keyboard) is listed alone.
    static func merge(profiler: [DeviceBattery], registry: [DeviceBattery], bluetoothLE: [String: Double]) -> [DeviceBattery] {
        func key(_ name: String) -> String { name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var devices = profiler
        for extra in registry {
            if let index = devices.firstIndex(where: { key($0.name) == key(extra.name) }) {
                if devices[index].levels.isEmpty { devices[index].levels = extra.levels }
                devices[index].maker = devices[index].maker ?? extra.maker
            } else {
                devices.append(extra)
            }
        }
        for (name, percent) in bluetoothLE {
            if let index = devices.firstIndex(where: { key($0.name) == key(name) }) {
                if devices[index].levels.isEmpty { devices[index].levels = [.init(part: .main, percent: percent)] }
                devices[index].connection = devices[index].connection ?? "Bluetooth LE"
            } else {
                devices.append(DeviceBattery(name: name, kind: DeviceBattery.kind(minorType: nil, name: name), maker: nil,
                                             connection: "Bluetooth LE", firmware: nil, levels: [.init(part: .main, percent: percent)]))
            }
        }
        // Devices with a battery first, then by name.
        return devices.sorted {
            if $0.levels.isEmpty != $1.levels.isEmpty { return !$0.levels.isEmpty }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: system_profiler

    private static func runProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-detailLevel", "basic"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return data
    }

    /// The connected devices in `system_profiler SPBluetoothDataType -json`, with or without a battery level.
    static func parseProfiler(_ data: Data) -> [DeviceBattery] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controllers = json["SPBluetoothDataType"] as? [[String: Any]] else { return [] }
        let parts: [(String, DeviceBattery.Part)] = [
            ("device_batteryLevelMain", .main), ("device_batteryLevel", .main), ("device_batteryLevelCombined", .main),
            ("device_batteryLevelLeft", .left), ("device_batteryLevelRight", .right), ("device_batteryLevelCase", .chargingCase),
        ]
        var devices: [DeviceBattery] = []
        for controller in controllers {
            for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                for (name, value) in entry {
                    guard let info = value as? [String: Any], !devices.contains(where: { $0.name == name }) else { continue }
                    var levels: [DeviceBattery.Level] = []
                    for (key, part) in parts where !levels.contains(where: { $0.part == part }) {
                        if let percent = percent(info[key]) { levels.append(.init(part: part, percent: percent)) }
                    }
                    let minorType = info["device_minorType"] as? String
                    let services = (info["device_services"] as? String)?.uppercased() ?? ""
                    devices.append(DeviceBattery(
                        name: name, kind: DeviceBattery.kind(minorType: minorType, name: name),
                        maker: DeviceBattery.maker(vendorID: info["device_vendorID"] as? String),
                        connection: services.contains("BLE") || services.contains("LOW ENERGY") ? "Bluetooth LE" : "Bluetooth",
                        firmware: (info["device_firmwareVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                        levels: levels.sorted { $0.part < $1.part }))
                }
            }
        }
        return devices
    }

    /// "85%", "85 %" or a number → 0.85.
    static func percent(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let text as String: number = Double(text.filter(\.isNumber))
        case let value as NSNumber: number = value.doubleValue
        default: number = nil
        }
        guard let number, number >= 0, number <= 100 else { return nil }
        return number / 100
    }

    // MARK: IORegistry

    /// Accessories that publish `BatteryPercent` themselves. On recent macOS Apple's own keep it on
    /// `AppleDeviceManagementHIDEventService`, a child of the HID device, so both classes are searched, up and down.
    private static func registryBatteries() -> [DeviceBattery] {
        var devices: [DeviceBattery] = []
        for className in ["AppleDeviceManagementHIDEventService", "IOHIDDevice"] {
            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }
            var service = IOIteratorNext(iterator)
            while service != 0 {
                defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
                func property(_ key: String, children: Bool = false) -> Any? {
                    let direction = children ? 0 : kIORegistryIterateParents
                    return IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                                           IOOptionBits(kIORegistryIterateRecursively | direction))
                }
                guard let percent = percent(property("BatteryPercent") ?? property("BatteryPercent", children: true)),
                      let name = property("Product") as? String, !name.isEmpty,
                      !devices.contains(where: { $0.name == name }) else { continue }
                let transport = (property("Transport") as? String)?.lowercased() ?? ""
                let vendor = (property("VendorID") as? NSNumber).map { String(format: "0x%04X", $0.intValue) }
                // Bit 1 of BatteryStatusFlags is set while it charges (a Magic accessory on its cable).
                let flags = (property("BatteryStatusFlags") as? NSNumber)?.intValue
                devices.append(DeviceBattery(
                    name: name, kind: DeviceBattery.kind(minorType: nil, name: name), maker: DeviceBattery.maker(vendorID: vendor),
                    connection: transport.contains("usb") ? "USB"
                        : transport.contains("low energy") || transport.contains("btle") || transport.hasSuffix(" le") ? "Bluetooth LE" : "Bluetooth",
                    firmware: nil, levels: [.init(part: .main, percent: percent, charging: flags.map { $0 & 0x2 != 0 })]))
            }
        }
        return devices
    }
}

/// Reads the standard Battery Service (0x180F, level 0x2A19) of the Bluetooth LE accessories the Mac is connected to:
/// keyboards and mice of other makers report their battery only this way. macOS already holds the connection, so
/// MenuStats only joins it to read one byte. Needs the Bluetooth permission, asked the first time the Battery tab opens.
final class BluetoothLEBatteryReader: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevel = CBUUID(string: "2A19")
    private static let humanInterface = CBUUID(string: "1812")

    private let queue = DispatchQueue(label: "MenuStats.bluetoothLE", qos: .utility)
    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var levels: [UUID: Double] = [:]
    private var pending: Set<UUID> = []
    private var completion: (([String: Double], Bool) -> Void)?
    private var waitingForPower = false
    private var generation = 0
    /// macOS refused the Bluetooth permission: the card then explains why some batteries are missing.
    private var denied = false

    /// Calls back on the reader's queue with name → level (0…1) of every connected LE accessory that shares it,
    /// and whether the Bluetooth permission was refused.
    func read(completion: @escaping ([String: Double], Bool) -> Void) {
        queue.async {
            guard self.completion == nil else { return completion([:], self.denied) }
            self.completion = completion
            self.generation += 1
            let generation = self.generation
            if let central = self.central, central.state == .poweredOn {
                self.scan(central)
            } else if self.central == nil {
                self.waitingForPower = true
                self.central = CBCentralManager(delegate: self, queue: self.queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            } else {
                self.finish()
            }
            // Never keep the card waiting: what was read in 4 seconds is what is shown.
            self.queue.asyncAfter(deadline: .now() + 4) { if self.generation == generation { self.finish() } }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        denied = central.state == .unauthorized
        guard waitingForPower else { return }
        waitingForPower = false
        if central.state == .poweredOn { scan(central) } else { finish() }
    }

    private func scan(_ central: CBCentralManager) {
        let connected = central.retrieveConnectedPeripherals(withServices: [Self.batteryService, Self.humanInterface])
        guard !connected.isEmpty else { return finish() }
        for peripheral in connected {
            peripherals[peripheral.identifier] = peripheral
            pending.insert(peripheral.identifier)
            peripheral.delegate = self
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.batteryService])
            } else {
                central.connect(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.batteryService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        done(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else { return done(peripheral) }
        peripheral.discoverCharacteristics([Self.batteryLevel], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == Self.batteryLevel }) else { return done(peripheral) }
        peripheral.readValue(for: characteristic)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if characteristic.uuid == Self.batteryLevel, let byte = characteristic.value?.first, byte <= 100 {
            levels[peripheral.identifier] = Double(byte) / 100
        }
        done(peripheral)
    }

    private func done(_ peripheral: CBPeripheral) {
        // Only MenuStats' own hold on the link goes away: macOS keeps the accessory connected.
        central?.cancelPeripheralConnection(peripheral)
        pending.remove(peripheral.identifier)
        if pending.isEmpty { finish() }
    }

    private func finish() {
        guard let completion else { return }
        self.completion = nil
        var result: [String: Double] = [:]
        for (id, level) in levels {
            if let name = peripherals[id]?.name, !name.isEmpty { result[name] = level }
        }
        pending.removeAll()
        levels.removeAll()
        completion(result, denied)
    }
}

/// Keeps the list fresh while the Battery tab is open (once a minute).
final class DeviceBatteryMonitor: ObservableObject {
    @Published private(set) var devices: [DeviceBattery] = []
    @Published private(set) var loaded = false
    @Published private(set) var bluetoothDenied = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "MenuStats.deviceBatteries", qos: .utility)
    private static let bluetoothLE = BluetoothLEBatteryReader()

    func start() {
        refresh()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let reader = Self.bluetoothLE
        reader.read { [weak self] levels, denied in
            self?.queue.async {
                let devices = DeviceBatteryReader.sample(bluetoothLE: levels)
                DispatchQueue.main.async {
                    self?.devices = devices
                    self?.bluetoothDenied = denied
                    self?.loaded = true
                }
            }
        }
    }
}
