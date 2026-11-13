import Charts
import Foundation
import SwiftUI

enum ChartViewMode: String, CaseIterable {
    case pie = "Pie"
    case history = "History"
}

struct UsageSample {
    let time: TimeInterval
    let cpuSystem: Double?
    let cpuUser: Double?
    let ramUsed: Double?

    init(host: HostSnapshot, time: TimeInterval) {
        self.init(time: time, cpuSystem: host.cpuSystem, cpuUser: host.cpuUser,
                  ramUsed: host.installedBytes > 0
                      ? host.usedMemoryBytes.map { Double($0) / Double(host.installedBytes) }
                      : nil)
    }

    init(time: TimeInterval, cpuSystem: Double?, cpuUser: Double?, ramUsed: Double?) {
        self.time = time
        self.cpuSystem = cpuSystem
        self.cpuUser = cpuUser
        self.ramUsed = ramUsed
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

    func segments(for metric: Metric, now: TimeInterval) -> [[Point]] {
        var result: [[Point]] = []
        var segment: [Point] = []
        for sample in samples where (now - Self.window...now).contains(sample.time) {
            let time = sample.time - now
            let point: Point?
            switch metric {
            case .cpu:
                if let system = sample.cpuSystem, let user = sample.cpuUser {
                    point = Point(time: time, lower: system, upper: min(1, system + user))
                } else {
                    point = nil
                }
            case .ram:
                point = sample.ramUsed.map { Point(time: time, lower: 0, upper: $0) }
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
    let systemColor: Color
    let userColor: Color
    let ramColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let segments = history.segments(for: metric, now: ProcessInfo.processInfo.systemUptime)
            let count = segments.reduce(0) { $0 + $1.count }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(metric == .cpu ? "CPU load" : "Share of installed RAM in use")
                        .font(.caption.weight(.semibold))
                    Spacer()
                    if count < 2 {
                        Text(count == 0 ? "Waiting for a reading" : "Collecting history…")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Chart {
                    ForEach(segments.indices, id: \.self) { index in
                        let segment = segments[index]
                        ForEach(segment.indices, id: \.self) { offset in
                            let point = segment[offset]
                            band(point, start: point.lower, end: point.upper,
                                 series: "upper-\(index)", color: metric == .cpu ? userColor : ramColor,
                                 isolated: segment.count == 1)
                            if metric == .cpu {
                                band(point, start: 0, end: point.lower,
                                     series: "system-\(index)", color: systemColor, isolated: segment.count == 1)
                            }
                        }
                    }
                }
                .chartXScale(domain: -UsageHistory.window...0)
                .chartYScale(domain: 0.0...1.0)
                .chartXAxis {
                    AxisMarks(values: [-UsageHistory.window, 0]) { mark in
                        AxisValueLabel(anchor: mark.index == 0 ? .topLeading : .topTrailing) {
                            Text(mark.index == 0 ? "60s ago" : "Now")
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0.0, 0.5, 1.0]) { mark in
                        AxisGridLine()
                        if let value = mark.as(Double.self), value != 0.5 {
                            AxisValueLabel { Text(value.formatted(.percent)) }
                        }
                    }
                }
                .chartLegend(.hidden)
                .frame(height: 102)
                .accessibilityRepresentation {
                    Text(chartSummary(count: count))
                }
            }
        }
    }

    private func chartSummary(count: Int) -> String {
        let scope = metric == .cpu
            ? "CPU load history. System and user CPU, with idle as unfilled space."
            : "RAM usage history. Share of installed RAM in use."
        let readings = count == 0
            ? "No readings in the last 60 seconds."
            : "\(count) \(count == 1 ? "reading" : "readings") in the last 60 seconds."
        return scope + " " + readings
    }

    @ChartContentBuilder
    private func band(_ point: UsageHistory.Point, start: Double, end: Double,
                      series: String, color: Color, isolated: Bool) -> some ChartContent {
        if isolated {
            PointMark(x: .value("Seconds from now", point.time), y: .value("Share", end))
                .symbolSize(16)
                .foregroundStyle(color)
        } else {
            AreaMark(x: .value("Seconds from now", point.time),
                     yStart: .value("Lower share", start), yEnd: .value("Upper share", end),
                     series: .value("Series", series))
                .foregroundStyle(color.opacity(0.20))
            LineMark(x: .value("Seconds from now", point.time), y: .value("Share", end),
                     series: .value("Series", series))
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}
