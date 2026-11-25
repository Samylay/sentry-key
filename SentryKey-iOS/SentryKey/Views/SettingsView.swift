import SwiftUI

import SentryKeyProtocol

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// The Mac waiting for the user to confirm "Forget".
    @State private var macToForget: [UInt8]?

    var body: some View {
        List {
            if !model.notificationsAllowed {
                Section {
                    Label("Notifications are off", systemImage: "bell.slash")
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } footer: {
                    Text("A sign-in request that arrives while SentryKey is not open will not be announced, and will expire unseen.")
                }
            }

            Section {
                if model.pairedMacKeys.isEmpty {
                    Text("No Mac is paired.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.pairedMacKeys, id: \.self) { key in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Mac")
                            Text(Self.shortFingerprint(of: key))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Forget", role: .destructive) { macToForget = key }
                    }
                }
            } header: {
                Text("Paired Macs")
            } footer: {
                Text("Forget a Mac you lost or no longer use: it can no longer send sign-in requests to this iPhone.")
            }
            .confirmationDialog(
                "Forget this Mac?",
                isPresented: Binding(get: { macToForget != nil }, set: { if !$0 { macToForget = nil } }),
                titleVisibility: .visible
            ) {
                Button("Forget Mac", role: .destructive) {
                    if let key = macToForget { model.forgetMac(identityKey: key) }
                    macToForget = nil
                }
            } message: {
                Text("It will no longer be able to ask this iPhone for signatures. To use it again, pair it again.")
            }

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

            Section {
                NavigationLink("Bluetooth test log") {
                    WakeLogView()
                }
            } footer: {
                Text("What the app did each time the Mac reached it, and whether it was on screen. See docs/BLE_WAKE_TEST.md.")
            }
            #endif
        }
        .navigationTitle("Settings")
    }

    /// The start of the Mac identity key's SHA-256, enough to tell two Macs
    /// apart. Public: it names a key, it is not one.
    private static func shortFingerprint(of key: [UInt8]) -> String {
        IdentityFingerprint.of(publicKey: key).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

#if DEBUG
/// The Bluetooth events recorded by `WakeLog`, newest first.
struct WakeLogView: View {
    private let log = WakeLog.shared

    var body: some View {
        List(log.entries.reversed()) { entry in
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.event)
                    Text(entry.date.formatted(date: .omitted, time: .standard))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(entry.appState)
                    .font(.caption)
                    .foregroundStyle(entry.appState == "background" ? .orange : .secondary)
            }
        }
        .overlay {
            if log.entries.isEmpty {
                ContentUnavailableView("No events yet", systemImage: "antenna.radiowaves.left.and.right")
            }
        }
        .navigationTitle("Bluetooth test log")
        .toolbar {
            Button("Clear") { log.clear() }
        }
    }
}
#endif
