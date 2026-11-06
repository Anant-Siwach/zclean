import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Live CPU, memory, disk, network and battery stats for the menu bar.
@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()

    @Published var cpu: Double = 0
    @Published var memoryUsed: Int64 = 0
    @Published var memoryTotal = Int64(ProcessInfo.processInfo.physicalMemory)
    @Published var swapUsed: Int64 = 0
    @Published var diskFree: Int64 = 0
    @Published var diskTotal: Int64 = 0
    @Published var download: Double = 0
    @Published var upload: Double = 0
    @Published var battery: Battery?
    @Published var topProcesses: [ProcessInfoRow] = []
    @Published var uptime: TimeInterval = 0

    struct Battery {
        var percent: Int
        var charging: Bool
        var onAC: Bool
        var health: Int?
        var cycles: Int?
        var minutesLeft: Int?
    }

    private var prevTicks: (user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)?
    private var prevNet: (rx: UInt64, tx: UInt64, time: Date)?
    private var timer: Timer?
    private var tick = 0

    func start() {
        guard timer == nil else { return }
        update()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    private func update() {
        cpu = cpuUsage()
        (memoryUsed, swapUsed) = memory()
        let disk = FileOps.diskSpace
        diskFree = disk.free
        diskTotal = disk.total
        network()
        uptime = ProcessInfo.processInfo.systemUptime
        if tick % 5 == 0 { battery = Self.readBattery() }
        if tick % 2 == 0 {
            Task { topProcesses = await Task.detached { Array(ProcessList.top(limit: 5)) }.value }
        }
        tick += 1
    }

    private func cpuUsage() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return cpu }
        let t = (info.cpu_ticks.0, info.cpu_ticks.1, info.cpu_ticks.2, info.cpu_ticks.3)
        defer { prevTicks = t }
        guard let p = prevTicks else { return 0 }
        let user = Double(t.0 &- p.user), system = Double(t.1 &- p.system), idle = Double(t.2 &- p.idle), nice = Double(t.3 &- p.nice)
        let total = user + system + idle + nice
        return total > 0 ? (user + system + nice) / total : 0
    }

    private func memory() -> (Int64, Int64) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard r == KERN_SUCCESS else { return (memoryUsed, swapUsed) }
        let page = Int64(vm_kernel_page_size)
        // Matches Activity Monitor's "Memory Used": app memory + wired + compressed.
        let app = Int64(stats.internal_page_count) - Int64(stats.purgeable_count)
        let used = (app + Int64(stats.wire_count) + Int64(stats.compressor_page_count)) * page
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        return (used, Int64(swap.xsu_used))
    }

    private func network() {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        var p: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = p {
            let name = String(cString: ifa.pointee.ifa_name)
            if ifa.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), name.hasPrefix("en") || name.hasPrefix("pdp_ip"),
               let data = ifa.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                rx += UInt64(data.pointee.ifi_ibytes)
                tx += UInt64(data.pointee.ifi_obytes)
            }
            p = ifa.pointee.ifa_next
        }
        let now = Date()
        if let prev = prevNet {
            let dt = now.timeIntervalSince(prev.time)
            // Counters are 32-bit per interface and wrap; ignore negative jumps.
            download = rx >= prev.rx ? Double(rx - prev.rx) / dt : download
            upload = tx >= prev.tx ? Double(tx - prev.tx) / dt : upload
        }
        prevNet = (rx, tx, now)
    }

    nonisolated static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            var b = Battery(percent: max > 0 ? cur * 100 / max : cur,
                            charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                            onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { b.minutesLeft = t }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
            if service != 0 {
                defer { IOObjectRelease(service) }
                func prop(_ key: String) -> Int? {
                    IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
                }
                b.cycles = prop("CycleCount")
                if let raw = prop("AppleRawMaxCapacity"), let design = prop("DesignCapacity"), design > 0 {
                    b.health = min(100, raw * 100 / design)
                }
            }
            return b
        }
        return nil
    }
}
