import Foundation

/// Where a screen observation came from. Core ML is optional and never synthesized.
public enum ObservationSource: String, Codable, Sendable, CaseIterable {
    case accessibility
    case ocr
    case coreML
}

public struct Point: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: Point) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

/// Rectangle in the shared coordinate system: global points, origin at the
/// top-left of the primary display, y increasing downward.
public struct Rect: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var center: Point { Point(x: x + width / 2, y: y + height / 2) }
    public var area: Double { max(0, width) * max(0, height) }
    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func intersection(_ other: Rect) -> Rect? {
        let ix = max(minX, other.minX)
        let iy = max(minY, other.minY)
        let ax = min(maxX, other.maxX)
        let ay = min(maxY, other.maxY)
        let w = ax - ix
        let h = ay - iy
        guard w > 0, h > 0 else { return nil }
        return Rect(x: ix, y: iy, width: w, height: h)
    }

    public func iou(_ other: Rect) -> Double {
        guard let overlap = intersection(other) else { return 0 }
        let union = area + other.area - overlap.area
        guard union > 0 else { return 0 }
        return overlap.area / union
    }

    public func contains(_ point: Point) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }
}

public enum Operation: String, Codable, Sendable, CaseIterable {
    case click
    case doubleClick
    case rightClick
    case scrollUp
    case scrollDown
    case pressKey
    case insertText
}

/// Keys the executor is willing to post. Anything else is refused.
public enum NavigationKey: String, Codable, Sendable, CaseIterable {
    case escape
    case returnKey
    case tab
    case up
    case down
    case left
    case right
    case pageUp
    case pageDown

    public var displayName: String {
        switch self {
        case .escape: "Escape"
        case .returnKey: "Return"
        case .tab: "Tab"
        case .up: "Up Arrow"
        case .down: "Down Arrow"
        case .left: "Left Arrow"
        case .right: "Right Arrow"
        case .pageUp: "Page Up"
        case .pageDown: "Page Down"
        }
    }
}

public struct UIElementObservation: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var role: String
    public var value: String?
    public var enabled: Bool
    public var bounds: Rect
    public var supportedActions: [String]
    public var parentLabels: [String]
    public var sources: [ObservationSource]
    public var isSecure: Bool

    public init(
        id: String,
        label: String,
        role: String,
        value: String? = nil,
        enabled: Bool,
        bounds: Rect,
        supportedActions: [String] = [],
        parentLabels: [String] = [],
        sources: [ObservationSource],
        isSecure: Bool = false
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.value = value
        self.enabled = enabled
        self.bounds = bounds
        self.supportedActions = supportedActions
        self.parentLabels = parentLabels
        self.sources = sources
        self.isSecure = isSecure
    }

    public var primarySource: ObservationSource { sources.first ?? .accessibility }
}

public struct ScreenObservation: Codable, Sendable, Equatable {
    public var appName: String
    public var bundleID: String?
    public var windowTitle: String
    public var windowID: UInt32?
    public var pid: Int32
    public var elements: [UIElementObservation]
    public var capturedAt: Date

    public init(
        appName: String,
        bundleID: String? = nil,
        windowTitle: String,
        windowID: UInt32? = nil,
        pid: Int32,
        elements: [UIElementObservation],
        capturedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.windowID = windowID
        self.pid = pid
        self.elements = elements
        self.capturedAt = capturedAt
    }
}

public enum StateFingerprint {
    public static func make(_ observation: ScreenObservation) -> String {
        let rows = observation.elements.map { element in
            [
                element.role,
                element.label,
                element.enabled ? "1" : "0",
                String(Int(element.bounds.x.rounded())),
                String(Int(element.bounds.y.rounded())),
                String(Int(element.bounds.width.rounded())),
                String(Int(element.bounds.height.rounded()))
            ].joined(separator: "|")
        }
        return ([observation.appName, observation.windowTitle, "pid:\(observation.pid)"] + rows.sorted())
            .joined(separator: "\n")
    }
}

public struct Candidate: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var controlType: String
    public var enabled: Bool
    public var bounds: Rect
    public var center: Point
    public var operation: Operation
    public var source: ObservationSource
    public var contextLabels: [String]
    /// Identity used to find the same control in a later observation.
    public var elementID: String
    public var navigationKey: NavigationKey?
    /// Coarse region word derived in code. Sent as text so the model never receives raw coordinates to invent.
    public var region: String

    public init(
        id: String,
        label: String,
        controlType: String,
        enabled: Bool,
        bounds: Rect,
        center: Point,
        operation: Operation,
        source: ObservationSource,
        contextLabels: [String],
        elementID: String,
        navigationKey: NavigationKey? = nil,
        region: String
    ) {
        self.id = id
        self.label = label
        self.controlType = controlType
        self.enabled = enabled
        self.bounds = bounds
        self.center = center
        self.operation = operation
        self.source = source
        self.contextLabels = contextLabels
        self.elementID = elementID
        self.navigationKey = navigationKey
        self.region = region
    }

    public var summary: String {
        switch operation {
        case .pressKey:
            return "Press \(navigationKey?.displayName ?? "key")"
        case .insertText:
            return "Type your text into \(label.isEmpty ? "text field" : label)"
        case .scrollUp:
            return "Scroll up \(label)"
        case .scrollDown:
            return "Scroll down \(label)"
        case .doubleClick:
            return "Double-click \(label)"
        case .rightClick:
            return "Right-click \(label)"
        case .click:
            return "Click \(label)"
        }
    }
}

public struct StepRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: Int
    public var candidateID: String
    public var label: String
    public var operation: Operation
    public var changedScreen: Bool
    public var detectionSeconds: Double
    public var decisionSeconds: Double
    public var executionSeconds: Double
    public var note: String

    public init(
        id: Int,
        candidateID: String,
        label: String,
        operation: Operation,
        changedScreen: Bool,
        detectionSeconds: Double,
        decisionSeconds: Double,
        executionSeconds: Double,
        note: String
    ) {
        self.id = id
        self.candidateID = candidateID
        self.label = label
        self.operation = operation
        self.changedScreen = changedScreen
        self.detectionSeconds = detectionSeconds
        self.decisionSeconds = decisionSeconds
        self.executionSeconds = executionSeconds
        self.note = note
    }

    public var stepSeconds: Double { detectionSeconds + decisionSeconds + executionSeconds }
}

public enum ExecutionMode: String, Codable, Sendable, CaseIterable {
    case review
    case automatic

    public var title: String {
        switch self {
        case .review: "Review actions"
        case .automatic: "Automatic"
        }
    }
}

public enum StopReason: String, Codable, Sendable {
    case completed
    case blockedByScreen
    case rejectedByUser
    case cancelled
    case permissionLost
    case repeatedState
    case ineffectiveActions
    case actionBudget
    case timeBudget
    case persistentErrors
    case staleTarget
    case noActionAvailable
    case failed
}

public enum TaskOutcomeKind: String, Codable, Sendable {
    case completed
    case blocked
    case cancelled
    case failed
    case unverified
}

extension StopReason {
    public var outcome: TaskOutcomeKind {
        switch self {
        case .completed:
            return .completed
        case .cancelled:
            return .cancelled
        case .permissionLost, .persistentErrors, .failed:
            return .failed
        case .actionBudget, .timeBudget:
            return .unverified
        case .blockedByScreen, .rejectedByUser, .repeatedState, .ineffectiveActions, .staleTarget, .noActionAvailable:
            return .blocked
        }
    }

    public var explanation: String {
        switch self {
        case .completed: "The task looks complete."
        case .blockedByScreen: "Nothing on this screen can move the task forward."
        case .rejectedByUser: "You declined the proposed action."
        case .cancelled: "You stopped the task."
        case .permissionLost: "Accessibility or Screen Recording permission is no longer available."
        case .repeatedState: "The screen kept returning to the same state."
        case .ineffectiveActions: "The last actions did not change the screen."
        case .actionBudget: "The action limit was reached before the task could be confirmed."
        case .timeBudget: "The time limit was reached before the task could be confirmed."
        case .persistentErrors: "The action service kept failing."
        case .staleTarget: "The chosen control moved or disappeared before it could be used."
        case .noActionAvailable: "No matching control was available."
        case .failed: "The task stopped because of an error."
        }
    }
}

public struct TaskResult: Codable, Sendable, Equatable {
    public var outcome: TaskOutcomeKind
    public var stopReason: StopReason
    public var steps: [StepRecord]
    public var elapsedSeconds: Double
    public var message: String

    public init(outcome: TaskOutcomeKind, stopReason: StopReason, steps: [StepRecord], elapsedSeconds: Double, message: String) {
        self.outcome = outcome
        self.stopReason = stopReason
        self.steps = steps
        self.elapsedSeconds = elapsedSeconds
        self.message = message
    }
}

public struct TaskLimits: Codable, Sendable, Equatable {
    public var maxActions: Int
    public var maxDurationSeconds: Double
    /// Same screen fingerprint this many times ends the task.
    public var repeatedStateLimit: Int
    /// Consecutive actions that do not change the screen.
    public var ineffectiveActionLimit: Int
    public var maxConsecutiveAPIErrors: Int

    public init(
        maxActions: Int = 15,
        maxDurationSeconds: Double = 180,
        repeatedStateLimit: Int = 3,
        ineffectiveActionLimit: Int = 2,
        maxConsecutiveAPIErrors: Int = 3
    ) {
        self.maxActions = maxActions
        self.maxDurationSeconds = maxDurationSeconds
        self.repeatedStateLimit = repeatedStateLimit
        self.ineffectiveActionLimit = ineffectiveActionLimit
        self.maxConsecutiveAPIErrors = maxConsecutiveAPIErrors
    }
}

public struct TaskRequest: Codable, Sendable, Equatable {
    public var text: String
    /// Text the user typed or explicitly approved. Never invented by the model.
    public var suppliedText: String?

    public init(text: String, suppliedText: String? = nil) {
        self.text = text
        self.suppliedText = suppliedText
    }
}

public enum PilotError: Error, Equatable, Sendable {
    case permissionDenied
    case staleTarget
    case applicationChanged
    case disabledTarget
    case missingUserText
    case refusedSecureField
    case executionFailed(String)
}

public struct Proposal: Sendable, Equatable {
    public var candidate: Candidate
    public var reason: ReviewReason
    public var confidence: Double

    public init(candidate: Candidate, reason: ReviewReason, confidence: Double) {
        self.candidate = candidate
        self.reason = reason
        self.confidence = confidence
    }
}

public enum ReviewReason: String, Codable, Sendable {
    case reviewMode
    case lowConfidence
    case ambiguous
    case consequential

    public var explanation: String {
        switch self {
        case .reviewMode: "Review is on, so this action waits for your approval."
        case .lowConfidence: "The choice was uncertain, so it waits for your approval."
        case .ambiguous: "Two controls were close, so this waits for your approval."
        case .consequential: "This action can send, pay, delete, or change access, so it needs your approval."
        }
    }
}

public enum Approval: Sendable, Equatable {
    case approved
    case rejected
    case stopped
}

public struct TaskSnapshot: Sendable, Equatable {
    public var status: String
    public var stepCount: Int
    public var elapsedSeconds: Double
    public var proposal: Proposal?
    public var lastDecisionSeconds: Double?
    public var steps: [StepRecord]
    public var result: TaskResult?

    public init(
        status: String,
        stepCount: Int,
        elapsedSeconds: Double,
        proposal: Proposal?,
        lastDecisionSeconds: Double?,
        steps: [StepRecord],
        result: TaskResult?
    ) {
        self.status = status
        self.stepCount = stepCount
        self.elapsedSeconds = elapsedSeconds
        self.proposal = proposal
        self.lastDecisionSeconds = lastDecisionSeconds
        self.steps = steps
        self.result = result
    }
}
