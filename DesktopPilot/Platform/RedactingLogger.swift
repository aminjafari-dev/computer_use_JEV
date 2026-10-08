import Foundation
import os
import PilotCore

/// Structured logs. Messages are expected to already exclude secrets.
/// If a caller accidentally includes a bearer token or the stored key, it is stripped.
struct RedactingLogger: PilotLogging, Sendable {
    private let logger = Logger(subsystem: "com.desktoppilot.app", category: "pilot")
    var diagnosticsEnabled: @Sendable () -> Bool

    func info(_ message: String) {
        guard diagnosticsEnabled() else { return }
        logger.info("\(self.redact(message), privacy: .public)")
    }

    func error(_ message: String) {
        guard diagnosticsEnabled() else { return }
        logger.error("\(self.redact(message), privacy: .public)")
    }

    func redact(_ message: String) -> String {
        var text = message
        if let key = KeychainStore.load(), key.count > 6 {
            text = text.replacingOccurrences(of: key, with: "[redacted]")
        }
        if let regex = try? NSRegularExpression(pattern: "(?i)bearer\\s+[A-Za-z0-9\\-\\._~+/]+=*") {
            let range = NSRange(text.startIndex..., in: text)
            text = regex.stringByReplacingMatches(in: text, range: range, withTemplate: "Bearer [redacted]")
        }
        return text
    }
}
