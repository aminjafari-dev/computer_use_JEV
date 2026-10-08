import AppKit
import PilotCore
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var taskText = ""
    @Published var suppliedText = ""
    @Published var status = "Ready"
    @Published var steps: [StepRecord] = []
    @Published var proposal: Proposal?
    @Published var result: TaskResult?
    @Published var elapsedSeconds: Double = 0
    @Published var decisionSeconds: Double?
    @Published var running = false
    @Published var paused = false
    @Published var targetName = "No application selected"
    @Published var hasAPIKey = KeychainStore.hasKey
    @Published var keyDraft = ""
    @Published var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
    @Published var banner: String?

    @AppStorage("model") var model = "jev-latest"
    @AppStorage("executionMode") var modeRaw = ExecutionMode.review.rawValue
    @AppStorage("maxActions") var maxActions = 15
    @AppStorage("maxDuration") var maxDuration = 180.0
    @AppStorage("minimumConfidence") var minimumConfidence = 0.5
    @AppStorage("topToSecondRatio") var topToSecondRatio = 2.0
    @AppStorage("completionThreshold") var completionThreshold = 0.8
    @AppStorage("blockedThreshold") var blockedThreshold = 0.8
    @AppStorage("diagnostics") var diagnostics = false
    @AppStorage("saveScreenshots") var saveScreenshots = false
    @AppStorage("showKeyCode") var showKeyCode = 2
    @AppStorage("showModifiers") var showModifiers = Int(HotKeyCombo.showPanel.modifiers)
    @AppStorage("stopKeyCode") var stopKeyCode = 53
    @AppStorage("stopModifiers") var stopModifiers = Int(HotKeyCombo.emergencyStop.modifiers)

    let permissions = PermissionManager()
    let observer = AXScreenObserver()
    let hotKeys = HotKeyManager()
    let panel = CommandPanelController()
    let overlay = HighlightOverlay()

    private let executor = AXActionExecutor()
    private let approvals = ApprovalBox()
    private var runTask: Task<Void, Never>?
    private var control = RunControl()
    private var startedAt: Date?
    private var timer: Timer?

    var mode: ExecutionMode {
        get { ExecutionMode(rawValue: modeRaw) ?? .review }
        set { modeRaw = newValue.rawValue }
    }

    var showCombo: HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(showKeyCode), modifiers: UInt32(showModifiers))
    }

    var stopCombo: HotKeyCombo {
        HotKeyCombo(keyCode: UInt32(stopKeyCode), modifiers: UInt32(stopModifiers))
    }

    var coreMLStatus: String { observer.coreMLStatus }

    init() {
        hotKeys.onShow = { [weak self] in self?.togglePanel() }
        hotKeys.onStop = { [weak self] in self?.stop() }
        registerHotKeys()
        panel.bind(self)
        refreshTarget()
        if showOnboarding { panel.show() }
    }

    func registerHotKeys() {
        hotKeys.register(show: showCombo, stop: stopCombo)
    }

    func togglePanel() {
        if panel.isVisible {
            panel.orderOut()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        refreshTarget()
        if !running, let target = observer.currentTarget() {
            observer.pin(pid: target.pid)
            targetName = target.name
        }
        panel.show()
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshTarget() {
        permissions.refresh()
        if let target = observer.currentTarget() {
            targetName = target.name
        }
    }

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingComplete")
        showOnboarding = false
    }

    func saveAPIKey() {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try KeychainStore.save(trimmed)
            keyDraft = ""
            hasAPIKey = true
            banner = "API key saved to Keychain."
        } catch {
            banner = "The API key could not be saved to Keychain."
        }
    }

    func deleteAPIKey() {
        KeychainStore.delete()
        hasAPIKey = false
        banner = "API key removed."
    }

    func start() {
        banner = nil
        result = nil
        steps = []
        proposal = nil
        permissions.refresh()
        guard permissions.accessibilityGranted else {
            banner = "Accessibility permission is required to read and use controls."
            return
        }
        guard hasAPIKey else {
            banner = "Add a TypeSafe API key in Settings."
            return
        }
        let text = taskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            banner = "Describe what you want done."
            return
        }
        refreshTarget()
        if let target = observer.currentTarget() {
            observer.pin(pid: target.pid)
            targetName = target.name
        }
        observer.setSaveScreenshots(saveScreenshots)
        running = true
        paused = false
        status = "Starting"
        startedAt = Date()
        control = RunControl()
        let request = TaskRequest(text: text, suppliedText: suppliedText)
        let limits = TaskLimits(maxActions: maxActions, maxDurationSeconds: maxDuration)
        let settings = ConfidenceSettings(
            minimumConfidence: minimumConfidence,
            minimumTopToSecondRatio: topToSecondRatio,
            completionThreshold: completionThreshold,
            blockedThreshold: blockedThreshold
        )
        let mode = self.mode
        let model = self.model
        let runner = makeRunner()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        runTask = Task.detached { [runner] in
            let result = await runner.run(request: request, limits: limits, mode: mode, settings: settings, model: model)
            await MainActor.run { [weak self] in
                self?.finish(result)
            }
        }
    }

    func pause() {
        guard running else { return }
        paused = true
        status = "Paused"
        control.pause()
    }

    func resume() {
        guard running else { return }
        paused = false
        status = "Continuing"
        control.resume()
    }

    func stop() {
        control.stop()
        runTask?.cancel()
        approvals.resume(.stopped)
        overlay.hide()
        if running {
            status = "Stopping"
        }
    }

    func approve() { approvals.resume(.approved) }
    func reject() { approvals.resume(.rejected) }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "DesktopPilot-diagnostics.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let payload = DiagnosticExport(result: result, steps: steps, banner: banner)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: url)
    }

    private func tick() {
        guard let startedAt, running else { return }
        elapsedSeconds = Date().timeIntervalSince(startedAt)
    }

    private func finish(_ result: TaskResult) {
        timer?.invalidate()
        self.result = result
        self.steps = result.steps
        self.elapsedSeconds = result.elapsedSeconds
        self.status = result.message
        self.running = false
        self.paused = false
        self.proposal = nil
        overlay.hide()
    }

    fileprivate func present(_ proposal: Proposal) {
        self.proposal = proposal
        status = proposal.reason.explanation
        overlay.show(global: proposal.candidate.bounds)
        panel.show()
    }

    fileprivate func apply(_ snapshot: TaskSnapshot) {
        status = snapshot.status
        steps = snapshot.steps
        elapsedSeconds = snapshot.elapsedSeconds
        decisionSeconds = snapshot.lastDecisionSeconds
        if let proposal = snapshot.proposal {
            present(proposal)
        }
    }

    private func makeRunner() -> TaskRunner {
        let logger = RedactingLogger { [diagnostics] in diagnostics }
        let key = KeychainStore.load() ?? ""
        let client = JevClient(apiKey: key, logger: logger)
        let bridge = ApprovalBridge { [weak self] proposal in
            guard let self else { return .stopped }
            return await self.approvals.wait {
                self.present(proposal)
            }
        }
        let progress = ProgressBridge { [weak self] snapshot in
            await MainActor.run { self?.apply(snapshot) }
        }
        return TaskRunner(
            observer: observer,
            executor: executor,
            decider: DecisionEngine(client: client),
            approvals: bridge,
            progress: progress,
            control: control
        )
    }
}

private struct DiagnosticExport: Encodable {
    var result: TaskResult?
    var steps: [StepRecord]
    var banner: String?
}

final class ApprovalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Approval, Never>?

    func wait(onReady: @escaping @MainActor () -> Void) async -> Approval {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Approval, Never>) in
                self.store(continuation)
                Task { @MainActor in onReady() }
            }
        } onCancel: {
            self.resume(.stopped)
        }
    }

    private func store(_ continuation: CheckedContinuation<Approval, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(_ approval: Approval) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: approval)
    }
}

struct ApprovalBridge: ApprovalProviding {
    var handler: @Sendable (Proposal) async -> Approval
    func requestApproval(_ proposal: Proposal) async -> Approval { await handler(proposal) }
}

struct ProgressBridge: TaskProgressReporting {
    var handler: @Sendable (TaskSnapshot) async -> Void
    func update(_ snapshot: TaskSnapshot) async { await handler(snapshot) }
}
