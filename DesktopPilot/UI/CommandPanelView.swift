import PilotCore
import SwiftUI

struct CommandPanelView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.showOnboarding {
                OnboardingView(model: model)
            } else {
                taskControls
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var taskControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.targetName)
                .font(.headline)
            Text(model.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let banner = model.banner {
                Text(banner)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("What should be done?", text: $model.taskText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Task")
            TextField("Text to enter, if the task needs it", text: $model.suppliedText)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Text to enter")
            Picker("Mode", selection: $model.modeRaw) {
                Text(ExecutionMode.review.title).tag(ExecutionMode.review.rawValue)
                Text(ExecutionMode.automatic.title).tag(ExecutionMode.automatic.rawValue)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Execution mode")
            HStack {
                Text("Step \(model.steps.count)")
                Spacer()
                Text(time(model.elapsedSeconds))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if let decision = model.decisionSeconds {
                Text("Last decision \(String(format: "%.2f", decision)) s")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            controls
            if let proposal = model.proposal {
                proposalCard(proposal)
            }
            if let result = model.result {
                Text(result.message)
                    .font(.body.weight(.semibold))
                Text(result.stopReason.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            history
            Text("Screen images are processed locally. Relevant screen text, your task, and recent actions are sent to TypeSafe to choose the next action.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Refresh target") { model.refreshTarget() }
                Spacer()
                SettingsLink { Text("Settings") }
            }
        }
    }

    private var controls: some View {
        HStack {
            Button("Start") { model.start() }
                .disabled(model.running)
                .keyboardShortcut(.defaultAction)
            Button(model.paused ? "Resume" : "Pause") {
                model.paused ? model.resume() : model.pause()
            }
            .disabled(!model.running)
            Button("Stop") { model.stop() }
                .disabled(!model.running)
                .keyboardShortcut(.cancelAction)
        }
    }

    private func proposalCard(_ proposal: Proposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(proposal.candidate.summary)
                .font(.headline)
            Text(proposal.reason.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("Approve") { model.approve() }
                    .keyboardShortcut(.defaultAction)
                Button("Don't do this") { model.reject() }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Activity")
                .font(.caption.weight(.semibold))
            if model.steps.isEmpty {
                Text("No actions yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.steps.suffix(6)) { step in
                    Text("\(step.id). \(step.label) · \(step.changedScreen ? "screen changed" : "no change") · \(String(format: "%.2f", step.stepSeconds)) s")
                        .font(.caption)
                        .lineLimit(2)
                }
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Desktop Pilot")
                .font(.title2.weight(.semibold))
            Text("Screen images are processed locally. Relevant screen text, your task, and recent actions are sent to TypeSafe to choose the next action.")
            Text("Accessibility is used to read controls and perform actions you approve. Screen Recording is used only to recognize text on the selected window.")
                .foregroundStyle(.secondary)
            permissionRow("Accessibility", granted: model.permissions.accessibilityGranted) {
                model.permissions.requestAccessibility()
                model.permissions.openAccessibilitySettings()
            }
            permissionRow("Screen Recording", granted: model.permissions.screenRecordingGranted) {
                model.permissions.requestScreenRecording()
                model.permissions.openScreenRecordingSettings()
            }
            Text(model.hasAPIKey ? "A TypeSafe API key is saved." : "Add a TypeSafe API key in Settings before starting a task.")
                .font(.callout)
            Button("Continue") { model.completeOnboarding() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func permissionRow(_ title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle" : "exclamationmark.circle")
            Text(title)
            Spacer()
            Button(granted ? "Settings" : "Grant") { action() }
        }
    }
}

struct MenuBarMenu: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button("Show Desktop Pilot") { model.showPanel() }
        Button("Stop") { model.stop() }
            .disabled(!model.running)
        Divider()
        SettingsLink()
        Divider()
        Button("Quit Desktop Pilot") { NSApp.terminate(nil) }
    }
}
