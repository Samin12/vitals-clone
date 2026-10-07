import Foundation
import IOKit

// Per-app GPU time: AGXDeviceUserClient children of IOAccelerator expose IOUserClientCreator
// ("pid N, name") and AppUsage[].accumulatedGPUTime (ns). Vitals imports
// IORegistryEntryGetChildIterator for exactly this walk.
final class GPUSampler {
    private var prev: [pid_t: UInt64] = [:]
    private var prevAt: UInt64 = 0

    func sample() -> [pid_t: Double] {
        var totals: [pid_t: UInt64] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iter) }
        var acc = IOIteratorNext(iter)
        while acc != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(acc, kIOServicePlane, &children) == KERN_SUCCESS {
                var c = IOIteratorNext(children)
                while c != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [[String: Any]] {
                        let head = creator.split(separator: ",").first ?? ""
                        let parts = head.split(separator: " ")
                        if parts.count == 2, let pid = Int32(parts[1]) {
                            let t = usage.reduce(UInt64(0)) { $0 &+ ((($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value) ?? 0) }
                            totals[pid, default: 0] &+= t
                        }
                    }
                    IOObjectRelease(c)
                    c = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(acc)
            acc = IOIteratorNext(iter)
        }
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var out: [pid_t: Double] = [:]
        if prevAt > 0, now > prevAt {
            let wall = Double(now - prevAt)
            for (pid, t) in totals { if let p = prev[pid], t >= p { out[pid] = min(1, Double(t - p) / wall) } }
        }
        prev = totals
        prevAt = now
        return out
    }
}

// Per-app network: "Per-app data use is checked every 30 seconds" (Vitals string). We read the same
// per-process byte counters via nettop on that cadence.
final class NetSampler {
    private var prev: [pid_t: (UInt64, UInt64)] = [:]
    private var prevAt: Date?
    private let queue = DispatchQueue(label: "vitals.net", qos: .utility)
    private var running = false

    func refresh(_ done: @escaping ([pid_t: (Double, Double)]) -> Void) {
        guard !running else { return }
        running = true
        queue.async { [self] in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
            p.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            var cur: [pid_t: (UInt64, UInt64)] = [:]
            if (try? p.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
                    let f = line.split(separator: ",", omittingEmptySubsequences: false)
                    guard f.count >= 3, let dot = f[0].lastIndex(of: "."),
                          let pid = Int32(f[0][f[0].index(after: dot)...]),
                          let i = UInt64(f[1]), let o = UInt64(f[2]) else { continue }
                    cur[pid] = (i, o)
                }
            }
            let now = Date()
            var rates: [pid_t: (Double, Double)] = [:]
            if let at = prevAt {
                let dt = now.timeIntervalSince(at)
                for (pid, v) in cur {
                    guard let p = prev[pid] else { continue }
                    rates[pid] = (v.0 >= p.0 ? Double(v.0 - p.0) / dt : 0, v.1 >= p.1 ? Double(v.1 - p.1) / dt : 0)
                }
            }
            prev = cur
            prevAt = now
            running = false
            DispatchQueue.main.async { done(rates) }
        }
    }
}

enum Hardware {
    static func sysctlString(_ name: String) -> String? {
        var len = 0
        guard sysctlbyname(name, nil, &len, nil, 0) == 0, len > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: len)
        guard sysctlbyname(name, &buf, &len, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
    static func sysctlInt(_ name: String) -> Int {
        var v: Int32 = 0
        var len = MemoryLayout<Int32>.size
        return sysctlbyname(name, &v, &len, nil, 0) == 0 ? Int(v) : 0
    }
    static let chip = sysctlString("machdep.cpu.brand_string") ?? "Mac"
    static let cores = ProcessInfo.processInfo.activeProcessorCount
    static let pCores = sysctlInt("hw.perflevel0.logicalcpu")
    static let eCores = sysctlInt("hw.perflevel1.logicalcpu")
    static let memory = ProcessInfo.processInfo.physicalMemory
    static var bootTime: Date = {
        var tv = timeval()
        var len = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        sysctl(&mib, 2, &tv, &len, nil, 0)
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }()
    static var summary: String {
        "\(chip) · \(cores) cores · \(ByteCountFormatter.string(fromByteCount: Int64(memory), countStyle: .memory).replacingOccurrences(of: ".0", with: ""))"
    }
}
