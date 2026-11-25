import SentryKeyProtocol

/// How one sign request ended, seen from the Mac.
public enum SignOutcome: Equatable, Sendable {
    case signature(blob: [UInt8])
    case refused(RefusalReason)
    case timedOut
    case phoneUnreachable
    /// Too many requests were already waiting for the phone.
    case queueFull
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
        let outcome = await withCheckedContinuation { continuation in
            inFlight?.continuation = continuation
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

    /// The connection that carried this request ended before the phone
    /// answered: no answer can come. Ignored if it is no longer in progress.
    public func requestLost(_ id: RequestID) {
        guard inFlight?.id == id else { return }
        resolve(.phoneUnreachable)
    }

    /// Passes the link's answers and lost requests to this queue, until
    /// both streams end.
    public func listen(to link: SecurePhoneLink) async {
        await withDiscardingTaskGroup { group in
            group.addTask { for await response in link.responses { await self.deliver(response) } }
            group.addTask { for await id in link.lostRequests { await self.requestLost(id) } }
        }
    }

    private func expire(_ id: RequestID) async {
        guard inFlight?.id == id else { return }
        resolve(.timedOut)
        // Tells the phone to drop its prompt. Best effort: the phone has its
        // own timeout, and its late answer would be dropped here anyway.
        try? await link.send(.cancel(id: id))
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
