import AppKit
import Foundation
import SwiftUI

enum Metric: String, CaseIterable {
    case cpu = "CPU"
    case ram = "RAM"
}

private enum RamBrand {
    static let name = "Ram Meter"
    static let mark: NSImage? = {
        guard let url = Bundle.main.url(forResource: "RamMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = NSSize(width: 18, height: 12)
        image.isTemplate = true
        return image
    }()

    static func color(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }

    static func workload(_ group: Workload, dark: Bool) -> Color {
        switch group {
        case .docker: return color(dark ? 0xf58a73 : 0xac513d)
        case .codex: return color(dark ? 0xc6a3f4 : 0x7450a6)
        case .browsers: return color(dark ? 0xedac5d : 0x9c661f)
        case .nodeServers: return color(dark ? 0xd0dc70 : 0x61701c)
        case .iOSSimulator: return color(dark ? 0xf0a3ce : 0xa04479)
        case .androidEmulator: return color(dark ? 0x7bddf2 : 0x166b7e)
        case .other: return color(dark ? 0x90acd7 : 0x56739f)
        case .idle: return color(dark ? 0x78e1cb : 0x19766b)
        }
    }
}

struct CapacityReading {
    let used: Double
    let total: Double
    var available: Double { total - used }

    init?(used: Double?, total: Double) {
        guard let used, used.isFinite, total.isFinite, total > 0, (0...total).contains(used) else {
            return nil
        }
        self.used = used
        self.total = total
    }
}

private func percent(_ amount: Double) -> String {
    amount.formatted(.percent.precision(.fractionLength(0...1)))
}

private func memory(_ bytes: UInt64) -> String {
    if bytes == 0 { return "0 MiB" }
    if bytes < 1 << 20 { return "<1 MiB" }
    if bytes < 1 << 30 { return (Double(bytes) / Double(1 << 20)).formatted(.number.precision(.fractionLength(0))) + " MiB" }
    return (Double(bytes) / Double(1 << 30)).formatted(.number.precision(.fractionLength(1))) + " GiB"
}

struct Dashboard: View {
    let host: HostSnapshot?
    let history: UsageHistory
    let guest: GuestSnapshot?
    let ended: [String: Monitor.EndedJob]
    @Binding var metric: Metric
    @Binding var expanded: Workload?
    var onQuit: () -> Void
    @State private var trackingCopyStatus: String?
    @State private var showStats = false
    @Environment(\.colorScheme) private var colorScheme
    private var dark: Bool { colorScheme == .dark }

    private var hostStale: Bool {
        host.map { Date().timeIntervalSince($0.date) > 6 } ?? false
    }

    private var guestStale: Bool {
        guest.map { Date().timeIntervalSince($0.date) > 15 } ?? false
    }

    private var visible: [Workload] {
        Workload.allCases.filter {
            switch $0 {
            case .idle: return false
            case .nodeServers, .iOSSimulator, .androidEmulator: return host?.groups[$0.id] != nil || history.contains($0, for: metric)
            default: return true
            }
        }
    }

    private var capacity: CapacityReading? {
        guard let host else { return nil }
        if metric == .cpu { return CapacityReading(used: host.busy, total: 1) }
        return CapacityReading(used: host.usedMemoryBytes.map { Double($0) }, total: Double(host.installedBytes))
    }

    private func capacityValue(_ amount: Double) -> String {
        if metric == .cpu { return percent(amount) }
        return (amount / Double(1 << 30)).formatted(.number.precision(.fractionLength(1))) + " GiB"
    }

    private func amount(_ value: Measurement) -> Double {
        metric == .cpu ? value.cpu : Double(value.bytes)
    }

    private func valueText(_ value: Measurement?) -> String {
        guard let value else { return "—" }
        if metric == .ram { return memory(value.bytes) }
        return host?.cpuBreakdown == true ? percent(value.cpu) : "—"
    }

    private var guestRows: [GuestReading] { guest?.rows ?? [] }
    private var runCount: Int { Set(guestRows.compactMap { $0.job?.key }).count }
    private var chatCount: Int { host?.details["codex"]?.filter { $0.id != "shared" }.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    if let mark = RamBrand.mark {
                        Image(nsImage: mark)
                            .foregroundStyle(RamBrand.color(dark ? 0xffa48f : 0x9b4938))
                            .frame(width: 26, height: 24)
                            .background(RamBrand.color(dark ? 0x46363b : 0xf0e2d8),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityHidden(true)
                    }
                    Text(RamBrand.name).font(.headline)
                }
                Spacer()
                if hostStale {
                    Label("Stale", systemImage: "clock").foregroundStyle(.orange)
                        .accessibilityLabel("Stale Mac measurements")
                } else if let host {
                    Text(host.date.formatted(date: .omitted, time: .standard))
                } else {
                    Text("Collecting")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                Picker("Resource metric", selection: $metric) {
                    ForEach(Metric.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                historyOverview
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: 14).fill(
                    LinearGradient(colors: [
                        RamBrand.color(dark ? 0x372a3d : 0xf3e9e2),
                        RamBrand.color(dark ? 0x252832 : 0xf8f2ef)
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.primary.opacity(0.10))
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Workload")
                    Spacer()
                    Text(metric == .cpu ? "Share of Mac CPU" : "Process footprint").padding(.trailing, 20)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                Divider()
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(visible) { group in
                            groupRow(group)
                            if expanded == group {
                                if group == .docker { dockerDetail }
                                else { processDetails(group) }
                            }
                            Divider()
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: showStats ? 150 : expanded == nil ? CGFloat(visible.count * 40) : 260)
                if showStats {
                    Text("Scroll for more workloads.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.top, 6)
                }

            }

            DisclosureGroup("Stats for nerds", isExpanded: $showStats) {
                nerdStats.padding(.top, 8)
            }
            .font(.subheadline)
            .padding(.horizontal, 6)

            HStack(alignment: .center) {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Quit", action: onQuit)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Quit Ram Meter")
            }
        }
        .padding(15)
        .frame(width: 440)
        .onChange(of: visible) { _, groups in
            if let expanded, !groups.contains(expanded) { self.expanded = nil }
        }
        .onExitCommand {
            if showStats { showStats = false }
            else if expanded != nil { expanded = nil }
            else { NSApp.keyWindow?.close() }
        }
    }

    private var historyOverview: some View {
        let ramColor = RamBrand.workload(.idle, dark: dark)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if metric == .cpu {
                    historyReading("System", host?.cpuSystem.map(percent))
                    historyReading("User", host?.cpuUser.map(percent))
                    historyReading("Idle", host?.busy.map { percent(1 - $0) }, tint: ramColor)
                } else {
                    historyReading("RAM used", capacity.map { capacityValue($0.used) }, tint: ramColor)
                    historyReading("Est. available", capacity.map { capacityValue($0.available) })
                    historyReading("Installed RAM", host.flatMap {
                        $0.installedBytes > 0 ? capacityValue(Double($0.installedBytes)) : nil
                    })
                }
            }
            UsageHistoryChart(metric: metric, history: history,
                              workloads: visible + (metric == .cpu ? [.idle] : [])) {
                RamBrand.workload($0, dark: dark)
            }
            if metric == .cpu {
                Divider()
                processCounts
            } else {
                Text("Stacked footprints can overlap and exceed installed RAM.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func historyReading(_ label: String, _ value: String?, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value ?? "—").font(.callout.weight(.semibold)).monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label == "Est. available" ? "Estimated RAM available" : label)
        .accessibilityValue(value ?? "Unavailable")
    }

    private var processCounts: some View {
        let counts = host?.processCounts
        let sampled = counts.flatMap { $0.processesWithThreadCounts > 0 ? $0 : nil }
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            countLabel("Processes", counts?.processes.formatted())
            countLabel("Observed threads", sampled?.observedThreads.formatted())
            if let sampled, sampled.processesWithThreadCounts < sampled.processes {
                Text("From \(sampled.processesWithThreadCounts.formatted()) of \(sampled.processes.formatted()) processes")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    private func countLabel(_ label: String, _ value: String?) -> some View {
        Text("\(label): \(value ?? "—")")
            .monospacedDigit()
            .accessibilityLabel("\(label): \(value ?? "Unavailable")")
    }

    private var nerdStats: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("CPU").fontWeight(.semibold)
                    stat("Busy core equivalents", host.flatMap { sample in
                        sample.busy.map { busy in
                            (busy * Double(sample.cores)).formatted(.number.precision(.fractionLength(1))) +
                                " / " + sample.cores.formatted()
                        }
                    })
                    stat("Physical cores", host?.physicalCores?.formatted())
                    stat("User", host?.cpuUser.map(percent))
                    stat("System", host?.cpuSystem.map(percent))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Memory").fontWeight(.semibold)
                    stat("Wired", host?.wiredBytes.map(memory))
                    stat("Compressed", host?.compressedBytes.map(memory))
                    stat("Page-ins", pagingRateText(host?.pageInBytesPerSecond))
                    stat("Page-outs", pagingRateText(host?.pageOutBytesPerSecond))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Paging measures virtual memory activity.")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(9)
        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ name: String, _ value: String?) -> some View {
        HStack(spacing: 5) {
            Text(name).foregroundStyle(.secondary)
            Spacer(minLength: 3)
            Text(value ?? "—").monospacedDigit().fixedSize()
        }
        .accessibilityElement(children: .combine)
    }

    private func pagingRateText(_ rate: Double?) -> String? {
        guard let rate else { return nil }
        if rate == 0 { return "0 B/s" }
        if rate < 1_024 { return "<1 KiB/s" }
        let divisor: Double = rate < 1_048_576 ? 1_024 : 1_048_576
        let value = (rate / divisor).formatted(.number.precision(.fractionLength(0...1)))
        return value + (divisor == 1_024 ? " KiB/s" : " MiB/s")
    }

    private var footer: String {
        guard let host else { return "This Mac" }
        if metric == .cpu { return "This Mac" }
        let pressure = host.memoryPressure.map { "Memory pressure: " + $0 } ?? "Memory pressure unavailable"
        let coverage = host.missingProcesses == 0 ? "" : " · Partial process coverage"
        return pressure + coverage
    }

    private func groupRow(_ group: Workload) -> some View {
        Button {
            expanded = expanded == group ? nil : group
        } label: {
            groupLabel(group)
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded == group ? "Hide workload details" : "Show workload details")
        .accessibilityValue(expanded == group ? "Expanded" : "Collapsed")
    }

    private func groupLabel(_ group: Workload) -> some View {
        HStack(spacing: 8) {
            if metric == .cpu {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(RamBrand.workload(group, dark: dark)).frame(width: 9, height: 9)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).fontWeight(.semibold)
                if let text = subtitle(group) {
                    Text(text).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Text(valueText(host?.groups[group.id])).monospacedDigit().fontWeight(.medium)
            Image(systemName: expanded == group ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minHeight: 36)
        .contentShape(Rectangle())
        .background(expanded == group ? Color.primary.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
    }

    private func subtitle(_ group: Workload) -> String? {
        switch group {
        case .codex:
            if host == nil { return nil }
            if chatCount == 0 { return "No registered chat work" }
            return chatCount == 1 ? "1 chat with tracked work" : "\(chatCount) chats with tracked work"
        case .docker:
            if guest == nil { return "Collecting local CI readings" }
            if guest?.configured == false { return "CI runners not configured" }
            if guest?.rows == nil || guestStale { return "Run readings unavailable" }
            if runCount == 0 { return "No labeled runs in this sample" }
            return runCount == 1 ? "1 labeled local run" : "\(runCount) labeled local runs"
        default: return nil
        }
    }

    private func processDetails(_ group: Workload) -> some View {
        let rows = (host?.details[group.id] ?? []).sorted { lhs, rhs in
            let a = amount(lhs.value), b = amount(rhs.value)
            return a == b ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : a > b
        }
        return VStack(alignment: .leading, spacing: 0) {
            if rows.isEmpty {
                detailLine(host == nil ? "Collecting process samples" : "No readable processes", value: nil)
            }
            ForEach(rows) { row in
                detailLine(row.name, note: row.note, value: valueText(row.value))
            }
                if group == .codex {
                    HStack {
                        Text(trackingCopyStatus ?? "Track a command from its Codex chat.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy command prefix") { copyTrackingPrefix() }
                            .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .padding(.vertical, 7)
                }
        }
        .padding(.leading, 23)
        .padding(.trailing, 20)
    }

    private func copyTrackingPrefix() {
        guard let path = Bundle.main.executableURL?.path else { return }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents()
        let copied = NSPasteboard.general.setString(quoted + " --track -- ", forType: .string)
        let status = copied ? "Copied. Add the command after --." : "Couldn’t copy the command prefix."
        trackingCopyStatus = status
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: status, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private var dockerDetail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Guest usage inside Docker. The Mac total already includes the VM.")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.vertical, 5)
            if guest?.configured == false {
                detailLine("CI runners not configured", note: "Add runners.json to the Ram Meter support folder.", value: nil)
            } else if guest?.rows == nil || guestStale {
                detailLine(guest == nil ? "Collecting runner samples" : "Runner readings unavailable", value: nil)
            } else {
                let labeled = guestRows.filter { $0.job != nil }
                let grouped = Dictionary(grouping: labeled) { $0.job!.key }
                ForEach(grouped.keys.sorted(), id: \.self) { key in
                    if let rows = grouped[key], let job = rows.first?.job {
                        detailLine(job.name, note: "Attempt " + job.attempt + " · " + runnerCount(rows),
                                   value: guestValue(rows))
                    }
                }
                ForEach(guestRows.filter { $0.job == nil && !$0.idle }, id: \.id) { row in
                    detailLine("Runner activity", note: row.runner + " · Run identity unavailable",
                               value: guestValue([row]))
                }
                if grouped.isEmpty && guestRows.allSatisfy(\.idle) {
                    detailLine("No local job identified", value: nil)
                }
                ForEach(ended.keys.sorted(), id: \.self) { key in
                    if let entry = ended[key], let job = entry.rows.first?.job,
                       Date().timeIntervalSince(entry.date) < 30 {
                        detailLine(job.name, note: "Ended · Last sample", value: guestValue(entry.rows))
                    }
                }
            }
        }
        .padding(.leading, 23)
        .padding(.trailing, 20)
    }

    private func runnerCount(_ rows: [GuestReading]) -> String {
        rows.count == 1 ? "1 runner" : "\(rows.count) runners"
    }

    private func guestValue(_ rows: [GuestReading]) -> String {
        if metric == .ram { return memory(rows.reduce(0) { $0 + $1.bytes }) }
        let cores = rows.reduce(0) { $0 + $1.cpu }
        return cores.formatted(.number.precision(.fractionLength(2))) + " cores"
    }

    private func detailLine(_ name: String, note: String? = nil, value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(2)
                if let note {
                    Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 5)
            if let value { Text(value).monospacedDigit().fontWeight(.medium) }
        }
        .font(.caption)
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

@main
struct WorkloadMeterApp: App {
    @StateObject private var monitor: Monitor
    @AppStorage("metric") private var metric: Metric = .cpu

    init() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "--track" { Registration.launch(Array(arguments.dropFirst())) }
        if arguments.first == "--read-live" { Self.readLive(includeGuest: arguments.contains("--ci")) }
        if arguments.first == "--render" { Self.render(arguments) }
        let meter = Monitor()
        _monitor = StateObject(wrappedValue: meter)
        DispatchQueue.main.async { meter.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            Dashboard(host: monitor.host, history: monitor.history, guest: monitor.guest, ended: monitor.endedJobs,
                      metric: $metric, expanded: $monitor.expanded) { NSApp.terminate(nil) }
                .onAppear { monitor.setShowing(true) }
                .onDisappear { monitor.setShowing(false) }
        } label: {
            HStack(spacing: 4) {
                if let mark = RamBrand.mark {
                    Image(nsImage: mark).accessibilityHidden(true)
                } else {
                    Image(systemName: "chart.xyaxis.line").accessibilityHidden(true)
                }
                Text(statusText).monospacedDigit()
            }
            .accessibilityLabel(statusLabel)
            .help(statusLabel)
        }
        .menuBarExtraStyle(.window)
    }

    private var freshHost: HostSnapshot? {
        monitor.host.flatMap { Date().timeIntervalSince($0.date) < 15 ? $0 : nil }
    }

    private var ramStatus: String? {
        guard let host = freshHost, let used = host.usedMemoryBytes, host.installedBytes > 0 else { return nil }
        return (Double(used) / Double(host.installedBytes))
            .formatted(.percent.precision(.fractionLength(0)))
    }

    private var cpuStatus: String? {
        freshHost?.busy?.formatted(.percent.precision(.fractionLength(0)))
    }

    private var statusText: String {
        "CPU " + (cpuStatus ?? "—") + "  RAM " + (ramStatus ?? "—")
    }

    private var statusLabel: String {
        RamBrand.name + ", Mac CPU used " + (cpuStatus ?? "unavailable") +
            ", Mac RAM used " + (ramStatus ?? "unavailable")
    }

    private static func snapshot() -> HostSnapshot {
        let sampler = HostSampler()
        _ = sampler.sample()
        Thread.sleep(forTimeInterval: 2)
        return sampler.sample()
    }

    private static func readLive(includeGuest: Bool) -> Never {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        struct Report: Codable {
            let host: HostSnapshot
            let guest: [GuestReading]?
        }
        let report = Report(host: snapshot(), guest: includeGuest ? RunnerSampler().sample().rows : nil)
        guard let data = try? encoder.encode(report) else { exit(1) }
        FileHandle.standardOutput.write(data)
        exit(0)
    }

    private static func render(_ arguments: [String]) -> Never {
        guard arguments.count == 2 else { exit(64) }
        _ = NSApplication.shared
        let ram = arguments[1].contains("-ram")
        let sampler = HostSampler()
        var history = UsageHistory()
        var host = sampler.sample()
        for _ in 0..<4 {
            Thread.sleep(forTimeInterval: 0.5)
            host = sampler.sample()
            history.append(UsageSample(host: host, time: ProcessInfo.processInfo.systemUptime))
        }
        let view = Dashboard(host: host, history: history, guest: nil, ended: [:],
                             metric: .constant(ram ? .ram : .cpu),
                             expanded: .constant(nil),
                             onQuit: {})
            .padding(4).background(.regularMaterial)
            .environment(\.colorScheme, ram ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        do { try png.write(to: URL(fileURLWithPath: arguments[1])) } catch { exit(1) }
        exit(0)
    }
}
