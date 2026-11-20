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
        // The Garmin face's step counter at its previous wake, epoch s (Garmin sends the counter).
        var garminPrevT: Double?
        var garminPrevCum: Double?
        // Since when the Garmin steps run without a break, epoch ms; nil before any Garmin message.
        var garminCoveredSinceMs: Double?
    }

    /// The longest gap between two Garmin wakes whose counter difference is placed between them.
    /// Wakes are 5 to 6 min apart. After a longer gap (out of range, a restart) the steps cannot be
    /// placed in time, so the run starts again and the Garmin steps are not used until it covers the
    /// 60-minute window: an hour holding only part of the steps would read a walk as sitting still.
    static let garminMaxGapS: Double = 15 * 60
    static let garminCoverMs: Double = 3_600_000

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

    /// A message from the Boost Garmin face: `t` (epoch s), `cum` (the watch's daily step counter, -1
    /// when unread) and `hr` ([[epoch s, bpm]]). The counter becomes one step sample between this
    /// wake and the previous one; a counter that went down (the midnight reset) or a gap over
    /// `garminMaxGapS` gives no sample and starts again from here. Returns the batch stored, or nil
    /// for a malformed message.
    @discardableResult func ingestGarmin(_ body: [String: Any], receivedAtMs: Double) -> WatchActivityFeed.Batch? {
        guard let t = (body["t"] as? NSNumber)?.doubleValue, t.isFinite,
              let cum = (body["cum"] as? NSNumber)?.doubleValue, cum.isFinite,
              let rows = body["hr"] as? [[NSNumber]]
        else { return nil }
        var hr: [WatchActivityFeed.Sample] = []
        for r in rows {
            guard r.count == 2, r[0].doubleValue.isFinite, r[0].doubleValue > 0, r[1].doubleValue > 0 else { return nil }
            let ms = r[0].doubleValue * 1000
            hr.append(.init(startMs: ms, endMs: ms, value: r[1].doubleValue))
        }
        lock.lock()
        var s = load()
        var steps: [WatchActivityFeed.Sample] = []
        if cum >= 0 {
            if let pt = s.garminPrevT, let pc = s.garminPrevCum, t > pt, t - pt <= Self.garminMaxGapS {
                // A counter that went down was reset at midnight; the steps since then are a lower bound.
                steps.append(.init(startMs: pt * 1000, endMs: t * 1000, value: cum >= pc ? cum - pc : cum))
            } else {
                s.garminCoveredSinceMs = t * 1000
            }
            s.garminPrevT = t
            s.garminPrevCum = cum
        }
        if let data = try? JSONEncoder().encode(s) { defaults.set(data, forKey: key) }
        lock.unlock()
        let batch = WatchActivityFeed.Batch(sentAtMs: t * 1000, heartRate: hr, steps: steps)
        ingest(batch, receivedAtMs: receivedAtMs)
        return batch
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
    /// With a Garmin feeding it, the steps must also have run without a break for the whole hour.
    func stepsUsable(nowMs: Double) -> Bool {
        let covered: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return load().garminCoveredSinceMs.map { nowMs - $0 >= Self.garminCoverMs } ?? true
        }()
        return covered && isLive(nowMs: nowMs) && !heartRate(sinceMs: nowMs - Self.freshMs, nowMs: nowMs).isEmpty
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
