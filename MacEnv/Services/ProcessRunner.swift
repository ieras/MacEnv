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
    // 设置页里的 brew 源与代理，AppState 每次改动都重算这一份。
    static var proxyEnvironment: [String: String] = [:]

    // 输出写临时文件，避免 brew 之类的大量输出堵住 Pipe。
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

    // 取消的是短期命令，直接结束整组；只停 shell 会留下继续写盘的子进程。
    // 常驻服务的优雅停止由 ProcessSupervisor 负责。
    static func cancel(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        _ = Darwin.kill(getpgid(pid) == pid ? -pid : pid, SIGKILL)
    }

    // 统一下载入口。不用 URLSession：中途拿不到进度，界面只能干转圈。
    // 也不用 curl 的 --progress-bar：进度条符号全是 # 号，可读性差。
    // 自己每秒轮询落盘字节数 —— 那是真实进度，\r 前缀让日志覆盖当前行不刷屏。
    // 顺带白捡一个正确性：Command.stream 会注入 Command.proxyEnvironment，curl 认那几个变量，
    // 而 URLSession 走的是系统代理设置 —— 用户在 MacEnv 里填的代理对下载才真正生效。
    static func download(_ url: URL, to file: URL, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = file.appendingPathExtension("part")
        defer { try? FileManager.default.removeItem(at: partial) }
        // 先报一行「正在下载 <url>」：连接阶段 curl 是哑巴（一个字节都不吐），
        // 不报这行，浮层从任务开始到首个字节之间一直停在「正在准备…」，看着像卡死。
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
        // -f：HTTP 4xx/5xx 直接当失败，别把错误页当包解压。 -L：跟着重定向走。
        // --connect-timeout：CDN 连不上时 curl 默认挂到天荒地老且零输出，界面就是「卡死」；
        // 15 秒连不上直接失败，错误消息（-sS）会进日志，用户知道是网络问题而不是软件死了。
        // 下载前先问服务器要完整大小，下载完比对 —— 网络半路掐断时 curl 可能仍然退出 0
        // （ClickHouse 的 174MB 二进制被截成整 50MB 踩过），残缺的 Mach-O 头照样有效，
        // 落位后一跑就 SIGSEGV，服务永远扫不出来 —— 还不如下载时就报错。
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
        // 只有完整下载才进入缓存；取消或 curl 失败留下的 .part 不会被下一次安装复用。
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        try FileManager.default.moveItem(at: partial, to: file)
    }

    // 只认最后一段响应；重定向页的长度不能拿来校验最终的下载文件。
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

    // 提权 + 长任务。privileged() 是同步阻塞的：跑完才返回，中间的输出一个字都拿不到。
    // 所以只能「脚本落盘 → 提权后台起 → 轮询日志文件」，这是唯一能拿到进度的办法。
    //
    // ⚠️ `&` 只把命令丢后台，命令自己的 `>` 重定向必须显式写 —— 不写的话输出全进
    //    osascript 的返回值里被吞掉，日志文件永远是空的。
    // ⚠️ osascript 非交互，脚本里任何 read / sudo 密码提示都会挂死。
    // ⚠️ 后台那半边进程我们拿不到 exit status，所以让脚本自己在最后一行 echo 退出码。
    // do shell script 没有控制终端，macOS 的 nohup 在这里尝试脱离 console 会失败；后台子进程也没有
    // 可挂断的终端，因此不用 nohup，只需把 stdin/stdout/stderr 全部显式断开。
    static func privilegedLaunchCommand(script: URL, log: URL) -> String {
        // job control 给脚本独立进程组，取消时连同 port/brew 的子进程一起停止。
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
            // 授权框返回前不能宣称已取消：后台 root 任务可能刚刚启动，必须拿到 PID 后清理。
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
                // UUID 脚本路径和组号都吻合才发信号，PID 已复用时不碰新进程。
                let stop = "if /bin/ps -p \(pid) -o command= | /usr/bin/grep -Fq -- \(singleQuoted(script.path)) && [ \"$(/bin/ps -p \(pid) -o pgid= | /usr/bin/tr -d ' ')\" = \"\(pid)\" ]; then /bin/kill -TERM -- -\(pid); for attempt in {1..20}; do /bin/kill -0 -- -\(pid) 2>/dev/null || exit 0; /bin/sleep 0.1; done; /bin/kill -KILL -- -\(pid) 2>/dev/null || true; fi"
                try await Task { try await privileged(stop) }.value
            }
            throw error
        }
    }

    // 只读「上次之后新增」的那一段。日志文件一路在长，每次整读一遍是 O(n²)。
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

    // gvm install 这种要跑几分钟、还得把过程给用户看的命令，不能用上面那个一次性版本：
    // 它只在进程退出后才把输出交出来，中间界面一直是空白的。
    // onStart 把 Process 交出去，调用方才能中途取消。
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
            // 回调在任意线程，交给主队列，ViewModel 里的 @Published 才能安全更新。
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

// 进程身份必须同时包含可执行文件、启动时间和实例目录；PID 或同名二进制都不足以证明归属。
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

    func launch(at executable: URL, arguments: [String], directory: URL, environment: [String: String], errorLog: URL) throws -> Process {
        try Data().write(to: errorLog)
        let handle = try FileHandle(forWritingTo: errorLog)
        defer { try? handle.close() }
        let item = Process()
        item.executableURL = executable
        item.arguments = arguments
        item.currentDirectoryURL = directory
        item.environment = environment
        item.standardInput = FileHandle.nullDevice
        item.standardOutput = FileHandle.nullDevice
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

    // 内核提供 PID 身份和 argv；改写标题的服务用启动记录核对，不依赖 ps 的展示文本。
    func inspect(_ pid: Int32) -> ManagedProcess? {
        var info = proc_bsdinfo()
        guard pid > 0, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
              info.pbi_status != UInt32(SZOMB) else { return nil }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        var arguments: [String]
        if let process, process.processIdentifier == pid {
            // 刚启动时内核的 argv 可能还没就绪；自己启动的进程已有完整参数。
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
        if !arguments.contains(where: { $0 == marker || $0.contains(marker + "/") }) {
            // setproctitle 可覆盖 argv；启动时留的身份记录仍必须与内核启动时间和路径完全一致。
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

    // 每次发信号都重新核对启动时间，等待期间 PID 被复用也不会打到新进程。
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

// 任务被取消（切页面取消 .task、URLSession 请求随之中断）不算错误，界面不该弹提示。
extension Error {
    var isCancelled: Bool { self is CancellationError || (self as? URLError)?.code == .cancelled }
}

// 提权执行。MacEnv 没有常驻 Helper，走 osascript 的系统授权框（一次授权 5 分钟内有效）。
// 写 /etc/hosts、装根证书、macports 的 port install 都走这一条。
func privileged(_ command: String) async throws {
    let output = try await Command.run("/usr/bin/osascript", ["-e", "do shell script \(doubleQuoted(command)) with administrator privileges"])
    guard output.status == 0 else {
        // osascript 把「用户点了取消」也报成退出码 1，原文抛出去让界面照实显示。
        throw CommandError(message: output.text.isEmpty ? L("error.privilegedFailed") : output.text)
    }
}
