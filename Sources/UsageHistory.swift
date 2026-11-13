import Charts
import Foundation
import SwiftUI

struct UsageSample {
    let time: TimeInterval
    let cpu: [String: Measurement]?
    let ram: [String: Measurement]?

    init(host: HostSnapshot, time: TimeInterval) {
        self.time = time
        cpu = host.cpuBreakdown ? host.groups : nil
        ram = host.groups.keys.contains(where: { $0 != Workload.idle.id }) ? host.groups : nil
    }
}

struct UsageHistory {
    static let window: TimeInterval = 60
    private static let maximumGap: TimeInterval = 16
    private static let maximumSamples = 40
    private var samples: [UsageSample] = []

    struct Point {
        let time: TimeInterval
        let lower: Double
        let upper: Double
    }

    mutating func append(_ sample: UsageSample) {
        samples.append(sample)
        samples.removeAll { sample.time - $0.time > Self.window }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    func contains(_ workload: Workload, for metric: Metric) -> Bool {
        samples.contains { (metric == .cpu ? $0.cpu : $0.ram)?[workload.id] != nil }
    }

    func segments(for metric: Metric, workload: Workload, now: TimeInterval) -> [[Point]] {
        var result: [[Point]] = []
        var segment: [Point] = []
        for sample in samples where (now - Self.window...now).contains(sample.time) {
            let time = sample.time - now
            let point: Point?
            switch metric {
            case .cpu:
                point = sample.cpu.map { groups in
                    let lower = Workload.allCases.prefix(while: { $0 != workload })
                        .reduce(0.0) { $0 + (groups[$1.id]?.cpu ?? 0) }
                    return Point(time: time, lower: lower, upper: lower + (groups[workload.id]?.cpu ?? 0))
                }
            case .ram:
                point = sample.ram.map {
                    Point(time: time, lower: 0, upper: Double($0[workload.id]?.bytes ?? 0) / Double(1 << 30))
                }
            }
            if point == nil || segment.last.map({ time - $0.time >= Self.maximumGap }) == true {
                if !segment.isEmpty { result.append(segment) }
                segment = []
            }
            if let point { segment.append(point) }
        }
        if !segment.isEmpty { result.append(segment) }
        return result
    }
}

struct UsageHistoryChart: View {
    let metric: Metric
    let history: UsageHistory
    let workloads: [Workload]
    let color: (Workload) -> Color
    @State private var highlighted: Workload?

    private let keyColumns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let now = ProcessInfo.processInfo.systemUptime
            let series = workloads.map { history.segments(for: metric, workload: $0, now: now) }
            let count = series.first?.reduce(0) { $0 + $1.count } ?? 0
            let peak = series.flatMap { $0 }.flatMap { $0 }.map(\.upper).max() ?? 0
            let ceiling = metric == .cpu ? 1 : max(1, (peak * 1.05).rounded(.up))
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(metric == .cpu ? "Mac CPU by workload" : "RAM footprint by workload")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if count < 2 {
                        Text(count == 0 ? "Waiting for a reading" : "Collecting history…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                workloadKey
                Chart {
                    ForEach(drawOrder, id: \.self) { i in
                        ForEach(series[i].indices, id: \.self) { j in
                            let segment = series[i][j]
                            ForEach(segment.indices, id: \.self) { k in
                                let point = segment[k]
                                band(point, start: point.lower, end: point.upper,
                                     series: "\(workloads[i].id)-\(j)", color: color(workloads[i]),
                                     isolated: segment.count == 1, workload: workloads[i])
                            }
                        }
                    }
                }
                .chartXScale(domain: -UsageHistory.window...0)
                .chartYScale(domain: 0.0...ceiling)
                .chartXAxis {
                    AxisMarks(values: [-UsageHistory.window, 0]) { mark in
                        AxisValueLabel(anchor: mark.index == 0 ? .topLeading : .topTrailing) {
                            Text(mark.index == 0 ? "60s ago" : "Now")
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0.0, ceiling / 2, ceiling]) { mark in
                        AxisGridLine()
                        if let value = mark.as(Double.self), value != ceiling / 2 {
                            AxisValueLabel { Text(metric == .cpu ? value.formatted(.percent) : value.formatted() + " GiB") }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 102)
                .accessibilityRepresentation {
                    Text(chartSummary(count: count) + (highlighted.map { " Highlighting " + $0.name + "." } ?? ""))
                }
            }
        }
    }

    private var drawOrder: [Int] {
        var order = Array(workloads.indices)
        if metric == .ram, let highlighted, let index = workloads.firstIndex(of: highlighted) {
            order.removeAll { $0 == index }
            order.append(index)
        }
        return order
    }

    private var workloadKey: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Highlight a workload")
                .font(.caption2)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: keyColumns, spacing: 4) {
                ForEach(workloads) { workload in
                    let selected = highlighted == workload
                    Button {
                        highlighted = selected ? nil : workload
                    } label: {
                        HStack(spacing: 6) {
                            Capsule()
                                .fill(color(workload))
                                .frame(width: 14, height: metric == .ram ? 3 : 8)
                                .accessibilityHidden(true)
                            Text(workload.name)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "checkmark")
                                .opacity(selected ? 1 : 0)
                                .accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(selected ? color(workload) : nil)
                    .accessibilityLabel(workload.name)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityHint(selected ? "Show all workloads" : "Highlight this workload in the chart")
                    .accessibilityIdentifier("chart-key-" + workload.id)
                }
            }
        }
        .onChange(of: metric) { _, _ in highlighted = nil }
        .onChange(of: workloads) { _, available in
            if let highlighted, !available.contains(highlighted) { self.highlighted = nil }
        }
    }

    private func chartSummary(count: Int) -> String {
        let scope = metric == .cpu
            ? "CPU load history. Stacked workload shares, including idle."
            : "RAM usage history. Separate workload footprints in GiB."
        let readings = count == 0
            ? "No readings in the last 60 seconds."
            : "\(count) \(count == 1 ? "reading" : "readings") in the last 60 seconds."
        return scope + " " + readings
    }

    @ChartContentBuilder
    private func band(_ point: UsageHistory.Point, start: Double, end: Double,
                      series: String, color: Color, isolated: Bool, workload: Workload) -> some ChartContent {
        let dimmed = highlighted != nil && highlighted != workload
        let selected = highlighted == workload
        if isolated && end > start {
            PointMark(x: .value("Seconds from now", point.time), y: .value("Share", end))
                .symbolSize(16)
                .foregroundStyle(color.opacity(dimmed ? 0.25 : 1))
        } else if !isolated {
            if metric == .cpu {
                AreaMark(x: .value("Seconds from now", point.time),
                     yStart: .value("Lower share", start), yEnd: .value("Upper share", end),
                     series: .value("Series", series))
                .foregroundStyle(color.opacity(dimmed ? 0.14 : selected ? 0.84 : 0.48))
            }
            if metric == .ram {
                LineMark(x: .value("Seconds from now", point.time), y: .value("Share", end),
                     series: .value("Series", series))
                .foregroundStyle(color.opacity(dimmed ? 0.22 : 1))
                .lineStyle(StrokeStyle(lineWidth: selected ? 2.8 : 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
