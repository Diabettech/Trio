import Foundation
import NextGenCore
import Testing

// Toolchain check for the nextgen-aid core (BUILD_PLAN.md step N0): the Kotlin/Native XCFramework
// linked into the app must give, on the iOS simulator, the decisions the JVM build recorded. The
// six snapshots are rebuilt here in Swift from core/src/commonTest/kotlin/nextgen/core/GoldenTrace.kt
// and the expected lines are read from the JVM-side record, so a change to either copy shows up.
// Synthetic values chosen to exercise the boundary; none describes a person or a setting.

// shortcut: reads the record from a sibling checkout of nextgen-aid by path, which only works on a
// simulator on this machine; bundle the record or vendor it with the framework before CI or a device.
// The record is source and the framework is a build output, so they drift apart whenever nextgen-aid
// changes a decision without the framework being rebuilt; a failure on one cycle is usually that.
private let recordedDecisionsURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../nextgen-aid/core/src/jvmTest/resources/golden_n0.decisions.jsonl")
    .standardizedFileURL

private let t0: Int64 = 1_700_000_000_000
private let minute: Int64 = 60000

private struct Variant {
    var nowMs: Int64
    var glucose: [GlucoseReading]? = nil
    var boluses: [Bolus]? = nil
    var uncertainDelivery: UncertainDelivery? = nil
    var insulin: Insulin? = nil
}

private func snapshot(_ v: Variant) -> Snapshot {
    // The Kotlin fixture builds each case with base.copy(...); Swift sees no default arguments, so
    // the base is restated here and each variant overrides the fields it changes.
    let baseGlucose = [
        GlucoseReading(
            sensorTimeMs: t0 - 5 * minute, receivedTimeMs: t0 - 5 * minute + 2000,
            value: 118, originalValue: 118, originalUnit: .mgDl, quality: []
        ),
        GlucoseReading(
            sensorTimeMs: t0, receivedTimeMs: t0 + 1500,
            value: 121, originalValue: 121, originalUnit: .mgDl, quality: [.smoothed]
        )
    ]
    return Snapshot(
        nowMs: v.nowMs,
        glucose: v.glucose ?? baseGlucose,
        boluses: v.boluses ?? [Bolus(timeMs: t0 - 90 * minute, amount: 0.35)],
        tempBasals: [BasalSegment(startMs: t0 - 30 * minute, endMs: t0 - 10 * minute, rate: 0)],
        scheduledBasal: [BasalSegment(startMs: t0 - 360 * minute, endMs: t0 + 360 * minute, rate: 0.8)],
        uncertainDelivery: v.uncertainDelivery,
        totalDailyDose: 40,
        bodyWeightKg: 75,
        target: 100,
        maxIob: 5,
        maxBasal: 3,
        insulin: v.insulin ?? Insulin(identity: .lyumjev, concentrationUnitsPerMl: 100),
        pump: PumpCapability(bolusStep: 0.025, basalStep: 0.05, microbolusPermitted: true)
    )
}

private let goldenSnapshots: [Snapshot] = [
    snapshot(Variant(nowMs: t0)),
    snapshot(Variant(
        nowMs: t0 + 5 * minute,
        glucose: [GlucoseReading(
            sensorTimeMs: t0 + 5 * minute, receivedTimeMs: t0 + 5 * minute + 1500,
            value: 126, originalValue: 7.0, originalUnit: .mmolL, quality: []
        )],
        uncertainDelivery: UncertainDelivery(requestedTimeMs: t0 + 1 * minute, requested: 0.1)
    )),
    snapshot(Variant(
        nowMs: t0 + 10 * minute,
        glucose: [GlucoseReading(
            sensorTimeMs: t0 + 10 * minute, receivedTimeMs: t0 + 10 * minute,
            value: .nan, originalValue: .nan, originalUnit: .mgDl, quality: []
        )]
    )),
    snapshot(Variant(nowMs: t0 + 15 * minute, insulin: Insulin(identity: .unknown, concentrationUnitsPerMl: 100))),
    snapshot(Variant(nowMs: t0 + 20 * minute, insulin: Insulin(identity: .lyumjev, concentrationUnitsPerMl: 200))),
    snapshot(Variant(nowMs: t0 + 25 * minute, boluses: [Bolus(timeMs: t0, amount: -0.5)]))
]

private struct RecordedDecision: Decodable {
    let reasonLine: String
    let state: String
}

@Suite("NextGenCore link (N0)") struct NextGenCoreLinkTests {
    @Test("Golden trace gives the decisions recorded on the JVM") func goldenTraceMatchesJvmRecord() throws {
        let text = try String(contentsOf: recordedDecisionsURL, encoding: .utf8)
        let recorded = try text.split(separator: "\n").map {
            try JSONDecoder().decode(RecordedDecision.self, from: Data($0.utf8))
        }
        #expect(recorded.count == goldenSnapshots.count)

        // State is threaded through the six cycles as the JVM jar threads it, starting from text that
        // does not decode, so the cycle counter in the encoded state is part of what is compared.
        var state = CoreState.companion.decode(text: nil)
        for (i, (snap, want)) in zip(goldenSnapshots, recorded).enumerated() {
            let out = DecideKt.decide(snapshot: snap, state: state)
            state = out.state
            #expect(out.decision.reasonLine == want.reasonLine, "cycle \(i + 1)")
            #expect(state.encode() == want.state, "cycle \(i + 1)")
            #expect(out.decision.tempBasal == nil, "cycle \(i + 1)")
            #expect(out.decision.microbolus == 0, "cycle \(i + 1)")
        }

        // The encoded state must survive the round trip the adapter will make through storage.
        #expect(CoreState.companion.decode(text: state.encode()).encode() == state.encode())
    }

    @Test("Time per decide call, indicative only") func decideTiming() {
        let snap = goldenSnapshots[0]
        let initial = CoreState.companion.decode(text: nil)
        let clock = ContinuousClock()
        var nanos: [Int64] = []
        nanos.reserveCapacity(1000)
        for _ in 0 ..< 1000 {
            let d = clock.measure { _ = DecideKt.decide(snapshot: snap, state: initial) }
            nanos.append(d.components.attoseconds / 1_000_000_000 + d.components.seconds * 1_000_000_000)
        }
        nanos.sort()
        print(
            "NEXTGEN_DECIDE_TIMING median_us=\(Double(nanos[500]) / 1000) p90_us=\(Double(nanos[900]) / 1000) max_us=\(Double(nanos[999]) / 1000)"
        )
        #expect(nanos[500] > 0)
    }
}
