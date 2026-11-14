import XCTest
@testable import MenuStats

final class DeviceBatteryTests: XCTestCase {
    private let profiler = """
    {"SPBluetoothDataType":[{
      "controller_properties":{"controller_state":"attrib_on"},
      "device_connected":[
        {"AirPods Pro di Thomas":{"device_address":"AA:BB","device_batteryLevelCase":"76%","device_batteryLevelLeft":"100%",
          "device_batteryLevelRight":"98%","device_firmwareVersion":"7A305","device_minorType":"Headphones","device_vendorID":"0x004C"}},
        {"MX Keys Mini":{"device_address":"CC:DD","device_minorType":"Keyboard","device_vendorID":"0x046D","device_services":"0x400000 < BLE >"}},
        {"Mouse di Casa":{"device_address":"EE:FF","device_batteryLevelMain":"45%","device_minorType":"Mouse","device_vendorID":"0x004C"}}
      ],
      "device_not_connected":[
        {"Cuffie vecchie":{"device_batteryLevelMain":"20%","device_minorType":"Headphones"}}
      ]
    }]}
    """

    func testProfilerListsEveryConnectedDeviceWithOrWithoutBattery() {
        let devices = DeviceBatteryReader.parseProfiler(Data(profiler.utf8))
        XCTAssertEqual(devices.map(\.name).sorted(), ["AirPods Pro di Thomas", "MX Keys Mini", "Mouse di Casa"])

        let airpods = devices.first { $0.name.hasPrefix("AirPods") }!
        XCTAssertEqual(airpods.levels.map(\.part), [.left, .right, .chargingCase])
        XCTAssertEqual(airpods.levels.map(\.percent), [1.0, 0.98, 0.76])
        XCTAssertEqual(airpods.kind, .headphones)
        XCTAssertEqual(airpods.maker, "Apple")
        XCTAssertEqual(airpods.firmware, "7A305")
        XCTAssertEqual(airpods.symbol(for: .left), "airpodpro.left")
        XCTAssertEqual(airpods.symbol(for: .chargingCase), "airpodspro.chargingcase.wireless")

        let keyboard = devices.first { $0.name == "MX Keys Mini" }!
        XCTAssertTrue(keyboard.levels.isEmpty, "a keyboard that does not report its battery is still listed")
        XCTAssertEqual(keyboard.kind, .keyboard)
        XCTAssertEqual(keyboard.maker, "Logitech")
        XCTAssertEqual(keyboard.connection, "Bluetooth LE")

        let mouse = devices.first { $0.name == "Mouse di Casa" }!
        XCTAssertEqual(mouse.levels, [.init(part: .main, percent: 0.45)])
        XCTAssertEqual(mouse.kind, .mouse)
    }

    func testBluetoothLEBatteryFillsTheDeviceTheProfilerFound() {
        let profilerDevices = DeviceBatteryReader.parseProfiler(Data(profiler.utf8))
        let merged = DeviceBatteryReader.merge(profiler: profilerDevices, registry: [], bluetoothLE: ["mx keys mini": 0.62, "MX Anywhere 3": 0.3])
        let keyboard = merged.first { $0.name == "MX Keys Mini" }!
        XCTAssertEqual(keyboard.levels.first?.percent, 0.62)
        let mouse = merged.first { $0.name == "MX Anywhere 3" }!
        XCTAssertEqual(mouse.kind, .mouse)
        XCTAssertEqual(mouse.connection, "Bluetooth LE")
        // Devices with a battery come before those without.
        XCTAssertFalse(merged.prefix(while: { !$0.levels.isEmpty }).isEmpty)
        XCTAssertTrue(merged.drop(while: { !$0.levels.isEmpty }).allSatisfy(\.levels.isEmpty))
    }

    func testRegistryBatteryIsAddedWithoutDuplicates() {
        let profilerDevices = DeviceBatteryReader.parseProfiler(Data(profiler.utf8))
        let registry = [
            DeviceBattery(name: "Mouse di Casa", kind: .mouse, maker: "Apple", connection: "Bluetooth", firmware: nil,
                          levels: [.init(part: .main, percent: 0.44)]),
            DeviceBattery(name: "Magic Keyboard", kind: .keyboard, maker: "Apple", connection: "USB", firmware: nil,
                          levels: [.init(part: .main, percent: 0.9, charging: true)]),
        ]
        let merged = DeviceBatteryReader.merge(profiler: profilerDevices, registry: registry, bluetoothLE: [:])
        XCTAssertEqual(merged.filter { $0.name == "Mouse di Casa" }.count, 1)
        XCTAssertEqual(merged.first { $0.name == "Mouse di Casa" }?.levels.first?.percent, 0.45, "the profiler's value is kept")
        XCTAssertEqual(merged.first { $0.name == "Magic Keyboard" }?.levels.first?.charging, true)
    }

    func testPercentParsing() {
        XCTAssertEqual(DeviceBatteryReader.percent("85%"), 0.85)
        XCTAssertEqual(DeviceBatteryReader.percent(NSNumber(value: 40)), 0.4)
        XCTAssertNil(DeviceBatteryReader.percent("n/d"))
        XCTAssertNil(DeviceBatteryReader.percent(NSNumber(value: 255)))
    }

    func testKindAndMaker() {
        XCTAssertEqual(DeviceBattery.kind(minorType: "Keyboard", name: "K380"), .keyboard)
        XCTAssertEqual(DeviceBattery.kind(minorType: nil, name: "MX Master 3S"), .mouse)
        XCTAssertEqual(DeviceBattery.kind(minorType: "Gamepad", name: "Xbox Wireless Controller"), .gamepad)
        XCTAssertEqual(DeviceBattery.kind(minorType: "Speaker", name: "JBL Xtreme 3"), .speaker)
        XCTAssertEqual(DeviceBattery.maker(vendorID: "0x046D"), "Logitech")
        XCTAssertEqual(DeviceBattery.maker(vendorID: "0x045e"), "Microsoft")
        XCTAssertNil(DeviceBattery.maker(vendorID: "0xFFFF"))
    }

    func testConnectionBannerText() {
        let airpods = DeviceBattery(name: "AirPods Pro", kind: .headphones, maker: "Apple", connection: "Bluetooth", firmware: nil,
                                    levels: [.init(part: .left, percent: 1), .init(part: .right, percent: 0.98), .init(part: .chargingCase, percent: 0.76)])
        XCTAssertEqual(DeviceBannerContent.batteryText(airpods), "S 100% · D 98% · custodia 76%")
        let mouse = DeviceBattery(name: "MX Anywhere 3", kind: .mouse, maker: "Logitech", connection: "Bluetooth LE", firmware: nil,
                                  levels: [.init(part: .main, percent: 0.15)])
        XCTAssertEqual(DeviceBannerContent.batteryText(mouse), "collegato · 15%")
        let content = DeviceBannerContent.make(mouse)
        XCTAssertEqual(content.title, "MX Anywhere 3")
        XCTAssertEqual(content.symbol, "computermouse")
        XCTAssertEqual(content.color, .systemRed, "a low battery shows in red")
        let keyboard = DeviceBattery(name: "K380", kind: .keyboard, maker: nil, connection: "Bluetooth", firmware: nil, levels: [])
        XCTAssertEqual(DeviceBannerContent.batteryText(keyboard), "collegato")
        XCTAssertEqual(DeviceAlerts.match(name: "k380", in: [mouse, keyboard])?.name, "K380")
    }
}
