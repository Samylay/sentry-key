import Foundation
import SentryKeyProtocol

/// Joins the Bluetooth peripheral to the app: pairing messages, and the
/// secure channel that carries sign requests and their answers.
///
/// Each connected device gets its own `PhoneChannelSession`. A device that
/// is not a paired Mac never gets past the handshake, so nothing it sends
/// reaches `AppModel`.
///
/// NOT YET RUN ON A DEVICE: checked by the compiler only.
///
/// NEEDS LINE-BY-LINE HUMAN REVIEW (security code).
@MainActor
final class PhoneLinkController {
    private let model: AppModel
    private let peripheral = BLEPeripheral()
    private let identityKeyStore = IdentityKeyStore()
    private var sessions: [UUID: PhoneChannelSession] = [:]
    private var connected: Set<UUID> = []
    /// Which device sent the request the user is looking at, so the answer
    /// goes back to that one. `AppModel` handles one request at a time.
    private var requestOrigins: [RequestID: UUID] = [:]
    private let log = WakeLog.shared

    init(model: AppModel) {
        self.model = model
        peripheral.onConnect = { [weak self] in self?.deviceConnected($0) }
        peripheral.onDisconnect = { [weak self] in self?.deviceDisconnected($0) }
        peripheral.onMessage = { [weak self] in self?.received($1, from: $0) }
        model.sendResponse = { [weak self] in self?.send($0) }
        model.startBluetooth = { [weak self] in self?.peripheral.start() }
        model.recordEvent = { [log] in log.record($0) }
        log.record("app launched")
        model.sendPairingRequest = { [weak self] in self?.sendPairingRequestToAll($0) }
        // Bluetooth is only asked for once it has a use: after pairing
        // started, or at launch when a Mac is paired. `hasPairedMac` comes
        // from the Keychain, so it is known even on a background launch
        // with the phone locked, when `phase` is not (its file is locked).
        // Starting here is what lets iOS hand over the restored state.
        if model.phase == .paired || model.hasPairedMac { peripheral.start() }
    }

    private func deviceConnected(_ device: UUID) {
        connected.insert(device)
        log.record("device connected")
        // A pairing in progress: the Mac showing the code is one of the
        // devices that connect. The request holds public keys only, and
        // only that Mac can answer it, so sending it to a stranger costs
        // nothing.
        if let request = model.pairingRequest {
            peripheral.send(TransportMessage.pairingRequest(request.encoded()).encoded(), to: device)
        }
    }

    private func deviceDisconnected(_ device: UUID) {
        connected.remove(device)
        log.record("device disconnected")
        sessions[device] = nil
        requestOrigins = requestOrigins.filter { $0.value != device }
    }

    private func sendPairingRequestToAll(_ request: PairingRequest) {
        for device in connected {
            peripheral.send(TransportMessage.pairingRequest(request.encoded()).encoded(), to: device)
        }
    }

    private func received(_ bytes: [UInt8], from device: UUID) {
        guard let message = try? TransportMessage.parse(bytes) else { return }
        switch message {
        case .pairingConfirmation(let body):
            guard let confirmation = try? PairingConfirmation.parse(body: body) else { return }
            // `AppModel` checks it against the scanned code's secret.
            model.receivePairingConfirmation(confirmation)
        case .channel(let body):
            receivedOnChannel(body, from: device)
        case .pairingRequest, .channelReset:
            // Only the phone sends these.
            break
        }
    }

    private func receivedOnChannel(_ body: [UInt8], from device: UUID) {
        guard var session = sessions[device] ?? makeSession() else { return }
        do {
            switch try session.receive(body, now: .now) {
            case .handshakeAnswer(let answer):
                sessions[device] = session
                log.record("handshake accepted")
                peripheral.send(TransportMessage.channel(answer).encoded(), to: device)
            case .request(let request):
                sessions[device] = session
                log.record("request received")
                if case .sign = request { requestOrigins[request.id] = device }
                model.receive(request)
            }
        } catch {
            // Refused: a stranger, a replay, an altered message, or a Mac
            // still using a session this app lost when iOS relaunched it.
            // The session is gone. The reset tells a paired Mac to start a
            // new handshake now instead of waiting for its timeout; it says
            // nothing a stranger could use.
            sessions[device] = nil
            log.record("message refused")
            peripheral.send(TransportMessage.channelReset.encoded(), to: device)
        }
    }

    /// A new session for a device that has not done the handshake yet, or
    /// nil when the phone has no identity key.
    private func makeSession() -> PhoneChannelSession? {
        guard let key = try? identityKeyStore.load() else { return nil }
        let pairedMacKeys = model.pairedMacKeys
        return PhoneChannelSession(
            identity: SecureEnclaveIdentity(key: key),
            pairedMacKey: { fingerprint in
                pairedMacKeys.first { IdentityFingerprint.of(publicKey: $0) == fingerprint }
            }
        )
    }

    private func send(_ response: PhoneResponse) {
        guard let device = requestOrigins.removeValue(forKey: response.id),
              var session = sessions[device],
              let sealed = try? session.seal(response, now: .now)
        else {
            return
        }
        sessions[device] = session
        peripheral.send(TransportMessage.channel(sealed).encoded(), to: device)
        log.record("answer sent")
    }
}
