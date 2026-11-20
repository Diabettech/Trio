import Foundation

/// Heart rate and steps the watch reads from its own Health store and sends to the iPhone. The
/// iPhone cannot read Health while it is locked, and the watch can whenever it is on the wrist, so
/// this feed carries Boost's activity inputs through the locked hours (the Garmin feed's role in
/// AAPS). Compiled into both the watch app and Trio, like `WatchMessageKeys`.
///
/// One batch is the samples the watch had not sent before, as a `transferUserInfo` dictionary, which
/// WatchConnectivity queues and delivers in order, waking Trio in the background.
enum WatchActivityFeed {
    static let key = "boostActivityFeed"
    static let version = 1

    struct Sample: Equatable, Codable, Hashable {
        let startMs: Double
        let endMs: Double
        let value: Double
    }

    struct Batch: Equatable {
        /// When the watch sent it, epoch ms. Also the watch's heartbeat: a batch with no samples
        /// still says the feed was alive at that time.
        let sentAtMs: Double
        let heartRate: [Sample] // bpm
        let steps: [Sample] // count
    }

    static func encode(_ batch: Batch) -> [String: Any] {
        let pack = { (s: [Sample]) in s.map { [$0.startMs, $0.endMs, $0.value] } }
        return [key: ["v": version, "sentAt": batch.sentAtMs, "hr": pack(batch.heartRate), "steps": pack(batch.steps)]]
    }

    /// nil for anything that is not a well-formed batch of this version.
    static func decode(_ userInfo: [String: Any]) -> Batch? {
        guard let body = userInfo[key] as? [String: Any],
              (body["v"] as? NSNumber)?.intValue == version,
              let sentAt = (body["sentAt"] as? NSNumber)?.doubleValue,
              let hr = unpack(body["hr"]), let steps = unpack(body["steps"])
        else { return nil }
        return Batch(sentAtMs: sentAt, heartRate: hr, steps: steps)
    }

    private static func unpack(_ any: Any?) -> [Sample]? {
        guard let rows = any as? [[NSNumber]] else { return nil }
        var out: [Sample] = []
        for r in rows {
            guard r.count == 3 else { return nil }
            let s = Sample(startMs: r[0].doubleValue, endMs: r[1].doubleValue, value: r[2].doubleValue)
            guard s.startMs.isFinite, s.endMs.isFinite, s.value.isFinite, s.endMs >= s.startMs, s.value >= 0 else { return nil }
            out.append(s)
        }
        return out
    }
}
