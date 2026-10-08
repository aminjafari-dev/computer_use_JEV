import Foundation

public struct EngineDecision: Sendable, Equatable {
    public var answers: ValidatedAnswers
    public var candidate: Candidate?
    public var reviewReasons: [ReviewReason]
    public var shouldStopComplete: Bool
    public var shouldStopBlocked: Bool

    public init(
        answers: ValidatedAnswers,
        candidate: Candidate?,
        reviewReasons: [ReviewReason],
        shouldStopComplete: Bool,
        shouldStopBlocked: Bool
    ) {
        self.answers = answers
        self.candidate = candidate
        self.reviewReasons = reviewReasons
        self.shouldStopComplete = shouldStopComplete
        self.shouldStopBlocked = shouldStopBlocked
    }
}

public protocol DecisionMaking: Sendable {
    func decide(
        goal: String,
        userTextAvailable: Bool,
        observation: ScreenObservation,
        candidates: [Candidate],
        unavailableLabels: [String],
        history: [StepRecord],
        mode: ExecutionMode,
        settings: ConfidenceSettings,
        model: String
    ) async throws -> EngineDecision
}

public struct DecisionEngine: DecisionMaking, Sendable {
    public var client: JevClient

    public init(client: JevClient) {
        self.client = client
    }

    public func decide(
        goal: String,
        userTextAvailable: Bool,
        observation: ScreenObservation,
        candidates: [Candidate],
        unavailableLabels: [String],
        history: [StepRecord],
        mode: ExecutionMode,
        settings: ConfidenceSettings,
        model: String
    ) async throws -> EngineDecision {
        let body = JevRequestSerializer.make(
            model: model,
            task: goal,
            userTextAvailable: userTextAvailable,
            observation: observation,
            candidates: candidates,
            unavailableLabels: unavailableLabels,
            history: history
        )
        let answers = try await client.evaluate(body)
        return Self.interpret(
            answers: answers,
            candidates: candidates,
            observation: observation,
            mode: mode,
            settings: settings
        )
    }

    public static func interpret(
        answers: ValidatedAnswers,
        candidates: [Candidate],
        observation: ScreenObservation,
        mode: ExecutionMode,
        settings: ConfidenceSettings
    ) -> EngineDecision {
        if answers.choiceID == JevRequestSerializer.noneBlockedID || answers.blocked >= settings.blockedThreshold {
            return EngineDecision(
                answers: answers,
                candidate: nil,
                reviewReasons: [],
                shouldStopComplete: false,
                shouldStopBlocked: true
            )
        }
        guard let candidate = candidates.first(where: { $0.id == answers.choiceID }) else {
            return EngineDecision(
                answers: answers,
                candidate: nil,
                reviewReasons: [],
                shouldStopComplete: false,
                shouldStopBlocked: true
            )
        }
        var reasons: [ReviewReason] = []
        if mode == .review { reasons.append(.reviewMode) }
        if answers.confidence < settings.minimumConfidence { reasons.append(.lowConfidence) }
        if settings.isAmbiguous(topToSecondRatio: answers.topToSecondRatio) { reasons.append(.ambiguous) }
        if SafetyPolicy.requiresReview(candidate: candidate, windowTitle: observation.windowTitle) {
            reasons.append(.consequential)
        }
        let complete = answers.taskComplete >= settings.completionThreshold
        return EngineDecision(
            answers: answers,
            candidate: candidate,
            reviewReasons: reasons,
            shouldStopComplete: complete,
            shouldStopBlocked: false
        )
    }
}

public protocol ScreenObserving: Sendable {
    func permissionsGranted() async -> Bool
    func observe() async throws -> ScreenObservation
}

public struct ExecutionReport: Sendable, Equatable {
    public var changedScreen: Bool
    public init(changedScreen: Bool) { self.changedScreen = changedScreen }
}

public protocol ActionExecuting: Sendable {
    func revalidate(_ candidate: Candidate, original: ScreenObservation, fresh: ScreenObservation) -> Revalidation
    func execute(_ candidate: Candidate, userText: String?, observation: ScreenObservation) async throws
}

public protocol ApprovalProviding: Sendable {
    func requestApproval(_ proposal: Proposal) async -> Approval
}

public protocol TaskProgressReporting: Sendable {
    func update(_ snapshot: TaskSnapshot) async
}

public protocol Clock: Sendable {
    func now() -> Date
}

public struct SystemClock: Clock {
    public init() {}
    public func now() -> Date { Date() }
}

public struct RunControl: Sendable {
    private let state: State

    public init() { self.state = State() }

    public func pause() { state.setPaused(true) }
    public func resume() { state.setPaused(false) }
    public func stop() { state.stop() }
    public func waitIfPaused() async throws { try await state.waitIfPaused() }
    public var isStopped: Bool { state.isStopped }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var paused = false
        private var stopped = false
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func setPaused(_ value: Bool) {
            lock.lock()
            paused = value
            let pending = value ? [] : waiters
            if !value { waiters.removeAll() }
            lock.unlock()
            pending.forEach { $0.resume() }
        }

        func stop() {
            lock.lock()
            stopped = true
            paused = false
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            pending.forEach { $0.resume(throwing: CancellationError()) }
        }

        var isStopped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return stopped
        }

        func waitIfPaused() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if stopped {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if !paused {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

public struct TaskRunner: Sendable {
    public var observer: any ScreenObserving
    public var executor: any ActionExecuting
    public var decider: any DecisionMaking
    public var approvals: any ApprovalProviding
    public var progress: any TaskProgressReporting
    public var clock: any Clock
    public var control: RunControl

    public init(
        observer: any ScreenObserving,
        executor: any ActionExecuting,
        decider: any DecisionMaking,
        approvals: any ApprovalProviding,
        progress: any TaskProgressReporting,
        clock: any Clock = SystemClock(),
        control: RunControl = RunControl()
    ) {
        self.observer = observer
        self.executor = executor
        self.decider = decider
        self.approvals = approvals
        self.progress = progress
        self.clock = clock
        self.control = control
    }

    public func run(
        request: TaskRequest,
        limits: TaskLimits,
        mode: ExecutionMode,
        settings: ConfidenceSettings,
        model: String
    ) async -> TaskResult {
        let started = clock.now()
        var steps: [StepRecord] = []
        var loop = LoopDetector(
            repeatedStateLimit: limits.repeatedStateLimit,
            ineffectiveActionLimit: limits.ineffectiveActionLimit
        )
        var apiErrors = 0
        var staleCount = 0
        var sawChange = false
        var lastDecision: Double?
        let userText = SuppliedText.resolve(task: request.text, explicit: request.suppliedText)

        func finish(_ reason: StopReason, message: String? = nil) async -> TaskResult {
            let elapsed = clock.now().timeIntervalSince(started)
            let result = TaskResult(
                outcome: reason.outcome,
                stopReason: reason,
                steps: steps,
                elapsedSeconds: elapsed,
                message: message ?? reason.explanation
            )
            await report(
                status: result.outcome.rawValue,
                steps: steps,
                started: started,
                proposal: nil,
                lastDecision: lastDecision,
                result: result
            )
            return result
        }

        do {
            while true {
                try Task.checkCancellation()
                try await control.waitIfPaused()
                let elapsed = clock.now().timeIntervalSince(started)
                if elapsed >= limits.maxDurationSeconds {
                    return await finish(.timeBudget)
                }
                if steps.filter({ $0.note == "executed" }).count >= limits.maxActions {
                    return await finish(.actionBudget)
                }
                guard await observer.permissionsGranted() else {
                    return await finish(.permissionLost)
                }

                await report(status: "Looking at the screen", steps: steps, started: started, proposal: nil, lastDecision: lastDecision, result: nil)
                let detectionStart = clock.now()
                let observation = try await observer.observe()
                let detection = clock.now().timeIntervalSince(detectionStart)
                if let stop = loop.observe(fingerprint: StateFingerprint.make(observation)) {
                    return await finish(stop)
                }

                let built = CandidateBuilder().build(
                    observation: observation,
                    task: request.text,
                    userTextAvailable: userText != nil
                )
                guard !built.candidates.isEmpty else {
                    return await finish(.noActionAvailable)
                }

                await report(status: "Choosing an action", steps: steps, started: started, proposal: nil, lastDecision: lastDecision, result: nil)
                let decisionStart = clock.now()
                let decision: EngineDecision
                do {
                    decision = try await decider.decide(
                        goal: request.text,
                        userTextAvailable: userText != nil,
                        observation: observation,
                        candidates: built.candidates,
                        unavailableLabels: built.unavailableLabels,
                        history: steps,
                        mode: mode,
                        settings: settings,
                        model: model
                    )
                    apiErrors = 0
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    apiErrors += 1
                    if apiErrors >= limits.maxConsecutiveAPIErrors {
                        return await finish(.persistentErrors, message: Self.friendly(error))
                    }
                    continue
                }
                lastDecision = clock.now().timeIntervalSince(decisionStart)

                if decision.shouldStopBlocked {
                    return await finish(.blockedByScreen)
                }

                if decision.shouldStopComplete {
                    let visible = observation.elements.contains { ResultVerifier.isCompletionSignal($0.label) }
                    if visible || sawChange {
                        let message = visible
                            ? "Finished. The screen shows a completion indicator."
                            : StopReason.completed.explanation
                        return await finish(.completed, message: message)
                    }
                }

                guard let candidate = decision.candidate else {
                    return await finish(.noActionAvailable)
                }

                let proposal = Proposal(
                    candidate: candidate,
                    reason: decision.reviewReasons.first ?? .reviewMode,
                    confidence: decision.answers.confidence
                )
                if !decision.reviewReasons.isEmpty {
                    await report(status: "Waiting for approval", steps: steps, started: started, proposal: proposal, lastDecision: lastDecision, result: nil)
                    let approval = await approvals.requestApproval(proposal)
                    switch approval {
                    case .approved: break
                    case .rejected: return await finish(.rejectedByUser)
                    case .stopped: return await finish(.cancelled)
                    }
                }

                try Task.checkCancellation()
                let executionStart = clock.now()
                let fresh = try await observer.observe()
                let check = executor.revalidate(candidate, original: observation, fresh: fresh)
                switch check {
                case .applicationChanged:
                    return await finish(.staleTarget, message: "The selected application changed.")
                case .disabled:
                    return await finish(.staleTarget, message: "That control is disabled.")
                case .stale:
                    staleCount += 1
                    if staleCount >= 2 { return await finish(.staleTarget) }
                    continue
                case .valid:
                    staleCount = 0
                }

                if candidate.operation == .insertText, userText == nil {
                    return await finish(.failed, message: "Text entry needs text you supply. The assistant does not invent it.")
                }
                try await executor.execute(candidate, userText: userText, observation: fresh)
                let after = try await observer.observe()
                let verification = ResultVerifier.verify(before: fresh, after: after)
                let changed: Bool
                switch verification {
                case .unchanged: changed = false
                case .changed: changed = true
                case .completed: changed = true
                }
                if changed { sawChange = true }
                let execution = clock.now().timeIntervalSince(executionStart)
                steps.append(StepRecord(
                    id: steps.count + 1,
                    candidateID: candidate.id,
                    label: candidate.summary,
                    operation: candidate.operation,
                    changedScreen: changed,
                    detectionSeconds: detection,
                    decisionSeconds: lastDecision ?? 0,
                    executionSeconds: execution,
                    note: "executed"
                ))
                if case .completed(let signal) = verification, decision.answers.taskComplete >= settings.completionThreshold || sawChange {
                    // A visible completion phrase is evidence. The Noul alone is not required once the phrase appears,
                    // but a phrase without a state change cannot happen because the phrase is new text.
                    _ = signal
                    return await finish(.completed, message: "Finished. The screen shows \"\(signal)\".")
                }
                if let stop = loop.recordAction(changedScreen: changed) {
                    return await finish(stop)
                }
            }
        } catch is CancellationError {
            return await finish(.cancelled)
        } catch let error as PilotError {
            switch error {
            case .permissionDenied: return await finish(.permissionLost)
            case .applicationChanged, .staleTarget, .disabledTarget: return await finish(.staleTarget)
            default: return await finish(.failed, message: Self.friendly(error))
            }
        } catch {
            return await finish(.failed, message: Self.friendly(error))
        }
    }

    private func report(
        status: String,
        steps: [StepRecord],
        started: Date,
        proposal: Proposal?,
        lastDecision: Double?,
        result: TaskResult?
    ) async {
        let snapshot = TaskSnapshot(
            status: status,
            stepCount: steps.count,
            elapsedSeconds: clock.now().timeIntervalSince(started),
            proposal: proposal,
            lastDecisionSeconds: lastDecision,
            steps: steps,
            result: result
        )
        await progress.update(snapshot)
    }

    static func friendly(_ error: Error) -> String {
        if let jev = error as? JevClientError {
            switch jev {
            case .missingAPIKey: return "Add a TypeSafe API key in Settings."
            case .authentication: return "The TypeSafe API key was rejected. Check it in Settings."
            case .rateLimited: return "TypeSafe rate limit reached. Wait a moment and try again."
            case .overloaded: return "TypeSafe is busy. Try again shortly."
            case .timeout: return "The request to TypeSafe timed out."
            case .network: return "Could not reach TypeSafe. Check the network and try again."
            case .rejected: return "TypeSafe rejected the request."
            case .malformed, .invalid: return "TypeSafe returned a response that could not be used."
            }
        }
        return "Something went wrong before the next action."
    }
}
