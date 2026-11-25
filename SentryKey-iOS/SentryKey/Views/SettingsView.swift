import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                if model.knownHosts.count == 0 {
                    Text("Servers you name in a request appear here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.knownHosts.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.fingerprint)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    let entries = model.knownHosts.entries
                    for index in offsets {
                        model.forget(fingerprint: entries[index].fingerprint)
                    }
                }
            } header: {
                Text("Named servers")
            } footer: {
                Text("Removing a name does not block the server. Its next request shows as a new server.")
            }

            #if DEBUG
            Section {
                Button("Show a demo request") {
                    DemoRequest.send(to: model)
                }
                Button("Show a demo request in 5 seconds") {
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        DemoRequest.send(to: model)
                    }
                }
            } header: {
                Text("Testing without a Mac")
            } footer: {
                Text("Builds a sign-in request on this iPhone, signed by a throwaway server key, and runs the real checks, Face ID and signature. Nothing leaves the phone. With the delay, leave the app or lock the phone before the request arrives to see its notification.")
            }
            #endif
        }
        .navigationTitle("Settings")
    }
}
