import Foundation
import AppKit
import Observation
import UserNotifications

// Mirrors Vitals/MonitorStore.swift + VitalsCore.InsightEngine (thresholds named in the binary).

struct Insight: Identifiable {
    // Kinds + fields match ~/Library/Application Support/Vitals/insights.json written by the real app.
    enum Kind: String { case sustainedCPU, memoryGrowth, memoryPressure, idleServers, networkBurst, diskBurst }
    let id = UUID()
    var date: Date
    let kind: Kind
    let key: String
    let groupID: String
    let bundlePath: String?
    let title: String
    var detail: String
    var count = 1
}

final class InsightEngine {
    var cpuPercent = 70.0
    var cpuWindow: TimeInterval = 10 * 60
    var memoryGrowthBytes: UInt64 = 1 << 30
    var memoryWindow: TimeInterval = 60 * 60
    var networkBurstBytes: Double = 1_073_741_824
    var diskBurstBytes: Double = 5_368_709_120
    var burstWindow: TimeInterval = 10 * 60
    var cooldown: TimeInterval = 60 * 60
    var idleServerCount = 3

    private struct Point { let at: Date; let cpu: Double; let mem: UInt64; let net: Double; let disk: Double }
    private var history: [String: [Point]] = [:]
    private var lastFired: [String: Date] = [:]
    private var lastPressureHigh = false

    func ingest(_ groups: [AppGroup], system: SystemSample, idleServers: Int, interval: TimeInterval, at now: Date = Date()) -> [Insight] {
        var out: [Insight] = []
        for g in groups where g.kind != .system || true {
            var h = history[g.id, default: []]
            h.append(Point(at: now, cpu: g.cpu, mem: g.memory, net: (g.netIn + g.netOut) * interval, disk: g.diskIO * interval))
            h.removeAll { now.timeIntervalSince($0.at) > max(cpuWindow, memoryWindow) }
            history[g.id] = h

            let cpuSlice = h.filter { now.timeIntervalSince($0.at) <= cpuWindow }
            if let first = cpuSlice.first, now.timeIntervalSince(first.at) >= cpuWindow * 0.9 {
                let avg = cpuSlice.map(\.cpu).reduce(0, +) / Double(cpuSlice.count)
                if avg >= cpuPercent {
                    fire(g, "cpu", now, &out, .sustainedCPU, "\(g.name) is keeping the CPU busy",
                         "\(Int(avg))% on average for the last \(Int(cpuWindow / 60)) minutes.")
                }
            }
            if let first = h.first, now.timeIntervalSince(first.at) >= memoryWindow * 0.3,
               g.memory > first.mem, g.memory - first.mem >= memoryGrowthBytes {
                let mins = Int(now.timeIntervalSince(first.at) / 60)
                fire(g, "mem", now, &out, .memoryGrowth, "\(g.name) is using more and more memory",
                     "Up \(fmtBytes(g.memory - first.mem)) in the last \(mins) minutes, now at \(fmtBytes(g.memory)).")
            }
            let burst = h.filter { now.timeIntervalSince($0.at) <= burstWindow }
            let net = burst.map(\.net).reduce(0, +), disk = burst.map(\.disk).reduce(0, +)
            if net >= networkBurstBytes {
                fire(g, "net", now, &out, .networkBurst, "\(g.name) is moving a lot of data",
                     "\(fmtBytes(Int64(net))) over the network in the last \(Int(burstWindow / 60)) minutes.")
            }
            if disk >= diskBurstBytes {
                fire(g, "disk", now, &out, .diskBurst, "\(g.name) is working the disk hard",
                     "\(fmtBytes(Int64(disk))) read and written in the last \(Int(burstWindow / 60)) minutes.")
            }
        }
        history = history.filter { k, _ in groups.contains { $0.id == k } }

        let high = system.memoryPressure >= 0.5
        if high && !lastPressureHigh {
            fireRaw("pressure", now, &out, Insight(date: now, kind: .memoryPressure, key: "pressure", groupID: AppGrouper.systemGroupID, bundlePath: nil,
                                                   title: "Memory pressure went up", detail: "macOS is working hard to keep memory free."))
        }
        lastPressureHigh = high
        if idleServers >= idleServerCount {
            fireRaw("idle", now, &out, Insight(date: now, kind: .idleServers, key: "idle", groupID: "", bundlePath: nil,
                                               title: "\(idleServers) dev servers are running but idle", detail: "They hold memory and ports. Stop the ones you’re done with."))
        }
        return out
    }

    private func fire(_ g: AppGroup, _ k: String, _ now: Date, _ out: inout [Insight], _ kind: Insight.Kind, _ title: String, _ detail: String) {
        fireRaw("\(k):\(g.id)", now, &out, Insight(date: now, kind: kind, key: "\(k):\(g.id)", groupID: g.id, bundlePath: g.bundlePath, title: title, detail: detail))
    }

    private func fireRaw(_ key: String, _ now: Date, _ out: inout [Insight], _ i: Insight) {
        if let l = lastFired[key], now.timeIntervalSince(l) < cooldown { return }
        lastFired[key] = now
        out.append(i)
    }
}

@Observable
final class MonitorStore {
    var system = SystemSample()
    var cpuHistory: [Double] = []
    var memHistory: [Double] = []
    var netInHistory: [Double] = []
    var netOutHistory: [Double] = []
    var gpuHistory: [Double] = []
    var diskHistory: [Double] = []
    var cpuDaySum = 0.0
    var cpuDayCount = 0.0
    var gpuSum = 0.0
    var gpuCount = 0.0
    var gpuPeak = 0.0
    var downloadedSession: Double = 0
    var uploadedSession: Double = 0
    var writtenSession: Double = 0
    var readSession: Double = 0
    var netReady = false
    var groups: [AppGroup] = []
    var projects: [DevProject] = []
    var ports: [ListeningPort] = []
    var blockers: [SleepBlocker] = []
    var idleServers: [IdleServer] = []
    var insights: [Insight] = []
    var unmeasuredCount = 0
    var interval: TimeInterval = 2
    var tab: VitalsTab = .overview

    private let sys = SystemSampler()
    private let proc = ProcessSampler()
    private let watcher = ServerWatcher()
    private let engine = InsightEngine()
    private let gpuSampler = GPUSampler()
    private let netSampler = NetSampler()
    private var appNet: [pid_t: (Double, Double)] = [:]
    private let queue = DispatchQueue(label: "vitals.sampler", qos: .utility)
    private var timer: Timer?
    private var tick = 0

    init() {
        _ = sys.sample(); _ = proc.sample()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.refresh() }
        schedule()
        if canNotify { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
    }

    func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        tick += 1
        if tick % 15 == 1 { netSampler.refresh { [weak self] r in self?.appNet = r; self?.netReady = true } }
        let heavy = tick % 3 == 1   // ports / projects / blockers are pricier: every 3rd tick
        queue.async { [self] in
            let s = sys.sample()
            var procs = proc.sample()
            let gpuByPID = gpuSampler.sample()
            let net = DispatchQueue.main.sync { appNet }
            for i in procs.indices {
                procs[i].gpu = gpuByPID[procs[i].pid] ?? 0
                if let n = net[procs[i].pid] { procs[i].netIn = n.0; procs[i].netOut = n.1 }
            }
            let groups = AppGrouper.group(procs).sorted { $0.cpu + Double($0.memory) / 1e10 > $1.cpu + Double($1.memory) / 1e10 }
            var projects: [DevProject]?
            var ports: [ListeningPort]?
            var blockers: [SleepBlocker]?
            if heavy {
                let mine = procs.filter { $0.uid == getuid() }
                projects = ProjectGrouper.projects(in: procs)
                ports = mine.flatMap { p in
                    ProcessSampler.listeningPorts(pid: p.pid).map { port in
                        ListeningPort(port: port, process: p,
                                      project: ProcessSampler.workingDirectory(pid: p.pid).flatMap(ProjectGrouper.projectRoot).map { ($0 as NSString).lastPathComponent })
                    }
                }.sorted { $0.port < $1.port }
                blockers = SleepBlockers.current()
            }
            let unmeasured = procs.filter { !$0.measured }.count
            DispatchQueue.main.async { [self] in
                system = s
                push(&cpuHistory, s.cpuTotal); push(&memHistory, Double(s.memoryUsed) / Double(max(s.memoryTotal, 1)))
                push(&netInHistory, s.netIn); push(&netOutHistory, s.netOut)
                push(&gpuHistory, s.gpu ?? 0); push(&diskHistory, s.diskRead + s.diskWrite)
                cpuDaySum += s.cpuTotal; cpuDayCount += 1
                if let g = s.gpu { gpuSum += g; gpuCount += 1; gpuPeak = max(gpuPeak, g) }
                downloadedSession += s.netIn * interval; uploadedSession += s.netOut * interval
                writtenSession += s.diskWrite * interval; readSession += s.diskRead * interval
                self.groups = groups
                unmeasuredCount = unmeasured
                if let projects { self.projects = projects }
                if let ports {
                    self.ports = ports
                    idleServers = watcher.ingest(ports)
                }
                if let blockers { self.blockers = blockers }
                let new = engine.ingest(groups, system: s, idleServers: idleServers.count, interval: interval)
                if !new.isEmpty {
                    for n in new {
                        if let i = insights.firstIndex(where: { $0.key == n.key }) {
                            var old = insights.remove(at: i)
                            old.count += 1; old.date = n.date; old.detail = n.detail
                            insights.insert(old, at: 0)
                        } else { insights.insert(n, at: 0) }
                    }
                    insights = Array(insights.prefix(50))
                    for i in new { notify(i) }
                }
            }
        }
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v); if a.count > 150 { a.removeFirst(a.count - 150) }
    }

    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    private func notify(_ i: Insight) {
        guard canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = i.title; c.body = i.detail
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: i.key, content: c, trigger: nil))
    }

    // MARK: Actions (ProcessActions.swift: Quit asks first, Force Quit ends at once)

    func quit(_ pids: [pid_t], force: Bool) {
        for pid in pids {
            if !force, let app = NSRunningApplication(processIdentifier: pid) { app.terminate() }
            else { kill(pid, force ? SIGKILL : SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.refresh() }
    }

    func quitGroup(_ g: AppGroup, force: Bool) {
        if !force, let b = g.bundlePath,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.path == b }) {
            app.terminate()
        } else {
            quit(g.processes.map(\.pid), force: force)
        }
    }
}

