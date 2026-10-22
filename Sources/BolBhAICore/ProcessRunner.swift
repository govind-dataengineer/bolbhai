import Foundation
import Darwin

public struct ProcessOutput: Sendable { public let stdout: String; public let stderr: String }

/// Files avoid pipe deadlock. Every process owns its own output directory, deleted on every exit path.
public enum ProcessRunner {
    public static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 180) async throws -> ProcessOutput {
        let job = ProcessJob(executable: executable, arguments: arguments, timeout: timeout)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Task.detached { try job.run() }.value
        } onCancel: { job.cancel() }
    }
}

private final class ProcessJob: @unchecked Sendable {
    private let lock = NSLock()
    private let process = Process()
    private var cancelled = false
    private let timeout: TimeInterval
    init(executable: String, arguments: [String], timeout: TimeInterval) {
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; self.timeout = timeout
    }
    func cancel() {
        lock.lock(); cancelled = true
        if process.isRunning { process.terminate() }
        lock.unlock()
    }
    func run() throws -> ProcessOutput {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BolBhAI-process-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("stdout"), errors = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: errors.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let outHandle = try FileHandle(forWritingTo: output), errHandle = try FileHandle(forWritingTo: errors)
        defer { try? outHandle.close(); try? errHandle.close() }
        process.standardOutput = outHandle; process.standardError = errHandle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw error }
        lock.unlock()
        let deadline = Date().addingTimeInterval(timeout)
        var terminationDeadline: Date?
        var timedOut = false
        while process.isRunning {
            lock.lock(); let stop = cancelled; lock.unlock()
            if stop || Date() >= deadline {
                timedOut = !stop
                if terminationDeadline == nil { process.terminate(); terminationDeadline = Date().addingTimeInterval(1) }
                if Date() >= terminationDeadline! { kill(process.processIdentifier, SIGKILL) }
            }
            Thread.sleep(forTimeInterval: 0.025)
        }
        process.waitUntilExit()
        lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw CancellationError() }
        if timedOut { throw BolBhAIError.processFailed("Local inference timed out.") }
        let stdout = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw BolBhAIError.processFailed("\(process.executableURL?.lastPathComponent ?? "Process") exited \(process.terminationStatus): \(stderr.suffix(1600))")
        }
        return ProcessOutput(stdout: stdout, stderr: stderr)
    }
}
