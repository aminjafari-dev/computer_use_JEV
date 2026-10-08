import SwiftUI

@main
struct DemoFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            FixtureView()
        }
        .defaultSize(width: 640, height: 480)
    }
}

struct FixtureView: View {
    @State private var page = "Home"
    @State private var showDialog = false
    @State private var note = ""
    @State private var rearranged = false
    @State private var status = "Status: Ready"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Desktop Pilot Demo")
                .font(.title2)
            Text(status)
                .accessibilityIdentifier("completion-status")
            navigation
            Group {
                if rearranged {
                    VStack(alignment: .leading, spacing: 12) { sections }
                } else {
                    HStack(alignment: .top, spacing: 24) { sections }
                }
            }
            Toggle("Rearrange layout", isOn: $rearranged)
            HStack {
                Button("Show Dialog") { showDialog = true }
                Menu("More") {
                    Button("Settings") { status = "Settings open" }
                    Menu("Arrange") {
                        Button("Compact") { rearranged = true }
                        Button("Wide") { rearranged = false }
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $showDialog) {
            VStack(spacing: 12) {
                Text("Save changes?")
                HStack {
                    Button("Cancel") { showDialog = false }
                    Button("OK") {
                        showDialog = false
                        status = "Dialog dismissed"
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
        }
    }

    private var navigation: some View {
        HStack {
            ForEach(["Home", "Library", "Analytics"], id: \.self) { name in
                Button(name) { page = name }
                    .disabled(page == name && name == "Home" ? false : false)
            }
            Text("Page: \(page)")
        }
    }

    @ViewBuilder private var sections: some View {
        VStack(alignment: .leading) {
            Text("Songs")
            Button("Open") { status = "Status: Complete" }
                .accessibilityLabel("Open")
                .accessibilityHint("Saved songs")
        }
        VStack(alignment: .leading) {
            Text("Files")
            Button("Open") { status = "Opened a file" }
        }
        VStack(alignment: .leading) {
            Text("Note")
            TextField("Note", text: $note)
                .frame(width: 180)
            Button("Save Note") {
                if !note.isEmpty { status = "Status: Complete" }
            }
            Button("Unavailable") {}
                .disabled(true)
        }
    }
}
