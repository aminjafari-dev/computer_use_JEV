import Foundation

/// Thresholds are starting points, not measurements of this product's accuracy.
///
/// `minimumConfidence` follows the TypeSafe guidance that confidence below 0.5
/// means the distribution is too spread to act on. It is the documented Choice
/// statistic, not a claim that 0.5 equals "probably correct".
///
/// `minimumTopToSecondRatio` is a second, local check: the winner must be at
/// least twice as likely as the runner-up. Several acceptable controls can share
/// probability and lower confidence without either one being safe to click.
/// Both gates are configurable in Settings and should be tightened if a task
/// domain shows false certainty.
public struct ConfidenceSettings: Codable, Sendable, Equatable {
    public var minimumConfidence: Double
    public var minimumTopToSecondRatio: Double
    /// A Noul has no separate confidence. This is how close to "yes" completion must be.
    public var completionThreshold: Double
    public var blockedThreshold: Double

    public init(
        minimumConfidence: Double = 0.5,
        minimumTopToSecondRatio: Double = 2,
        completionThreshold: Double = 0.8,
        blockedThreshold: Double = 0.8
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumTopToSecondRatio = minimumTopToSecondRatio
        self.completionThreshold = completionThreshold
        self.blockedThreshold = blockedThreshold
    }

    public func isConfident(confidence: Double, topToSecondRatio: Double) -> Bool {
        confidence >= minimumConfidence && topToSecondRatio >= minimumTopToSecondRatio
    }

    public func isAmbiguous(topToSecondRatio: Double) -> Bool {
        topToSecondRatio < minimumTopToSecondRatio
    }
}

public enum SafetyPolicy {
    /// Whole-word checks. Screen text cannot add words to this list at runtime.
    public static let consequentialWords: Set<String> = [
        "send", "post", "publish", "tweet", "reply",
        "buy", "purchase", "pay", "payment", "checkout", "subscribe", "order",
        "delete", "erase", "remove", "trash",
        "share", "permission", "permissions", "privacy",
        "password", "passwd", "credential", "credentials", "login", "signin", "sign-in",
        "install", "uninstall",
        "terminal", "shell", "sudo"
    ]

    public static func requiresReview(candidate: Candidate, windowTitle: String) -> Bool {
        if candidate.operation == .insertText, looksLikeCredential(candidate) { return true }
        let haystack = TokenizerTokens.of([candidate.label, candidate.controlType, windowTitle] + candidate.contextLabels)
        return !haystack.isDisjoint(with: consequentialWords)
    }

    public static func looksLikeCredential(_ candidate: Candidate) -> Bool {
        let words = TokenizerTokens.of([candidate.label] + candidate.contextLabels)
        let markers: Set<String> = ["password", "passwd", "credential", "secret", "pin", "otp"]
        return !words.isDisjoint(with: markers)
    }
}

enum TokenizerTokens {
    static func of(_ parts: [String]) -> Set<String> {
        var words: Set<String> = []
        for part in parts {
            let lowered = part.lowercased().replacingOccurrences(of: "-", with: " ")
            for word in lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                words.insert(String(word))
            }
        }
        return words
    }
}

public struct LoopDetector: Sendable {
    public var repeatedStateLimit: Int
    public var ineffectiveActionLimit: Int
    private var fingerprints: [String] = []
    private var ineffectiveStreak = 0

    public init(repeatedStateLimit: Int = 3, ineffectiveActionLimit: Int = 2) {
        self.repeatedStateLimit = repeatedStateLimit
        self.ineffectiveActionLimit = ineffectiveActionLimit
    }

    public mutating func observe(fingerprint: String) -> StopReason? {
        fingerprints.append(fingerprint)
        let recent = fingerprints.suffix(repeatedStateLimit)
        if recent.count >= repeatedStateLimit, Set(recent).count == 1 {
            return .repeatedState
        }
        return nil
    }

    public mutating func recordAction(changedScreen: Bool) -> StopReason? {
        if changedScreen {
            ineffectiveStreak = 0
            return nil
        }
        ineffectiveStreak += 1
        if ineffectiveStreak >= ineffectiveActionLimit {
            return .ineffectiveActions
        }
        return nil
    }
}

public enum Verification: Sendable, Equatable {
    case changed
    case unchanged
    case completed(signal: String)
}

public enum ResultVerifier {
    public static func verify(before: ScreenObservation, after: ScreenObservation) -> Verification {
        let beforeText = Set(before.elements.map { $0.label.lowercased() })
        let signals = after.elements.compactMap { element -> String? in
            let label = element.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isCompletionSignal(label) else { return nil }
            guard !beforeText.contains(label.lowercased()) else { return nil }
            return label
        }
        if let signal = signals.first {
            return .completed(signal: signal)
        }
        if StateFingerprint.make(before) == StateFingerprint.make(after) {
            return .unchanged
        }
        return .changed
    }

    /// Explicit on-screen phrases. A successful click is not one of them.
    public static func isCompletionSignal(_ label: String) -> Bool {
        let lowered = label.lowercased()
        let phrases = ["status: complete", "task complete", "completed successfully", "saved successfully"]
        return phrases.contains(where: { lowered.contains($0) })
    }
}

public enum TargetMatching {
    public static func revalidate(
        candidate: Candidate,
        original: ScreenObservation,
        fresh: ScreenObservation
    ) -> Revalidation {
        if fresh.pid != original.pid { return .applicationChanged }
        if let originalWindow = original.windowID, let freshWindow = fresh.windowID, originalWindow != freshWindow {
            return .stale
        }
        if candidate.operation == .pressKey { return .valid }
        guard let match = find(candidate, in: fresh) else { return .stale }
        if !match.enabled { return .disabled }
        return .valid
    }

    public static func find(_ candidate: Candidate, in observation: ScreenObservation) -> UIElementObservation? {
        let sameID = observation.elements.first { $0.id == candidate.elementID && !$0.isSecure }
        if let sameID {
            if candidate.bounds.area == 0 || sameID.bounds.iou(candidate.bounds) >= 0.3 || sameID.bounds.center.distance(to: candidate.center) < 40 {
                return sameID
            }
        }
        let labeled = observation.elements.filter { element in
            !element.isSecure
                && element.role == candidate.controlType
                && element.label.caseInsensitiveCompare(candidate.label) == .orderedSame
                && element.parentLabels == candidate.contextLabels
        }
        return labeled.max { lhs, rhs in
            lhs.bounds.iou(candidate.bounds) < rhs.bounds.iou(candidate.bounds)
        }.flatMap { element in
            let iou = element.bounds.iou(candidate.bounds)
            let near = element.bounds.center.distance(to: candidate.center) < 40
            return (iou >= 0.3 || near) ? element : nil
        }
    }
}

public enum Revalidation: Sendable, Equatable {
    case valid
    case stale
    case disabled
    case applicationChanged
}

public struct SuppliedText {
    public static func resolve(task: String, explicit: String?) -> String? {
        if let explicit {
            let trimmed = explicit.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        guard let opening = task.firstIndex(of: "\"") else { return nil }
        let rest = task[task.index(after: opening)...]
        guard let closing = rest.firstIndex(of: "\"") else { return nil }
        let value = task[task.index(after: opening)..<closing]
        let text = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
