import Foundation

/// Anti-spam for approval prompts (ARCHITECTURE.md, Signing).
///
/// A compromised Mac could send prompts until the user taps Approve out of
/// fatigue. After `maxPrompts` prompts within `window` seconds, the phone
/// refuses every request for `cooldown` seconds without showing anything.
public struct PromptRateLimiter: Sendable {
    public let maxPrompts: Int
    public let window: TimeInterval
    public let cooldown: TimeInterval

    private var recent: [Date] = []
    private var blockedUntil: Date?

    /// The defaults are a first guess for the demo, not a tested value.
    public init(maxPrompts: Int = 5, window: TimeInterval = 60, cooldown: TimeInterval = 120) {
        precondition(maxPrompts > 0 && window > 0 && cooldown >= 0)
        self.maxPrompts = maxPrompts
        self.window = window
        self.cooldown = cooldown
    }

    /// True when the phone may show a prompt at `now`. Counts the prompt.
    public mutating func shouldPrompt(at now: Date) -> Bool {
        if let blockedUntil, now < blockedUntil { return false }
        blockedUntil = nil
        // A clock moved backwards keeps old entries, which errs on refusing.
        // Copied out: the closure may not read `self` while `recent` is being modified.
        let window = window
        recent.removeAll { now.timeIntervalSince($0) >= window }
        guard recent.count < maxPrompts else {
            blockedUntil = now.addingTimeInterval(cooldown)
            recent.removeAll()
            return false
        }
        recent.append(now)
        return true
    }
}
