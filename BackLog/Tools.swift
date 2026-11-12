import Foundation

/// Finds and runs the command-line tools BackLog uses (yt-dlp, ffmpeg).
/// Bundled copies in Contents/Resources/bin win; otherwise Homebrew's.
enum Tools {
    static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

    static func find(_ name: String) -> URL? {
        if let bundled = Bundle.main.resourceURL?.appending(path: "bin/\(name)"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        for dir in searchPaths {
            let url = URL(fileURLWithPath: dir).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    static var ytdlp: URL? { find("yt-dlp") }
    static var ffmpeg: URL? { find("ffmpeg") }

    struct Failure: Error, LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Runs a tool, calling `onLine` for each stdout line, and returns all of stdout.
    /// Throws with stderr when it exits non-zero. Cancelling the task terminates the process.
    static func run(_ executable: URL, _ arguments: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ([executable.deletingLastPathComponent().path] + searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collector = OutputCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendOut(data) }
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { collector.appendErr(data) }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                process.terminationHandler = { p in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
                    collector.flush()
                    if p.terminationStatus == 0 {
                        continuation.resume(returning: collector.stdout)
                    } else if p.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(throwing: Failure(message: collector.stderr))
                    }
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}

/// Collects a process's output from the pipe handlers' threads.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data(), pending = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func appendOut(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        out.append(data)
        pending += String(decoding: data, as: UTF8.self)
        var lines: [String] = []
        while let r = pending.firstIndex(where: \.isNewline) {
            lines.append(String(pending[..<r]))
            pending = String(pending[pending.index(after: r)...])
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func appendErr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock(); err.append(data); lock.unlock()
    }

    func flush() {
        lock.lock(); let rest = pending; pending = ""; lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }

    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
