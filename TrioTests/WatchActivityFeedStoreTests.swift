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

/// The Boost Garmin face's messages: HR pairs and the daily step counter.
@Suite("GarminActivityIngestTests") struct GarminActivityIngestTests {
    private let t0: Double = 1_800_000_000 // epoch s

    private func store() -> WatchActivityFeedStore {
        WatchActivityFeedStore(defaults: UserDefaults(suiteName: "GarminActivityIngestTests.\(UUID().uuidString)")!)
    }

    // As the Connect IQ SDK delivers it: integer NSNumbers in an NSDictionary.
    private func msg(_ t: Double, cum: Int, hr: [[Int]] = []) -> [String: Any] {
        NSDictionary(dictionary: [
            "boostActivity": NSNumber(value: 1), "t": NSNumber(value: Int(t)), "cum": NSNumber(value: cum),
            "hr": hr.map { $0.map { NSNumber(value: $0) } }
        ]) as! [String: Any]
    }

    /// Wakes every 5 min from `from` for `minutes`, `stepsPerWake` each, with a heart-rate reading.
    private func wakes(_ s: WatchActivityFeedStore, from: Double, minutes: Int, cum0: Int, stepsPerWake: Int) -> Int {
        var cum = cum0
        for k in 0 ... minutes / 5 {
            let t = from + Double(k * 300)
            s.ingestGarmin(msg(t, cum: cum, hr: [[Int(t) - 30, 80]]), receivedAtMs: t * 1000)
            cum += stepsPerWake
        }
        return cum
    }

    @Test("The counter difference between wakes becomes steps; heart rate is kept") func counterToSteps() {
        let s = store()
        #expect(s.ingestGarmin(msg(t0, cum: 1000, hr: [[Int(t0) - 60, 72]]), receivedAtMs: t0 * 1000)?.steps.isEmpty == true)
        let b = s.ingestGarmin(msg(t0 + 300, cum: 1400, hr: [[Int(t0) + 240, 95]]), receivedAtMs: (t0 + 300) * 1000)
        #expect(b?.steps == [.init(startMs: t0 * 1000, endMs: (t0 + 300) * 1000, value: 400)])
        #expect(s.steps(sinceMs: (t0 - 3600) * 1000, nowMs: (t0 + 300) * 1000) == 400)
        #expect(s.heartRate(sinceMs: (t0 - 600) * 1000, nowMs: (t0 + 300) * 1000).map(\.value) == [72, 95])
    }

    @Test("Steps are not used until the Garmin has covered a whole hour without a break") func needsAnHour() {
        let s = store()
        _ = wakes(s, from: t0, minutes: 55, cum0: 0, stepsPerWake: 10)
        #expect(!s.stepsUsable(nowMs: (t0 + 55 * 60) * 1000)) // 55 min covered
        _ = wakes(s, from: t0 + 3600, minutes: 0, cum0: 120, stepsPerWake: 0)
        #expect(s.stepsUsable(nowMs: (t0 + 3600) * 1000))
    }

    @Test("A gap over 15 min restarts the hour, so a walk out of range never reads as sitting still") func gapRestarts() {
        let s = store()
        let cum = wakes(s, from: t0, minutes: 60, cum0: 0, stepsPerWake: 10)
        #expect(s.stepsUsable(nowMs: (t0 + 3600) * 1000))
        // 50 min out of range while walking, then back
        let back = t0 + 3600 + 3000
        s.ingestGarmin(msg(back, cum: cum + 5000, hr: [[Int(back) - 30, 110]]), receivedAtMs: back * 1000)
        #expect(!s.stepsUsable(nowMs: back * 1000))
        _ = wakes(s, from: back + 300, minutes: 55, cum0: cum + 5100, stepsPerWake: 100)
        #expect(s.stepsUsable(nowMs: (back + 3600) * 1000))
    }

    @Test("A midnight reset counts the steps since midnight; an unread counter gives none") func resetAndUnread() {
        let s = store()
        s.ingestGarmin(msg(t0, cum: 9000), receivedAtMs: t0 * 1000)
        #expect(s.ingestGarmin(msg(t0 + 300, cum: 20), receivedAtMs: (t0 + 300) * 1000)?.steps.first?.value == 20)
        #expect(s.ingestGarmin(msg(t0 + 600, cum: -1), receivedAtMs: (t0 + 600) * 1000)?.steps.isEmpty == true)
        #expect(s.ingestGarmin(msg(t0 + 900, cum: 120), receivedAtMs: (t0 + 900) * 1000)?.steps.first?.value == 100)
    }

    @Test("A malformed message is refused") func malformed() {
        let s = store()
        #expect(s.ingestGarmin(["boostActivity": 1], receivedAtMs: 0) == nil)
        #expect(s.ingestGarmin(msg(t0, cum: 0, hr: [[Int(t0), 0]]), receivedAtMs: 0) == nil)
    }
}
