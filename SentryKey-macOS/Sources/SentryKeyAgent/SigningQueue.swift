import SentryKeyProtocol

/// How one sign request ended, seen from the Mac.
public enum SignOutcome: Equatable, Sendable {
    case signature(blob: [UInt8])
    case refused(RefusalReason)
    case timedOut
    case phoneUnreachable
    /// Too many requests were already waiting for the phone.
    case queueFull
    /// The caller's task was cancelled (ssh went away) before the answer.
    case cancelled
}

/// Sends sign requests to the phone one at a time and matches each answer
/// to its request (ARCHITECTURE.md, RequestQueue).
///
/// One at a time, because the phone shows one prompt at a time and refuses
/// a second request while the first is open.
public actor SigningQueue {
    /// Longer than the phone's own answer time (30 s), so the phone's
    /// refusal normally arrives before the Mac gives up.
    public static let defaultAnswerTime: Duration = .seconds(45)
    public static let defaultMaxWaiting = 8

    private struct InFlight {
        let id: RequestID
        var continuation: CheckedContinuation<SignOutcome, Never>?
        /// An answer that arrived while the request was still being sent.
        var earlyOutcome: SignOutcome?
    }

    private let link: any PhoneLink
    private let maxWaiting: Int
    private let waitForTimeout: @Sendable () async -> Void

    private var nextID: UInt32 = 0
    private var isSigning = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var inFlight: InFlight?

    /// - Parameters:
    ///   - maxWaiting: requests allowed to wait behind the one in progress.
    ///     Bounded so a local process cannot make the agent hold an
    ///     unlimited number of requests.
    ///   - waitForTimeout: returns when a request has waited long enough.
    ///     Injected so tests do not sleep.
    public init(
        link: any PhoneLink,
        maxWaiting: Int = SigningQueue.defaultMaxWaiting,
        waitForTimeout: @escaping @Sendable () async -> Void = {
            try? await Task.sleep(for: SigningQueue.defaultAnswerTime)
        }
    ) {
        self.link = link
        self.maxWaiting = maxWaiting
        self.waitForTimeout = waitForTimeout
    }

    /// Requests waiting behind the one in progress.
    public var waitingCount: Int { waiting.count }

    /// Asks the phone for one signature and waits for its answer.
    public func sign(keyBlob: [UInt8], data: [UInt8], bind: SessionBind?) async -> SignOutcome {
        guard await takeTurn() else { return .queueFull }
        defer { passTurn() }
        // ssh may have gone away while this request waited for its turn:
        // nothing is sent, and the phone shows no prompt for it.
        guard !Task.isCancelled else { return .cancelled }

        let id = RequestID(rawValue: nextID)
        nextID &+= 1
        inFlight = InFlight(id: id)

        do {
            try await link.send(.sign(id: id, keyBlob: keyBlob, data: data, bind: bind))
        } catch {
            inFlight = nil
            return .phoneUnreachable
        }
        if let early = inFlight?.earlyOutcome {
            inFlight = nil
            return early
        }

        let timeout = Task {
            await waitForTimeout()
            // A cancelled wait returns early: that is not a timeout.
            guard !Task.isCancelled else { return }
            await expire(id)
        }
        // If ssh goes away now, the phone is told to close its prompt and
        // the turn passes to the next request at once.
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                inFlight?.continuation = continuation
            }
        } onCancel: {
            Task { await self.giveUp(id, outcome: .cancelled) }
        }
        timeout.cancel()
        return outcome
    }

    /// Hands over an answer received from the phone. An answer to a request
    /// that is no longer in progress is dropped: see `RequestID`.
    public func deliver(_ response: PhoneResponse) {
        guard inFlight?.id == response.id else { return }
        switch response.outcome {
        case .signature(let blob): resolve(.signature(blob: blob))
        case .refused(let reason): resolve(.refused(reason))
        }
    }

    private func expire(_ id: RequestID) async {
        await giveUp(id, outcome: .timedOut)
    }

    /// Ends a request without the phone's answer, and tells the phone to
    /// drop its prompt.
    private func giveUp(_ id: RequestID, outcome: SignOutcome) async {
        guard inFlight?.id == id else { return }
        // The cancel is sent before the request ends: ending it hands the
        // turn to the next request, whose sign must not reach the phone
        // before this cancel, or the phone would answer it "busy".
        // Best effort: the phone has its own timeout, and its late answer
        // would be dropped here anyway.
        try? await link.send(.cancel(id: id))
        resolve(outcome)
    }

    private func resolve(_ outcome: SignOutcome) {
        guard var flight = inFlight else { return }
        if let continuation = flight.continuation {
            inFlight = nil
            continuation.resume(returning: outcome)
        } else if flight.earlyOutcome == nil {
            flight.earlyOutcome = outcome
            inFlight = flight
        }
    }

    /// Waits until no other request is in progress. Returns false when too
    /// many are already waiting.
    private func takeTurn() async -> Bool {
        guard isSigning else {
            isSigning = true
            return true
        }
        guard waiting.count < maxWaiting else { return false }
        await withCheckedContinuation { waiting.append($0) }
        // The turn was handed over by `passTurn`: `isSigning` is still true.
        return true
    }

    private func passTurn() {
        if waiting.isEmpty {
            isSigning = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
