/// Lets the main actor run until `condition` holds, or the timeout passes. No fixed sleeps:
/// returns as soon as the condition is true.
@MainActor
func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        if clock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}
