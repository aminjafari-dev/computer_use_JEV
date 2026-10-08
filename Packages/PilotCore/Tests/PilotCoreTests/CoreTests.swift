import XCTest
@testable import PilotCore

final class CoordinateConverterTests: XCTestCase {
    func testCocoaAndGlobalRoundTripOnPrimaryDisplay() {
        let cocoa = Rect(x: 100, y: 200, width: 40, height: 20)
        let global = CoordinateConverter.cocoaRectToGlobal(cocoa: cocoa, primaryHeight: 1000)
        XCTAssertEqual(global, Rect(x: 100, y: 780, width: 40, height: 20))
        let back = CoordinateConverter.globalRectToCocoa(global: global, primaryHeight: 1000)
        XCTAssertEqual(back, cocoa)
    }

    func testWindowOnLeftDisplayKeepsNegativeX() {
        let cocoa = Rect(x: -500, y: 800, width: 100, height: 100)
        let global = CoordinateConverter.cocoaRectToGlobal(cocoa: cocoa, primaryHeight: 1000)
        XCTAssertEqual(global.x, -500)
        XCTAssertEqual(global.y, 100, accuracy: 0.001)
    }

    func testRetinaVisionBoxMapsToGlobalPoints() {
        // 200x100 pt window at global (10, 20), captured at 2x as 400x200 px.
        // Vision box covers the top-left quarter of the image: normalized origin
        // bottom-left would be x=0, y=0.5, w=0.5, h=0.5 for the top half? 
        // Top-left quarter in a bottom-left normalized box is x=0, y=0.5, w=0.5, h=0.5.
        let capture = Rect(x: 10, y: 20, width: 200, height: 100)
        let global = CoordinateConverter.visionBoxToGlobal(
            originX: 0, originY: 0.5, boxWidth: 0.5, boxHeight: 0.5,
            imageWidth: 400, imageHeight: 200,
            captureGlobal: capture,
            scale: 2
        )
        XCTAssertEqual(global.x, 10, accuracy: 0.001)
        XCTAssertEqual(global.y, 20, accuracy: 0.001)
        XCTAssertEqual(global.width, 100, accuracy: 0.001)
        XCTAssertEqual(global.height, 50, accuracy: 0.001)
    }

    func testPointFlipUsesPrimaryHeight() {
        let global = CoordinateConverter.cocoaPointToGlobal(cocoa: Point(x: 10, y: 10), primaryHeight: 800)
        XCTAssertEqual(global, Point(x: 10, y: 790))
    }
}

final class ObservationMergerTests: XCTestCase {
    func testOverlappingOCRAndAccessibilityKeepBothSources() {
        let ax = element("Save", source: .accessibility, bounds: Rect(x: 0, y: 0, width: 40, height: 20))
        let ocr = element("Save", source: .ocr, bounds: Rect(x: 2, y: 1, width: 38, height: 18))
        let merged = ObservationMerger.merge([[ax], [ocr]])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].sources, [.accessibility, .ocr])
        XCTAssertEqual(merged[0].bounds, ax.bounds)
    }

    func testDuplicateLabelsThatDoNotOverlapStayDistinct() {
        let left = element("Open", source: .accessibility, bounds: Rect(x: 0, y: 0, width: 30, height: 20))
        let right = element("Open", source: .accessibility, bounds: Rect(x: 200, y: 0, width: 30, height: 20), id: "b")
        XCTAssertEqual(ObservationMerger.merge([[left, right]]).count, 2)
    }

    func testSecureFieldsAreDropped() {
        var secure = element("Password", source: .accessibility, bounds: Rect(x: 0, y: 0, width: 10, height: 10))
        secure.isSecure = true
        XCTAssertTrue(ObservationMerger.merge([[secure]]).isEmpty)
    }

    private func element(_ label: String, source: ObservationSource, bounds: Rect, id: String = "a") -> UIElementObservation {
        UIElementObservation(
            id: id, label: label, role: "AXButton", enabled: true, bounds: bounds,
            supportedActions: ["AXPress"], sources: [source]
        )
    }
}

final class CandidateBuilderTests: XCTestCase {
    func testDuplicateLabelsGetDistinctGroundedIDs() {
        let observation = ScreenObservation(
            appName: "Demo", windowTitle: "Fixture", pid: 1,
            elements: [
                button("Open", id: "songs", x: 0, context: ["Songs"]),
                button("Open", id: "files", x: 200, context: ["Files"])
            ]
        )
        let built = CandidateBuilder().build(observation: observation, task: "Open my saved songs", userTextAvailable: false)
        let opens = built.candidates.filter { $0.label == "Open" && $0.operation == .click }
        XCTAssertEqual(opens.count, 2)
        XCTAssertEqual(Set(opens.map(\.id)).count, 2)
        XCTAssertTrue(opens.contains { $0.contextLabels == ["Songs"] })
    }

    func testDisabledAndSecureAreNotExecutable() {
        var disabled = button("Save", id: "d", x: 0, context: [])
        disabled.enabled = false
        var secure = button("Password", id: "s", x: 10, context: [])
        secure.isSecure = true
        secure.role = "AXTextField"
        let observation = ScreenObservation(appName: "Demo", windowTitle: "W", pid: 1, elements: [disabled, secure, button("OK", id: "ok", x: 40, context: [])])
        let built = CandidateBuilder().build(observation: observation, task: "Save", userTextAvailable: true)
        XCTAssertFalse(built.candidates.contains { $0.label == "Save" || $0.label == "Password" })
        XCTAssertTrue(built.unavailableLabels.contains { $0.contains("Save") })
        XCTAssertTrue(built.candidates.contains { $0.label == "OK" })
    }

    func testTextInsertionOnlyWhenUserSuppliedText() {
        var field = button("Note", id: "f", x: 0, context: [])
        field.role = "AXTextField"
        field.supportedActions = []
        let observation = ScreenObservation(appName: "Demo", windowTitle: "W", pid: 1, elements: [field])
        let without = CandidateBuilder().build(observation: observation, task: "type hello", userTextAvailable: false)
        XCTAssertFalse(without.candidates.contains { $0.operation == .insertText })
        let with = CandidateBuilder().build(observation: observation, task: "type hello", userTextAvailable: true)
        XCTAssertTrue(with.candidates.contains { $0.operation == .insertText && $0.elementID == "f" })
    }

    func testCandidateCapStaysUnderChoiceLimit() {
        let elements = (0..<300).map { button("Analytics \($0)", id: "e\($0)", x: Double($0 * 10), context: []) }
        let observation = ScreenObservation(appName: "Demo", windowTitle: "W", pid: 1, elements: elements)
        let built = CandidateBuilder(maxCandidates: 120).build(observation: observation, task: "analytics", userTextAvailable: false)
        XCTAssertEqual(built.candidates.count, 120)
        XCTAssertEqual(built.candidates.map(\.id), (1...120).map { "c\($0)" })
    }

    private func button(_ label: String, id: String, x: Double, context: [String]) -> UIElementObservation {
        UIElementObservation(
            id: id, label: label, role: "AXButton", enabled: true,
            bounds: Rect(x: x, y: 0, width: 20, height: 20),
            supportedActions: ["AXPress"], parentLabels: context, sources: [.accessibility]
        )
    }
}

final class JevContractTests: XCTestCase {
    func testSerializerOmitsSecretsScreenshotsAndUserText() throws {
        let secret = "clipboard-and-password-value"
        let observation = ScreenObservation(appName: "Mail", windowTitle: "Inbox", pid: 4, elements: [
            UIElementObservation(id: "b", label: "Send", role: "AXButton", enabled: true, bounds: Rect(x: 0, y: 0, width: 10, height: 10), supportedActions: ["AXPress"], sources: [.accessibility])
        ])
        let built = CandidateBuilder().build(observation: observation, task: "Send", userTextAvailable: true)
        let body = JevRequestSerializer.make(
            model: "jev-latest", task: "Send the note", userTextAvailable: true,
            observation: observation, candidates: built.candidates, unavailableLabels: ["Password"],
            history: []
        )
        let data = try body.jsonData()
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(raw.contains(secret))
        XCTAssertFalse(raw.contains("screenshot"))
        XCTAssertFalse(raw.contains("image"))
        XCTAssertTrue(raw.contains("UNTRUSTED_SCREEN_DATA"))
        XCTAssertTrue(raw.contains("none_blocked"))
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let state = object?["state"] as? [String: Any]
        XCTAssertEqual(Set(state?.keys.map { $0 } ?? []), JevRequestSerializer.stateKeys)
        XCTAssertEqual(state?["user_supplied_text_available"] as? Bool, true)
        XCTAssertNil(state?["supplied_text"])
    }

    func testValidatorRejectsInventedChoiceAndBadProbabilities() {
        let allowed: Set<String> = ["c1", "none_blocked"]
        XCTAssertThrowsError(try JevResponseValidator.validate(data: response(choice: "c99", probabilities: ["c99": 1, "c1": 0, "none_blocked": 0]), allowedChoiceIDs: allowed)) { error in
            XCTAssertEqual(error as? JevValidationError, .unknownChoice("c99"))
        }
        XCTAssertThrowsError(try JevResponseValidator.validate(data: response(choice: "c1", probabilities: ["c1": 0.9, "none_blocked": 0.9]), allowedChoiceIDs: allowed)) { error in
            guard let validation = error as? JevValidationError, case JevValidationError.probabilitySum = validation else {
                return XCTFail("expected sum error, got \(error)")
            }
        }
        XCTAssertThrowsError(try JevResponseValidator.validate(data: response(choice: "c1", probabilities: ["c1": 1], noul: 2), allowedChoiceIDs: allowed))
    }

    func testValidatorAcceptsGroundedChoice() throws {
        let answers = try JevResponseValidator.validate(
            data: response(choice: "c1", probabilities: ["c1": 0.8, "none_blocked": 0.2]),
            allowedChoiceIDs: ["c1", "none_blocked"]
        )
        XCTAssertEqual(answers.choiceID, "c1")
        XCTAssertEqual(answers.confidence, 0.7, accuracy: 0.001)
        XCTAssertEqual(answers.topToSecondRatio, 4, accuracy: 0.001)
        XCTAssertEqual(answers.model, "jev-1.13.0")
    }

    private func response(choice: String, probabilities: [String: Double], noul: Double = 0.1) -> Data {
        let probs = probabilities.mapValues { $0 as Any }
        let json: [String: Any] = [
            "model": "jev-1.13.0",
            "answers": [
                "next_action": [
                    "type": "choice",
                    "choice": choice,
                    "probabilities": probs,
                    "confidence": 0.7
                ],
                "task_complete": ["type": "noul", "noul": noul],
                "blocked": ["type": "noul", "noul": 0.05]
            ],
            "usage": ["input_tokens": 10, "output_tokens": 4]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }
}

final class ConfidenceAndSafetyTests: XCTestCase {
    func testChoiceConfidenceMatchesDocumentedFormula() {
        // (0.6 - 1/3) / (1 - 1/3) = 0.4
        XCTAssertEqual(ConfidenceMath.choiceConfidence([0.6, 0.3, 0.1]), 0.4, accuracy: 0.0001)
        XCTAssertEqual(ConfidenceMath.choiceConfidence([1, 0, 0]), 1, accuracy: 0.0001)
    }

    func testAmbiguousAndLowConfidenceRequireReview() {
        let settings = ConfidenceSettings()
        let candidate = sampleCandidate()
        let low = answers(choice: "c1", confidence: 0.2, probabilities: ["c1": 0.4, "none_blocked": 0.6], complete: 0, blocked: 0)
        let decision = DecisionEngine.interpret(answers: low, candidates: [candidate], observation: sampleObservation(), mode: .automatic, settings: settings)
        XCTAssertTrue(decision.reviewReasons.contains(.lowConfidence))
        XCTAssertTrue(decision.reviewReasons.contains(.ambiguous))

        let clear = answers(choice: "c1", confidence: 0.9, probabilities: ["c1": 0.95, "none_blocked": 0.05], complete: 0, blocked: 0)
        let auto = DecisionEngine.interpret(answers: clear, candidates: [candidate], observation: sampleObservation(), mode: .automatic, settings: settings)
        XCTAssertTrue(auto.reviewReasons.isEmpty)

        let review = DecisionEngine.interpret(answers: clear, candidates: [candidate], observation: sampleObservation(), mode: .review, settings: settings)
        XCTAssertEqual(review.reviewReasons, [.reviewMode])
    }

    func testConsequentialActionsAlwaysNeedReview() {
        var send = sampleCandidate()
        send.label = "Send"
        XCTAssertTrue(SafetyPolicy.requiresReview(candidate: send, windowTitle: "Mail"))
        let answers = answers(choice: "c1", confidence: 0.99, probabilities: ["c1": 0.99, "none_blocked": 0.01], complete: 0, blocked: 0)
        let decision = DecisionEngine.interpret(answers: answers, candidates: [send], observation: sampleObservation(), mode: .automatic, settings: ConfidenceSettings())
        XCTAssertTrue(decision.reviewReasons.contains(.consequential))
        var display = sampleCandidate()
        display.label = "Display options"
        XCTAssertFalse(SafetyPolicy.requiresReview(candidate: display, windowTitle: "Photos"))
    }

    func testSuppliedTextComesFromUserNotModel() {
        XCTAssertEqual(SuppliedText.resolve(task: "Type \"Hello there\"", explicit: nil), "Hello there")
        XCTAssertEqual(SuppliedText.resolve(task: "Type \"ignored\"", explicit: "Kept"), "Kept")
        XCTAssertNil(SuppliedText.resolve(task: "no quotes", explicit: "  "))
    }

    private func answers(choice: String, confidence: Double, probabilities: [String: Double], complete: Double, blocked: Double) -> ValidatedAnswers {
        ValidatedAnswers(
            choiceID: choice, probabilities: probabilities, confidence: confidence,
            topToSecondRatio: ConfidenceMath.topToSecondRatio(probabilities, selected: choice),
            taskComplete: complete, blocked: blocked, model: "jev-1.13.0", inputTokens: 1, outputTokens: 1
        )
    }
}

final class VerifierAndLoopTests: XCTestCase {
    func testClickWithoutStateChangeIsNotCompletion() {
        let before = sampleObservation()
        let after = sampleObservation()
        XCTAssertEqual(ResultVerifier.verify(before: before, after: after), .unchanged)
    }

    func testNewCompletionPhraseIsEvidence() {
        var after = sampleObservation()
        after.elements.append(UIElementObservation(
            id: "done", label: "Status: Complete", role: "AXStaticText", enabled: true,
            bounds: Rect(x: 0, y: 40, width: 80, height: 16), sources: [.accessibility]
        ))
        XCTAssertEqual(ResultVerifier.verify(before: sampleObservation(), after: after), .completed(signal: "Status: Complete"))
    }

    func testRepeatedStateAndIneffectiveActions() {
        var loop = LoopDetector(repeatedStateLimit: 3, ineffectiveActionLimit: 2)
        XCTAssertNil(loop.observe(fingerprint: "A"))
        XCTAssertNil(loop.observe(fingerprint: "A"))
        XCTAssertEqual(loop.observe(fingerprint: "A"), .repeatedState)
        var actions = LoopDetector(repeatedStateLimit: 9, ineffectiveActionLimit: 2)
        XCTAssertNil(actions.recordAction(changedScreen: false))
        XCTAssertEqual(actions.recordAction(changedScreen: false), .ineffectiveActions)
        XCTAssertNil(actions.recordAction(changedScreen: true))
    }

    func testStaleTargetWhenControlMoved() {
        let candidate = sampleCandidate()
        var fresh = sampleObservation()
        fresh.elements[0].bounds = Rect(x: 400, y: 400, width: 20, height: 20)
        XCTAssertEqual(TargetMatching.revalidate(candidate: candidate, original: sampleObservation(), fresh: fresh), .stale)
        var other = sampleObservation()
        other.pid = 99
        XCTAssertEqual(TargetMatching.revalidate(candidate: candidate, original: sampleObservation(), fresh: other), .applicationChanged)
    }
}

final class JevClientTests: XCTestCase {
    func testRetriesRateLimitThenValidates() async throws {
        let transport = ScriptedTransport(steps: [
            .response(429, Data("{}".utf8), "1"),
            .response(200, okBody, nil)
        ])
        let sleeper = RecordingSleeper()
        let logs = RecordingLog()
        let client = JevClient(apiKey: "secret-key", transport: transport, sleeper: sleeper, logger: logs, maxAttempts: 3)
        let answers = try await client.evaluate(sampleBody())
        XCTAssertEqual(answers.choiceID, "c1")
        XCTAssertEqual(transport.attempts, 2)
        XCTAssertEqual(sleeper.delays, [1_000_000_000])
        XCTAssertFalse(logs.lines.joined().contains("secret-key"))
    }

    func testAuthenticationIsNotRetried() async {
        let transport = ScriptedTransport(steps: [.response(401, Data("{}".utf8), nil)])
        let client = JevClient(apiKey: "secret-key", transport: transport, sleeper: RecordingSleeper(), maxAttempts: 3)
        do {
            _ = try await client.evaluate(sampleBody())
            XCTFail("expected authentication error")
        } catch JevClientError.authentication {
            XCTAssertEqual(transport.attempts, 1)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testNetworkRetriesThenFails() async {
        let transport = ScriptedTransport(steps: [.throwURL, .throwURL, .throwURL])
        let client = JevClient(apiKey: "k", transport: transport, sleeper: RecordingSleeper(), maxAttempts: 3)
        do {
            _ = try await client.evaluate(sampleBody())
            XCTFail("expected network")
        } catch JevClientError.network {
            XCTAssertEqual(transport.attempts, 3)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    private var okBody: Data {
        let json: [String: Any] = [
            "model": "jev-1.13.0",
            "answers": [
                "next_action": ["type": "choice", "choice": "c1", "probabilities": ["c1": 1.0, "none_blocked": 0.0], "confidence": 1.0],
                "task_complete": ["type": "noul", "noul": 0.0],
                "blocked": ["type": "noul", "noul": 0.0]
            ],
            "usage": ["input_tokens": 3, "output_tokens": 3]
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func sampleBody() -> JevRequestBody {
        JevRequestSerializer.make(
            model: "jev-latest", task: "Click OK", userTextAvailable: false,
            observation: sampleObservation(), candidates: [sampleCandidate()],
            unavailableLabels: [], history: []
        )
    }
}

final class TaskRunnerTests: XCTestCase {
    func testApprovedClickAndCompletionSignal() async {
        let harness = Harness()
        harness.observations = [obs("Ready"), obs("Ready"), obs("Status: Complete")]
        harness.choices = ["c1", "c1"]
        let result = await harness.runner(mode: .review).run(
            request: TaskRequest(text: "Finish the demo"),
            limits: TaskLimits(), mode: .review, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(harness.executed, ["Click Ready"])
        XCTAssertEqual(harness.approvals, 1)
    }

    func testCancellationDuringApproval() async {
        let harness = Harness()
        harness.approval = .wait
        let runner = harness.runner(mode: .review)
        let task = Task { await runner.run(request: TaskRequest(text: "Go"), limits: TaskLimits(), mode: .review, settings: ConfidenceSettings(), model: "jev-latest") }
        try? await Task.sleep(nanoseconds: 80_000_000)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertTrue(harness.executed.isEmpty)
    }

    func testIneffectiveActionsStop() async {
        let harness = Harness()
        harness.observations = [obs("Same"), obs("Same"), obs("Same")]
        harness.choices = ["c1", "c1", "c1"]
        let result = await harness.runner(mode: .automatic).run(
            request: TaskRequest(text: "Same"),
            limits: TaskLimits(repeatedStateLimit: 9, ineffectiveActionLimit: 2),
            mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(result.stopReason, .ineffectiveActions)
        XCTAssertEqual(result.outcome, .blocked)
    }

    func testRepeatedStateStops() async {
        let harness = Harness()
        harness.observations = [obs("Loop"), obs("Loop"), obs("Loop")]
        harness.choices = ["c1"]
        let result = await harness.runner(mode: .automatic).run(
            request: TaskRequest(text: "Loop"),
            limits: TaskLimits(repeatedStateLimit: 3, ineffectiveActionLimit: 9),
            mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(result.stopReason, .repeatedState)
    }

    func testStaleTargetStopsWhenItPersists() async {
        let harness = Harness()
        harness.observations = [obs("A", y: 0), obs("B", y: 30), obs("C", y: 60)]
        harness.revalidation = .stale
        let result = await harness.runner(mode: .automatic).run(
            request: TaskRequest(text: "A"),
            limits: TaskLimits(repeatedStateLimit: 9),
            mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(result.stopReason, .staleTarget)
        XCTAssertTrue(harness.executed.isEmpty)
    }

    func testConsequentialActionIsNotAutomatic() async {
        let harness = Harness()
        harness.observations = [obs("Delete")]
        harness.approval = .reject
        let result = await harness.runner(mode: .automatic).run(
            request: TaskRequest(text: "Delete"),
            limits: TaskLimits(), mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(result.stopReason, .rejectedByUser)
        XCTAssertEqual(harness.approvals, 1)
        XCTAssertTrue(harness.executed.isEmpty)
    }

    func testExactTextInsertion() async {
        let harness = Harness()
        harness.role = "AXTextField"
        harness.label = "Note"
        harness.observations = [obs("Note", role: "AXTextField"), obs("Note", role: "AXTextField"), obs("Status: Complete", role: "AXStaticText")]
        let result = await harness.runner(mode: .automatic).run(
            request: TaskRequest(text: "Save the note", suppliedText: "Exact words"),
            limits: TaskLimits(), mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(harness.inserted, ["Exact words"])
        XCTAssertEqual(result.outcome, .completed)
    }

    func testPermissionLossAndAPIFailure() async {
        let denied = Harness()
        denied.allowed = false
        let deniedResult = await denied.runner(mode: .automatic).run(
            request: TaskRequest(text: "Go"), limits: TaskLimits(), mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(deniedResult.stopReason, .permissionLost)

        let failing = Harness()
        failing.observations = (0..<5).map { obs("Err \($0)", y: Double($0)) }
        failing.decisionError = JevClientError.network
        let failed = await failing.runner(mode: .automatic).run(
            request: TaskRequest(text: "Go"),
            limits: TaskLimits(maxConsecutiveAPIErrors: 3),
            mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(failed.stopReason, .persistentErrors)
        XCTAssertEqual(failed.outcome, .failed)
        XCTAssertFalse(failed.message.contains("JevClientError"))
    }

    func testUnverifiedWhenBudgetEndsWithoutSignal() async {
        let harness = Harness()
        harness.observations = (0..<6).map { obs("Step \($0)", y: Double($0)) }
        harness.choices = Array(repeating: "c1", count: 6)
        let result = await harness.runner(mode: .automatic).run(
            request: TaskRequest(text: "Step"),
            limits: TaskLimits(maxActions: 2, repeatedStateLimit: 9, ineffectiveActionLimit: 9),
            mode: .automatic, settings: ConfidenceSettings(), model: "jev-latest"
        )
        XCTAssertEqual(result.outcome, .unverified)
        XCTAssertEqual(result.stopReason, .actionBudget)
    }
}

final class LiveJevTests: XCTestCase {
    func testLiveChoiceRoundTrip() async throws {
        let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? ""
        try XCTSkipIf(key.isEmpty, "Live integration. Set TYPESAFE_API_KEY to run against api.typesafe.ai. Mocked tests do not cover this.")
        let client = JevClient(apiKey: key)
        let body = JevRequestSerializer.make(
            model: "jev-latest", task: "Click OK", userTextAvailable: false,
            observation: sampleObservation(), candidates: [sampleCandidate()],
            unavailableLabels: [], history: []
        )
        let answers = try await client.evaluate(body)
        XCTAssertTrue(body.allowedChoiceIDs.contains(answers.choiceID))
        XCTAssertEqual(answers.probabilities.count, body.allowedChoiceIDs.count)
    }
}

// MARK: - fixtures

private func sampleCandidate() -> Candidate {
    Candidate(
        id: "c1", label: "OK", controlType: "AXButton", enabled: true,
        bounds: Rect(x: 0, y: 0, width: 20, height: 20), center: Point(x: 10, y: 10),
        operation: .click, source: .accessibility, contextLabels: [], elementID: "ok", region: "top-left"
    )
}

private func sampleObservation() -> ScreenObservation {
    ScreenObservation(appName: "Demo", windowTitle: "Fixture", pid: 7, elements: [
        UIElementObservation(id: "ok", label: "OK", role: "AXButton", enabled: true, bounds: Rect(x: 0, y: 0, width: 20, height: 20), supportedActions: ["AXPress"], sources: [.accessibility])
    ])
}

private func obs(_ label: String, y: Double = 0, role: String = "AXButton") -> ScreenObservation {
    ScreenObservation(appName: "Demo", windowTitle: "Fixture", pid: 7, elements: [
        UIElementObservation(
            id: "only", label: label, role: role, enabled: true,
            bounds: Rect(x: 0, y: y, width: 80, height: 24),
            supportedActions: role == "AXTextField" ? [] : ["AXPress"],
            sources: [.accessibility]
        )
    ])
}

private final class Harness: @unchecked Sendable {
    var observations: [ScreenObservation] = [obs("Ready")]
    var choices: [String] = ["c1"]
    var allowed = true
    var approval: ApprovalMode = .approve
    var revalidation: Revalidation = .valid
    var decisionError: JevClientError?
    var label = "Ready"
    var role = "AXButton"
    fileprivate let state = State()

    var executed: [String] { state.executed }
    var inserted: [String] { state.inserted }
    var approvals: Int { state.approvals }

    func runner(mode: ExecutionMode) -> TaskRunner {
        let observer = ScriptedObserver(harness: self)
        let executor = ScriptedExecutor(harness: self)
        let decider = ScriptedDecider(harness: self)
        let approvals = ScriptedApprovals(harness: self)
        return TaskRunner(
            observer: observer, executor: executor, decider: decider,
            approvals: approvals, progress: IgnoreProgress(), control: RunControl()
        )
    }

    fileprivate final class State: @unchecked Sendable {
        let lock = NSLock()
        var cursor = 0
        var choiceCursor = 0
        var executed: [String] = []
        var inserted: [String] = []
        var approvals = 0

        func nextObservation(from observations: [ScreenObservation]) -> ScreenObservation {
            lock.lock()
            defer { lock.unlock() }
            let index = min(cursor, max(0, observations.count - 1))
            if cursor < observations.count { cursor += 1 }
            return observations[index]
        }

        func nextChoice(from choices: [String]) -> String {
            lock.lock()
            defer { lock.unlock() }
            let index = min(choiceCursor, max(0, choices.count - 1))
            if choiceCursor < choices.count { choiceCursor += 1 }
            return choices[index]
        }

        func recordExecution(_ summary: String, text: String?) {
            lock.lock()
            executed.append(summary)
            if let text { inserted.append(text) }
            lock.unlock()
        }

        func noteApproval() {
            lock.lock()
            approvals += 1
            lock.unlock()
        }
    }

    enum ApprovalMode { case approve, reject, wait }
}

private struct ScriptedObserver: ScreenObserving {
    let harness: Harness
    func permissionsGranted() async -> Bool { harness.allowed }
    func observe() async throws -> ScreenObservation {
        harness.state.nextObservation(from: harness.observations)
    }
}

private struct ScriptedExecutor: ActionExecuting {
    let harness: Harness
    func revalidate(_ candidate: Candidate, original: ScreenObservation, fresh: ScreenObservation) -> Revalidation {
        harness.revalidation
    }
    func execute(_ candidate: Candidate, userText: String?, observation: ScreenObservation) async throws {
        harness.state.recordExecution(candidate.summary, text: userText)
    }
}

private struct ScriptedDecider: DecisionMaking {
    let harness: Harness
    func decide(
        goal: String, userTextAvailable: Bool, observation: ScreenObservation, candidates: [Candidate],
        unavailableLabels: [String], history: [StepRecord], mode: ExecutionMode, settings: ConfidenceSettings, model: String
    ) async throws -> EngineDecision {
        if let decisionError = harness.decisionError { throw decisionError }
        let choice = harness.state.nextChoice(from: harness.choices)
        let ids = Set(candidates.map(\.id)).union([JevRequestSerializer.noneBlockedID])
        var probabilities = Dictionary(uniqueKeysWithValues: ids.map { ($0, 0.0) })
        probabilities[choice] = 1
        let answers = ValidatedAnswers(
            choiceID: choice, probabilities: probabilities, confidence: 1, topToSecondRatio: .greatestFiniteMagnitude,
            taskComplete: 0, blocked: 0, model: "mock", inputTokens: 0, outputTokens: 0
        )
        return DecisionEngine.interpret(answers: answers, candidates: candidates, observation: observation, mode: mode, settings: settings)
    }
}

private struct ScriptedApprovals: ApprovalProviding {
    let harness: Harness
    func requestApproval(_ proposal: Proposal) async -> Approval {
        harness.state.noteApproval()
        switch harness.approval {
        case .approve: return .approved
        case .reject: return .rejected
        case .wait:
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return Task.isCancelled ? .stopped : .approved
        }
    }
}

private struct IgnoreProgress: TaskProgressReporting {
    func update(_ snapshot: TaskSnapshot) async {}
}

private enum ScriptedStep {
    case response(Int, Data, String?)
    case throwURL
}

private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    let steps: [ScriptedStep]
    private let lock = NSLock()
    private var index = 0
    private(set) var attempts = 0

    init(steps: [ScriptedStep]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step = next()
        switch step {
        case .throwURL:
            throw URLError(.cannotConnectToHost)
        case .response(let status, let data, let retry):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: retry.map { ["retry-after": $0] })!
            return (data, response)
        }
    }

    private func next() -> ScriptedStep {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        let step = steps[min(index, steps.count - 1)]
        index += 1
        return step
    }
}

private final class RecordingSleeper: RetrySleeper, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var delays: [UInt64] = []
    func sleep(nanoseconds: UInt64) async throws {
        record(nanoseconds)
    }

    private func record(_ nanoseconds: UInt64) {
        lock.lock()
        delays.append(nanoseconds)
        lock.unlock()
    }
}

private final class RecordingLog: PilotLogging, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    func info(_ message: String) { append(message) }
    func error(_ message: String) { append(message) }
    private func append(_ message: String) {
        lock.lock()
        lines.append(message)
        lock.unlock()
    }
}
