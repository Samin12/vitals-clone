import SwiftUI
import Charts

// Reusable pieces measured off the real Vitals window (cards #F5F5F7 r14, bar sparklines,
// tinted icon tiles, pills, inline table bars).

struct Card<Content: View>: View {
    var radius: CGFloat = 14
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Capsule bars with a faint full-height track; idle values render as a dot (min height = width).
struct BarSpark: View {
    let values: [Double]
    let color: Color
    var count = 48
    var maxValue: Double? = nil
    var body: some View {
        GeometryReader { g in
            let vals = Array((Array(repeating: 0.0, count: max(0, count - values.count)) + values).suffix(count))
            let m = maxValue ?? max(vals.max() ?? 1, 1e-9)
            let w: CGFloat = 4
            let gap = max(1, (g.size.width - w * CGFloat(count)) / CGFloat(max(count - 1, 1)))
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(vals.enumerated()), id: \.offset) { _, v in
                    ZStack(alignment: .bottom) {
                        Capsule().fill(color.opacity(0.16))
                        Capsule().fill(color).frame(height: max(w, g.size.height * CGFloat(min(v / m, 1))))
                    }
                    .frame(width: w)
                }
            }
        }
    }
}

struct LineSpark: View {
    let values: [Double]
    let color: Color
    var maxValue: Double? = nil
    var body: some View {
        let m = maxValue ?? max(values.max() ?? 1, 1e-9)
        Chart(Array(values.enumerated()), id: \.offset) { i, v in
            AreaMark(x: .value("t", i), y: .value("v", min(v / m, 1)))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("t", i), y: .value("v", min(v / m, 1)))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
    }
}

/// Hero chart: line + gradient area, dotted horizontal grid, trailing y labels, time x labels.
struct HeroChart: View {
    let values: [Double]
    let color: Color
    let interval: TimeInterval
    var maxValue: Double? = nil
    var yLabel: (Double) -> String = { pct($0) }
    var body: some View {
        let top = maxValue ?? max(values.max() ?? 1, 1e-9) * 1.15
        let now = Date()
        let pts = values.enumerated().map { (now.addingTimeInterval(-Double(values.count - 1 - $0.offset) * interval), $0.element) }
        Chart(pts, id: \.0) { t, v in
            AreaMark(x: .value("Time", t), y: .value("Value", min(v, top)))
                .interpolationMethod(.monotone)
                .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0)], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", t), y: .value("Value", min(v, top)))
                .interpolationMethod(.monotone)
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3])).foregroundStyle(Theme.ink3.opacity(0.6))
                AxisValueLabel { if let d = v.as(Double.self) { Text(yLabel(d)).font(.system(size: 10)).foregroundStyle(Theme.ink3) } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 2)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute()).font(.system(size: 10)).foregroundStyle(Theme.ink2)
            }
        }
    }
}

struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(color.opacity(0.13), in: Capsule())
    }
}

struct InlineBar: View {
    let value: Double   // 0…1
    let color: Color
    var width: CGFloat = 40
    var height: CGFloat = 4
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.ink.opacity(0.09))
            Capsule().fill(color).frame(width: max(value > 0 ? height : 0, width * CGFloat(min(max(value, 0), 1))))
        }
        .frame(width: width, height: height)
    }
}

struct BigNumber: View {
    let value: String
    let unit: String
    var size: CGFloat = 46
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(.system(size: size, weight: .bold)).tracking(-0.8).monospacedDigit().foregroundStyle(Theme.ink)
            if !unit.isEmpty {
                Text(unit).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(Theme.ink2)
            }
        }
        .lineLimit(1).minimumScaleFactor(0.6)
    }
}

struct StatColumn: View {
    let label: String
    let value: String
    var dot: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(label).font(.system(size: 11)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Text(value).font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(Theme.ink).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppIconView: View {
    let group: AppGroup
    var size: CGFloat = 16
    var body: some View {
        if let icon = group.icon {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else if group.kind == .system {
            Image(systemName: "apple.logo").font(.system(size: size * 0.85)).foregroundStyle(Theme.ink2).frame(width: size, height: size)
        } else {
            Image(systemName: "apple.terminal").font(.system(size: size * 0.75)).foregroundStyle(Theme.ink2).frame(width: size, height: size)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.ink)
            Spacer()
            if let trailing {
                Button(trailing) { action?() }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(Theme.accent)
            }
        }
    }
}
