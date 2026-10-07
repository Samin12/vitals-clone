import Foundation

/// `VitalsClone --dump` prints one real sample of every subsystem and exits (verification aid).
enum SelfTest {
    static func run() -> Never {
        let sys = SystemSampler(), proc = ProcessSampler()
        _ = sys.sample(); _ = proc.sample()
        Thread.sleep(forTimeInterval: 2)
        let s = sys.sample()
        let procs = proc.sample()
        print(String(format: "CPU %.1f%% (user %.1f, sys %.1f) cores=%d load=%.2f", s.cpuTotal * 100, s.cpuUser * 100, s.cpuSystem * 100, s.cpuPerCore.count, s.loadAverage))
        print("MEM used \(fmtBytes(s.memoryUsed)) / \(fmtBytes(s.memoryTotal)) app=\(fmtBytes(s.memoryApp)) wired=\(fmtBytes(s.memoryWired)) compressed=\(fmtBytes(s.memoryCompressed)) cached=\(fmtBytes(s.memoryCached)) swap=\(fmtBytes(s.swapUsed)) pressure=\(pct(s.memoryPressure))")
        print("NET in \(fmtRate(s.netIn)) out \(fmtRate(s.netOut)) | DISK r \(fmtRate(s.diskRead)) w \(fmtRate(s.diskWrite)) free \(fmtBytes(s.diskAvailable)) of \(fmtBytes(s.diskTotal))")
        print("GPU \(s.gpu.map(pct) ?? "n/a") | battery \(s.battery.map { "\($0.level)%" } ?? "none")")
        let groups = AppGrouper.group(procs).sorted { $0.memory > $1.memory }
        print("PROCESSES \(procs.count) (unmeasured \(procs.filter { !$0.measured }.count)) → \(groups.count) apps")
        for g in groups.prefix(8) { print(String(format: "  %-28@ %6.1f%%  %@  (%d procs)", g.name as NSString, g.cpu, fmtBytes(g.memory) as NSString, g.processes.count)) }
        let projects = ProjectGrouper.projects(in: procs)
        print("PROJECTS \(projects.count)")
        for p in projects.prefix(6) { print("  \(p.name)  \(p.processes.count) procs  \(fmtBytes(p.memory))  ports \(p.ports)") }
        let mine = procs.filter { $0.uid == getuid() }
        let ports = mine.flatMap { p in ProcessSampler.listeningPorts(pid: p.pid).map { ($0, p.name) } }.sorted { $0.0 < $1.0 }
        print("PORTS \(ports.count): " + ports.prefix(15).map { ":\($0.0) \($0.1)" }.joined(separator: ", "))
        let b = SleepBlockers.current()
        print("AWAKE \(b.count): " + b.prefix(6).map { "\($0.processName) [\($0.kind.rawValue)] \($0.reason)" }.joined(separator: " | "))
        exit(0)
    }
}
