import Foundation
import IOKit
import IOKit.ps

struct ThermalReading {
    var cpu: Double?
    var gpu: Double?
    var ssd: Double?
    var battery: Double?
    var hottest: Double?
    var state: ProcessInfo.ThermalState = .nominal
}

struct BatteryReading {
    var percent: Int
    var charging: Bool
    var onAC: Bool
    var minutesLeft: Int?
    var watts: Double?
    var health: Int?
    var cycles: Int?
    var temperature: Double?
}

// Private IOHIDEventSystem functions (the same ones used by Stats, iStat, etc.)
// to read Apple Silicon temperature sensors without root.
private typealias HIDCreate = @convention(c) (CFAllocator?) -> UnsafeMutableRawPointer?
private typealias HIDSetMatching = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Int32
private typealias HIDCopyServices = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
private typealias HIDCopyProperty = @convention(c) (UnsafeRawPointer, CFString) -> UnsafeMutableRawPointer?
private typealias HIDCopyEvent = @convention(c) (UnsafeRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
private typealias HIDGetFloat = @convention(c) (UnsafeMutableRawPointer, Int32) -> Double

final class Sensors {
    private struct Sensor {
        let name: String
        let service: UnsafeRawPointer
    }

    private var sensors: [Sensor] = []
    private var servicesArray: CFArray?        // keeps the service refs alive
    private var client: UnsafeMutableRawPointer?
    private var copyEvent: HIDCopyEvent?
    private var getFloat: HIDGetFloat?
    private var batteryService: io_service_t = 0

    init() {
        setupHID()
        batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit {
        if batteryService != 0 { IOObjectRelease(batteryService) }
    }

    // MARK: Temperature

    private func setupHID() {
        let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
            ?? UnsafeMutableRawPointer(bitPattern: -2)

        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(handle, name) else { return nil }
            return unsafeBitCast(p, to: type)
        }

        guard let create = sym("IOHIDEventSystemClientCreate", HIDCreate.self),
              let setMatching = sym("IOHIDEventSystemClientSetMatching", HIDSetMatching.self),
              let copyServices = sym("IOHIDEventSystemClientCopyServices", HIDCopyServices.self),
              let copyProperty = sym("IOHIDServiceClientCopyProperty", HIDCopyProperty.self),
              let copyEventFn = sym("IOHIDServiceClientCopyEvent", HIDCopyEvent.self),
              let getFloatFn = sym("IOHIDEventGetFloatValue", HIDGetFloat.self)
        else { return }

        guard let client = create(kCFAllocatorDefault) else { return }
        let matching: [String: Int] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        _ = setMatching(client, matching as CFDictionary)

        guard let servicesRaw = copyServices(client) else { return }
        let services = Unmanaged<CFArray>.fromOpaque(servicesRaw).takeRetainedValue()

        let count = CFArrayGetCount(services)
        var found: [Sensor] = []
        for i in 0..<count {
            guard let svc = CFArrayGetValueAtIndex(services, i) else { continue }
            guard let nameRaw = copyProperty(svc, "Product" as CFString) else { continue }
            let nameObj = Unmanaged<AnyObject>.fromOpaque(nameRaw).takeRetainedValue()
            guard let name = nameObj as? String else { continue }
            found.append(Sensor(name: name, service: svc))
        }

        self.client = client
        self.servicesArray = services
        self.sensors = found
        self.copyEvent = copyEventFn
        self.getFloat = getFloatFn
    }

    func readThermal() -> ThermalReading {
        var r = ThermalReading()
        r.state = ProcessInfo.processInfo.thermalState
        guard let copyEvent = copyEvent, let getFloat = getFloat, !sensors.isEmpty else { return r }

        let temperatureType: Int64 = 15            // kIOHIDEventTypeTemperature
        let field = Int32(15 << 16)                 // IOHIDEventFieldBase(kIOHIDEventTypeTemperature)

        var cpuMTR: [Double] = [], tdie: [Double] = [], gpu: [Double] = []
        var ssd: [Double] = [], batt: [Double] = [], all: [Double] = []

        for s in sensors {
            guard let ev = copyEvent(s.service, temperatureType, 0, 0) else { continue }
            let v = getFloat(ev, field)
            Unmanaged<AnyObject>.fromOpaque(ev).release()
            guard v > 1, v < 130 else { continue }

            let n = s.name.lowercased()
            all.append(v)
            if n.contains("pacc") || n.contains("eacc") || (n.contains("cpu") && !n.contains("gpu")) {
                cpuMTR.append(v)
            } else if n.contains("tdie") {
                tdie.append(v)
            } else if n.contains("gpu") {
                gpu.append(v)
            } else if n.contains("nand") || n.contains("ssd") {
                ssd.append(v)
            } else if n.contains("battery") || n.contains("gas gauge") {
                batt.append(v)
            }
        }

        func avg(_ a: [Double]) -> Double? { a.isEmpty ? nil : a.reduce(0, +) / Double(a.count) }
        r.cpu = avg(cpuMTR) ?? avg(tdie)
        r.gpu = avg(gpu)
        r.ssd = avg(ssd)
        r.battery = avg(batt)
        r.hottest = all.max()
        return r
    }

    // MARK: Battery

    func readBattery() -> BatteryReading? {
        guard let blobU = IOPSCopyPowerSourcesInfo() else { return nil }
        let blob = blobU.takeRetainedValue()
        guard let listU = IOPSCopyPowerSourcesList(blob) else { return nil }
        let list = listU.takeRetainedValue() as NSArray

        for item in list {
            let ps = item as CFTypeRef
            guard let descU = IOPSGetPowerSourceDescription(blob, ps) else { continue }
            let desc = descU.takeUnretainedValue() as NSDictionary
            guard (desc["Type"] as? String) == "InternalBattery" else { continue }

            let current = (desc["Current Capacity"] as? NSNumber)?.intValue ?? 0
            let capMax = (desc["Max Capacity"] as? NSNumber)?.intValue ?? 100
            let pct = capMax > 0 ? Int((Double(current) / Double(capMax) * 100).rounded()) : current
            let charging = (desc["Is Charging"] as? NSNumber)?.boolValue ?? false
            let onAC = (desc["Power Source State"] as? String) == "AC Power"
            let tte = (desc["Time to Empty"] as? NSNumber)?.intValue ?? -1

            var r = BatteryReading(percent: min(100, max(0, pct)), charging: charging, onAC: onAC,
                                   minutesLeft: (!onAC && tte > 0) ? tte : nil)
            fillSmartBattery(&r)
            return r
        }
        return nil
    }

    private func prop(_ key: String) -> Any? {
        guard batteryService != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(batteryService, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    private func number(_ key: String) -> NSNumber? { prop(key) as? NSNumber }

    private func fillSmartBattery(_ r: inout BatteryReading) {
        if let t = number("Temperature")?.doubleValue, t > 0 { r.temperature = t / 100 }
        if let c = number("CycleCount")?.intValue { r.cycles = c }

        let design = number("DesignCapacity")?.doubleValue ?? 0
        let rawMax = number("AppleRawMaxCapacity")?.doubleValue ?? number("NominalChargeCapacity")?.doubleValue ?? 0
        if design > 0, rawMax > 0 {
            r.health = min(100, Int((rawMax / design * 100).rounded()))
        }

        if !r.onAC,
           let mv = number("Voltage")?.doubleValue,
           let ampN = number("InstantAmperage") ?? number("Amperage") {
            var a = ampN.int64Value
            if a > Int64(Int32.max) { a = Int64(Int32(truncatingIfNeeded: a)) }
            let w = abs(Double(a) * mv) / 1_000_000
            if w > 0.05 && w < 300 { r.watts = w }
        } else if let tel = prop("PowerTelemetryData") as? NSDictionary,
                  let mw = (tel["SystemPowerIn"] as? NSNumber)?.doubleValue {
            let w = mw / 1000
            if w > 0.05 && w < 300 { r.watts = w }
        }
    }
}
