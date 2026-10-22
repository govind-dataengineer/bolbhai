import Foundation
import Darwin
import BolBhAICore

@main struct Benchmark {
    static func main() async {
        let operation = Task { try await run() }
        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in operation.cancel() }
            source.resume()
            return source
        }
        defer { signals.forEach { $0.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }
        do { try await operation.value }
        catch is CancellationError { FileHandle.standardError.write(Data("Cancelled; owned speech processes stopped and temporary files removed.\n".utf8)); exit(130) }
        catch { FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8)); exit(1) }
    }
    static func run() async throws {
        var values: [String: String] = [:]
        var clean = false, list = false
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.contains("--help") {
            print("""
            bolbhai-benchmark --audio FILE --model FILE [--whisper-cli FILE] [--language auto|en|hi]
              [--clean --endpoint http://127.0.0.1:1234 --cleanup-model ID] [--runs N] [--threads N]
              [--worker /path/to/whisper-server] (keeps model resident across runs)
            bolbhai-benchmark --list-models [--endpoint http://127.0.0.1:1234]
            bolbhai-benchmark --cleanup-text TEXT [--cleanup-model ID] [--endpoint URL]
            Each CLI run reloads Whisper. Run 1 is process-cold; later runs are filesystem-cache-warm,
            NOT resident-model inference. Audio and text are printed only by this explicit benchmark.
            """); return
        }
        while !args.isEmpty {
            let key = args.removeFirst()
            if key == "--clean" { clean = true; continue }
            if key == "--list-models" { list = true; continue }
            guard ["--audio", "--model", "--whisper-cli", "--language", "--endpoint", "--cleanup-model", "--runs", "--threads", "--cleanup-text", "--worker"].contains(key), !args.isEmpty else { throw BolBhAIError.invalidConfiguration("Unknown or missing argument: \(key)") }
            values[key] = args.removeFirst()
        }
        let cleanup = CleanupConfiguration(endpoint: values["--endpoint"] ?? "http://127.0.0.1:1234", modelID: values["--cleanup-model"] ?? "google/gemma-4-e4b")
        let service = LMStudioCleanupService()
        if let text = values["--cleanup-text"] {
            let start = Date()
            do { print("Raw: \(text)\nCleaned: \(try await service.clean(text, configuration: cleanup))") }
            catch is CancellationError { throw CancellationError() }
            catch { print("Raw: \(text)\nCleaned: \(text)\nCleanup failed; raw retained: \(error.localizedDescription)") }
            print(String(format: "Cleanup: %.3f s", Date().timeIntervalSince(start))); return
        }
        if list {
            for model in try await service.discoverModels(configuration: cleanup) { print(model) }
            return
        }
        guard let source = values["--audio"], let model = values["--model"], let runs = Int(values["--runs"] ?? "1"), (1...20).contains(runs), let threads = Int(values["--threads"] ?? "8") else { throw BolBhAIError.invalidConfiguration("Supply --audio, --model; --runs must be 1–20 and threads an integer.") }
        let speech = SpeechConfiguration(executablePath: values["--whisper-cli"] ?? FileManager.default.currentDirectoryPath + "/.local/whisper.cpp/build/bin/whisper-cli", modelPath: model, language: values["--language"] ?? "auto", threads: threads)
        try speech.validate()
        if clean { try cleanup.validate() }
        let worker = values["--worker"].map { PersistentWhisperService(serverPath: $0) }
        let transcriber: any TranscriptionService
        if let worker { transcriber = worker } else { transcriber = WhisperCLIService() }
        do {
        for run in 1...runs {
            try Task.checkCancellation()
            let start = Date()
            let raw = try await transcriber.transcribe(URL(fileURLWithPath: source), configuration: speech)
            let speechTime = Date().timeIntervalSince(start)
            let cleanupStart = Date()
            var edited = raw, status = "bypassed"
            if clean {
                do { edited = try await service.clean(raw, configuration: cleanup); status = "completed" }
                catch is CancellationError { throw CancellationError() }
                catch { status = "failed; raw retained: \(error.localizedDescription)" }
            }
            let cleanupTime = clean ? Date().timeIntervalSince(cleanupStart) : 0
            print("Run \(run) (\(run == 1 ? "process cold; shader cache may be warm" : worker == nil ? "cache warm, new process" : "resident model warm"))\nRaw: \(raw)\nCleaned: \(edited)\nCleanup: \(status)")
            print(String(format: "Transcription: %.3f s | Cleanup: %.3f s | Total: %.3f s", speechTime, cleanupTime, Date().timeIntervalSince(start)))
        }
        } catch { await worker?.shutdown(); throw error }
        await worker?.shutdown()
    }
}
