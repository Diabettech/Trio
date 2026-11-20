import Foundation
import HealthKit
import WatchConnectivity

/// Reads heart rate and steps from the watch's own Health store and sends the iPhone what it has not
/// sent before (`WatchActivityFeed`). The iPhone cannot read Health while it is locked; the watch can
/// whenever it is on the wrist and unlocked.
///
/// HealthKit wakes the app in the background when new samples arrive. watchOS limits how often:
/// about four times an hour with Trio's complication on the active face, reportedly less without it.
/// Testing branch: how often batches reach the iPhone on a real watch is what this measures.
final class WatchActivityReader: @unchecked Sendable {
    static let shared = WatchActivityReader()

    private let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private let stepType = HKQuantityType(.stepCount)
    private let bpm = HKUnit.count().unitDivided(by: .minute())
    private let queue = DispatchQueue(label: "WatchActivityReader")
    /// History sent on the first run or after a long gap; the iPhone keeps two hours.
    private static let lookback: TimeInterval = 2 * 3600
    private var started = false

    func start() {
        queue.async { [self] in
            guard HKHealthStore.isHealthDataAvailable(), !started else { return }
            started = true
            store.requestAuthorization(toShare: [], read: [hrType, stepType]) { [self] _, error in
                if let error { WatchLogger.shared.warning(.data, "Activity feed: Health authorisation failed", error: error) }
                for type in [hrType, stepType] {
                    let observer = HKObserverQuery(sampleType: type, predicate: nil) { [self] _, completion, error in
                        if let error {
                            WatchLogger.shared.warning(.data, "Activity feed: observer failed", error: error)
                            completion()
                            return
                        }
                        sendNew(completion: completion)
                    }
                    store.execute(observer)
                    store.enableBackgroundDelivery(for: type, frequency: .immediate) { ok, error in
                        if !ok { WatchLogger.shared.warning(.data, "Activity feed: background delivery refused", error: error) }
                    }
                }
                sendNew {}
            }
        }
    }

    /// Fetches both types from their saved anchors and sends one batch, empty or not: an empty batch
    /// tells the iPhone the feed is alive and the person took no steps.
    func sendNew(completion: @escaping () -> Void) {
        queue.async { [self] in
            let group = DispatchGroup()
            var fetched: [HKQuantityType: (samples: [WatchActivityFeed.Sample], anchor: HKQueryAnchor?)?] = [:]
            let lock = NSLock()
            for (type, unit) in [(hrType, bpm), (stepType, HKUnit.count())] {
                group.enter()
                fetch(type, unit: unit) { result in
                    lock.lock()
                    fetched[type] = result
                    lock.unlock()
                    group.leave()
                }
            }
            group.notify(queue: queue) { [self] in
                defer { completion() }
                // A failed read (the watch's own Health is locked off the wrist or on the charger)
                // sends nothing: an empty batch would tell the iPhone the person took no steps.
                guard
                    let hr = fetched[hrType] ?? nil, let steps = fetched[stepType] ?? nil
                else {
                    WatchLogger.shared.debug(.data, "Activity feed: a Health read failed, nothing sent")
                    return
                }
                let session = WCSession.default
                guard session.activationState == .activated, session.isCompanionAppInstalled else { return }
                let batch = WatchActivityFeed.Batch(
                    sentAtMs: Date().timeIntervalSince1970 * 1000,
                    heartRate: hr.samples,
                    steps: steps.samples
                )
                session.transferUserInfo(WatchActivityFeed.encode(batch))
                // A queued transfer survives a relaunch, so the anchors move on once it is queued.
                if let anchor = hr.anchor { saveAnchor(anchor, for: hrType) }
                if let anchor = steps.anchor { saveAnchor(anchor, for: stepType) }
                WatchLogger.shared.debug(
                    .data,
                    "Activity feed: queued \(batch.heartRate.count) HR, \(batch.steps.count) step samples"
                )
            }
        }
    }

    private func fetch(
        _ type: HKQuantityType,
        unit: HKUnit,
        done: @escaping ((samples: [WatchActivityFeed.Sample], anchor: HKQueryAnchor?)?) -> Void
    ) {
        // The watch's own samples only: Health on the watch can also hold the iPhone's steps, which
        // the iPhone counts itself once unlocked, and counting both would double the steps.
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForSamples(withStart: Date().addingTimeInterval(-Self.lookback), end: nil),
            HKQuery.predicateForObjects(withDeviceProperty: HKDevicePropertyKeyModel, allowedValues: ["Watch"])
        ])
        let query = HKAnchoredObjectQuery(
            type: type, predicate: predicate, anchor: loadAnchor(for: type), limit: HKObjectQueryNoLimit
        ) { _, added, _, anchor, error in
            if let error {
                WatchLogger.shared.warning(.data, "Activity feed: read failed", error: error)
                done(nil)
                return
            }
            let samples = (added as? [HKQuantitySample] ?? []).map {
                WatchActivityFeed.Sample(
                    startMs: $0.startDate.timeIntervalSince1970 * 1000,
                    endMs: $0.endDate.timeIntervalSince1970 * 1000,
                    value: $0.quantity.doubleValue(for: unit)
                )
            }
            done((samples, anchor))
        }
        store.execute(query)
    }

    private func anchorKey(_ type: HKQuantityType) -> String { "activityFeedAnchor.\(type.identifier)" }

    private func loadAnchor(for type: HKQuantityType) -> HKQueryAnchor? {
        guard let data = UserDefaults.standard.data(forKey: anchorKey(type)) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    private func saveAnchor(_ anchor: HKQueryAnchor, for type: HKQuantityType) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) else { return }
        UserDefaults.standard.set(data, forKey: anchorKey(type))
    }
}
