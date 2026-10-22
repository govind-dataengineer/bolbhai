import Foundation
import AVFoundation

public protocol TranscriptionService: Sendable {
    func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String
}

public struct AudioStatistics: Sendable { public let duration: Double; public let rms: Double; public let peak: Double }

public enum AudioPreparation {
    /// Caller owns returned directory and must remove it with defer, also on cancellation.
    public static func convert(_ source: URL, in directory: URL) async throws -> URL {
        let target = directory.appendingPathComponent("speech.wav")
        let channels = try await Task.detached { try AVAudioFile(forReading: source).processingFormat.channelCount }.value
        var arguments = [source.path, target.path, "-f", "WAVE", "-d", "LEI16@16000", "-c", "1"]
        // afconvert rejects mixing an already-mono PCM input. Multichannel input
        // needs downmixing, otherwise channel removal can silently discard speech.
        if channels > 1 { arguments.append("--mix") }
        _ = try await ProcessRunner.run("/usr/bin/afconvert", arguments: arguments, timeout: 30)
        try Task.checkCancellation()
        _ = try await Task.detached { try validate(target) }.value
        return target
    }
    public static func validate(_ url: URL) throws -> AudioStatistics {
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0, file.processingFormat.channelCount == 1, file.processingFormat.sampleRate == 16000 else {
            throw BolBhAIError.unusableAudio("Expected mono 16 kHz audio.")
        }
        let duration = Double(file.length) / 16000
        guard duration >= 0.35, duration <= 300 else { throw BolBhAIError.unusableAudio("Record between 0.35 seconds and 5 minutes.") }
        var square = 0.0, peak = 0.0, count = 0
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            guard let samples = buffer.floatChannelData?[0] else { throw BolBhAIError.unusableAudio("Cannot decode audio.") }
            for i in 0..<Int(buffer.frameLength) {
                let value = Double(samples[i]); square += value * value; peak = max(peak, abs(value)); count += 1
            }
        }
        let rms = sqrt(square / Double(max(count, 1)))
        guard rms >= 0.001, peak >= 0.008 else { throw BolBhAIError.unusableAudio("Recording is silent or too quiet. Nothing was transcribed or inserted.") }
        return AudioStatistics(duration: duration, rms: rms, peak: peak)
    }
}

public struct WhisperCLIService: TranscriptionService {
    public init() {}
    public func transcribe(_ audio: URL, configuration: SpeechConfiguration) async throws -> String {
        try configuration.validate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BolBhAI-inference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let wav = try await AudioPreparation.convert(audio, in: directory)
        let prefix = directory.appendingPathComponent("transcript").path
        _ = try await ProcessRunner.run(configuration.executablePath, arguments: ["-m", configuration.modelPath, "-f", wav.path, "-l", configuration.language, "-t", String(configuration.threads), "-nt", "-otxt", "-of", prefix, "-np", "-sns"])
        try Task.checkCancellation()
        let text = try String(contentsOfFile: prefix + ".txt", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !["[BLANK_AUDIO]", "(silence)", "[silence]"].contains(text) else { throw BolBhAIError.unusableAudio("No usable speech was detected.") }
        return text
    }
}
