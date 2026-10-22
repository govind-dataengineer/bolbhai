import Foundation

public enum BolBhAIError: LocalizedError, Sendable {
    case invalidConfiguration(String), processFailed(String), unusableAudio(String)
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message), .processFailed(let message), .unusableAudio(let message): message
        }
    }
}

public struct SpeechConfiguration: Codable, Sendable, Equatable {
    public var executablePath: String
    public var modelPath: String
    public var language: String
    public var threads: Int
    public init(executablePath: String, modelPath: String, language: String = "auto", threads: Int = 8) {
        self.executablePath = executablePath; self.modelPath = modelPath; self.language = language; self.threads = threads
    }
    public func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: executablePath) else {
            throw BolBhAIError.invalidConfiguration("Choose an executable whisper-cli. Run scripts/setup-whisper.sh first.")
        }
        guard FileManager.default.isReadableFile(atPath: modelPath) else {
            throw BolBhAIError.invalidConfiguration("Whisper model is missing or unreadable.")
        }
        let header = try FileHandle(forReadingFrom: URL(fileURLWithPath: modelPath))
        defer { try? header.close() }
        let data = try header.read(upToCount: 16) ?? Data()
        guard data.count == 16, Array(data.prefix(4)) == [0x6c, 0x6d, 0x67, 0x67] else {
            throw BolBhAIError.invalidConfiguration("Model is not a whisper.cpp GGML model.")
        }
        // n_vocab follows magic. Multilingual Whisper has 51865 tokens; .en has 51864.
        let vocab = data.dropFirst(4).prefix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard vocab >= 51865 else { throw BolBhAIError.invalidConfiguration("Use multilingual Whisper, not an English-only model.") }
        guard ["auto", "en", "hi"].contains(language), (1...12).contains(threads) else {
            throw BolBhAIError.invalidConfiguration("Language must be auto, en, or hi; threads must be 1–12.")
        }
    }
}

public struct DictionaryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var spoken: String
    public var written: String
    public init(spoken: String, written: String) { self.spoken = spoken; self.written = written }
}

public enum PersonalDictionary {
    public static func apply(_ entries: [DictionaryEntry], to text: String) -> String {
        entries.prefix(100).reduce(text) { result, entry in
            let phrase = entry.spoken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !phrase.isEmpty, phrase.count <= 100, !entry.written.isEmpty, entry.written.count <= 100 else { return result }
            let pattern = "(?<![\\p{L}\\p{M}\\p{N}_])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{M}\\p{N}_])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return result }
            return regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: NSRegularExpression.escapedTemplate(for: entry.written))
        }
    }
}
