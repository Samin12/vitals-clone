import SwiftUI
import AppKit

// Main window, matched to the real Vitals window: unified toolbar with title + subtitle on the left,
// a capsule tab bar in the centre (selected tab expands with its tinted label), filter field + gear
// on the right; scrolling content; a status bar along the bottom.

struct ConfirmQuit: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let action: (Bool) -> Void
}

struct MainWindowView: View {
    @Environment(MonitorStore.self) var store
    @State private var filter = ""
    @State private var confirm: ConfirmQuit?

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Group {
                switch store.tab {
                case .overview: OverviewTab(filter: filter, confirm: $confirm)
                case .projects: ProjectsTab(confirm: $confirm)
                default: MetricTab(tab: store.tab, filter: filter, confirm: $confirm)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            StatusBar()
        }
        .background(Theme.bg)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Vitals").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(Hardware.summary).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                }
                .padding(.horizontal, 6)
            }
            ToolbarItem(placement: .principal) { TabCapsule(selection: $store.tab) }
            ToolbarItemGroup(placement: .primaryAction) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    TextField("Filter apps", text: $filter).textFieldStyle(.plain).font(.system(size: 13)).frame(width: 110)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Theme.card, in: Capsule())
                .help("Show only apps whose name contains this (⌘F)")
            }
        }
        .toolbar(removing: .title)
        .alert(item: $confirm) { c in
            Alert(title: Text(c.title), message: Text(c.message),
                  primaryButton: .destructive(Text("Quit")) { c.action(false) },
                  secondaryButton: .cancel())
        }
        .frame(minWidth: 1000, minHeight: 640)
    }
}

struct TabCapsule: View {
    @Binding var selection: VitalsTab
    var body: some View {
        HStack(spacing: 2) {
            ForEach(VitalsTab.allCases) { t in
                let on = t == selection
                Button { withAnimation(.snappy(duration: 0.25)) { selection = t } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                        if on { Text(t.title).font(.system(size: 13, weight: .semibold)).fixedSize() }
                    }
                    .foregroundStyle(on ? t.tint : Theme.ink2)
                    .padding(.horizontal, on ? 12 : 9).frame(height: 28)
                    .background(on ? t.tint.opacity(0.13) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(t.title) (⌘\(t.rawValue + 1))")
                .keyboardShortcut(KeyEquivalent(Character("\(t.rawValue + 1)")), modifiers: .command)
            }
        }
        .padding(3)
        .background(Theme.card, in: Capsule())
        .overlay(Capsule().stroke(Theme.line))
    }
}

struct StatusBar: View {
    @Environment(MonitorStore.self) var store
    var body: some View {
        let procs = store.groups.reduce(0) { $0 + $1.processes.count }
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(store.groups.count) apps · \(procs.formatted()) processes")
                Spacer()
                if store.unmeasuredCount > 0 {
                    Image(systemName: "checkmark.shield")
                    Text("\(store.unmeasuredCount) system processes aren’t measured, so the list adds up to less than the total")
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .font(.system(size: 11)).foregroundStyle(Theme.ink2)
            .padding(.horizontal, 14).frame(height: 26)
        }
    }
}

// MARK: Overview

struct OverviewTab: View {
    @Environment(MonitorStore.self) var store
    let filter: String
    @Binding var confirm: ConfirmQuit?
    @State private var showAllInsights = false

    var body: some View {
        let s = store.system
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3), spacing: 16) {
                    OverviewCard(tab: .cpu, caption: "Now", value: pctNum(s.cpuTotal), unit: "%", extra: nil, pill: nil,
                                 stats: [("User", pct(s.cpuUser), nil), ("System", pct(s.cpuSystem), nil),
                                         ("Average", pct(store.cpuDaySum / max(store.cpuDayCount, 1)), nil),
                                         ("Uptime", fmtDuration(Date().timeIntervalSince(Hardware.bootTime)), nil)],
                                 values: store.cpuHistory, maxValue: 1)
                    let mem = splitUnit(fmtBytes(s.memoryUsed))
                    OverviewCard(tab: .memory, caption: "In Use of \(fmtBytes(s.memoryTotal).replacingOccurrences(of: ".0", with: ""))",
                                 value: mem.0, unit: mem.1, extra: nil, pill: pressurePill(s),
                                 stats: [("App", fmtBytes(s.memoryApp), Theme.cpu), ("Wired", fmtBytes(s.memoryWired), Theme.projects),
                                         ("Compressed", fmtBytes(s.memoryCompressed).replacingOccurrences(of: "Zero KB", with: "0 bytes"), Theme.network)],
                                 values: store.memHistory, maxValue: 1)
                    OverviewCard(tab: .gpu, caption: Hardware.chip, value: s.gpu.map(pctNum) ?? "—", unit: "%", extra: nil, pill: nil,
                                 stats: [("Busiest", store.groups.max { $0.gpu < $1.gpu }.map { $0.gpu > 0.005 ? $0.name : "—" } ?? "—", nil),
                                         ("Average", pct(store.gpuSum / max(store.gpuCount, 1)), nil), ("Peak", pct(store.gpuPeak), nil)],
                                 values: store.gpuHistory, maxValue: 1)
                    let free = splitUnit(fmtBytes(s.diskAvailable))
                    let usedPct = Double(s.diskTotal - s.diskAvailable) / Double(max(s.diskTotal, 1))
                    OverviewCard(tab: .disk, caption: "Free of \(fmtBytes(s.diskTotal))", value: free.0, unit: free.1,
                                 extra: "\(pct(usedPct)) used", pill: nil,
                                 stats: [("Reading", fmtRate(s.diskRead), nil), ("Writing", fmtRate(s.diskWrite), nil),
                                         ("Written", fmtBytes(Int64(store.writtenSession)), nil)],
                                 values: store.diskHistory, maxValue: nil)
                    let down = splitUnit(fmtRate(s.netIn))
                    OverviewCard(tab: .network, caption: "Downloading", value: down.0, unit: down.1,
                                 extra: "↑ \(fmtRate(s.netOut))", pill: nil,
                                 stats: [("Downloaded", fmtBytes(Int64(store.downloadedSession)), nil),
                                         ("Uploaded", fmtBytes(Int64(store.uploadedSession)), nil),
                                         ("Interface", primaryInterface(), nil)],
                                 values: store.netInHistory, maxValue: nil)
                    ProjectsOverviewCard()
                }

                if !store.insights.isEmpty {
                    SectionHeader(title: "Worth a Look",
                                  trailing: store.insights.count > 3 ? (showAllInsights ? "Show Less" : "Show All \(store.insights.count)") : nil) {
                        showAllInsights.toggle()
                    }
                    .padding(.top, 28).padding(.bottom, 12)
                    VStack(spacing: 0) {
                        let list = showAllInsights ? store.insights : Array(store.insights.prefix(3))
                        ForEach(Array(list.enumerated()), id: \.element.id) { i, ins in
                            InsightRowView(insight: ins)
                            if i < list.count - 1 { Divider().padding(.leading, 56) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                SectionHeader(title: "Right Now").padding(.top, 30).padding(.bottom, 8)
                AppTable(primary: .cpu, filter: filter, confirm: $confirm, limit: 25)
            }
            .padding(20)
        }
    }

    func pressurePill(_ s: SystemSample) -> (String, Color, String)? {
        let p = s.memoryPressure
        if p < 0.5 { return ("Normal · \(pct(p))", Theme.green, "checkmark.circle.fill") }
        if p < 0.8 { return ("Elevated · \(pct(p))", Theme.disk, "exclamationmark.circle.fill") }
        return ("High · \(pct(p))", Theme.red, "exclamationmark.triangle.fill")
    }
}

func primaryInterface() -> String {
    var addrs: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&addrs) == 0, let first = addrs else { return "—" }
    defer { freeifaddrs(addrs) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let a = p {
        let name = String(cString: a.pointee.ifa_name)
        if name.hasPrefix("en"), a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) {
            return name == "en0" ? "Ethernet en0" : "Wi-Fi \(name)"
        }
        p = a.pointee.ifa_next
    }
    return "—"
}

struct OverviewCard: View {
    @Environment(MonitorStore.self) var store
    let tab: VitalsTab
    let caption: String
    let value: String
    let unit: String
    let extra: String?
    let pill: (String, Color, String)?
    let stats: [(String, String, Color?)]
    let values: [Double]
    let maxValue: Double?
    @State private var hover = false

    var body: some View {
        Button { withAnimation(.snappy) { store.tab = tab } } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: tab.icon).font(.system(size: 13, weight: .semibold))
                    Text(tab.title).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(tab.tint)
                Text(caption).font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1).padding(.top, 12)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BigNumber(value: value, unit: unit)
                    if let extra { Text(extra).font(.system(size: 14)).foregroundStyle(Theme.ink2).lineLimit(1) }
                    Spacer(minLength: 0)
                    if let pill { Pill(text: pill.0, color: pill.1, symbol: pill.2) }
                }
                HStack(alignment: .top, spacing: 8) {
                    ForEach(stats.indices, id: \.self) { i in StatColumn(label: stats[i].0, value: stats[i].1, dot: stats[i].2) }
                }
                .padding(.top, 6)
                Spacer(minLength: 10)
                BarSpark(values: values, color: tab.tint, maxValue: maxValue).frame(height: 30)
            }
            .padding(EdgeInsets(top: 16, leading: 17, bottom: 14, trailing: 17))
            .frame(height: 198)
            .background(hover ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct ProjectsOverviewCard: View {
    @Environment(MonitorStore.self) var store
    @State private var hover = false
    var body: some View {
        let mem = store.projects.reduce(UInt64(0)) { $0 + $1.memory }
        let portCount = store.ports.count
        Button { withAnimation(.snappy) { store.tab = .projects } } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: VitalsTab.projects.icon).font(.system(size: 13, weight: .semibold))
                    Text("Projects").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                }
                .foregroundStyle(Theme.projects)
                Text("\(fmtBytes(mem)) · \(portCount) ports open").font(.system(size: 11)).foregroundStyle(Theme.ink2).padding(.top, 12)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    BigNumber(value: "\(store.projects.count)", unit: store.projects.count == 1 ? "project" : "projects")
                    Spacer()
                    if !store.idleServers.isEmpty { Pill(text: "\(store.idleServers.count) idle", color: Theme.projects, symbol: "moon.zzz.fill") }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.projects.prefix(3)) { p in
                        HStack {
                            Text(p.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            if let port = p.ports.first { Text(String(port)).font(.system(size: 11)).foregroundStyle(Theme.ink2).monospacedDigit() }
                            Spacer()
                            Text(fmtBytes(p.memory)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.ink2)
                        }
                    }
                    if store.projects.isEmpty { Text("Nothing is running inside a project folder.").font(.system(size: 12)).foregroundStyle(Theme.ink2) }
                }
                .padding(.top, 8)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 16, leading: 17, bottom: 14, trailing: 17))
            .frame(height: 198)
            .background(hover ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct InsightRowView: View {
    let insight: Insight
    @Environment(MonitorStore.self) var store
    @State private var hover = false
    var body: some View {
        let g = store.groups.first { $0.id == insight.groupID }
        HStack(spacing: 12) {
            Group {
                if let path = insight.bundlePath { Image(nsImage: IconCache.icon(path)).resizable() }
                else { Image(systemName: insight.groupID == AppGrouper.systemGroupID ? "apple.logo" : "waveform.path.ecg").resizable().scaledToFit().foregroundStyle(Theme.ink2).padding(3) }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(insight.title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if insight.count > 1 {
                        Text("\(insight.count)×").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Theme.ink.opacity(0.07), in: Capsule())
                    }
                }
                Text(insight.detail).font(.system(size: 12.5)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer()
            if let g {
                Text("Now \(insight.kind.nowValue(g))").font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(Theme.ink)
            }
            Pill(text: insight.kind.label, color: insight.kind.color, symbol: insight.kind.symbol).frame(width: 92)
            Text(insight.date, format: .relative(presentation: .named)).font(.system(size: 13)).foregroundStyle(Theme.ink2).frame(width: 110, alignment: .trailing)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 16).frame(height: 54)
        .background(hover ? Theme.cardHi : .clear)
        .onHover { hover = $0 }
    }
}

extension Insight.Kind {
    var label: String {
        switch self {
        case .sustainedCPU: "CPU"
        case .memoryGrowth, .memoryPressure: "Memory"
        case .idleServers: "Projects"
        case .networkBurst: "Network"
        case .diskBurst: "Disk"
        }
    }
    var color: Color {
        switch self {
        case .sustainedCPU: Theme.cpu
        case .memoryGrowth, .memoryPressure: Theme.memory
        case .idleServers: Theme.projects
        case .networkBurst: Theme.network
        case .diskBurst: Theme.disk
        }
    }
    var symbol: String {
        switch self {
        case .memoryGrowth: "arrow.up.right.circle.fill"
        default: "circle.fill"
        }
    }
    func nowValue(_ g: AppGroup) -> String {
        switch self {
        case .sustainedCPU: String(format: "%.0f%%", g.cpu / Double(Hardware.cores))
        case .memoryGrowth, .memoryPressure, .idleServers: fmtBytes(g.memory)
        case .networkBurst: fmtRate(g.netIn + g.netOut)
        case .diskBurst: fmtRate(g.diskIO)
        }
    }
}

// MARK: Metric tabs (CPU, Memory, Disk, Network, GPU)

struct MetricTab: View {
    @Environment(MonitorStore.self) var store
    let tab: VitalsTab
    let filter: String
    @Binding var confirm: ConfirmQuit?

    var body: some View {
        let s = store.system
        let spec = heroSpec(s)
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                // Hero
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            IconTile(symbol: tab.icon, color: tab.tint, size: 24)
                            Text(tab.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        }
                        Spacer(minLength: 0)
                        BigNumber(value: spec.value, unit: spec.unit, size: 46)
                        Text(spec.caption).font(.system(size: 13)).foregroundStyle(Theme.ink2).lineLimit(1)
                    }
                    .frame(width: 210, alignment: .leading)
                    HeroChart(values: spec.history, color: tab.tint, interval: store.interval, maxValue: spec.max, yLabel: spec.yLabel)
                }
                .padding(18)
                .frame(height: 186)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Stat cards
                HStack(spacing: 12) {
                    ForEach(spec.stats.indices, id: \.self) { i in
                        let st = spec.stats[i]
                        StatCard(symbol: st.symbol, title: st.title, value: st.value, unit: st.unit, caption: st.caption, color: st.color ?? tab.tint)
                    }
                    BusiestCard(tab: tab, group: busiest)
                }
                .frame(height: 96)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            ScrollView {
                AppTable(primary: tab, filter: filter, confirm: $confirm, limit: nil).padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
    }

    var busiest: AppGroup? { store.groups.max { tab.metric($0) < tab.metric($1) } }

    struct Stat { let symbol: String; let title: String; let value: String; let unit: String; let caption: String; var color: Color? = nil }
    struct Spec { let value: String; let unit: String; let caption: String; let history: [Double]; let max: Double?; let yLabel: (Double) -> String; let stats: [Stat] }

    func heroSpec(_ s: SystemSample) -> Spec {
        switch tab {
        case .cpu:
            return Spec(value: pctNum(s.cpuTotal), unit: "%", caption: Hardware.chip, history: store.cpuHistory, max: 1, yLabel: { pct($0) }, stats: [
                Stat(symbol: "person.fill", title: "User", value: pctNum(s.cpuUser), unit: "%", caption: "Your apps"),
                Stat(symbol: "apple.logo", title: "System", value: pctNum(s.cpuSystem), unit: "%", caption: "macOS"),
                Stat(symbol: "gauge.with.dots.needle.50percent", title: "Load Average", value: String(format: "%.2f", s.loadAverage), unit: "", caption: "across \(Hardware.cores) cores"),
            ])
        case .memory:
            let u = splitUnit(fmtBytes(s.memoryUsed))
            let free = s.memoryTotal > s.memoryUsed ? s.memoryTotal - s.memoryUsed : 0
            let pressure = s.memoryPressure < 0.5 ? "Normal" : s.memoryPressure < 0.8 ? "Elevated" : "High"
            return Spec(value: u.0, unit: u.1, caption: "In use of \(fmtBytes(s.memoryTotal)) · \(pressure)", history: store.memHistory, max: 1, yLabel: { pct($0) }, stats: [
                Stat(symbol: "square.stack.fill", title: "App", value: splitUnit(fmtBytes(s.memoryApp)).0, unit: splitUnit(fmtBytes(s.memoryApp)).1, caption: "Memory that apps are using"),
                Stat(symbol: "pin.fill", title: "Wired", value: splitUnit(fmtBytes(s.memoryWired)).0, unit: splitUnit(fmtBytes(s.memoryWired)).1, caption: "Kept in place by macOS"),
                Stat(symbol: "arrow.down.right.and.arrow.up.left", title: "Free", value: splitUnit(fmtBytes(free)).0, unit: splitUnit(fmtBytes(free)).1, caption: "Swap \(fmtBytes(s.swapUsed).replacingOccurrences(of: "Zero KB", with: "0 MB"))", color: Theme.network),
            ])
        case .disk:
            let f = splitUnit(fmtBytes(s.diskAvailable))
            let r = splitUnit(fmtRate(s.diskRead)), w = splitUnit(fmtRate(s.diskWrite))
            return Spec(value: f.0, unit: f.1, caption: "Free of \(fmtBytes(s.diskTotal))", history: store.diskHistory, max: nil, yLabel: { fmtRate($0) }, stats: [
                Stat(symbol: "arrow.down.doc.fill", title: "Reading", value: r.0, unit: r.1, caption: "Read \(fmtBytes(Int64(store.readSession))) this session"),
                Stat(symbol: "arrow.up.doc.fill", title: "Writing", value: w.0, unit: w.1, caption: "Data the disk is writing"),
                Stat(symbol: "square.and.pencil", title: "Written", value: splitUnit(fmtBytes(Int64(store.writtenSession))).0, unit: splitUnit(fmtBytes(Int64(store.writtenSession))).1, caption: "Since Vitals started"),
            ])
        case .network:
            let d = splitUnit(fmtRate(s.netIn)), u = splitUnit(fmtRate(s.netOut))
            return Spec(value: d.0, unit: d.1, caption: "Downloading · \(primaryInterface())", history: store.netInHistory, max: nil, yLabel: { fmtRate($0) }, stats: [
                Stat(symbol: "arrow.up", title: "Uploading", value: u.0, unit: u.1, caption: "Network data going out"),
                Stat(symbol: "arrow.down.circle.fill", title: "Downloaded", value: splitUnit(fmtBytes(Int64(store.downloadedSession))).0, unit: splitUnit(fmtBytes(Int64(store.downloadedSession))).1, caption: "This session"),
                Stat(symbol: "arrow.up.circle.fill", title: "Uploaded", value: splitUnit(fmtBytes(Int64(store.uploadedSession))).0, unit: splitUnit(fmtBytes(Int64(store.uploadedSession))).1, caption: "This session"),
            ])
        default: // GPU
            return Spec(value: s.gpu.map(pctNum) ?? "—", unit: "%", caption: Hardware.chip, history: store.gpuHistory, max: 1, yLabel: { pct($0) }, stats: [
                Stat(symbol: "equal.circle.fill", title: "Average", value: pctNum(store.gpuSum / max(store.gpuCount, 1)), unit: "%", caption: "In the chart above"),
                Stat(symbol: "arrow.up.to.line", title: "Peak", value: pctNum(store.gpuPeak), unit: "%", caption: "Since Vitals started"),
                Stat(symbol: "cpu.fill", title: "Cores", value: "\(Hardware.cores)", unit: "", caption: Hardware.eCores > 0 ? "\(Hardware.pCores) P · \(Hardware.eCores) E CPU cores" : "CPU cores", color: Theme.cpu),
            ])
        }
    }
}

struct StatCard: View {
    let symbol: String
    let title: String
    let value: String
    let unit: String
    let caption: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                IconTile(symbol: symbol, color: color, size: 20)
                Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2)
            }
            BigNumber(value: value, unit: unit, size: 24)
            Text(caption).font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct BusiestCard: View {
    let tab: VitalsTab
    let group: AppGroup?
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                IconTile(symbol: "crown.fill", color: tab.tint, size: 20)
                Text("Busiest App").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink2)
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            if let g = group {
                HStack(spacing: 6) {
                    AppIconView(group: g, size: 20)
                    Text(g.name).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                }
                .frame(height: 29)
                Text("\(tab.format(g))  ·  \(g.processes.count) processes").font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension VitalsTab {
    func metric(_ g: AppGroup) -> Double {
        switch self {
        case .memory: Double(g.memory)
        case .disk: g.diskIO
        case .network: g.netIn + g.netOut
        case .gpu: g.gpu
        default: g.cpu
        }
    }
    func format(_ g: AppGroup) -> String {
        switch self {
        case .memory: fmtBytes(g.memory)
        case .disk: fmtRate(g.diskIO)
        case .network: fmtRate(g.netIn + g.netOut)
        case .gpu: String(format: "%.1f%%", g.gpu * 100)
        default: String(format: "%.1f%%", g.cpu / Double(Hardware.cores))
        }
    }
    var columnTitle: String {
        switch self {
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .memory: "Memory"
        default: "CPU"
        }
    }
}

// MARK: App table (outline rows, alternating stripes, inline bar in the primary column)

struct AppTable: View {
    @Environment(MonitorStore.self) var store
    let primary: VitalsTab
    let filter: String
    @Binding var confirm: ConfirmQuit?
    let limit: Int?
    @State private var expanded: Set<String> = []
    @State private var sortKey: String?
    @State private var ascending = false

    var columns: [VitalsTab] {
        var c: [VitalsTab] = [primary]
        for t in [VitalsTab.cpu, .memory] where t != primary { c.append(t) }
        return c
    }

    var body: some View {
        let key = sortKey ?? primary.columnTitle
        let sortTab = columns.first { $0.columnTitle == key } ?? primary
        var rows = store.groups.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        let _ = rows.sort {
            if key == "Name" { return ascending ? $0.name < $1.name : $0.name > $1.name }
            if key == "Processes" { return ascending ? $0.processes.count < $1.processes.count : $0.processes.count > $1.processes.count }
            return ascending ? sortTab.metric($0) < sortTab.metric($1) : sortTab.metric($0) > sortTab.metric($1)
        }
        let shown = limit.map { Array(rows.prefix($0)) } ?? rows
        let maxPrimary = max(store.groups.map(primary.metric).max() ?? 1, 1e-9)

        LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
            Section {
                var idx = 0
                ForEach(shown) { g in
                    let _ = (idx += 1)
                    AppTableRow(group: g, columns: columns, primary: primary, maxPrimary: maxPrimary,
                                striped: (shown.firstIndex { $0.id == g.id } ?? 0) % 2 == 1,
                                isExpanded: expanded.contains(g.id),
                                toggle: { if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) } },
                                confirm: $confirm)
                }
            } header: {
                header(key)
            }
        }
    }

    func header(_ key: String) -> some View {
        HStack(spacing: 0) {
            headerCell("Name", key).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 42)
            ForEach(columns) { c in headerCell(c.columnTitle, key, trailing: true).frame(width: c == primary ? 200 : 120, alignment: .trailing) }
            headerCell("Processes", key, trailing: true).frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(Theme.bg)
        .overlay(alignment: .bottom) { Divider() }
    }

    func headerCell(_ title: String, _ key: String, trailing: Bool = false) -> some View {
        Button {
            if key == title { ascending.toggle() } else { sortKey = title; ascending = title == "Name" }
        } label: {
            HStack(spacing: 3) {
                Text(title).font(.system(size: 12, weight: key == title ? .semibold : .regular))
                if key == title { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)) }
            }
            .foregroundStyle(key == title ? Theme.ink : Theme.ink2)
        }
        .buttonStyle(.plain)
    }
}

struct AppTableRow: View {
    @Environment(MonitorStore.self) var store
    let group: AppGroup
    let columns: [VitalsTab]
    let primary: VitalsTab
    let maxPrimary: Double
    let striped: Bool
    let isExpanded: Bool
    let toggle: () -> Void
    @Binding var confirm: ConfirmQuit?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink2)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0)).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(group.processes.count > 1 ? 1 : 0)
                AppIconView(group: group, size: 16).padding(.trailing, 8)
                Text(group.name).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 8)
                ForEach(columns) { c in
                    HStack(spacing: 10) {
                        if c == primary { InlineBar(value: primary.metric(group) / maxPrimary, color: primary.tint, width: 54) }
                        Text(c.format(group)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink)
                    }
                    .frame(width: c == primary ? 200 : 120, alignment: .trailing)
                }
                Text("\(group.processes.count)").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 12).frame(height: 26)
            .background((hover ? Theme.cardHi : striped ? Theme.card : .clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: toggle)
            .onHover { hover = $0 }
            .contextMenu { menu }

            if isExpanded {
                ForEach(group.processes.sorted { primary.processMetric($0) > primary.processMetric($1) }.prefix(60)) { p in
                    HStack(spacing: 0) {
                        Text(p.name).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(1).padding(.leading, 42)
                        Text("  \(p.pid)").font(.system(size: 11)).monospacedDigit().foregroundStyle(Theme.ink3)
                        Spacer(minLength: 8)
                        ForEach(columns) { c in
                            Text(c.formatProcess(p)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.ink2)
                                .frame(width: c == primary ? 200 : 120, alignment: .trailing)
                        }
                        Text("").frame(width: 110)
                    }
                    .padding(.horizontal, 12).frame(height: 22)
                    .contextMenu {
                        Button("Quit Process") { store.quit([p.pid], force: false) }
                        Button("Force Quit Process") { store.quit([p.pid], force: true) }
                        Divider()
                        Button("Copy Process Name") { copy(p.name) }
                        Button("Copy Process Path") { copy(p.path) }
                    }
                }
            }
        }
    }

    @ViewBuilder var menu: some View {
        if group.kind != .system {
            Button("Quit \(group.name)…") {
                confirm = ConfirmQuit(title: "Quit \(group.name)?",
                                      message: "\(group.processes.count) process\(group.processes.count == 1 ? "" : "es") will close. It can ask to save first.") { _ in
                    store.quitGroup(group, force: false)
                }
            }
            Button("Force Quit \(group.name)…") {
                confirm = ConfirmQuit(title: "Force Quit \(group.name)?",
                                      message: "It ends at once. Unsaved changes will be lost.") { _ in
                    store.quitGroup(group, force: true)
                }
            }
            Divider()
        }
        if let b = group.bundlePath { Button("Reveal in Finder") { NSWorkspace.shared.selectFile(b, inFileViewerRootedAtPath: "") } }
        Button("Copy Name") { copy(group.name) }
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

extension VitalsTab {
    func processMetric(_ p: ProcessSample) -> Double {
        switch self {
        case .memory: Double(p.memory)
        case .disk: p.diskRead + p.diskWrite
        case .network: p.netIn + p.netOut
        case .gpu: p.gpu
        default: p.cpu
        }
    }
    func formatProcess(_ p: ProcessSample) -> String {
        switch self {
        case .memory: fmtBytes(p.memory)
        case .disk: fmtRate(p.diskRead + p.diskWrite)
        case .network: fmtRate(p.netIn + p.netOut)
        case .gpu: String(format: "%.1f%%", p.gpu * 100)
        default: String(format: "%.1f%%", p.cpu / Double(Hardware.cores))
        }
    }
}

// MARK: Projects tab ("Dev servers and open ports, by project")

struct ProjectsTab: View {
    @Environment(MonitorStore.self) var store
    @Binding var confirm: ConfirmQuit?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !store.idleServers.isEmpty {
                    let mem = store.idleServers.reduce(UInt64(0)) { $0 + $1.process.memory }
                    let ports = store.idleServers.flatMap(\.ports).map(String.init).joined(separator: ", ")
                    HStack(spacing: 12) {
                        IconTile(symbol: "moon.zzz.fill", color: Theme.projects, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(store.idleServers.count) dev server\(store.idleServers.count == 1 ? " is" : "s are") running but idle")
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                            Text("Stopping them frees \(fmtBytes(mem)) and ports \(ports).").font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        }
                        Spacer()
                        Button("Stop All…") {
                            confirm = ConfirmQuit(title: "Stop \(store.idleServers.count) idle servers?",
                                                  message: "Each is asked to exit, which frees its port.") { _ in
                                store.quit(store.idleServers.map(\.process.pid), force: false)
                            }
                        }
                        .controlSize(.large)
                    }
                    .padding(14)
                    .background(Theme.projects.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.bottom, 20)
                }

                SectionHeader(title: "Projects", trailing: nil).padding(.bottom, 10)
                if store.projects.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("No Projects Running").font(.system(size: 14, weight: .semibold))
                            Text("When a dev server, test runner, editor or Compose container is working inside a project folder, it shows up here with its memory, CPU and open ports.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        }
                    }
                }
                VStack(spacing: 10) {
                    ForEach(store.projects) { p in ProjectCardView(project: p, confirm: $confirm) }
                }

                let projectPIDs = Set(store.projects.flatMap { $0.processes.map(\.pid) })
                let other = store.ports.filter { !projectPIDs.contains($0.process.pid) }
                if !other.isEmpty {
                    SectionHeader(title: "Other Open Ports").padding(.top, 28).padding(.bottom, 10)
                    VStack(spacing: 0) {
                        ForEach(Array(other.enumerated()), id: \.element.id) { i, lp in
                            PortRow(port: lp.port, name: lp.process.name, detail: "pid \(lp.process.pid) · up \(fmtDuration(lp.process.uptime))",
                                    memory: lp.process.memory, idle: nil, dynamic: lp.isDynamic, pid: lp.process.pid, confirm: $confirm)
                            if i < other.count - 1 { Divider().padding(.leading, 86) }
                        }
                    }
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                SectionHeader(title: "Keeping This Mac Awake").padding(.top, 28).padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 0) {
                    if store.blockers.isEmpty {
                        Text("No app is keeping this Mac awake. Left alone, it goes to sleep when Energy settings say so.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.ink2).padding(14)
                    }
                    ForEach(Array(store.blockers.enumerated()), id: \.element.id) { i, b in
                        HStack(spacing: 12) {
                            IconTile(symbol: b.kind == .display ? "display" : "cup.and.saucer.fill", color: Theme.disk, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(b.processName).font(.system(size: 13, weight: .medium))
                                Text(b.reason).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
                            }
                            Spacer()
                            Pill(text: b.kind == .display ? "Screen On" : "Mac Awake", color: Theme.disk)
                        }
                        .padding(.horizontal, 14).frame(height: 48)
                        if i < store.blockers.count - 1 { Divider().padding(.leading, 52) }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .padding(20)
        }
    }
}

struct ProjectCardView: View {
    @Environment(MonitorStore.self) var store
    let project: DevProject
    @Binding var confirm: ConfirmQuit?
    var body: some View {
        let idle = Dictionary(store.idleServers.map { ($0.process.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let servers = store.ports.filter { lp in project.processes.contains { $0.pid == lp.process.pid } }
        let working = project.cpu >= 2
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "folder.fill", color: Theme.projects, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("\(project.processes.count) processes · \(String(format: "%.1f%%", project.cpu / Double(Hardware.cores))) CPU").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
                if working { Pill(text: "working", color: Theme.network) }
                Spacer()
                Text(fmtBytes(project.memory)).font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Menu {
                    Button("Quit All Processes…") {
                        confirm = ConfirmQuit(title: "Quit everything running in \(project.name)?",
                                              message: "Stops \(project.processes.count) processes and frees \(fmtBytes(project.memory)). Terminal tabs open in the folder stay open.") { _ in
                            store.quit(project.processes.map(\.pid), force: false)
                        }
                    }
                    Button("Force Quit All") { store.quit(project.processes.map(\.pid), force: true) }
                    Divider()
                    Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.id) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)).foregroundStyle(Theme.ink2) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(14)
            if !servers.isEmpty {
                Divider().padding(.leading, 52)
                ForEach(Array(servers.enumerated()), id: \.element.id) { i, lp in
                    let idleInfo = idle[lp.process.pid]
                    PortRow(port: lp.port, name: lp.process.name, detail: idleInfo.map { "idle \(fmtAge($0.idleFor))" } ?? "up \(fmtDuration(lp.process.uptime))",
                            memory: lp.process.memory, idle: idleInfo != nil, dynamic: lp.isDynamic, pid: lp.process.pid, confirm: $confirm)
                    if i < servers.count - 1 { Divider().padding(.leading, 86) }
                }
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct PortRow: View {
    @Environment(MonitorStore.self) var store
    let port: UInt16
    let name: String
    let detail: String
    let memory: UInt64
    let idle: Bool?
    let dynamic: Bool
    let pid: pid_t
    @Binding var confirm: ConfirmQuit?
    @State private var hover = false
    var body: some View {
        HStack(spacing: 12) {
            Text(String(port)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(dynamic ? Theme.ink2 : Theme.projects)
                .frame(width: 60, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(idle == true ? Theme.projects : Theme.ink2).lineLimit(1)
            }
            Spacer()
            Text(fmtBytes(memory)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink2)
            if !dynamic {
                Button { NSWorkspace.shared.open(URL(string: "http://localhost:\(port)")!) } label: { Image(systemName: "safari") }
                    .buttonStyle(.borderless).help("Open http://localhost:\(port)")
            }
            Button("Stop…") {
                confirm = ConfirmQuit(title: "Stop the process on port \(port)?",
                                      message: "\(name) is asked to exit, which frees the port. Force Quit ends it at once, for a process that won’t quit.") { _ in
                    store.quit([pid], force: false)
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).frame(height: 44)
        .background(hover ? Theme.cardHi : .clear)
        .onHover { hover = $0 }
    }
}
