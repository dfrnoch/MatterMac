/// Retry policy for safe reads only (SPEC §9: "Backoff safe reads with jitter; do not
/// blindly retry writes whose result is unknown").
///
/// - At most `maximumAttempts` attempts in total (default 3).
/// - Exponential backoff with *full jitter*: before retry `n` (1-based) the delay is
///   uniform in `0 ... min(maximumDelay, baseDelay * 2^(n-1))` (base 0.5 s, cap 8 s).
/// - A 429 with a server hint waits exactly `Retry-After`/`X-RateLimit-Reset`
///   seconds when that is at most `maximumRetryAfter` (60 s); a longer hint is not
///   waited out — the `.rateLimited` error is returned to the caller.
/// - Only errors with `APIError.isRetryableRead` are retried (rate limiting,
///   not-sent and unknown-outcome transport failures, 5xx other than 501).
/// - POST/PUT/DELETE are never retried here.
public struct RetryPolicy: Sendable {
    public var maximumAttempts: Int
    public var baseDelay: Duration
    public var maximumDelay: Duration
    public var maximumRetryAfter: Duration
    /// Uniform random source in `0..<1`; injected for deterministic tests.
    public var unitRandom: @Sendable () -> Double

    public init(maximumAttempts: Int = 3, baseDelay: Duration = .milliseconds(500), maximumDelay: Duration = .seconds(8),
                maximumRetryAfter: Duration = .seconds(60),
                unitRandom: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }) {
        self.maximumAttempts = max(1, maximumAttempts)
        self.baseDelay = baseDelay
        self.maximumDelay = maximumDelay
        self.maximumRetryAfter = maximumRetryAfter
        self.unitRandom = unitRandom
    }

    public static let standard = RetryPolicy()
    public static let never = RetryPolicy(maximumAttempts: 1)

    /// The delay before the next attempt after `attempt` (1-based) failed with
    /// `error`, or `nil` when the operation must not be retried.
    public func delay(afterAttempt attempt: Int, error: APIError) -> Duration? {
        guard attempt >= 1, attempt < maximumAttempts, error.isRetryableRead else { return nil }
        if case .rateLimited(let seconds?) = error {
            let hint = Duration.seconds(max(0, seconds))
            return hint <= maximumRetryAfter ? hint : nil
        }
        let exponent = min(attempt - 1, 30)
        var ceiling = baseDelay * (1 << exponent)
        if ceiling > maximumDelay || ceiling < .zero { ceiling = maximumDelay }
        let fraction = min(max(unitRandom(), 0), 1)
        return ceiling * fraction
    }

    /// Runs `operation` with retries. `isSafe == false` disables retrying entirely.
    /// Cancellation during a backoff sleep throws `.cancelled`.
    public func run<T: Sendable>(isSafe: Bool, clock: any Clock<Duration>,
                                 onRetry: (@Sendable (APIError, Duration) -> Void)? = nil,
                                 _ operation: () async throws(APIError) -> T) async throws(APIError) -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard isSafe, let delay = delay(afterAttempt: attempt, error: error) else { throw error }
                onRetry?(error, delay)
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    throw .cancelled
                }
                if Task.isCancelled { throw .cancelled }
                attempt += 1
            }
        }
    }
}
