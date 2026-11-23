import SwiftUI

/// First screen. Layout studied on Appllama: a large left-aligned title,
/// three icon rows that each state one promise, one primary action pinned
/// to the bottom (X's passkey setup, Dashlane's 2FA intro).
struct WelcomeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Your iPhone is your SSH key")
                    .font(.largeTitle.bold())
                    .padding(.top, 40)

                FeatureRow(
                    symbol: "lock.iphone",
                    title: "The key stays on this iPhone",
                    detail: "It is created in the Secure Enclave and can never be copied, not even by SentryKey."
                )
                FeatureRow(
                    symbol: "faceid",
                    title: "Face ID for every signature",
                    detail: "Each git push or SSH login asks you first. One Face ID signs exactly once."
                )
                FeatureRow(
                    symbol: "checkmark.shield",
                    title: "You see which server is asking",
                    detail: "Your iPhone checks the server's identity itself, so your Mac cannot fake it."
                )
            }
            .padding(.horizontal, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaInset(edge: .bottom) {
            NavigationLink {
                PairingView()
            } label: {
                Text("Pair with your Mac")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
        }
        .toolbar(.hidden, for: .navigationBar)
    }
}

struct FeatureRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack { WelcomeView() }
        .environment(AppModel())
}
