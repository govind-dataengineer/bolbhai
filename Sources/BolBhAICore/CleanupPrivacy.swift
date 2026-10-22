import Foundation

/// A fail-closed check of LM Studio's persisted logging configuration.
/// The live server still requires restart and a synthetic log-delta verification after setup.
public struct LMStudioLoggingPolicy: Sendable {
    public let settingsURL: URL

    public init(settingsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".lmstudio/.internal/http-server-config.json")) {
        self.settingsURL = settingsURL
    }

    public func validate(configuration: CleanupConfiguration) throws {
        let endpoint = try configuration.validatedEndpoint()
        guard settingsURL.isFileURL else {
            throw CleanupError.privacyUnverified("Logging settings must be read from a local file.")
        }
        let settings: LoggingSettings
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: settingsURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else {
                throw CleanupError.privacyUnverified("The LM Studio logging settings file is unsupported.")
            }
            settings = try JSONDecoder().decode(LoggingSettings.self, from: Data(contentsOf: settingsURL))
        } catch let error as CleanupError {
            throw error
        } catch {
            throw CleanupError.privacyUnverified("LM Studio logging settings are missing, unreadable, or use an unsupported schema.")
        }
        guard settings.logSensitiveData == false, settings.logIncomingTokens == false,
              settings.verbose == false, settings.fileLoggingMode == .off else {
            throw CleanupError.privacyUnverified("In LM Studio, open Developer → Developer Logs → More options. Enable Redact Content, set File Logging Mode to OFF, and disable Verbose Logging and Log Incoming Tokens. Restart the server and verify with synthetic text before private dictation.")
        }
        let port = endpoint.port ?? (endpoint.scheme?.lowercased() == "https" ? 443 : 80)
        guard (1...65_535).contains(settings.port), settings.port == port else {
            throw CleanupError.privacyUnverified("The verified LM Studio settings port does not match the configured cleanup endpoint.")
        }
        guard ["127.0.0.1", "::1"].contains(settings.networkInterface) else {
            throw CleanupError.privacyUnverified("LM Studio must bind to a literal loopback interface. Turn off Serve on Local Network.")
        }
    }

    private struct LoggingSettings: Decodable {
        let logSensitiveData: Bool
        let logIncomingTokens: Bool
        let verbose: Bool
        let fileLoggingMode: FileLoggingMode
        let port: Int
        let networkInterface: String
    }
    private enum FileLoggingMode: String, Decodable { case off, succinct, full }
}
