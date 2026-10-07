import Foundation
import Darwin

struct ManagedProcess {
    let pid: Int32
    let command: String
}

enum Command {
    static let brewEnvironment = ["HOMEBREW_NO_AUTO_UPDATE": "1", "HOMEBREW_NO_ANALYTICS": "1"]
    // 设置页里的 brew 源与代理，AppState 每次改动都重算这一份。
    static var proxyEnvironment: [String: String] = [:]

    // 输出写临时文件，避免 brew 之类的大量输出堵住 Pipe。
    static func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) async throws -> CommandOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("macenv-command-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stdout = directory.appendingPathComponent("out")
        let stderr = directory.appendingPathComponent("err")
        try Data().write(to: stdout)
        try Data().write(to: stderr)
        let out = try FileHandle(forWritingTo: stdout)
        let err = try FileHandle(forWritingTo: stderr)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }.merging(Command.proxyEnvironment) { _, new in new }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = err
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finished in
                try? out.close()
                try? err.close()
                let result = CommandOutput(status: finished.terminationStatus,
                                           stdout: (try? String(contentsOf: stdout, encoding: .utf8)) ?? "",
                                           stderr: (try? String(contentsOf: stderr, encoding: .utf8)) ?? "")
                try? FileManager.default.removeItem(at: directory)
                continuation.resume(returning: result)
            }
            do { try process.run() }
            catch {
                try? out.close()
                try? err.close()
                try? FileManager.default.removeItem(at: directory)
                continuation.resume(throwing: error)
            }
        }
    }

    // 统一下载入口。用 curl 而不是 URLSession：URLSession 的下载中途拿不到任何进度，
    // 界面只能干转圈；curl 的 --progress-bar 每几十毫秒吐一次，正好喂给任务日志。
    // 顺带白捡一个正确性：Command.stream 会注入 Command.proxyEnvironment，curl 认那几个变量，
    // 而 URLSession 走的是系统代理设置 —— 用户在 MacEnv 里填的代理对下载才真正生效。
    static func download(_ url: URL, to file: URL, report: @escaping (String) -> Void = { _ in }, onStart: ((Process) -> Void)? = nil) async throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: file)
        // -f：HTTP 4xx/5xx 直接当失败，别把错误页当包解压。 -L：跟着重定向走。
        let status = try await stream("/usr/bin/curl", ["-fL", "--progress-bar", "-o", file.path, url.absoluteString],
                                      onStart: onStart, onOutput: report)
        guard status == 0 else { throw CommandError(message: L("error.downloadFailed") + "（\(status)）") }
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
        "/bin/bash \(singleQuoted(script.path)) < /dev/null > \(singleQuoted(log.path)) 2>&1 & echo started"
    }

    static func privilegedStream(_ command: String, report: @escaping (String) -> Void) async throws {
        let name = "macenv-task-" + UUID().uuidString
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".sh")
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".log")
        try ("#!/bin/bash\n" + command + "\necho \"__MACENV_EXIT=$?\"\n").write(to: script, atomically: true, encoding: .utf8)
        try Data().write(to: log)
        // 任务跑完（或失败）就把脚本和日志收走，别让 /var/folders 里越攒越多。
        defer { try? FileManager.default.removeItem(at: script); try? FileManager.default.removeItem(at: log) }
        try await privileged(privilegedLaunchCommand(script: script, log: log))

        var offset: UInt64 = 0
        var tail = ""
        // 兜底上限：命令真挂死了，界面不能跟着转一辈子。
        let deadline = Date().addingTimeInterval(3600)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 400_000_000)
            let text = readNew(log, from: &offset)
            if !text.isEmpty {
                report(text)
                tail = String((tail + text).suffix(64))
            }
            // 标记可能被切在两次读取之间，所以在「上一次的尾巴 + 这一次」上找。
            if let value = firstCapture(#"__MACENV_EXIT=(\d+)"#, in: tail) {
                guard value == "0" else { throw CommandError(message: L("error.toolCommandFailed") + "（\(value)）") }
                return
            }
        }
        throw CommandError(message: L("error.toolTimeout"))
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
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = { finished in
                pipe.fileHandleForReading.readabilityHandler = nil
                DispatchQueue.main.async { continuation.resume(returning: finished.terminationStatus) }
            }
            do {
                try process.run()
                onStart?(process)
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}

// 托管一个前台子进程：启动、接管残留进程、按命令快照核对后停止。
@MainActor
final class ProcessSupervisor {
    private let marker: String
    private(set) var process: Process?
    private var adoptedPID: Int32?
    var onExit: (() -> Void)?

    init(marker: String) { self.marker = marker }

    var isRunning: Bool { process?.isRunning == true || adoptedPID != nil }

    func launch(at executable: URL, arguments: [String], directory: URL, environment: [String: String], errorLog: URL) throws -> Process {
        try Data().write(to: errorLog)
        let handle = try FileHandle(forWritingTo: errorLog)
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
        try? handle.close()
        process = item
        return item
    }

    // 找到仍在使用 MacEnv 目录的进程，用于接管上一次运行留下的实例。
    func find(_ binary: String) async throws -> ManagedProcess? {
        let output = try await Command.run("/bin/ps", ["-axo", "pid=,command="])
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]), parts[1].contains(marker), parts[1].contains(binary) else { continue }
            return ManagedProcess(pid: pid, command: String(parts[1]))
        }
        return nil
    }

    func adopt(_ target: ManagedProcess) { adoptedPID = target.pid }

    // 从 pid 文件认领上一次运行留下的实例。
    //
    // 用 libproc 的 proc_pidpath 直接问内核要可执行路径，而不是扫 ps：
    //   · 不跑子进程、不解析输出 —— 扫 ps 那套在沙箱里会静默返回空表，认领悄悄失败
    //   · 拿的是内核里的真实路径，不怕 setproctitle 把命令行改得面目全非
    //   · pid 被复用时路径对不上，直接不认，不会误杀别人的进程
    func owned(pidFile: URL, binary: String) -> ManagedProcess? {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN)) > 0 else { return nil }
        let path = String(cString: buffer)
        guard path.hasSuffix("/" + binary) else { return nil }
        return ManagedProcess(pid: pid, command: path)
    }

    func signal(_ pid: Int32, _ signal: Int32) { _ = Darwin.kill(pid, signal) }

    func alive(_ pid: Int32) -> Bool { Darwin.kill(pid, 0) == 0 }

    // 等进程消失，最多 attempts × 100ms。进程已经退出（或我们自己的句柄已经失效）就立刻返回。
    private func waitGone(_ pid: Int32, attempts: Int) async throws {
        for _ in 0..<attempts where alive(pid) && process?.isRunning != false { try await Task.sleep(nanoseconds: 100_000_000) }
    }

    // graceful 用于数据库这类需要先礼貌关闭的服务；force 才会用 SIGKILL 收尾。
    func terminate(_ target: ManagedProcess, graceful: (() async throws -> Void)? = nil, force: Bool = false) async throws {
        // 没有 graceful 就直接发信号。否则会在这里白等满 5 秒才动手，nginx 这类服务每次停都要卡一下。
        if let graceful {
            try? await graceful()
            try await waitGone(target.pid, attempts: 50)
        }
        if alive(target.pid) || process?.isRunning == true {
            signal(target.pid, SIGTERM)
            try await waitGone(target.pid, attempts: 30)
        }
        if force, alive(target.pid) || process?.isRunning == true {
            signal(target.pid, SIGKILL)
            try await waitGone(target.pid, attempts: 20)
        }
        process = nil
        adoptedPID = nil
        guard !alive(target.pid) else { throw CommandError(message: L("error.stopTimeout")) }
    }

    func forget() { process = nil; adoptedPID = nil }
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
