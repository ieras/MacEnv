import Foundation
import Darwin

struct ManagedProcess: Codable {
    let pid: Int32
    let command: String
    let executable: String
    let startedAt: UInt64
}

enum Command {
    static let brewEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
    static var proxyEnvironment: [String: String] = [:]

    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) async throws -> CommandOutput {
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macenv-command-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdout = directory.appendingPathComponent("out")
        let stderr = directory.appendingPathComponent("err")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let out = try FileHandle(forWritingTo: stdout)
        defer { try? out.close() }
        let err = try FileHandle(forWritingTo: stderr)
        defer { try? err.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }.merging(Command.proxyEnvironment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandOutput, Error>) in
                process.terminationHandler = { finished in
                    let result = CommandOutput(status: finished.terminationStatus,
                                               stdout: (try? String(contentsOf: stdout, encoding: .utf8)) ?? "",
                                               stderr: (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
                    continuation.resume(returning: result)
                }
                do {
                    try process.run()
                    if Task.isCancelled { cancel(process) }
                }
                catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancel(process)
        }
        try Task.checkCancellation()
        return result
    }

    static func cancel(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        _ = Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
    }

    static func download(_ url: URL, to file: URL, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = file.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: partial) }
        report(L("message.downloading") + " " + url.absoluteString + "\n")
        let progress = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 800_000_000) } catch { return }
                let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int64 ?? 0
                guard size > 0 else { continue }
                report("\r" + String(format: L("message.downloadProgress"), String(format: "%.1f", Double(size) / 1_048_576)))
            }
        }
        defer { progress.cancel() }
        let head = try? await Command.run("/usr/bin/curl", ["-sIL", "--connect-timeout", "15", "--max-time", "30", url.absoluteString])
        try Task.checkCancellation()
        let expected = Self.contentLength(head?.stdout ?? "")
        let status = try await stream("/usr/bin/curl", ["-fL", "-sS", "--connect-timeout", "15", "--speed-limit", "1", "--speed-time", "30", "-o", partial.path, url.absoluteString],
                                      onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.downloadFailed") + "（\(status)）") }
        if let expected {
            let actual = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int64 ?? 0
            guard actual == Int64(expected) else {
                throw CommandError(message: L("error.downloadIncomplete"))
            }
        }
        try Task.checkCancellation()
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: partial, to: file)
    }

    static func contentLength(_ headers: String) -> Int? {
        var length: Int?
        for line in headers.lowercased().split(whereSeparator: \.isNewline) {
            if line.hasPrefix("http/") { length = nil }
            else if line.hasPrefix("content-length:") {
                length = Int(line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
            }
        }
        return length
    }

    static func privilegedLaunchCommand(script: URL, log: URL) -> String {
        let launch = "set -m; /bin/bash \(singleQuoted(script.path)) < /dev/null > \(singleQuoted(log.path)) 2>&1 & echo $! > \(singleQuoted(script.appendingPathExtension("pid").path)); echo started"
        return "/bin/bash -c " + singleQuoted(launch)
    }

    static func privilegedStream(_ command: String, report: @escaping (String) -> Void) async throws {
        try Task.checkCancellation()
        let name = "macenv-task-" + UUID().uuidString
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".sh")
        let log = script.deletingPathExtension().appendingPathExtension("log")
        let pidFile = script.appendingPathExtension("pid")
        try ("#!/bin/bash\n/bin/bash -c " + singleQuoted(command) + "\nprintf '__MACENV_EXIT=%s\\n' \"$?\"\n").write(to: script, atomically: true, encoding: .utf8)
        try Data().write(to: log)
        defer { for file in [script, log, pidFile] { try? FileManager.default.removeItem(at: file) } }
        do {
            try await Task { try await privileged(privilegedLaunchCommand(script: script, log: log)) }.value
            var offset: UInt64 = 0
            var tail = ""
            let deadline = Date().addingTimeInterval(3600)
            while Date() < deadline {
                try await Task.sleep(nanoseconds: 400_000_000)
                let text = readNew(log, from: &offset)
                if !text.isEmpty { report(text); tail = String((tail + text).suffix(64)) }
                if let value = firstCapture(#"__MACENV_EXIT=(\d+)"#, in: tail) {
                    guard value == "0" else { throw CommandError(message: L("error.toolCommandFailed") + "（\(value)）") }
                    return
                }
            }
            throw CommandError(message: L("error.toolTimeout"))
        } catch {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                let stop = "if /bin/ps -p \(pid) -o command= | /usr/bin/grep -Fq -- \(singleQuoted(script.path)) && [ \"$(/bin/ps -p \(pid) -o pgid= | /usr/bin/tr -d ' ')\" = \"\(pid)\" ]; then /bin/kill -TERM -- -\(pid); for attempt in {1..20}; do /bin/kill -0 -- -\(pid) 2>/dev/null || exit 0; /bin/sleep 0.1; done; /bin/kill -KILL -- -\(pid) 2>/dev/null || true; fi"
                try await Task { try await privileged(stop) }.value
            }
            throw error
        }
    }

    private static func readNew(_ url: URL, from offset: inout UInt64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > offset else { return "" }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        return String(decoding: data, as: UTF8.self)
    }

    static func stream(_ executable: String,
                       _ arguments: [String],
                       environment: [String: String] = [:],
                       onStart: ((Process) -> Void)? = nil,
                       onOutput: @escaping (String) -> Void) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }.merging(Command.proxyEnvironment) { _, new in new }
        let pipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { onOutput(text) }
        }
        defer { pipe.fileHandleForReading.readabilityHandler = nil }
        let status = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
                process.terminationHandler = { finished in
                    pipe.fileHandleForReading.readabilityHandler = nil
                    DispatchQueue.main.async { continuation.resume(returning: finished.terminationStatus) }
                }
                do {
                    try process.run()
                    onStart?(process)
                    if Task.isCancelled { cancel(process) }
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            cancel(process)
        }
        try Task.checkCancellation()
        return status
    }
}

@MainActor
final class ProcessSupervisor {
    private let marker: String
    private(set) var process: Process?
    private var adopted: ManagedProcess?
    var onExit: (() -> Void)?

    init(marker: String) { self.marker = marker }

    var target: ManagedProcess? {
        if let process, process.isRunning { return inspect(process.processIdentifier) }
        guard let adopted else { return nil }
        if let current = inspect(adopted.pid), current.startedAt == adopted.startedAt,
           current.executable == adopted.executable { return current }
        self.adopted = nil
        Task { self.onExit?() }
        return nil
    }

    var isRunning: Bool { target != nil }

    func launch(at executable: URL, arguments: [String], directory: URL, environment: [String: String], errorLog: URL, outputLog: URL? = nil) throws -> Process {
        try Data().write(to: errorLog)
        let handle = try FileHandle(forWritingTo: errorLog)
        defer { try? handle.close() }
        let outputHandle: FileHandle?
        if let outputLog {
            try Data().write(to: outputLog)
            outputHandle = try FileHandle(forWritingTo: outputLog)
        } else {
            outputHandle = nil
        }
        defer { try? outputHandle?.close() }
        let item = Process()
        item.executableURL = executable
        item.arguments = arguments
        item.currentDirectoryURL = directory
        item.environment = environment
        item.standardInput = FileHandle.nullDevice
        item.standardOutput = outputHandle ?? FileHandle.nullDevice
        item.standardError = handle
        item.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self, self.process?.processIdentifier == finished.processIdentifier else { return }
                self.process = nil
                self.onExit?()
            }
        }
        try item.run()
        process = item
        adopted = nil
        do {
            guard let target = inspect(item.processIdentifier) else {
                throw CommandError(message: L("error.databaseStartFailed"))
            }
            try JSONEncoder().encode(target).write(to: URL(fileURLWithPath: marker).appendingPathComponent("process-\(target.pid).json"), options: .atomic)
        } catch {
            Command.cancel(item)
            throw error
        }
        return item
    }

    func inspect(_ pid: Int32) -> ManagedProcess? {
        var info = proc_bsdinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        var arguments: [String]
        if let process, process.processIdentifier == pid {
            arguments = process.arguments ?? []
        } else {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var bytes = [UInt8](repeating: 0, count: Int(sysconf(_SC_ARG_MAX)))
            var size = bytes.count
            guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0, size > 4 else { return nil }
            let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            var offset = 4
            while offset < size, bytes[offset] != 0 { offset += 1 }
            while offset < size, bytes[offset] == 0 { offset += 1 }
            arguments = []
            for _ in 0..<argc {
                let begin = offset
                while offset < size, bytes[offset] != 0 { offset += 1 }
                arguments.append(String(decoding: bytes[begin..<offset], as: UTF8.self))
                if offset < size { offset += 1 }
            }
        }
        let executable = URL(fileURLWithPath: String(cString: path)).resolvingSymlinksInPath().path
        let startedAt = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        let launchedHere = process?.processIdentifier == pid && process?.isRunning == true
        if !launchedHere && !arguments.contains(where: { $0 == marker || $0.contains(marker + "/") }) {
            let receipt = URL(fileURLWithPath: marker).appendingPathComponent("process-\(pid).json")
            guard let data = try? Data(contentsOf: receipt), let saved = try? JSONDecoder().decode(ManagedProcess.self, from: data),
                  saved.pid == pid, saved.startedAt == startedAt, saved.executable == executable else { return nil }
            return saved
        }
        return ManagedProcess(pid: pid, command: executable + " " + arguments.joined(separator: " "),
                              executable: executable, startedAt: startedAt)
    }

    func find(_ binary: String) async throws -> ManagedProcess? {
        if let target, URL(fileURLWithPath: target.executable).lastPathComponent.hasPrefix(binary) { return target }
        let count = proc_listallpids(nil, 0)
        var pids = [Int32](repeating: 0, count: Int(count) + 128)
        let actual = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        for pid in pids.prefix(Int(max(0, actual))) {
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  URL(fileURLWithPath: String(cString: path)).lastPathComponent.hasPrefix(binary),
                  let target = inspect(pid) else { continue }
            return target
        }
        return nil
    }

    func adopt(_ target: ManagedProcess) { adopted = target }

    func owned(pidFile: URL, binary: String) -> ManagedProcess? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let target = inspect(pid), URL(fileURLWithPath: target.executable).lastPathComponent == binary else { return nil }
        return target
    }

    func signal(_ target: ManagedProcess, _ signal: Int32) throws {
        guard let current = inspect(target.pid), current.startedAt == target.startedAt,
              current.executable == target.executable else { return }
        guard Darwin.kill(target.pid, signal) == 0 || errno == ESRCH else {
            throw CommandError(message: String(cString: strerror(errno)))
        }
    }

    private func waitGone(_ target: ManagedProcess, attempts: Int) async throws {
        for _ in 0..<attempts {
            guard let current = inspect(target.pid), current.startedAt == target.startedAt else { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    func terminate(_ target: ManagedProcess, graceful: (() async throws -> Void)? = nil, force: Bool = false) async throws {
        guard let current = inspect(target.pid), current.startedAt == target.startedAt,
              current.executable == target.executable else { return }
        if let graceful {
            try? await graceful()
            try await waitGone(target, attempts: 50)
        }
        try signal(target, SIGTERM)
        try await waitGone(target, attempts: 30)
        if force {
            try signal(target, SIGKILL)
            try await waitGone(target, attempts: 20)
        }
        if let current = inspect(target.pid), current.startedAt == target.startedAt {
            throw CommandError(message: L("error.stopTimeout"))
        }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: marker).appendingPathComponent("process-\(target.pid).json"))
        forget()
    }

    func forget() { process = nil; adopted = nil }
}

extension Error {
    var isCancelled: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}

func privileged(_ command: String) async throws {
    let output = try await Command.run("/usr/bin/osascript", ["-e", "do shell script \(doubleQuoted(command)) with administrator privileges"])
    guard output.status == 0 else {
        throw CommandError(message: output.text.isEmpty ? L("error.privilegedFailed") : output.text)
    }
}
