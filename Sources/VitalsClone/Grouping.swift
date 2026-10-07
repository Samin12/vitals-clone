import Foundation
import AppKit
import IOKit.pwr_mgt

// Mirrors VitalsCore.AppGrouper / AppGroup / GroupKind, ProjectGrouper / DevProject,
// SleepBlockers / SleepBlocker and IdleServer (names + fields recovered by REA).

enum GroupKind: String { case app, commandLine, system }

struct AppGroup: Identifiable {
    let id: String          // canonical ID: outermost .app bundle path, or exec path
    let name: String
    let kind: GroupKind
    let bundlePath: String?
    var processes: [ProcessSample]

    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
    var diskIO: Double { processes.reduce(0) { $0 + $1.diskRead + $1.diskWrite } }
    var gpu: Double { processes.reduce(0) { $0 + $1.gpu } }
    var netIn: Double { processes.reduce(0) { $0 + $1.netIn } }
    var netOut: Double { processes.reduce(0) { $0 + $1.netOut } }
    var diskWrite: Double { processes.reduce(0) { $0 + $1.diskWrite } }
    var icon: NSImage? { bundlePath.map(IconCache.icon) }
}

enum AppGrouper {
    static let systemGroupID = "system"

    /// Outermost `.app` in the path, so helpers (Chrome Helper, Slack Helper…) fold into the parent app.
    static func outermostApp(_ path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return path.hasSuffix(".app") ? path : nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    static func group(_ processes: [ProcessSample]) -> [AppGroup] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        let myUID = getuid()
        var groups: [String: AppGroup] = [:]

        for p in processes {
            var key: String
            var name: String
            var kind: GroupKind
            var bundle: String?

            if let app = outermostApp(p.path) {
                key = app; bundle = app; kind = .app
                name = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
            } else if p.uid != myUID || p.path.hasPrefix("/System/") || p.path.hasPrefix("/usr/libexec") || p.path.hasPrefix("/usr/sbin") || p.path.isEmpty {
                key = systemGroupID; name = "macOS"; kind = .system
            } else {
                // Command-line tool: attribute to the app that launched it (terminal, editor) if any ancestor is an app.
                var cur = p.ppid, hops = 0
                var found: String?
                while cur > 1, hops < 12, let parent = byPID[cur] {
                    if let app = outermostApp(parent.path) { found = app; break }
                    cur = parent.ppid; hops += 1
                }
                if let app = found {
                    key = app; bundle = app; kind = .app
                    name = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
                } else {
                    key = "exec:" + p.path; name = p.name; kind = .commandLine
                }
            }
            groups[key, default: AppGroup(id: key, name: name, kind: kind, bundlePath: bundle, processes: [])].processes.append(p)
        }
        return Array(groups.values)
    }
}

// MARK: Projects ("An activity monitor that thinks in apps and projects")

struct DevProject: Identifiable {
    let id: String        // project root path
    let name: String
    var processes: [ProcessSample]
    var ports: [UInt16]
    var memory: UInt64 { processes.reduce(0) { $0 + $1.memory } }
    var cpu: Double { processes.reduce(0) { $0 + $1.cpu } }
}

enum ProjectGrouper {
    private static var rootCache: [String: String?] = [:]
    private static let markers = [".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "Package.swift", "Gemfile", "docker-compose.yml", "compose.yaml"]

    /// Walk up from a working directory to the nearest folder with a .git folder or project file.
    static func projectRoot(for dir: String) -> String? {
        if let c = rootCache[dir] { return c }
        let home = NSHomeDirectory()
        var cur = dir
        var result: String?
        while cur.hasPrefix(home), cur != home {
            if markers.contains(where: { FileManager.default.fileExists(atPath: cur + "/" + $0) }) {
                result = cur
                if FileManager.default.fileExists(atPath: cur + "/.git") { break }
            }
            cur = (cur as NSString).deletingLastPathComponent
        }
        rootCache[dir] = result
        return result
    }

    static func projects(in processes: [ProcessSample]) -> [DevProject] {
        let myUID = getuid()
        var out: [String: DevProject] = [:]
        for p in processes where p.uid == myUID && AppGrouper.outermostApp(p.path) == nil {
            guard let cwd = ProcessSampler.workingDirectory(pid: p.pid), let root = projectRoot(for: cwd) else { continue }
            let ports = ProcessSampler.listeningPorts(pid: p.pid)
            out[root, default: DevProject(id: root, name: (root as NSString).lastPathComponent, processes: [], ports: [])].processes.append(p)
            out[root]!.ports.append(contentsOf: ports)
        }
        return out.values.map { var p = $0; p.ports = Array(Set(p.ports)).sorted(); return p }
            .sorted { $0.memory > $1.memory }
    }
}

// MARK: Ports

struct ListeningPort: Identifiable {
    let port: UInt16
    let process: ProcessSample
    let project: String?
    var id: String { "\(process.pid):\(port)" }
    var isDynamic: Bool { port >= 49152 }   // UInt16.firstDynamicPort
}

// MARK: Sleep blockers ("Keeping This Mac Awake")

struct SleepBlocker: Identifiable {
    enum Kind: String { case display = "Keeps the screen on", system = "Keeps the Mac awake" }
    let pid: pid_t
    let processName: String
    let kind: Kind
    let reason: String
    var id: String { "\(pid)-\(kind)-\(reason)" }
}

enum SleepBlockers {
    static func current() -> [SleepBlocker] {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let d = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        var out: [SleepBlocker] = []
        for (pidNum, list) in d {
            for a in list {
                let type = a["AssertType"] as? String ?? ""
                let kind: SleepBlocker.Kind
                switch type {
                case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": kind = .display
                case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion": kind = .system
                default: continue
                }
                let name = a["Process Name"] as? String ?? "pid \(pidNum)"
                if name == "powerd" || name == "coreaudiod" && kind == .system { continue }
                let reason = (a["AssertName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "No reason given"
                out.append(SleepBlocker(pid: pidNum.int32Value, processName: name, kind: kind, reason: reason))
            }
        }
        return out.sorted { $0.processName < $1.processName }
    }
}

// MARK: Idle servers (ServerWatcher)

struct IdleServer: Identifiable {
    let process: ProcessSample
    let ports: [UInt16]
    let project: String?
    let idleFor: TimeInterval
    var id: pid_t { process.pid }
}

final class ServerWatcher {
    // Defaults inferred from VitalsCore.ServerWatcher.Thresholds field names.
    var busyCPUPercent = 2.0
    var idleWindow: TimeInterval = 30 * 60
    var minimumUptime: TimeInterval = 60 * 60
    var minimumMemory: UInt64 = 50 * 1024 * 1024
    private var lastBusy: [pid_t: Date] = [:]
    private let watchingSince = Date()

    func ingest(_ ports: [ListeningPort], at now: Date = Date()) -> [IdleServer] {
        var byPID: [pid_t: (ProcessSample, [UInt16], String?)] = [:]
        for lp in ports { byPID[lp.process.pid, default: (lp.process, [], lp.project)].1.append(lp.port) }
        var out: [IdleServer] = []
        for (pid, (p, ps, proj)) in byPID {
            if p.cpu >= busyCPUPercent || lastBusy[pid] == nil { lastBusy[pid] = lastBusy[pid] == nil ? max(watchingSince, p.startTime) : now }
            if p.cpu >= busyCPUPercent { lastBusy[pid] = now }
            let idle = now.timeIntervalSince(lastBusy[pid]!)
            if idle >= idleWindow, p.uptime >= minimumUptime, p.memory >= minimumMemory {
                out.append(IdleServer(process: p, ports: ps, project: proj, idleFor: idle))
            }
        }
        lastBusy = lastBusy.filter { byPID[$0.key] != nil }
        return out.sorted { $0.process.memory > $1.process.memory }
    }
}
