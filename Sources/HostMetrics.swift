import Darwin
import Foundation

struct ProcessKey: Codable, Hashable {
    let pid: pid_t
    let start: UInt64
}

struct ProcessReading {
    let key: ProcessKey
    let parent: pid_t
    let uid: uid_t
    let cpu: UInt64
    let bytes: UInt64
    let executable: String
}

enum Workload: String, CaseIterable, Identifiable {
    case docker, codex, browsers, other, idle

    var id: String { rawValue }
    var name: String {
        switch self {
        case .docker: return "Docker VM"
        case .codex: return "Codex"
        case .browsers: return "Browsers"
        case .other: return "Other apps & macOS"
        case .idle: return "Idle"
        }
    }
}

struct Measurement: Codable {
    var cpu: Double = 0
    var bytes: UInt64 = 0

    mutating func add(_ other: Measurement) {
        cpu += other.cpu
        bytes += other.bytes
    }
}

struct WorkloadRow: Codable, Identifiable {
    let id: String
    var name: String
    var note: String? = nil
    var value = Measurement()
}

struct HostSnapshot: Codable {
    let date: Date
    let busy: Double?
    let cpuBreakdown: Bool
    let groups: [String: Measurement]
    let details: [String: [WorkloadRow]]
    let processBytes: UInt64
    let installedBytes: UInt64
    let memoryPressure: String?
    let missingProcesses: Int
    let cores: Int
}

func processUsage(_ pid: pid_t) -> rusage_info_v0? {
    var usage = rusage_info_v0()
    let result = withUnsafeMutablePointer(to: &usage) { pointer in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V0, $0)
        }
    }
    return result == 0 && usage.ri_proc_start_abstime != 0 ? usage : nil
}

func processBSDInfo(_ pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout.size(ofValue: info))
    return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
}

final class HostSampler {
    private let hardware = ProcessInfo.processInfo
    private var timebase = mach_timebase_info_data_t()
    private var previousTicks: [UInt32]?
    private var previousTime: UInt64?
    private var previousProcesses: [ProcessKey: ProcessReading] = [:]

    init() { mach_timebase_info(&timebase) }

    func reset() {
        previousTicks = nil
        previousTime = nil
        previousProcesses = [:]
    }

    private func hostTicks() -> [UInt32]? {
        var info = host_cpu_load_info()
        let size = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(size)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: size) {
                host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        return [ticks.0, ticks.1, ticks.2, ticks.3]
    }

    private func readProcesses() -> ([ProcessReading], Int) {
        var pids = [pid_t](repeating: 0, count: max(256, Int(proc_listallpids(nil, 0)) + 128))
        let count = pids.withUnsafeMutableBytes {
            Int(proc_listallpids($0.baseAddress, Int32($0.count)))
        }
        guard count > 0 else { return ([], 1) }
        var denied = 0
        var rows: [ProcessReading] = []
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(count) where pid > 0 {
            guard let info = processBSDInfo(pid) else { denied += 1; continue }
            guard let usage = processUsage(pid) else { denied += 1; continue }
            let key = ProcessKey(pid: pid, start: usage.ri_proc_start_abstime)
            // Reuse a path for an established process. The registration wrapper
            // owns its identity across exec, where the original path is immaterial.
            let executable: String
            if let old = previousProcesses[key], !old.executable.isEmpty {
                executable = old.executable
            } else if proc_pidpath(pid, &path, UInt32(path.count)) > 0 ||
                        proc_name(pid, &path, UInt32(path.count)) > 0 {
                executable = String(cString: path)
            } else {
                executable = ""
            }
            rows.append(ProcessReading(key: key, parent: pid_t(info.pbi_ppid), uid: info.pbi_uid,
                                       cpu: usage.ri_user_time + usage.ri_system_time,
                                       bytes: usage.ri_phys_footprint, executable: executable))
        }
        return (rows, denied)
    }

    private func pressure() -> String? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else {
            return nil
        }
        switch level {
        case 1: return "Normal"
        case 2: return "Warning"
        case 4: return "Critical"
        default: return nil
        }
    }

    func sample() -> HostSnapshot {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let ticks = hostTicks()
        let (processes, denied) = readProcesses()
        let table = Dictionary(uniqueKeysWithValues: processes.map { ($0.key.pid, $0) })
        let registrations = Registration.activeProcesses(table)
        let dockerVMs = processes.filter { $0.executable.hasSuffix("/com.apple.Virtualization.VirtualMachine") }
        let dockerVM = dockerVMs.count == 1 && processes.contains(where: {
            $0.executable.hasSuffix("/Docker.app/Contents/MacOS/com.docker.virtualization")
        }) ? dockerVMs.first?.key : nil
        let classifications = Dictionary(uniqueKeysWithValues: processes.map {
            ($0.key, classify($0.executable, dockerVM: $0.key == dockerVM))
        })
        let coreCount = max(1, hardware.activeProcessorCount)
        let elapsed = previousTime.map { now > $0 ? Double(now - $0) : 0 } ?? 0
        var busy: Double?
        // Reset after sleep or a missed sampling interval.
        if elapsed > 0, elapsed < 16_000_000_000,
           let ticks, let previousTicks {
            let delta = zip(ticks, previousTicks).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            if total > 0 { busy = 1 - delta[Int(CPU_STATE_IDLE)] / total }
        }
        var groups: [Workload: Measurement] = [:]
        var details: [Workload: [String: WorkloadRow]] = [:]
        let nanosPerTick = Double(timebase.numer) / Double(max(1, timebase.denom))
        for process in processes {
            let owner = ownership(of: process, in: table, registered: registrations, classifications: classifications)
            let cpu: Double
            if busy != nil, let old = previousProcesses[process.key], process.cpu >= old.cpu {
                cpu = Double(process.cpu - old.cpu) * nanosPerTick / elapsed / Double(coreCount)
            } else {
                cpu = 0
            }
            let measure = Measurement(cpu: cpu, bytes: process.bytes)
            groups[owner.0, default: Measurement()].add(measure)
            details[owner.0, default: [:]][owner.1,
                default: WorkloadRow(id: owner.1, name: owner.2, note: owner.3)].value.add(measure)
        }
        var reconciled = false
        if let busy {
            let attributed = groups.values.reduce(0) { $0 + $1.cpu }
            if attributed <= busy + 0.02 {
                reconciled = true
                if attributed > busy, attributed > 0 {
                    let factor = busy / attributed
                    for category in Workload.allCases {
                        groups[category]?.cpu *= factor
                        for id in details[category]?.keys.map({ $0 }) ?? [] {
                            details[category]?[id]?.value.cpu *= factor
                        }
                    }
                } else if attributed < busy {
                    let residual = Measurement(cpu: busy - attributed)
                    groups[.other, default: Measurement()].add(residual)
                    details[.other, default: [:]]["residual"] = WorkloadRow(
                        id: "residual", name: "Unattributed CPU", value: residual)
                }
            }
            groups[.idle] = Measurement(cpu: 1 - busy)
        }
        previousTicks = ticks
        previousTime = now
        previousProcesses = Dictionary(uniqueKeysWithValues: processes.map { ($0.key, $0) })
        return HostSnapshot(date: Date(), busy: busy, cpuBreakdown: reconciled,
                            groups: Dictionary(uniqueKeysWithValues: groups.map { ($0.key.rawValue, $0.value) }),
                            details: Dictionary(uniqueKeysWithValues: details.map { ($0.key.rawValue, Array($0.value.values)) }),
                            processBytes: groups.values.reduce(0) { $0 + $1.bytes },
                            installedBytes: hardware.physicalMemory, memoryPressure: pressure(),
                            missingProcesses: denied, cores: coreCount)
    }

    private typealias Ownership = (Workload, String, String, String?)

    private func ownership(of process: ProcessReading, in table: [pid_t: ProcessReading],
                           registered: [ProcessKey: Registration], classifications: [ProcessKey: Ownership]) -> Ownership {
        var node = process
        var inheritedCodex = false
        var visited = Set<pid_t>()
        while visited.insert(node.key.pid).inserted {
            if node.uid == process.uid, let tag = registered[node.key] {
                return (.codex, tag.chat, tag.name ?? "Chat " + tag.chat.suffix(8), "Tracked local work")
            }
            inheritedCodex = inheritedCodex || classifications[node.key]?.0 == .codex
            guard let parent = table[node.parent], parent.key.start <= node.key.start else { break }
            node = parent
        }
        let own = classifications[process.key] ?? (.other, "unknown", "Unknown process", nil)
        if own.0 != .other { return own }
        return inheritedCodex ? (.codex, "shared", "Shared Codex", nil) : own
    }

    private func classify(_ path: String, dockerVM: Bool) -> Ownership {
        let leaf = path.split(separator: "/").last.map(String.init) ?? "Unknown process"
        if path.contains("/Docker.app/") || dockerVM ||
            leaf == "com.docker.vmnetd" || leaf == "com.docker.socket" {
            return (.docker, "docker", "Docker VM & helpers", nil)
        }
        if path.contains("/ChatGPT.app/") && (path.contains("/codex-cli/") || path.contains("Codex")) ||
            path.contains("/Codex.app/") || path.contains("/Codex Computer Use.app/") ||
            leaf == "codex" || leaf == "codex-code-mode-host" {
            return (.codex, "shared", "Shared Codex", nil)
        }
        for browser in ["Google Chrome", "Safari", "Firefox", "Microsoft Edge", "Brave Browser", "Arc"] {
            if path.contains("/" + browser + ".app/") {
                return (.browsers, browser, browser, "App and helpers")
            }
        }
        let bundle = path.components(separatedBy: "/").first { $0.hasSuffix(".app") }
        let name = bundle.map { String($0.dropLast(4)) } ?? leaf
        return (.other, name, name, nil)
    }
}
