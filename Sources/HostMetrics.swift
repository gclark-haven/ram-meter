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
    case docker, codex, browsers, nodeServers, iOSSimulator, androidEmulator, other, idle

    var id: String { rawValue }
    var name: String {
        switch self {
        case .docker: return "Docker VM"
        case .codex: return "Codex"
        case .browsers: return "Browsers"
        case .nodeServers: return "Node servers"
        case .iOSSimulator: return "iOS Simulator"
        case .androidEmulator: return "Android Emulator"
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
    let usedMemoryBytes: UInt64?
    let memoryPressure: String?
    let missingProcesses: Int
    let processCounts: ProcessCounts?
    let cores: Int
    let cpuUser: Double?
    let cpuSystem: Double?
    let physicalCores: Int?
    let wiredBytes: UInt64?
    let compressedBytes: UInt64?
    let pageInBytesPerSecond: Double?
    let pageOutBytesPerSecond: Double?
}

struct ProcessCounts: Codable {
    let processes: Int
    let observedThreads: Int
    let processesWithThreadCounts: Int
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
    private var previousMemory: vm_statistics64?
    private var previousTime: UInt64?
    private var previousProcesses: [ProcessKey: ProcessReading] = [:]

    private let physicalCores: Int? = {
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        guard sysctlbyname("hw.physicalcpu", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return Int(value)
    }()

    init() { mach_timebase_info(&timebase) }

    func reset() {
        previousTicks = nil
        previousMemory = nil
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

    private func readProcesses() -> ([ProcessReading], Int, ProcessCounts?) {
        func listPIDs(_ capacity: Int) -> (pids: [pid_t], count: Int) {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = pids.withUnsafeMutableBytes {
                Int(proc_listallpids($0.baseAddress, Int32($0.count)))
            }
            return (pids, count)
        }
        let capacity = max(256, Int(proc_listallpids(nil, 0)) + 128)
        var list = listPIDs(capacity)
        if list.count >= list.pids.count { list = listPIDs(capacity * 2) }
        guard list.count > 0 else { return ([], 1, nil) }
        let pids = list.pids.prefix(list.count).filter { $0 > 0 }
        var denied = 0
        var observedThreads = 0
        var processesWithThreadCounts = 0
        var rows: [ProcessReading] = []
        var path = [CChar](repeating: 0, count: 4096)
        for pid in pids {
            var task = proc_taskallinfo()
            let size = Int32(MemoryLayout.size(ofValue: task))
            let taskRead = proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &task, size) == size
            if taskRead, task.ptinfo.pti_threadnum > 0 {
                observedThreads += Int(task.ptinfo.pti_threadnum)
                processesWithThreadCounts += 1
            }
            // Keep attribution for processes whose basic information is readable.
            guard let info = taskRead ? task.pbsd : processBSDInfo(pid) else { denied += 1; continue }
            guard let usage = processUsage(pid) else { denied += 1; continue }
            let key = ProcessKey(pid: pid, start: usage.ri_proc_start_abstime)
            let executable: String
            // exec can change the executable without changing PID or start time.
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 ||
                        proc_name(pid, &path, UInt32(path.count)) > 0 {
                executable = String(cString: path)
            } else {
                executable = ""
            }
            rows.append(ProcessReading(key: key, parent: pid_t(info.pbi_ppid), uid: info.pbi_uid,
                                       cpu: usage.ri_user_time + usage.ri_system_time,
                                       bytes: usage.ri_phys_footprint, executable: executable))
        }
        let counts = list.count < list.pids.count && !pids.isEmpty
            ? ProcessCounts(processes: pids.count, observedThreads: observedThreads,
                            processesWithThreadCounts: processesWithThreadCounts)
            : nil
        return (rows, denied, counts)
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

    private func memoryStatistics() -> vm_statistics64? {
        var info = vm_statistics64()
        let words = MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: words) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        // Older kernels return the original VM counters without the tag-storage fields.
        let tagOffset = MemoryLayout<vm_statistics64>.offset(of: \.total_tag_storage_pages)!
        guard status == KERN_SUCCESS, Int(count) * MemoryLayout<integer_t>.size >= tagOffset,
              info.wire_count > 0 else { return nil }
        if Int(count) * MemoryLayout<integer_t>.size < tagOffset + MemoryLayout<UInt64>.size {
            info.total_tag_storage_pages = 0
        }
        return info
    }

    private func usedMemoryBytes(_ info: vm_statistics64) -> UInt64 {
        // Count anonymous memory, wired pages and physical compressor storage.
        // Exclude purgeable anonymous pages and avoid counting file caches.
        let anonymous = UInt64(info.internal_page_count) -
            UInt64(min(info.internal_page_count, info.purgeable_count))
        // Include the kernel-reported tag-storage region in the whole-Mac estimate.
        let pages = anonymous + UInt64(info.wire_count) + UInt64(info.compressor_page_count)
            + info.total_tag_storage_pages
        return min(pages * UInt64(vm_kernel_page_size), hardware.physicalMemory)
    }

    private func pagingRate(_ current: UInt64?, _ previous: UInt64?, elapsed: Double) -> Double? {
        guard let current, let previous, current >= previous, elapsed > 0, elapsed < 16_000_000_000 else {
            return nil
        }
        return Double(current - previous) * Double(vm_kernel_page_size) * 1_000_000_000 / elapsed
    }

    func sample() -> HostSnapshot {
        let now = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        let ticks = hostTicks()
        let memory = memoryStatistics()
        let (processes, denied, counts) = readProcesses()
        let table = Dictionary(uniqueKeysWithValues: processes.map { ($0.key.pid, $0) })
        let registrations = Registration.activeProcesses(table)
        let dockerVMs = processes.filter { $0.executable.hasSuffix("/com.apple.Virtualization.VirtualMachine") }
        let dockerVM = dockerVMs.count == 1 && processes.contains(where: {
            $0.executable.hasSuffix("/Docker.app/Contents/MacOS/com.docker.virtualization")
        }) ? dockerVMs.first?.key : nil
        let simulatorRoots = iOSSimulatorRoots(processes, in: table)
        let classifications = Dictionary(uniqueKeysWithValues: processes.map {
            ($0.key, classify($0, dockerVM: $0.key == dockerVM, simulatorRoots: simulatorRoots))
        })
        let coreCount = max(1, hardware.activeProcessorCount)
        let elapsed = previousTime.map { now > $0 ? Double(now - $0) : 0 } ?? 0
        var busy: Double?
        var cpuUser: Double?
        var cpuSystem: Double?
        // Reset after sleep or a missed sampling interval.
        if elapsed > 0, elapsed < 16_000_000_000,
           let ticks, let previousTicks {
            let delta = zip(ticks, previousTicks).map { Double($0 &- $1) }
            let total = delta.reduce(0, +)
            if total > 0 {
                busy = 1 - delta[Int(CPU_STATE_IDLE)] / total
                cpuUser = (delta[Int(CPU_STATE_USER)] + delta[Int(CPU_STATE_NICE)]) / total
                cpuSystem = delta[Int(CPU_STATE_SYSTEM)] / total
            }
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
        let pageIn = pagingRate(memory?.pageins, previousMemory?.pageins, elapsed: elapsed)
        let pageOut = pagingRate(memory?.pageouts, previousMemory?.pageouts, elapsed: elapsed)
        previousTicks = ticks
        previousMemory = memory
        previousTime = now
        previousProcesses = Dictionary(uniqueKeysWithValues: processes.map { ($0.key, $0) })
        return HostSnapshot(date: Date(), busy: busy, cpuBreakdown: reconciled,
                            groups: Dictionary(uniqueKeysWithValues: groups.map { ($0.key.rawValue, $0.value) }),
                            details: Dictionary(uniqueKeysWithValues: details.map { ($0.key.rawValue, Array($0.value.values)) }),
                            processBytes: groups.values.reduce(0) { $0 + $1.bytes },
                            installedBytes: hardware.physicalMemory, usedMemoryBytes: memory.map(usedMemoryBytes),
                            memoryPressure: pressure(),
                            missingProcesses: denied, processCounts: counts, cores: coreCount,
                            cpuUser: cpuUser, cpuSystem: cpuSystem, physicalCores: physicalCores,
                            wiredBytes: memory.map { UInt64($0.wire_count) * UInt64(vm_kernel_page_size) },
                            compressedBytes: memory.map { UInt64($0.compressor_page_count) * UInt64(vm_kernel_page_size) },
                            pageInBytesPerSecond: pageIn, pageOutBytesPerSecond: pageOut)
    }

    private typealias Ownership = (Workload, String, String, String?)

    private func ownership(of process: ProcessReading, in table: [pid_t: ProcessReading],
                           registered: [ProcessKey: Registration], classifications: [ProcessKey: Ownership]) -> Ownership {
        let own = classifications[process.key] ?? (.other, "unknown", "Unknown process", nil)
        if own.0.isDevelopment { return own }
        var node = process
        var inheritedCodex = false
        var registration: Registration?
        var visited = Set<pid_t>()
        while visited.insert(node.key.pid).inserted {
            if node.uid == process.uid {
                if own.0 == .other, let parent = classifications[node.key], parent.0.isDevelopment {
                    return parent
                }
                if registration == nil { registration = registered[node.key] }
            }
            inheritedCodex = inheritedCodex || classifications[node.key]?.0 == .codex
            guard let parent = table[node.parent], parent.key.start <= node.key.start else { break }
            node = parent
        }
        if let tag = registration {
            return (.codex, tag.chat, tag.name ?? "Chat " + tag.chat.suffix(8), "Tracked local work")
        }
        if own.0 != .other { return own }
        return inheritedCodex ? (.codex, "shared", "Shared Codex", nil) : own
    }

    private func classify(_ process: ProcessReading, dockerVM: Bool, simulatorRoots: Set<ProcessKey>) -> Ownership {
        let path = process.executable
        let leaf = path.split(separator: "/").last.map(String.init) ?? "Unknown process"
        if path.contains("/Simulator.app/") || isIOSRuntime(path) || simulatorRoots.contains(process.key) {
            return (.iOSSimulator, "ios", "Simulator and device processes", nil)
        }
        if isAndroidEmulator(path) {
            return (.androidEmulator, "android", "Android virtual device processes", nil)
        }
        if leaf == "node", process.uid == getuid(), hasListeningTCPSocket(process.key.pid) {
            let id = String(process.key.pid)
            return (.nodeServers, id, "Node server · PID " + id, "Listening for TCP connections")
        }
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

    private func isIOSRuntime(_ path: String) -> Bool {
        path.contains("/CoreSimulator/") && path.contains("/iOS ") && path.contains(".simruntime/")
    }

    private func isAndroidEmulator(_ path: String) -> Bool {
        if path.hasSuffix("/emulator/emulator") { return true }
        return path.contains("/emulator/qemu/") &&
            (path.split(separator: "/").last?.hasPrefix("qemu-system-") == true)
    }

    private func iOSSimulatorRoots(_ processes: [ProcessReading],
                                   in table: [pid_t: ProcessReading]) -> Set<ProcessKey> {
        var roots = Set<ProcessKey>()
        for process in processes where isIOSRuntime(process.executable) {
            var node = process
            var visited = Set<ProcessKey>()
            while visited.insert(node.key).inserted {
                if node.executable.split(separator: "/").last == "launchd_sim" {
                    roots.insert(node.key)
                    break
                }
                guard let parent = table[node.parent], parent.key.start <= node.key.start else { break }
                node = parent
            }
        }
        return roots
    }

    private func hasListeningTCPSocket(_ pid: pid_t) -> Bool {
        let wanted = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard wanted > 0 else { return false }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: min(4096, Int(wanted) / stride + 32))
        let count = descriptors.withUnsafeMutableBytes {
            Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))) / stride
        }
        guard count > 0 else { return false }
        for descriptor in descriptors.prefix(count) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            if proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
               info.psi.soi_kind == Int32(SOCKINFO_TCP),
               info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN {
                return true
            }
        }
        return false
    }
}

private extension Workload {
    var isDevelopment: Bool {
        self == .nodeServers || self == .iOSSimulator || self == .androidEmulator
    }
}
