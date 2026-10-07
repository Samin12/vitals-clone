import Foundation
import Darwin
import IOKit
import IOKit.ps

// Mirrors VitalsCore.SystemSample / BatterySample / SystemSampler recovered by REA (inspect-macho exports).

struct BatteryInfo: Equatable {
    var level: Int
    var isCharging: Bool
    var isPluggedIn: Bool
    var minutesRemaining: Int?
}

struct SystemSample {
    var timestamp = Date()
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cpuPerCore: [Double] = []
    var loadAverage = 0.0
    var memoryTotal: UInt64 = 0
    var memoryApp: UInt64 = 0
    var memoryWired: UInt64 = 0
    var memoryCompressed: UInt64 = 0
    var memoryCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var memoryPressure = 0.0
    var netIn = 0.0
    var netOut = 0.0
    var diskRead = 0.0
    var diskWrite = 0.0
    var diskTotal: Int64 = 0
    var diskAvailable: Int64 = 0
    var gpu: Double?
    var battery: BatteryInfo?

    var cpuTotal: Double { cpuUser + cpuSystem }
    var memoryUsed: UInt64 { memoryApp + memoryWired + memoryCompressed }
}

final class SystemSampler {
    private typealias Ticks = (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)
    private var lastTicks: [Ticks] = []
    private var lastNet: (UInt64, UInt64)?
    private var lastDisk: (UInt64, UInt64)?
    private var lastAt: Date?
    private var diskSpace: (Int64, Int64) = (0, 0)
    private var diskSpaceAt = Date.distantPast
    private var battery: BatteryInfo?
    private var batteryAt = Date.distantPast

    func sample() -> SystemSample {
        var s = SystemSample()
        let now = Date()
        let dt = lastAt.map { now.timeIntervalSince($0) } ?? 0
        lastAt = now

        cpu(into: &s)
        memory(into: &s)

        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        s.loadAverage = la[0]

        let net = networkBytes()
        if let l = lastNet, dt > 0 {
            s.netIn = net.0 >= l.0 ? Double(net.0 - l.0) / dt : 0
            s.netOut = net.1 >= l.1 ? Double(net.1 - l.1) / dt : 0
        }
        lastNet = net

        let disk = diskBytes()
        if let l = lastDisk, dt > 0 {
            s.diskRead = disk.0 >= l.0 ? Double(disk.0 - l.0) / dt : 0
            s.diskWrite = disk.1 >= l.1 ? Double(disk.1 - l.1) / dt : 0
        }
        lastDisk = disk

        if now.timeIntervalSince(diskSpaceAt) > 30 {
            diskSpaceAt = now
            let url = URL(fileURLWithPath: "/")
            if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
                diskSpace = (Int64(v.volumeTotalCapacity ?? 0), v.volumeAvailableCapacityForImportantUsage ?? 0)
            }
        }
        s.diskTotal = diskSpace.0
        s.diskAvailable = diskSpace.1

        s.gpu = gpuUtilization()

        if now.timeIntervalSince(batteryAt) > 30 {
            batteryAt = now
            battery = Self.readBattery()
        }
        s.battery = battery
        return s
    }

    // MARK: CPU (host_processor_info, same import Vitals uses)

    private func cpu(into s: inout SystemSample) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [Ticks] = []
        for i in 0..<Int(count) {
            let b = Int(CPU_STATE_MAX) * i
            func t(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[b + Int(state)])) }
            ticks.append((t(CPU_STATE_USER), t(CPU_STATE_SYSTEM), t(CPU_STATE_IDLE), t(CPU_STATE_NICE)))
        }
        defer { lastTicks = ticks }
        guard lastTicks.count == ticks.count else { return }

        var sumUser = 0.0, sumSys = 0.0, sumAll = 0.0
        var perCore: [Double] = []
        for (n, o) in zip(ticks, lastTicks) {
            let du = Double(n.user &- o.user), ds = Double(n.system &- o.system)
            let di = Double(n.idle &- o.idle), dn = Double(n.nice &- o.nice)
            let total = du + ds + di + dn
            perCore.append(total > 0 ? (du + ds + dn) / total : 0)
            sumUser += du + dn
            sumSys += ds
            sumAll += total
        }
        s.cpuPerCore = perCore
        if sumAll > 0 {
            s.cpuUser = sumUser / sumAll
            s.cpuSystem = sumSys / sumAll
        }
    }

    // MARK: Memory (host_statistics64 + memorystatus level + swap)

    private func memory(into s: inout SystemSample) {
        s.memoryTotal = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        if kr == KERN_SUCCESS {
            let page = UInt64(vm_kernel_page_size)
            let internalPages = UInt64(stats.internal_page_count)
            let purgeable = UInt64(stats.purgeable_count)
            s.memoryApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.memoryWired = UInt64(stats.wire_count) * page
            s.memoryCompressed = UInt64(stats.compressor_page_count) * page
            s.memoryCached = (UInt64(stats.external_page_count) + purgeable) * page
        }
        var level: Int32 = 0
        var len = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &len, nil, 0) == 0 {
            s.memoryPressure = max(0, min(1, 1 - Double(level) / 100))
        }
        var xsw = xsw_usage()
        var xlen = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &xsw, &xlen, nil, 0) == 0 {
            s.swapUsed = xsw.xsu_used
        }
    }

    // MARK: Network (64-bit interface counters via NET_RT_IFLIST2)

    private func networkBytes() -> (UInt64, UInt64) {
        let rtmIfInfo2: UInt8 = 0x12
        let iftLoop: UInt8 = 0x18
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }
        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        buf.withUnsafeBytes { p in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = p.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if hdr.ifm_type == rtmIfInfo2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = p.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if h2.ifm_data.ifi_type != iftLoop {
                        inBytes &+= h2.ifm_data.ifi_ibytes
                        outBytes &+= h2.ifm_data.ifi_obytes
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return (inBytes, outBytes)
    }

    // MARK: Disk IO + GPU (IOKit registry, same keys found in Vitals' strings)

    private func forEachService(_ cls: String, _ body: (io_object_t) -> Void) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        var e = IOIteratorNext(iter)
        while e != 0 {
            body(e)
            IOObjectRelease(e)
            e = IOIteratorNext(iter)
        }
    }

    private func property(_ e: io_object_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
    }

    private func diskBytes() -> (UInt64, UInt64) {
        var r: UInt64 = 0, w: UInt64 = 0
        forEachService("IOBlockStorageDriver") { e in
            guard let stats = property(e, "Statistics") else { return }
            r &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            w &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (r, w)
    }

    private func gpuUtilization() -> Double? {
        var best: Double?
        forEachService("IOAccelerator") { e in
            guard let perf = property(e, "PerformanceStatistics"),
                  let u = (perf["Device Utilization %"] as? NSNumber)?.doubleValue else { return }
            best = max(best ?? 0, u / 100)
        }
        return best
    }

    // MARK: Battery (IOPS*)

    static func readBattery() -> BatteryInfo? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d["Type"] as? String) == "InternalBattery" else { continue }
            let cur = d["Current Capacity"] as? Int ?? 0
            let maxCap = d["Max Capacity"] as? Int ?? 100
            let tte = d["Time to Empty"] as? Int
            return BatteryInfo(
                level: maxCap > 0 ? cur * 100 / maxCap : cur,
                isCharging: d["Is Charging"] as? Bool ?? false,
                isPluggedIn: (d["Power Source State"] as? String) == "AC Power",
                minutesRemaining: (tte ?? -1) > 0 ? tte : nil)
        }
        return nil
    }
}
