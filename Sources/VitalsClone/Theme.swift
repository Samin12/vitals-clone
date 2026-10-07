import SwiftUI
import AppKit

// Design tokens lifted from vitalsmac.com's stylesheet (:root light / dark), which matches the app.
private func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { ap in
        let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                       blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    })
}

enum Theme {
    static let bg = dyn(0xFFFFFF, 0x131315)
    static let card = dyn(0xF5F5F7, 0x1F1F22)
    static let cardHi = dyn(0xE8E8ED, 0x27272B)
    static let raised = dyn(0xFFFFFF, 0x1A1A1D)
    static let ink = dyn(0x1D1D1F, 0xF5F5F7)
    static let ink2 = dyn(0x6E6E73, 0xA1A1A6)
    static let ink3 = dyn(0xA1A1A6, 0x6E6E73)
    static let line = Color.primary.opacity(0.08)
    static let accent = dyn(0x007AFF, 0x0A84FF)
    static let cpu = dyn(0x2A78D6, 0x3987E5)
    static let memory = dyn(0x4A3AA7, 0x9085E9)
    static let disk = dyn(0xEDA100, 0xC98500)
    static let network = dyn(0x1BAF7A, 0x199E70)
    static let gpu = dyn(0xE87BA4, 0xD55181)
    static let battery = dyn(0x008300, 0x2FA83A)
    static let projects = dyn(0xEB6834, 0xD95926)
    static let sound = dyn(0xC2379B, 0xD955B3)
    static let red = dyn(0xE0352B, 0xFF5A50)
    static let green = dyn(0x248A3D, 0x30D158)
}

enum IconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let i = NSWorkspace.shared.icon(forFile: path)
        i.size = NSSize(width: 32, height: 32)
        cache[path] = i
        return i
    }
}

enum VitalsTab: Int, CaseIterable, Identifiable {
    case overview, cpu, memory, disk, network, gpu, projects
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .memory: "Memory"
        case .disk: "Disk"
        case .network: "Network"
        case .gpu: "GPU"
        case .projects: "Projects"
        }
    }
    // Symbol names read from the real app's toolbar accessibility identifiers.
    var icon: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .cpu: "cpu.fill"
        case .memory: "memorychip.fill"
        case .disk: "internaldrive.fill"
        case .network: "network"
        case .gpu: "square.stack.3d.up.fill"
        case .projects: "folder.fill"
        }
    }
    var tint: Color {
        switch self {
        case .overview: Theme.accent
        case .cpu: Theme.cpu
        case .memory: Theme.memory
        case .disk: Theme.disk
        case .network: Theme.network
        case .gpu: Theme.gpu
        case .projects: Theme.projects
        }
    }
}

// MARK: Formatting

func fmtBytes<T: BinaryInteger>(_ b: T) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .memory)
}
func fmtRate(_ b: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(b, 0)), countStyle: .file) + "/s"
}
/// Splits "134.45 GB" → ("134.45", "GB") for the big-number + small-unit treatment.
func splitUnit(_ s: String) -> (String, String) {
    let s = s.replacingOccurrences(of: "Zero", with: "0")
    guard let r = s.lastIndex(of: " ") else { return (s, "") }
    return (String(s[..<r]), String(s[s.index(after: r)...]))
}
func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
func pctNum(_ v: Double) -> String { String(format: "%.0f", v * 100) }
func fmtDuration(_ t: TimeInterval) -> String {
    let d = Int(t) / 86400, h = Int(t) % 86400 / 3600, m = Int(t) % 3600 / 60
    if d > 0 { return "\(d)d \(h)h" }
    if h > 0 { return "\(h)h \(m)m" }
    return "\(max(m, 1)) min"
}
func fmtAge(_ t: TimeInterval) -> String {
    let d = Int(t) / 86400, h = Int(t) / 3600, m = Int(t) / 60
    if d > 0 { return "\(d) day\(d == 1 ? "" : "s")" }
    if h > 0 { return "\(h) hour\(h == 1 ? "" : "s")" }
    return "\(max(m, 1)) min"
}
