import Foundation
import Testing
@testable import Trio

/// The watch activity feed (testing branch): the message format and the iPhone's store of it.
@Suite("WatchActivityFeedStoreTests") struct WatchActivityFeedStoreTests {
    private let t0: Double = 1_800_000_000_000 // epoch ms
    private let min: Double = 60000

    private func store() -> WatchActivityFeedStore {
        let suite = "WatchActivityFeedStoreTests.\(UUID().uuidString)"
        return WatchActivityFeedStore(defaults: UserDefaults(suiteName: suite)!)
    }

    private func sample(_ startMin: Double, _ endMin: Double, _ value: Double) -> WatchActivityFeed.Sample {
        .init(startMs: t0 + startMin * min, endMs: t0 + endMin * min, value: value)
    }

    @Test("A batch survives encoding as a userInfo dictionary") func roundTrip() {
        let b = WatchActivityFeed.Batch(sentAtMs: t0, heartRate: [sample(0, 0, 61)], steps: [sample(-5, 0, 120)])
        #expect(WatchActivityFeed.decode(WatchActivityFeed.encode(b)) == b)
    }

    @Test("Malformed or other-version batches are refused") func refusesMalformed() {
        #expect(WatchActivityFeed.decode([:]) == nil)
        #expect(WatchActivityFeed.decode([WatchActivityFeed.key: ["v": 2, "sentAt": t0, "hr": [], "steps": []]]) == nil)
        let backwards: [[Double]] = [[t0, t0 - 1, 10]]
        #expect(WatchActivityFeed.decode([WatchActivityFeed.key: ["v": 1, "sentAt": t0, "hr": [], "steps": backwards]]) == nil)
        let negative: [[Double]] = [[t0, t0, -3]]
        #expect(WatchActivityFeed.decode([WatchActivityFeed.key: ["v": 1, "sentAt": t0, "hr": negative, "steps": []]]) == nil)
    }

    @Test("A resent sample is counted once") func dedupes() {
        let s = store()
        let b = WatchActivityFeed.Batch(sentAtMs: t0, heartRate: [sample(0, 0, 61)], steps: [sample(-10, -5, 300)])
        s.ingest(b, receivedAtMs: t0)
        s.ingest(b, receivedAtMs: t0 + min)
        #expect(s.steps(sinceMs: t0 - 60 * min, nowMs: t0) == 300)
        #expect(s.heartRate(sinceMs: t0 - 16 * min, nowMs: t0).count == 1)
    }

    @Test("A sample straddling the window edge counts in proportion") func prorates() {
        let s = store()
        s.ingest(.init(sentAtMs: t0, heartRate: [], steps: [sample(-70, -50, 200)]), receivedAtMs: t0)
        // 10 of its 20 minutes fall inside the last hour
        #expect(abs(s.steps(sinceMs: t0 - 60 * min, nowMs: t0) - 100) < 1E-9)
    }

    @Test("Samples older than two hours are dropped") func prunes() {
        let s = store()
        s.ingest(.init(sentAtMs: t0, heartRate: [sample(-150, -150, 60)], steps: [sample(-130, -125, 50)]), receivedAtMs: t0)
        #expect(s.heartRate(sinceMs: 0, nowMs: t0).isEmpty)
        #expect(s.steps(sinceMs: 0, nowMs: t0) == 0)
    }

    @Test("The feed is live for 12 minutes after its newest batch, and never before one") func liveness() {
        let s = store()
        #expect(!s.isLive(nowMs: t0))
        s.ingest(.init(sentAtMs: t0, heartRate: [], steps: []), receivedAtMs: t0)
        #expect(s.isLive(nowMs: t0 + 12 * min))
        #expect(!s.isLive(nowMs: t0 + 12 * min + 1))
        // A batch from a watch clock far ahead does not keep the feed live
        let ahead = store()
        ahead.ingest(.init(sentAtMs: t0 + 60 * min, heartRate: [], steps: []), receivedAtMs: t0)
        #expect(!ahead.isLive(nowMs: t0))
    }

    @Test("Feed steps count only while the watch is worn: live and with recent heart rate") func stepsUsable() {
        let worn = store()
        worn.ingest(.init(sentAtMs: t0, heartRate: [sample(-3, -3, 64)], steps: []), receivedAtMs: t0)
        #expect(worn.stepsUsable(nowMs: t0))
        // Off the wrist: batches keep arriving, empty, with no heart rate
        let offWrist = store()
        offWrist.ingest(.init(sentAtMs: t0, heartRate: [], steps: []), receivedAtMs: t0)
        #expect(offWrist.isLive(nowMs: t0))
        #expect(!offWrist.stepsUsable(nowMs: t0))
        // Heart rate older than the freshness window does not count
        let stale = store()
        stale.ingest(.init(sentAtMs: t0, heartRate: [sample(-13, -13, 64)], steps: []), receivedAtMs: t0)
        #expect(!stale.stepsUsable(nowMs: t0))
    }
}
