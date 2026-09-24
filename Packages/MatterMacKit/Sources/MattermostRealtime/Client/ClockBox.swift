/// Type-erased monotonic time source over an injected `Clock<Duration>`. Elapsed
/// time is measured from the box's creation so instants of an existential clock can
/// be compared without knowing the concrete `Instant` type.
struct ClockBox: Sendable {
    let elapsed: @Sendable () -> Duration
    let sleep: @Sendable (Duration) async throws -> Void

    init(_ clock: any Clock<Duration>) {
        self = Self.make(clock)
    }

    private init(elapsed: @escaping @Sendable () -> Duration, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        self.elapsed = elapsed
        self.sleep = sleep
    }

    private static func make<C: Clock>(_ clock: C) -> ClockBox where C.Duration == Duration {
        let origin = clock.now
        return ClockBox(
            elapsed: { origin.duration(to: clock.now) },
            sleep: { duration in try await clock.sleep(for: duration) })
    }
}
