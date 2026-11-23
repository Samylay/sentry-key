import SentryKeyProtocol
import SwiftUI

/// The approval sheet: the screen the whole project exists for.
///
/// Layout studied on Appllama: wallet connection requests (Xverse) put the
/// origin at the top, the facts in grouped rows, and Deny / Accept side by
/// side at equal width at the bottom. Here the origin is the server as the
/// phone verified it: the name the user gave it, its host-key fingerprint,
/// and the account. Nothing on this sheet comes from the Mac unchecked.
struct ApprovalView: View {
    let request: PendingRequest
    @Environment(AppModel.self) private var model
    @State private var newName = ""
    @State private var isSigning = false
    @Environment(\.scenePhase) private var scenePhase

    private var isNewServer: Bool { request.knownName == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    header
                }
                .listRowBackground(Color.clear)

                Section {
                    LabeledContent("Server") {
                        if let name = request.knownName {
                            Text(name)
                        } else {
                            Text("New server").foregroundStyle(.orange)
                        }
                    }
                    LabeledContent("Account", value: request.approval.userName)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Host key fingerprint")
                        Text(request.hostFingerprint)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text(request.approval.hostKeyAlgorithm)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } footer: {
                    if isNewServer {
                        Text("SentryKey has never signed for this server. Compare the fingerprint with the one the server's owner publishes before you approve.")
                    }
                }

                if isNewServer {
                    Section {
                        TextField("For example, GitHub", text: $newName)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Name this server")
                    } footer: {
                        Text("Optional. Next time, the request shows this name.")
                    }
                }
            }
            .navigationTitle("Sign-in request")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) { buttons }
        }
        // The app-level cover does not reach sheets, so this one hides the
        // user name and fingerprint from the app switcher snapshot.
        .overlay {
            if scenePhase != .active {
                PrivacyCover()
            }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Sign in as \(request.approval.userName)?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            // Counts down with the system clock; no timer code needed.
            Text("Expires in \(Text(timerInterval: request.receivedAt...request.expiresAt, countsDown: true))")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button {
                model.deny(request)
            } label: {
                Text("Deny").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button {
                isSigning = true
                Task {
                    await model.approve(request, newName: newName)
                    isSigning = false
                }
            } label: {
                Label("Approve", systemImage: "faceid").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .controlSize(.large)
        .disabled(isSigning)
        .padding()
        .background(.bar)
    }
}
