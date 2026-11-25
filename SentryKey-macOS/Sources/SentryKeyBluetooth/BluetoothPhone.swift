import Foundation
import SentryKeyAgent
import SentryKeyProtocol

/// Reaches the paired phone over Bluetooth. `SecurePhoneLink` runs the
/// handshake and the encryption on top of the connections this opens.
///
/// NOT YET RUN: see `BluetoothLink`.
public struct BluetoothPhoneConnector: PhoneConnector {
    public static let defaultConnectTime: TimeInterval = 10

    private let phoneIdentifier: UUID
    private let connectTime: TimeInterval

    /// - Parameter phoneIdentifier: the phone's Bluetooth identifier,
    ///   recorded at pairing. It only says which device to call: the
    ///   handshake is what proves it is the phone.
    public init(phoneIdentifier: UUID, connectTime: TimeInterval = BluetoothPhoneConnector.defaultConnectTime) {
        self.phoneIdentifier = phoneIdentifier
        self.connectTime = connectTime
    }

    public func connect() async throws -> any PhoneConnection {
        let link = BluetoothLink()
        _ = try await link.open(.known(phoneIdentifier), timeout: connectTime)
        return BluetoothPhoneConnection(link: link)
    }
}

struct BluetoothPhoneConnection: PhoneConnection {
    let link: BluetoothLink

    func send(_ message: [UInt8]) async throws {
        try await link.send(.channel(message))
    }

    func receive() async throws -> [UInt8] {
        for await message in link.incoming {
            // Pairing messages have no place on an established link.
            if case .channel(let body) = message { return body }
        }
        throw PhoneLinkError.connectionLost
    }

    func close() async {
        link.close()
    }
}

/// Pairing, seen from the Mac: show the code, wait for the phone that
/// scanned it, check its answer, record it.
///
/// NOT YET RUN: see `BluetoothLink`.
public enum BluetoothPairing {
    public struct Result: Sendable {
        public let phone: PairedPhone
        public let phoneIdentifier: UUID
    }

    /// - Parameter showCode: called with the text to display as a QR code.
    public static func pair(
        identity: any IdentitySigner,
        showCode: @Sendable (String) -> Void
    ) async throws -> Result {
        var pairing = MacPairing(macIdentityKey: identity.publicKey, now: Date())
        showCode(pairing.offer.code)

        let link = BluetoothLink()
        defer { link.close() }
        // The phone advertises once its app has scanned the code.
        let phoneIdentifier = try await link.open(.anyAdvertising, timeout: PairingLimits.offerLifetimeSeconds)

        for await message in link.incoming {
            guard case .pairingRequest(let body) = message,
                  let request = try? PairingRequest.parse(body: body),
                  // A request that fails the check is ignored: it comes from
                  // a device that did not see the code.
                  let accepted = try? pairing.accept(request, now: Date())
            else { continue }
            try await link.send(.pairingConfirmation(accepted.confirmation.encoded()))
            return Result(phone: accepted.phone, phoneIdentifier: phoneIdentifier)
        }
        throw BluetoothError.disconnected
    }
}
