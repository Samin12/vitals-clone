import SwiftUI
import AppKit

// Dropdown, matched to Vitals' compact panel: icon tab strip on top, a header row with uptime,
// a 2-column grid of metric tiles, "Busiest Right Now", and a footer with Open Vitals / Settings / Quit.

struct MenuBarView: View {
    @Environment(MonitorStore.self) var store
    @Environment(\.openWindow) var openWindow
    @State private var tab: VitalsTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Tab strip
            HStack(spacing: 0) {
                ForEach(VitalsTab.allCases) { t in
                    Button { tab = t } label: {
                        Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(t == tab ? .white : Theme.ink2)
                            .frame(width: 30, height: 28)
                            .background(t == tab ? t.tint : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(t.title)
                }
            }
            .padding(4)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack {
                Text(tab.title).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Spacer()
                Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Theme.ink2)
                Text("Up \(fmtDuration(Date().timeIntervalSince(Hardware.bootTime)))").font(.system(size: 11)).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 2)

            if tab == .overview { overviewGrid } else { detail(tab) }

            // Busiest
            VStack(alignment: .leading, spacing: 6) {
                Text(tab == .overview ? "Busiest Right Now" : "Top Apps").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                let metric: VitalsTab = tab == .overview || tab == .projects ? .cpu : tab
                let top = Array(store.groups.sorted { metric.metric($0) > metric.metric($1) }.prefix(5))
                let m = max(top.first.map(metric.metric) ?? 1, 1e-9)
                ForEach(top) { g in
                    HStack(spacing: 8) {
                        AppIconView(group: g, size: 16)
                        Text(g.name).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                        Spacer(minLength: 6)
                        InlineBar(value: metric.metric(g) / m, color: metric.tint, width: 56, height: 5)
                        Text(metric.format(g)).font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink).frame(width: 70, alignment: .trailing)
                    }
                    .frame(height: 22)
                }
            }
            .padding(12)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            // Footer
            HStack(spacing: 8) {
                FooterButton(symbol: "macwindow", title: "Open Vitals", expand: true) {
                    store.tab = tab
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                FooterButton(symbol: "power", title: "Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 380)
        .background(Theme.bg)
    }

    var overviewGrid: some View {
        let s = store.system
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            MiniTile(tab: .cpu, value: pctNum(s.cpuTotal), unit: "%", detail: String(format: "load %.1f", s.loadAverage)) {
                LineSpark(values: store.cpuHistory, color: Theme.cpu, maxValue: 1)
            }
            let m = splitUnit(fmtBytes(s.memoryUsed))
            MiniTile(tab: .memory, value: m.0, unit: m.1, detail: "of \(fmtBytes(s.memoryTotal))") {
                LineSpark(values: store.memHistory, color: Theme.memory, maxValue: 1)
            }
            let d = splitUnit(fmtRate(s.netIn))
            MiniTile(tab: .network, value: d.0, unit: d.1, detail: "↑ \(fmtRate(s.netOut))") {
                LineSpark(values: store.netInHistory, color: Theme.network)
            }
            let f = splitUnit(fmtBytes(s.diskAvailable))
            MiniTile(tab: .disk, value: f.0, unit: f.1, detail: "free") {
                InlineBar(value: Double(s.diskTotal - s.diskAvailable) / Double(max(s.diskTotal, 1)), color: Theme.disk, width: 150, height: 6)
            }
            MiniTile(tab: .gpu, value: s.gpu.map(pctNum) ?? "—", unit: "%", detail: "GPU") {
                LineSpark(values: store.gpuHistory, color: Theme.gpu, maxValue: 1)
            }
            MiniTile(tab: .projects, value: "\(store.projects.count)", unit: "", detail: "\(store.ports.count) ports open") {
                InlineBar(value: store.projects.isEmpty ? 0 : Double(store.idleServers.count) / Double(max(store.projects.count, 1)), color: Theme.projects, width: 150, height: 6)
            }
        }
    }

    @ViewBuilder func detail(_ t: VitalsTab) -> some View {
        let s = store.system
        VStack(alignment: .leading, spacing: 8) {
            switch t {
            case .cpu:
                BigNumber(value: pctNum(s.cpuTotal), unit: "%", size: 34)
                Text(Hardware.chip).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                LineSpark(values: store.cpuHistory, color: Theme.cpu, maxValue: 1).frame(height: 44)
                row("User", pct(s.cpuUser)); row("System", pct(s.cpuSystem)); row("Load Average", String(format: "%.2f", s.loadAverage))
            case .memory:
                let m = splitUnit(fmtBytes(s.memoryUsed))
                BigNumber(value: m.0, unit: m.1, size: 34)
                Text("of \(fmtBytes(s.memoryTotal)) · \(s.memoryPressure < 0.5 ? "Normal" : "Elevated")").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                LineSpark(values: store.memHistory, color: Theme.memory, maxValue: 1).frame(height: 44)
                row("App", fmtBytes(s.memoryApp)); row("Wired", fmtBytes(s.memoryWired)); row("Compressed", fmtBytes(s.memoryCompressed)); row("Swap Used", fmtBytes(s.swapUsed))
            case .disk:
                let f = splitUnit(fmtBytes(s.diskAvailable))
                BigNumber(value: f.0, unit: f.1 + " free", size: 34)
                Text("\(fmtBytes(s.diskTotal - s.diskAvailable)) used of \(fmtBytes(s.diskTotal))").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                InlineBar(value: Double(s.diskTotal - s.diskAvailable) / Double(max(s.diskTotal, 1)), color: Theme.disk, width: 330, height: 6)
                row("Reading", fmtRate(s.diskRead)); row("Writing", fmtRate(s.diskWrite))
            case .network:
                let d = splitUnit(fmtRate(s.netIn))
                BigNumber(value: d.0, unit: d.1, size: 34)
                Text("↑ \(fmtRate(s.netOut))").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                LineSpark(values: store.netInHistory, color: Theme.network).frame(height: 44)
                row("Downloaded This Session", fmtBytes(Int64(store.downloadedSession))); row("Uploaded This Session", fmtBytes(Int64(store.uploadedSession)))
            case .gpu:
                BigNumber(value: s.gpu.map(pctNum) ?? "—", unit: "%", size: 34)
                Text(Hardware.chip).font(.system(size: 12)).foregroundStyle(Theme.ink2)
                LineSpark(values: store.gpuHistory, color: Theme.gpu, maxValue: 1).frame(height: 44)
                row("Average", pct(store.gpuSum / max(store.gpuCount, 1))); row("Peak", pct(store.gpuPeak))
            default:
                BigNumber(value: "\(store.projects.count)", unit: "projects", size: 34)
                Text("\(fmtBytes(store.projects.reduce(UInt64(0)) { $0 + $1.memory })) · \(store.ports.count) ports open").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Text("Running Now").font(.system(size: 12)).foregroundStyle(Theme.ink2).padding(.top, 4)
                ForEach(store.projects.prefix(6)) { p in
                    HStack {
                        Text(p.name).font(.system(size: 13, weight: .medium))
                        if let port = p.ports.first { Text(String(port)).font(.system(size: 12)).foregroundStyle(Theme.projects).monospacedDigit() }
                        Spacer()
                        Text(fmtBytes(p.memory)).font(.system(size: 13)).monospacedDigit()
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(Theme.ink2); Spacer(); Text(v).monospacedDigit().foregroundStyle(Theme.ink) }.font(.system(size: 12.5))
    }
}

struct MiniTile<Footer: View>: View {
    let tab: VitalsTab
    let value: String
    let unit: String
    let detail: String
    @ViewBuilder var footer: Footer
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon).font(.system(size: 10, weight: .semibold)).foregroundStyle(tab.tint)
                Text(tab.title).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.7)
                Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
                Spacer(minLength: 2)
                Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Spacer(minLength: 0)
            footer.frame(height: 20, alignment: .bottom)
        }
        .padding(10)
        .frame(height: 84)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct FooterButton: View {
    let symbol: String
    let title: String
    var expand = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { Image(systemName: symbol); Text(title) }
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                .frame(maxWidth: expand ? .infinity : nil).padding(.horizontal, 12).frame(height: 32)
                .background(hover ? Theme.cardHi : Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
