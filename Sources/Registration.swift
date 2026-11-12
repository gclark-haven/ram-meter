import Darwin
import Foundation

struct Registration: Codable {
    let process: ProcessKey
    let chat: String
    let name: String?

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Workload Meter/Registrations", isDirectory: true)
    }

    static func activeProcesses(_ processes: [pid_t: ProcessReading]) -> [ProcessKey: Registration] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return [:] }
        var active: [ProcessKey: Registration] = [:]
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("process-") {
            guard let properties = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
                  properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? 0) <= 2048,
                  let data = try? Data(contentsOf: file),
                  let row = try? JSONDecoder().decode(Registration.self, from: data),
                  row.process.pid > 1, UUID(uuidString: row.chat) != nil,
                  row.filename == file.lastPathComponent else { continue }
            if let proc = processes[row.process.pid], proc.key == row.process, proc.uid == getuid() {
                active[row.process] = row
            } else if (kill(row.process.pid, 0) == -1 && errno == ESRCH) ||
                      processes[row.process.pid].map({ $0.key != row.process }) == true {
                try? fm.removeItem(at: file)
            }
        }
        return active
    }

    private var filename: String { "process-\(process.pid)-\(process.start).json" }

    static func launch(_ arguments: [String]) -> Never {
        guard let divider = arguments.firstIndex(of: "--"), divider < arguments.count - 1,
              divider == 0 || (divider == 2 && arguments[0] == "--name") else {
            stop("Usage: workload-meter --track [--name chat-title] -- command [arguments]", code: 64)
        }
        let command = Array(arguments.suffix(from: divider + 1))
        if let chat = ProcessInfo.processInfo.environment["CODEX_THREAD_ID"], UUID(uuidString: chat) != nil,
           let usage = processUsage(getpid()) {
            let label = divider == 2 ? String(arguments[1].prefix(120)) : nil
            let row = Registration(process: ProcessKey(pid: getpid(), start: usage.ri_proc_start_abstime),
                                   chat: chat.lowercased(), name: label?.isEmpty == true ? nil : label)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let file = directory.appendingPathComponent(row.filename)
                try JSONEncoder().encode(row).write(to: file, options: .atomic)
            } catch {
                fputs("Workload Meter: command will run without registration.\n", stderr)
            }
        } else {
            fputs("Workload Meter: no Codex chat ID available. Running command without registration.\n", stderr)
        }
        var argv = command.map { strdup($0) }
        argv.append(nil)
        let error = argv.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let first = buffer[0], let base = buffer.baseAddress else { return ENOMEM }
            execvp(first, base)
            return errno
        }
        argv.forEach { free($0) }
        stop("Workload Meter: could not launch \(command[0]) (\(String(cString: strerror(error)))).",
             code: error == ENOENT ? 127 : 126)
    }

    private static func stop(_ message: String, code: Int32) -> Never {
        fputs(message + "\n", stderr)
        exit(code)
    }
}
