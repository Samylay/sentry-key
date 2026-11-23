import SwiftUI

/// Home: the key to install, and what it signed. A plain inset-grouped
/// list, like iOS Settings, so the security facts read as facts.
struct HomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let fingerprint = model.keyFingerprint {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Fingerprint")
                            Text(fingerprint)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let line = model.publicKeyLine {
                        ShareLink(item: line) {
                            Label("Share public key", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = line
                        } label: {
                            Label("Copy public key", systemImage: "doc.on.doc")
                        }
                    }
                } header: {
                    Text("SSH key")
                } footer: {
                    Text("Add the public key to GitHub (Settings › SSH and GPG keys) or to ~/.ssh/authorized_keys on your servers. It is public: sharing it is safe.")
                }

                Section("Recent requests") {
                    if model.history.isEmpty {
                        Text("Nothing signed yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.history) { entry in
                            HistoryRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle("SentryKey")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(spacing: 12) {
            icon
                .font(.title3)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.server).font(.body)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(entry.date, format: .dateTime.hour().minute())
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch entry.outcome {
        case .approved:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .denied:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        case .refused:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var subtitle: String {
        let user = entry.userName.map { "as \($0) · " } ?? ""
        switch entry.outcome {
        case .approved: return user + "Signed"
        case .denied: return user + "Denied"
        case .refused(let reason): return user + "Refused: " + reason
        }
    }
}
