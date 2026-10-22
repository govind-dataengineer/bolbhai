import Foundation
import Darwin

/// A private loopback whisper.cpp worker keeps model weights resident between sessions.
/// The actor rejects overlapping requests. Cancellation kills its worker, so the next
/// session starts a clean process rather than reusing potentially stale inference.
public actor PersistentWhisperService: TranscriptionService {
    private let serverPath: String
    private let session: URLSession
    private var worker: WhisperProcess?
    private var workerConfiguration: SpeechConfiguration?
    private var modelStamp: WhisperModelStamp?
    private var endpoint: URL?
    private var activeGate: WhisperCancellationGate?
    private var busy = false
    private var generation = UUID()

    public init(serverPath: String) {
        self.serverPath = serverPath
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 180
        session = URLSession(configuration: configuration, delegate: WhisperRedirectBlocker(), delegateQueue: nil)
    }

    deinit { worker?.terminate(); session.invalidateAndCancel() }

    public func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String {
        guard !busy else { throw BolBhAIError.processFailed("Speech worker is finishing another request. Try again shortly.") }
        busy = true
        let token = generation
        let gate = WhisperCancellationGate()
        activeGate = gate
        defer { busy = false; activeGate = nil }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try configuration.validate()
                guard FileManager.default.isExecutableFile(atPath: serverPath) else {
                    throw BolBhAIError.invalidConfiguration("whisper-server is missing. Run setup and repackage the app.")
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BolBhAI-worker-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                defer { try? FileManager.default.removeItem(at: directory) }
                let wav = try await AudioPreparation.convert(audio, in: directory)
                let target = try await prepareWorker(configuration, gate: gate)
                try checkGeneration(token)
                let boundary = "BolBhAI-" + UUID().uuidString
                // Validated recordings are <=5 min; data is held only for this request.
                let body = try Self.multipart(wav, language: configuration.language, boundary: boundary)
                var request = URLRequest(url: target.appendingPathComponent("inference"))
                request.httpMethod = "POST"
                request.timeoutInterval = 180
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
                let (data, response) = try await session.data(for: request)
                try checkGeneration(token)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                      data.count <= 1_048_576,
                      let text = try JSONDecoder().decode(WhisperTextResponse.self, from: data).text else {
                    throw BolBhAIError.processFailed("Local speech worker returned an invalid response.")
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !["[BLANK_AUDIO]", "(silence)", "[silence]"].contains(trimmed) else {
                    throw BolBhAIError.unusableAudio("No usable speech was detected.")
                }
                return trimmed
            } catch {
                // A failed request cannot leave inference running or stale context reusable.
                await stopWorker()
                if Task.isCancelled || gate.isCancelled || token != generation { throw CancellationError() }
                if let error = error as? BolBhAIError { throw error }
                throw BolBhAIError.processFailed("Local speech worker failed: \(error.localizedDescription)")
            }
        } onCancel: { gate.cancel() }
    }

    /// Call after sleep, configuration changes, or application termination.
    public func shutdown() async {
        generation = UUID()
        activeGate?.cancel()
        await stopWorker()
    }

    private func checkGeneration(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }

    private func prepareWorker(_ configuration: SpeechConfiguration, gate: WhisperCancellationGate) async throws -> URL {
        let attributes = try FileManager.default.attributesOfItem(atPath: configuration.modelPath)
        let stamp = WhisperModelStamp(size: attributes[.size] as? UInt64 ?? 0, modified: attributes[.modificationDate] as? Date)
        if workerConfiguration != configuration || modelStamp != stamp || worker?.isRunning != true { await stopWorker() }
        if let worker, let endpoint {
            gate.attach(worker)
            try Task.checkCancellation()
            return endpoint
        }
        let port = try Self.availableLoopbackPort()
        // An unpredictable request prefix plus a live owned PID distinguishes this
        // server from unrelated localhost listeners during readiness probing.
        let requestPath = "/bolbhai-" + UUID().uuidString.lowercased()
        let target = URL(string: "http://127.0.0.1:\(port)\(requestPath)")!
        let process = try WhisperProcess(executable: serverPath, arguments: [
            "--host", "127.0.0.1", "--port", String(port), "--request-path", requestPath,
            "--public", "/dev/null", "-m", configuration.modelPath,
            "-l", configuration.language, "-t", String(configuration.threads),
            "-nt", "-sns", "-bs", "5", "-bo", "5"
        ])
        worker = process; workerConfiguration = configuration; modelStamp = stamp; endpoint = target
        gate.attach(process)
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard !gate.isCancelled else { throw CancellationError() }
            guard process.isRunning else {
                throw BolBhAIError.processFailed("Local speech worker exited \(process.exitStatus). Rebuild it or try CPU mode.")
            }
            var request = URLRequest(url: target.appendingPathComponent("health"))
            request.timeoutInterval = 0.7
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   (try? JSONDecoder().decode(WhisperHealthResponse.self, from: data).status) == "ok",
                   process.isRunning {
                    return target
                }
            } catch { try Task.checkCancellation() }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BolBhAIError.processFailed("Local speech worker did not become ready within 90 seconds.")
    }

    private func stopWorker() async {
        let old = worker
        worker = nil; workerConfiguration = nil; modelStamp = nil; endpoint = nil
        old?.terminate()
        if let old { await Task.detached { old.waitForExit() }.value }
    }

    private static func multipart(_ audio: URL, language: String, boundary: String) throws -> Data {
        var data = Data()
        func append(_ string: String) { data.append(Data(string.utf8)) }
        for (name, value) in [("response_format", "json"), ("language", language), ("temperature", "0.0"), ("temperature_inc", "0.2"), ("suppress_nst", "true"), ("translate", "false")] {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\nContent-Type: audio/wav\r\n\r\n")
        data.append(try Data(contentsOf: audio))
        append("\r\n--\(boundary)--\r\n")
        return data
    }

    private static func availableLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BolBhAIError.processFailed("Cannot create a local speech worker socket.") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bindResult == 0 else { throw BolBhAIError.processFailed("Cannot reserve a loopback speech worker port.") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard result == 0 else { throw BolBhAIError.processFailed("Cannot discover the speech worker port.") }
        return UInt16(bigEndian: address.sin_port)
    }
}

private struct WhisperTextResponse: Decodable { let text: String? }
private struct WhisperHealthResponse: Decodable { let status: String }
private struct WhisperModelStamp: Equatable { let size: UInt64; let modified: Date? }

private final class WhisperRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class WhisperCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var process: WhisperProcess?
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func attach(_ value: WhisperProcess) {
        lock.lock(); process = value; let stop = cancelled; lock.unlock()
        if stop { value.terminate() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = process; lock.unlock()
        current?.terminate()
    }
}

private final class WhisperProcess: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var stopped = false
    var isRunning: Bool { process.isRunning }
    var exitStatus: Int32 { process.terminationStatus }
    init(executable: String, arguments: [String]) throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func terminate() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning { process.terminate() }
        // Graceful shutdown can wait for active inference. Force cancellation soon.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
    func waitForExit() {
        process.waitUntilExit()
    }
}
