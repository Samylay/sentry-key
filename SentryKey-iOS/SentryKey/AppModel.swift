import Foundation
import LocalAuthentication
import Observation
import SentryKeyProtocol

/// One sign request waiting for the user, shown by `ApprovalView`.
struct PendingRequest: Identifiable {
    let id = UUID()
    /// The Mac's number for this request, repeated in the answer.
    let requestID: RequestID
    let approval: LoginApproval
    let hostFingerprint: String
    /// The name the user gave this server earlier, or nil the first time.
    /// Filled in late if the request arrived while the phone was locked
    /// and the names could not be read yet.
    var knownName: String?
    let dataToSign: [UInt8]
    let receivedAt: Date
    let expiresAt: Date
}

/// One line of the signature history.
struct LogEntry: Identifiable {
    enum Outcome {
        case approved
        case denied
        case refused(String)
    }

    let id = UUID()
    let date: Date
    /// Server name, or the start of its fingerprint.
    let server: String
    let userName: String?
    let outcome: Outcome
}

/// The app's state and the decisions the user makes.
///
/// `PhoneLinkController` calls `receive(_:)` with what a paired Mac sent
/// through the secure channel, and sets `sendResponse`. In Debug builds,
/// `DemoRequest` builds a request on the phone itself.
/// TODO(J4): the signature history becomes the hash-chained audit log.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case onboarding
        case paired
    }

    enum PairingStage: Equatable {
        case notStarted
        /// The QR code was scanned and the phone's keys exist. The Mac
        /// has not confirmed it received them yet.
        case waitingForMac
        case confirmed
    }

    private(set) var phase: Phase
    private(set) var pairingStage = PairingStage.notStarted
    /// What to send the Mac to finish pairing, once the Bluetooth link is
    /// up. Nil when no pairing is in progress.
    private(set) var pairingRequest: PairingRequest?
    private(set) var publicKeyLine: String?
    private(set) var keyFingerprint: String?
    private(set) var knownHosts: KnownHosts
    private(set) var history: [LogEntry] = []
    var pending: PendingRequest?
    var errorMessage: String?

    /// Where answers to the Mac go. Set by `PhoneLinkController`.
    var sendResponse: (PhoneResponse) -> Void = { _ in }
    /// Turns Bluetooth on. Set by `PhoneLinkController`.
    var startBluetooth: () -> Void = {}
    /// Notes an event in the Bluetooth test log. Set by `PhoneLinkController`.
    var recordEvent: (String) -> Void = { _ in }
    /// Sends the pairing request to the Mac. Set by `PhoneLinkController`.
    var sendPairingRequest: (PairingRequest) -> Void = { _ in }
    /// Closes the open connections of a Mac the user forgot, by identity
    /// fingerprint. Set by `PhoneLinkController`.
    var dropConnections: ([UInt8]) -> Void = { _ in }

    /// False when the user turned notifications off: a request that
    /// arrives while the app is not open then goes unnoticed. Shown in
    /// Settings.
    private(set) var notificationsAllowed = true

    /// True while the app is on screen. Set by the app's scene. A request
    /// that arrives otherwise is announced by a notification.
    var isOnScreen = false

    /// How long the user has to answer. The Mac gives up after 30 to 60 s.
    static let answerTime: TimeInterval = 30

    private let keyStore = KeyStore()
    private let identityKeyStore = IdentityKeyStore()
    private var pairing: PhonePairing?
    /// Identity public keys of the Macs this phone is paired with.
    private(set) var pairedMacKeys: [[UInt8]] = []
    private let notifier = ApprovalNotifier()
    private let storage = Storage()
    private let linkStateStore = LinkStateStore()
    private var ourKeyBlob: [UInt8]?
    private var limiter = PromptRateLimiter()
    /// False while the saved state cannot be read (phone locked at launch).
    /// Saving then would overwrite the real file with empty state.
    private var storageLoaded = false

    init() {
        knownHosts = KnownHosts()
        phase = .onboarding
        loadLinkState()
        reloadIfNeeded()
    }

    /// True once a Mac has confirmed pairing. Readable with the phone
    /// locked, unlike `phase`, which needs the saved file.
    var hasPairedMac: Bool { !pairedMacKeys.isEmpty }

    /// Reads the paired Macs and the SSH public key from the Keychain. Works
    /// with the phone locked, as long as it was unlocked once since it
    /// started, so a request can reach the user from a background launch.
    private func loadLinkState() {
        guard let state = try? linkStateStore.load() else { return }
        pairedMacKeys = state.pairedMacKeys
        ourKeyBlob = state.sshKeyBlob
    }

    private func saveLinkState() {
        // Failing to save only means a locked phone cannot answer until it
        // is opened once: the file still has everything.
        try? linkStateStore.save(LinkStateStore.State(pairedMacKeys: pairedMacKeys, sshKeyBlob: ourKeyBlob))
    }

    /// Reads the saved state if that has not worked yet. Called at launch
    /// and each time the app becomes active.
    func reloadIfNeeded() {
        guard !storageLoaded else { return }
        switch storage.load() {
        case .saved(let saved):
            storageLoaded = true
            knownHosts = saved.knownHosts
            // The Keychain copy wins. The file's copy only matters for a
            // phone paired before the Keychain copy existed.
            if pairedMacKeys.isEmpty, let fromFile = saved.pairedMacKeys, !fromFile.isEmpty {
                pairedMacKeys = fromFile
                saveLinkState()
            }
            phase = saved.isPaired ? .paired : .onboarding
            if saved.isPaired { loadKey() }
            // A request that arrived while locked was shown without the
            // server's name: look it up now.
            if var request = pending, request.knownName == nil {
                request.knownName = knownHosts.name(forFingerprint: request.hostFingerprint)
                pending = request
            }
        case .none:
            storageLoaded = true
        case .unavailable:
            break
        }
    }

    private func save() {
        guard storageLoaded else { return }
        storage.save(isPaired: phase == .paired, knownHosts: knownHosts, pairedMacKeys: pairedMacKeys)
    }

    // MARK: Pairing

    /// Called with the text of the QR code on the Mac. Creates the phone's
    /// two keys and prepares the message that gives the Mac their public
    /// halves. The phone is paired only once the Mac has confirmed.
    ///
    /// `PhoneLinkController` sends `pairingRequest` over Bluetooth and
    /// passes the Mac's answer to `receivePairingConfirmation`.
    func pair(qrPayload: String) throws {
        var scanned: PhonePairing
        do {
            scanned = try PhonePairing(code: qrPayload)
        } catch {
            throw PairingFailure.unreadableCode
        }
        let sshKey = try keyStore.loadOrCreate()
        let identityKey = try identityKeyStore.loadOrCreate()
        pairingRequest = try scanned.request(
            phoneIdentityKey: Array(identityKey.publicKey.x963Representation),
            sshKeyBlob: try ECDSAP256.publicKeyBlob(x963Point: Array(sshKey.publicKey.x963Representation))
        )
        pairing = scanned
        loadKey()
        pairingStage = .waitingForMac
        startBluetooth()
        if let pairingRequest { sendPairingRequest(pairingRequest) }
    }

    /// The Mac's answer to `pairingRequest`.
    func receivePairingConfirmation(_ confirmation: PairingConfirmation) {
        guard let pairing else { return }
        do {
            try pairing.confirm(confirmation)
        } catch {
            // Not from the Mac whose code was scanned: the pairing stays
            // open, and only that Mac's real answer can close it.
            return
        }
        if !pairedMacKeys.contains(pairing.macIdentityKey) {
            pairedMacKeys.append(pairing.macIdentityKey)
        }
        saveLinkState()
        self.pairing = nil
        pairingRequest = nil
        pairingStage = .confirmed
        save()
    }

    /// Gives up on a pairing the Mac never confirmed. The keys stay: they
    /// are reused by the next attempt.
    func cancelPairing() {
        pairing = nil
        pairingRequest = nil
        pairingStage = .notStarted
    }

    #if DEBUG
    /// Creates the SSH key without any Mac, so the demo request can be
    /// tried on a phone alone. Debug builds only: a release build pairs
    /// with a real code or not at all.
    func pairForDemo() throws {
        _ = try keyStore.loadOrCreate()
        loadKey()
        pairingStage = .confirmed
    }
    #endif

    func finishOnboarding() {
        phase = .paired
        save()
        checkNotifications()
    }

    /// Asks for notification permission if it was never asked, and notes
    /// whether it is granted. Called when pairing ends and each time the
    /// app comes to the screen, so a phone paired with an older build, or
    /// a user who changed their mind in Settings, is covered too.
    func checkNotifications() {
        guard phase == .paired else { return }
        Task { notificationsAllowed = await notifier.requestPermission() }
    }

    // MARK: Paired Macs

    /// Unpairs a Mac: it can no longer open a channel or send a request.
    /// For a lost or stolen Mac (ARCHITECTURE.md, Recovery). Its open
    /// connections are closed at once.
    func forgetMac(identityKey: [UInt8]) {
        pairedMacKeys.removeAll { $0 == identityKey }
        save()
        saveLinkState()
        dropConnections(IdentityFingerprint.of(publicKey: identityKey))
    }

    enum PairingFailure: LocalizedError {
        case unreadableCode
        var errorDescription: String? { "This QR code is not a SentryKey pairing code." }
    }

    private func loadKey() {
        do {
            guard let blob = try keyStore.publicKeyBlob() else {
                // Paired before, but the key is gone: a new phone or a
                // restored backup. Never create a new key silently.
                ourKeyBlob = nil
                publicKeyLine = nil
                keyFingerprint = nil
                phase = .onboarding
                save()
                saveLinkState()
                errorMessage = "This iPhone no longer has its SSH key. Pair again, then install the new public key on your servers."
                return
            }
            if ourKeyBlob != blob {
                ourKeyBlob = blob
                saveLinkState()
            }
            keyFingerprint = Fingerprint.of(blob)
            publicKeyLine = try OpenSSHPublicKey.line(keyBlob: blob, comment: "sentrykey")
        } catch {
            errorMessage = "The signing key is not available on this device."
        }
    }

    // MARK: Sign requests

    /// A message from the Mac, received through the secure channel.
    func receive(_ request: PhoneRequest) {
        switch request {
        case .sign(let id, let keyBlob, let data, let bind):
            receiveSignRequest(id: id, requestKeyBlob: keyBlob, data: data, bind: bind)
        case .cancel(let id):
            cancel(id)
        }
    }

    /// A sign request, with the session-bind ssh sent before it.
    private func receiveSignRequest(id: RequestID, requestKeyBlob: [UInt8], data: [UInt8], bind: SessionBind?) {
        guard let ourKeyBlob else {
            return refuse(id, .keyUnavailable, shownAs: "No signing key", server: nil)
        }
        guard pending == nil else {
            return refuse(id, .busy, shownAs: "Another request is open", server: nil)
        }

        let approval: LoginApproval
        do {
            approval = try LoginApprovalCheck.check(
                requestKeyBlob: requestKeyBlob, data: data, bind: bind, ourKeyBlob: ourKeyBlob
            )
        } catch {
            return refuse(id, .invalidRequest, shownAs: Self.describe(error), server: nil)
        }
        // Checked after LoginApprovalCheck, which guarantees `bind` exists.
        guard let bind, HostVerifier.isValid(bind) else {
            return refuse(id, .invalidRequest, shownAs: "Server signature invalid", server: nil)
        }

        let fingerprint = Fingerprint.of(approval.hostKey)
        let name = knownHosts.name(forFingerprint: fingerprint)
        guard limiter.shouldPrompt(at: .now) else {
            return refuse(id, .rateLimited, shownAs: "Too many requests", server: name ?? Self.short(fingerprint))
        }

        let request = PendingRequest(
            requestID: id,
            approval: approval,
            hostFingerprint: fingerprint,
            knownName: name,
            dataToSign: data,
            receivedAt: .now,
            expiresAt: .now.addingTimeInterval(Self.answerTime)
        )
        pending = request
        if !isOnScreen {
            notifier.post(for: request)
            recordEvent("notification posted")
        }
        Task {
            try? await Task.sleep(for: .seconds(Self.answerTime))
            if pending?.id == request.id { deny(request, .expired, shownAs: "Timed out") }
        }
    }

    /// The Mac gave up on a request. If its prompt is still open, it is
    /// closed without an answer: the Mac no longer listens for one.
    private func cancel(_ id: RequestID) {
        guard let request = pending, request.requestID == id else { return }
        pending = nil
        notifier.remove(for: request)
        record(.refused("Cancelled by the Mac"), request: request)
    }

    /// Face ID, then one signature. `newName` names a first-time server.
    func approve(_ request: PendingRequest, newName: String) async {
        guard pending?.id == request.id, Date.now < request.expiresAt else { return }
        let server = request.knownName ?? Self.short(request.hostFingerprint)
        do {
            let raw = try await keyStore.sign(
                request.dataToSign,
                reason: "Sign in as \(request.approval.userName) on \(server)"
            )
            // The request may have timed out while Face ID was showing.
            guard pending?.id == request.id else { return }
            let blob = try ECDSAP256.signatureBlob(rawSignature: raw)
            sendResponse(PhoneResponse(id: request.requestID, outcome: .signature(blob: blob)))
            pending = nil
            notifier.remove(for: request)
            remember(name: newName, for: request)
            record(.approved, request: request)
        } catch let error as LAError where error.code == .systemCancel || error.code == .appCancel {
            // Interrupted by the system (a call, the app going to the
            // background): the request stays open until it expires.
        } catch let error as LAError where error.code == .userCancel {
            deny(request, .deniedByUser, shownAs: "Cancelled at Face ID")
        } catch {
            // Includes a key made unusable by a change in enrolled faces
            // (.biometryCurrentSet). The exact error is checked on a device.
            deny(request, .keyUnavailable, shownAs: "Face ID or key unavailable")
            errorMessage = "Signing failed. If you changed your Face ID settings, the key can no longer be used: pair again."
        }
    }

    /// Closes a prompt without signing. With no arguments, the user tapped
    /// Deny. `reason` goes to the Mac, `text` to the history.
    func deny(_ request: PendingRequest, _ reason: RefusalReason = .deniedByUser, shownAs text: String? = nil) {
        guard pending?.id == request.id else { return }
        sendResponse(PhoneResponse(id: request.requestID, outcome: .refused(reason)))
        pending = nil
        notifier.remove(for: request)
        record(text.map { .refused($0) } ?? .denied, request: request)
    }

    // MARK: Known servers

    func rename(fingerprint: String, to name: String) {
        try? knownHosts.remember(name: name, forFingerprint: fingerprint)
        save()
    }

    func forget(fingerprint: String) {
        knownHosts.forget(fingerprint: fingerprint)
        save()
    }

    private func remember(name: String, for request: PendingRequest) {
        guard request.knownName == nil, !name.isEmpty else { return }
        rename(fingerprint: request.hostFingerprint, to: name)
    }

    // MARK: History

    private func record(_ outcome: LogEntry.Outcome, request: PendingRequest) {
        let server = knownHosts.name(forFingerprint: request.hostFingerprint) ?? Self.short(request.hostFingerprint)
        history.insert(LogEntry(date: .now, server: server, userName: request.approval.userName, outcome: outcome), at: 0)
    }

    /// Refuses a request before any prompt. `reason` goes to the Mac,
    /// `text` to the history.
    private func refuse(_ id: RequestID, _ reason: RefusalReason, shownAs text: String, server: String?) {
        sendResponse(PhoneResponse(id: id, outcome: .refused(reason)))
        history.insert(LogEntry(date: .now, server: server ?? "Unknown", userName: nil, outcome: .refused(text)), at: 0)
    }

    static func short(_ fingerprint: String) -> String {
        String(fingerprint.prefix("SHA256:".count + 8)) + "…"
    }

    private static func describe(_ refusal: ApprovalRefusal) -> String {
        switch refusal {
        case .wrongKey: "Not this phone's key"
        case .notALogin: "Not an SSH login"
        case .noSessionBind: "Server not identified"
        case .forwardedSession: "Agent forwarding"
        case .sessionMismatch: "Wrong session"
        case .hostKeyMismatch: "Wrong server key"
        case .unsafeUserName: "Suspicious user name"
        }
    }
}
