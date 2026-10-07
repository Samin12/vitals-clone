import Foundation
import Darwin

// Mirrors VitalsCore.ProcessSample / RawUsage / ProcessSampler (proc_listpids, proc_pid_rusage,
// proc_pidinfo, proc_pidfdinfo, proc_pidpath — the libproc imports REA found in both binaries).

struct ProcessSample: Identifiable, Hashable {
    let pid: pid_t
    let ppid: pid_t
    let uid: uid_t
    let name: String
    let path: String
    let startTime: Date
    var memory: UInt64 = 0
    var cpu: Double = 0          // percent of one core (Activity Monitor style)
    var diskRead: Double = 0     // bytes/s
    var diskWrite: Double = 0
    var measured = false
    var gpu: Double = 0          // fraction of GPU time
    var netIn: Double = 0        // bytes/s
    var netOut: Double = 0
    var id: pid_t { pid }

    var uptime: TimeInterval { Date().timeIntervalSince(startTime) }
}

func cTupleString<T>(_ tuple: T) -> String {
    withUnsafeBytes(of: tuple) { raw in
        String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

final class ProcessSampler {
    private struct Prev { var cpuNs: UInt64; var read: UInt64; var write: UInt64; var at: UInt64 }
    private var prev: [pid_t: Prev] = [:]
    private var identity: [pid_t: (name: String, path: String, start: Date, ppid: pid_t, uid: uid_t)] = [:]
    private let numer: UInt64
    private let denom: UInt64

    init() {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer)
        denom = UInt64(max(tb.denom, 1))
    }

    private func ns(_ ticks: UInt64) -> UInt64 { ticks / denom * numer + (ticks % denom) * numer / denom }

    func sample() -> [ProcessSample] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        let now = ns(mach_absolute_time())
        var out: [ProcessSample] = []
        var seen = Set<pid_t>()

        for pid in pids.prefix(Int(got)) where pid > 0 {
            seen.insert(pid)
            guard let id = identityFor(pid) else { continue }
            var s = ProcessSample(pid: pid, ppid: id.ppid, uid: id.uid, name: id.name, path: id.path, startTime: id.start)

            var ri = rusage_info_v4()
            let rc = withUnsafeMutablePointer(to: &ri) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            if rc == 0 {
                s.measured = true
                s.memory = ri.ri_phys_footprint
                let cpuNs = ns(ri.ri_user_time &+ ri.ri_system_time)
                if let p = prev[pid], now > p.at {
                    let wall = Double(now - p.at)
                    s.cpu = cpuNs >= p.cpuNs ? Double(cpuNs - p.cpuNs) / wall * 100 : 0
                    let secs = wall / 1e9
                    s.diskRead = ri.ri_diskio_bytesread >= p.read ? Double(ri.ri_diskio_bytesread - p.read) / secs : 0
                    s.diskWrite = ri.ri_diskio_byteswritten >= p.write ? Double(ri.ri_diskio_byteswritten - p.write) / secs : 0
                }
                prev[pid] = Prev(cpuNs: cpuNs, read: ri.ri_diskio_bytesread, write: ri.ri_diskio_byteswritten, at: now)
            }
            out.append(s)
        }
        prev = prev.filter { seen.contains($0.key) }
        identity = identity.filter { seen.contains($0.key) }
        return out
    }

    private func identityFor(_ pid: pid_t) -> (name: String, path: String, start: Date, ppid: pid_t, uid: uid_t)? {
        if let c = identity[pid] { return c }
        var path = ""
        var pbuf = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pbuf, UInt32(pbuf.count)) > 0 { path = String(cString: pbuf) }

        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result: (name: String, path: String, start: Date, ppid: pid_t, uid: uid_t)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            var name = cTupleString(info.pbi_name)
            if name.isEmpty { name = cTupleString(info.pbi_comm) }
            if !path.isEmpty { name = (path as NSString).lastPathComponent }
            let start = Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec) + TimeInterval(info.pbi_start_tvusec) / 1e6)
            result = (name, path, start, pid_t(info.pbi_ppid), info.pbi_uid)
        } else {
            var short = proc_bsdshortinfo()
            let ss = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &short, ss) == ss else { return nil }
            let name = path.isEmpty ? cTupleString(short.pbsi_comm) : (path as NSString).lastPathComponent
            result = (name, path, Date(), pid_t(short.pbsi_ppid), short.pbsi_uid)
        }
        identity[pid] = result
        return result
    }

    // MARK: Listening TCP ports (ServerWatcher / "Ports" tab)

    static func listeningPorts(pid: pid_t) -> [UInt16] {
        let bufSize = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bufSize > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufSize) / stride + 8)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var ports = Set<UInt16>()
        for fd in fds.prefix(Int(used) / stride) where Int(fd.proc_fdtype) == Int(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let sz = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, sz) == sz else { continue }
            guard Int(si.psi.soi_kind) == Int(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard Int(tcp.tcpsi_state) == Int(TSI_S_LISTEN) else { continue }
            let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }

    // MARK: Working directory (ProjectLocator)

    static func workingDirectory(pid: pid_t) -> String? {
        var v = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &v, sz) == sz else { return nil }
        let p = cTupleString(v.pvi_cdir.vip_path)
        return p.isEmpty ? nil : p
    }
}
