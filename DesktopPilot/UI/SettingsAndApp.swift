import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            account
                .tabItem { Label("TypeSafe", systemImage: "key") }
            behavior
                .tabItem { Label("Limits", systemImage: "slider.horizontal.3") }
            shortcuts
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            privacy
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }

    private var account: some View {
        Form {
            SecureField("API key", text: $model.keyDraft)
            HStack {
                Button("Save key") { model.saveAPIKey() }
                    .disabled(model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove key") { model.deleteAPIKey() }
                    .disabled(!model.hasAPIKey)
                Text(model.hasAPIKey ? "Saved in Keychain" : "No key saved")
                    .foregroundStyle(.secondary)
            }
            Picker("Model", selection: $model.model) {
                Text("jev-latest").tag("jev-latest")
                Text("jev-preview").tag("jev-preview")
                Text("jev-1.13.0").tag("jev-1.13.0")
            }
            TextField("Custom model id", text: $model.model)
            if let banner = model.banner {
                Text(banner).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var behavior: some View {
        Form {
            Picker("Default mode", selection: $model.modeRaw) {
                Text("Review actions").tag("review")
                Text("Automatic").tag("automatic")
            }
            Stepper("Action limit: \(model.maxActions)", value: $model.maxActions, in: 1...50)
            Stepper("Time limit: \(Int(model.maxDuration)) s", value: $model.maxDuration, in: 15...600, step: 15)
            confidenceSlider("Confidence floor", value: $model.minimumConfidence, help: "Below 0.5, TypeSafe's own confidence says the options are too close to act on. This is a starting point, not a measured accuracy rate.")
            Stepper(String(format: "Winner must be %.1f× the runner-up", model.topToSecondRatio), value: $model.topToSecondRatio, in: 1...10, step: 0.5)
            confidenceSlider("Completion certainty", value: $model.completionThreshold, help: "How strongly the screen must look finished before the task can end as complete.")
            confidenceSlider("Blocked certainty", value: $model.blockedThreshold, help: "How strongly progress must look impossible before the task stops as blocked.")
        }
        .formStyle(.grouped)
    }

    private var shortcuts: some View {
        Form {
            LabeledContent("Show panel") { Text(model.showCombo.display) }
            ShortcutRecorder(title: "Set show shortcut") { combo in
                model.showKeyCode = Int(combo.keyCode)
                model.showModifiers = Int(combo.modifiers)
                model.registerHotKeys()
            }
            LabeledContent("Emergency stop") { Text(model.stopCombo.display) }
            ShortcutRecorder(title: "Set stop shortcut") { combo in
                model.stopKeyCode = Int(combo.keyCode)
                model.stopModifiers = Int(combo.modifiers)
                model.registerHotKeys()
            }
            Text("The stop shortcut works while a task is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var privacy: some View {
        Form {
            LabeledContent("Accessibility") {
                Text(model.permissions.accessibilityGranted ? "Allowed" : "Not allowed")
            }
            Button("Open Accessibility settings") { model.permissions.openAccessibilitySettings() }
            LabeledContent("Screen Recording") {
                Text(model.permissions.screenRecordingGranted ? "Allowed" : "Not allowed")
            }
            Button("Open Screen Recording settings") { model.permissions.openScreenRecordingSettings() }
            LabeledContent("Local detector") { Text(model.coreMLStatus) }
            Toggle("Diagnostic logging", isOn: $model.diagnostics)
            Toggle("Save window captures on this Mac", isOn: $model.saveScreenshots)
            Text("Captures stay on this Mac and are off unless you turn this on. They are not sent to TypeSafe.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Screen images are processed locally. Relevant screen text, your task, and recent actions are sent to TypeSafe to choose the next action.")
                .font(.caption)
            Button("Export diagnostics") { model.exportDiagnostics() }
        }
        .formStyle(.grouped)
    }

    private func confidenceSlider(_ title: String, value: Binding<Double>, help: String) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(title) {
                Slider(value: value, in: 0.1...0.95) { Text(title) }
                    .frame(width: 160)
                Text(String(format: "%.2f", value.wrappedValue)).monospacedDigit()
            }
            Text(help).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ShortcutRecorder: View {
    var title: String
    var onRecord: (HotKeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press a shortcut…" : title) {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let combo = HotKeyCombo(keyCode: UInt32(event.keyCode), modifiers: HotKeyCombo.carbonModifiers(from: event.modifierFlags))
                onRecord(combo)
                recording = false
                if let monitor {
                    NSEvent.removeMonitor(monitor)
                    self.monitor = nil
                }
                return nil
            }
        }
    }
}

@main
struct DesktopPilotApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Desktop Pilot", systemImage: "dot.scope") {
            MenuBarMenu(model: model)
        }
        Settings {
            SettingsView(model: model)
        }
    }
}
