import AppKit
import Foundation

struct JobIdentity: Codable {
    let repository: String
    let run: String
    let attempt: String
    let workflow: String

    var key: String { repository + "/" + run + "/" + attempt }
    var name: String { workflow + " #" + run }
}

struct GuestReading: Codable {
    let id: String
    let runner: String
    let cpu: Double
    let bytes: UInt64
    let worker: String?
    var job: JobIdentity?
    let reusable: Bool
    let idle: Bool
}

struct GuestSnapshot {
    let date: Date
    let rows: [GuestReading]?
    let configured: Bool
}

final class RunnerSampler {
    private var jobsByWorker: [String: JobIdentity] = [:]
    static var config: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Ram Meter/runners.json")
    }

    func reset() { jobsByWorker.removeAll() }

    func sample() -> GuestSnapshot {
        let configured = FileManager.default.fileExists(atPath: Self.config.path)
        let result = configured ? read() : nil
        var retained: [String: JobIdentity] = [:]
        let rows = result?.map { row in
            var sample = row
            if row.reusable, let worker = row.worker {
                let key = row.id + "/" + worker
                sample.job = row.job ?? jobsByWorker[key]
                retained[key] = sample.job
            }
            return sample
        }
        jobsByWorker = retained
        return GuestSnapshot(date: Date(), rows: rows, configured: configured)
    }

    private func read() -> [GuestReading]? {
        guard let script = Bundle.main.url(forResource: "runner_metrics", withExtension: "py") else { return nil }
        let fm = FileManager.default
        guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first(where: fm.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", script.path, Self.config.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return try? JSONDecoder().decode([GuestReading].self, from: data)
    }
}

final class Monitor: ObservableObject {
    @Published private(set) var host: HostSnapshot?
    private(set) var history = UsageHistory()
    @Published private(set) var guest: GuestSnapshot?
    @Published private(set) var endedJobs: [String: EndedJob] = [:]
    @Published var expanded: Workload?

    struct EndedJob {
        let rows: [GuestReading]
        let date: Date
    }

    private let hostSampler = HostSampler()
    private let runnerSampler = RunnerSampler()
    private let hostQueue = DispatchQueue(label: "Ram Meter host", qos: .utility)
    private let runnerQueue = DispatchQueue(label: "Ram Meter runner", qos: .utility)
    private var timer: Timer?
    private var measuringHost = false
    private var measuringGuest = false
    private var showing = false
    private var lastGuestRequest: Date?
    private var wakeObserver: NSObjectProtocol?
    private var generation = 0

    func start() {
        guard timer == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.wake() }
        schedule()
        poll()
    }

    private func wake() {
        generation += 1
        history = UsageHistory()
        host = nil
        guest = nil
        endedJobs = [:]
        lastGuestRequest = nil
        hostQueue.async { [hostSampler] in hostSampler.reset() }
        runnerQueue.async { [runnerSampler] in runnerSampler.reset() }
        poll()
    }

    func setShowing(_ value: Bool) {
        start()
        showing = value
        schedule()
        if value { poll() }
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.poll()
        }
        timer?.tolerance = 0.25
    }

    private func poll() {
        let requestedGeneration = generation
        if !measuringHost {
            measuringHost = true
            hostQueue.async { [weak self] in
                guard let self else { return }
                let time = ProcessInfo.processInfo.systemUptime
                let snapshot = self.hostSampler.sample()
                DispatchQueue.main.async {
                    self.measuringHost = false
                    if self.generation == requestedGeneration {
                        self.history.append(UsageSample(host: snapshot, time: time))
                        self.host = snapshot
                    } else { self.poll() }
                }
            }
        }
        guard showing, !measuringGuest,
              lastGuestRequest.map({ Date().timeIntervalSince($0) > 6 }) ?? true else { return }
        lastGuestRequest = Date()
        measuringGuest = true
        runnerQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.runnerSampler.sample()
            DispatchQueue.main.async {
                self.measuringGuest = false
                if self.generation == requestedGeneration { self.receiveGuest(snapshot) }
                else { self.poll() }
            }
        }
    }

    private func receiveGuest(_ snapshot: GuestSnapshot) {
        let now = snapshot.date
        endedJobs = endedJobs.filter { now.timeIntervalSince($0.value.date) < 30 }
        if let rows = snapshot.rows, let previous = guest?.rows {
            let currentKeys = Set(rows.compactMap { $0.job?.key })
            let runners = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            let previousRuns = Dictionary(grouping: previous.filter { $0.job != nil }) { $0.job!.key }
            for (key, readings) in previousRuns where !currentKeys.contains(key) {
                // Require a fresh sample of the same containers showing that
                // their workers changed. A missing counter alone proves nothing.
                if readings.allSatisfy({ old in
                    guard let new = runners[old.id] else { return false }
                    return new.idle || (new.reusable && new.worker != old.worker)
                }) {
                    endedJobs[key] = EndedJob(rows: readings, date: now)
                }
            }
            for key in currentKeys { endedJobs.removeValue(forKey: key) }
        }
        guest = snapshot
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}
