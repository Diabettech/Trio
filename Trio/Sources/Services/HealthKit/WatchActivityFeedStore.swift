import Foundation

/// The watch's heart rate and steps (`WatchActivityFeed`) as received, kept for two hours in
/// UserDefaults, which stays readable while the iPhone is locked, unlike Health. Read by
/// `BoostActivityMonitor` only when its Health reads fail.
///
/// Testing branch: the feed's cadence on a real watch is what this is for measuring.
final class WatchActivityFeedStore: @unchecked Sendable {
    static let shared = WatchActivityFeedStore()

    /// Two hours covers the 60-minute step window and the 30-minute HR window with room for a late batch.
    static let keepMs: Double = 2 * 3_600_000
    /// The feed counts as live while its newest batch is this recent: AAPS's wear step freshness
    /// (`WearStepSource.FRESH_MS`, 12 min). Steps then gate the INACTIVE raise, so a stale feed must
    /// not read as a person sitting still.
    static let freshMs: Double = 12 * 60000

    private struct Stored: Codable {
        var heartRate: [WatchActivityFeed.Sample] = []
        var steps: [WatchActivityFeed.Sample] = []
        var lastSentAtMs: Double = 0
        var lastReceivedAtMs: Double = 0
    }

    private let key = "boost_watch_activity_feed_v1"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func load() -> Stored {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(Stored.self, from: data) else {
            return Stored()
        }
        return s
    }

    /// Adds a batch, dropping samples already held (the watch can resend) and anything older than `keepMs`.
    func ingest(_ batch: WatchActivityFeed.Batch, receivedAtMs: Double) {
        lock.lock()
        defer { lock.unlock() }
        var s = load()
        let cutoff = receivedAtMs - Self.keepMs
        let merge = { (held: [WatchActivityFeed.Sample], new: [WatchActivityFeed.Sample]) in
            Array(Set(held + new)).filter { $0.endMs > cutoff }.sorted { ($0.endMs, $0.startMs) < ($1.endMs, $1.startMs) }
        }
        s.heartRate = merge(s.heartRate, batch.heartRate)
        s.steps = merge(s.steps, batch.steps)
        s.lastSentAtMs = max(s.lastSentAtMs, batch.sentAtMs)
        s.lastReceivedAtMs = receivedAtMs
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
    }

    /// Age of the newest batch at `nowMs`, by the watch's clock; nil when none has arrived.
    func ageMs(nowMs: Double) -> Double? {
        lock.lock()
        defer { lock.unlock() }
        let sent = load().lastSentAtMs
        return sent > 0 ? nowMs - sent : nil
    }

    func isLive(nowMs: Double) -> Bool {
        guard let age = ageMs(nowMs: nowMs) else { return false }
        return age <= Self.freshMs && age >= -Self.freshMs // a watch clock far ahead is not trusted either
    }

    /// Whether the feed's steps can be read as the person's steps: live, and holding a heart-rate
    /// sample within `freshMs`. A watch on the wrist records heart rate every few minutes in the
    /// background; one off the wrist records none, and its batches carry no steps because nobody is
    /// wearing it, which must not read as sitting still (the INACTIVE raise adds insulin).
    func stepsUsable(nowMs: Double) -> Bool {
        isLive(nowMs: nowMs) && !heartRate(sinceMs: nowMs - Self.freshMs, nowMs: nowMs).isEmpty
    }

    /// Steps in [sinceMs, nowMs], a sample straddling an edge counted in proportion to its overlap,
    /// as HealthKit's cumulative sum does.
    func steps(sinceMs: Double, nowMs: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return load().steps.reduce(0) { sum, s in
            let overlap = min(s.endMs, nowMs) - max(s.startMs, sinceMs)
            if s.endMs == s.startMs { return sum + (s.endMs >= sinceMs && s.endMs <= nowMs ? s.value : 0) }
            return overlap > 0 ? sum + s.value * overlap / (s.endMs - s.startMs) : sum
        }
    }

    /// Heart-rate samples ending in [sinceMs, nowMs], oldest first.
    func heartRate(sinceMs: Double, nowMs: Double) -> [WatchActivityFeed.Sample] {
        lock.lock()
        defer { lock.unlock() }
        return load().heartRate.filter { $0.endMs >= sinceMs && $0.endMs <= nowMs }
    }
}
