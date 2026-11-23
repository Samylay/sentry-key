import SwiftUI
import VisionKit

/// Pairing: explain the steps, scan the Mac's QR code, then show the
/// result. Layout studied on Appllama: Dashlane's "Add 2FA token" (steps in
/// a card, one primary Scan button) and its success screen (icon tile,
/// large title, one button), Zengo's dark full-screen QR scanner.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    @State private var isScanning = false
    @State private var isPaired = false
    @State private var scanError: String?

    var body: some View {
        Group {
            if isPaired {
                PairedView()
            } else {
                intro
            }
        }
        .navigationBarBackButtonHidden(isPaired)
        .fullScreenCover(isPresented: $isScanning) {
            QRScannerSheet { payload in
                isScanning = false
                do {
                    try model.pair(qrPayload: payload)
                    withAnimation { isPaired = true }
                } catch {
                    scanError = error.localizedDescription
                }
            }
        }
    }

    private var intro: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IconTile(symbol: "qrcode.viewfinder")
                Text("Pair with your Mac")
                    .font(.title.bold())
                VStack(alignment: .leading, spacing: 12) {
                    Step(number: 1, text: "On your Mac, open the SentryKey menu and choose Pair iPhone.")
                    Step(number: 2, text: "Scan the QR code it shows.")
                    Step(number: 3, text: "Keep both devices close until pairing ends.")
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: .rect(cornerRadius: 16))

                if let scanError {
                    Label(scanError, systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                scanError = nil
                isScanning = true
            } label: {
                Text("Scan QR Code").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
            .disabled(!QRScannerSheet.isSupported)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// After pairing: the one thing left to do is install the public key.
struct PairedView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                IconTile(symbol: "checkmark")
                Text("Paired")
                    .font(.largeTitle.bold())
                Text("Last step: add your SSH key where you log in, for example GitHub (Settings › SSH and GPG keys › New SSH key).")
                    .foregroundStyle(.secondary)
                if let line = model.publicKeyLine {
                    ShareLink(item: line) {
                        Label("Share public key", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(24)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                model.finishOnboarding()
            } label: {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(24)
        }
    }
}

struct IconTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.title)
            .foregroundStyle(.tint)
            .frame(width: 64, height: 64)
            .background(.tint.quaternary, in: .rect(cornerRadius: 16))
            .accessibilityHidden(true)
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.bold())
                .frame(width: 24, height: 24)
                .background(.tint.quaternary, in: .circle)
            Text(text)
        }
    }
}

// MARK: - Scanner

/// Full-screen QR scanner using VisionKit's DataScannerViewController, so
/// the camera, focus and highlighting are Apple's own.
struct QRScannerSheet: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var cameraFailed = false

    static var isSupported: Bool {
        DataScannerViewController.isSupported
    }

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isAvailable && !cameraFailed {
                    DataScanner(onCode: onCode, onUnavailable: { cameraFailed = true })
                        .ignoresSafeArea()
                } else {
                    ContentUnavailableView(
                        "Camera not available",
                        systemImage: "camera",
                        description: Text("Allow camera access for SentryKey in Settings.")
                    )
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

private struct DataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    /// Starts once the view is on screen. Starting in make() can fail
    /// silently before the camera permission prompt is answered.
    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        guard !scanner.isScanning else { return }
        do {
            try scanner.startScanning()
        } catch {
            onUnavailable()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode, onUnavailable: onUnavailable) }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        let onUnavailable: () -> Void
        private var done = false

        init(onCode: @escaping (String) -> Void, onUnavailable: @escaping () -> Void) {
            self.onCode = onCode
            self.onUnavailable = onUnavailable
        }

        func dataScanner(_ scanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onUnavailable()
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let payload = code.payloadStringValue {
                    done = true // report one code only
                    onCode(payload)
                    return
                }
            }
        }
    }
}

#Preview {
    NavigationStack { PairingView() }
        .environment(AppModel())
}
