import CoreGraphics
import XCTest
import simd
@testable import ICanSii_iOS

final class TrackerTests: XCTestCase {
    private func dummyIntrinsics() -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(1000, 0, 0),
            SIMD3<Float>(0, 1000, 0),
            SIMD3<Float>(320, 320, 1)
        )
    }

    private func det(x: CGFloat = 0.4, y: CGFloat = 0.4, cx: CGFloat = 320, cy: CGFloat = 320) -> Detection2DWithDepth {
        Detection2DWithDepth(
            boundingBox: CGRect(x: x, y: y, width: 0.2, height: 0.2),
            centroidUV: CGPoint(x: x + 0.1, y: y + 0.1),
            centroidPx: CGPoint(x: cx, y: cy),
            classId: 0,
            className: "person",
            confidence: 0.9,
            depthMeters: 2.0
        )
    }

    func testAssignsStableIDAcrossTwoFrames() {
        var tracker = Tracker()
        let K = dummyIntrinsics()

        let a = tracker.step(detections: [det()], intrinsics: K, timestamp: 0.0)
        let b = tracker.step(detections: [det()], intrinsics: K, timestamp: 0.1)

        XCTAssertEqual(a.first?.id, b.first?.id)
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(b.count, 1)
    }

    func testPredictsBrieflyAfterDetectionLost() {
        var tracker = Tracker()
        let K = dummyIntrinsics()

        _ = tracker.step(detections: [det()], intrinsics: K, timestamp: 0.0)
        _ = tracker.step(detections: [det()], intrinsics: K, timestamp: 0.1)

        let out = tracker.step(detections: [], intrinsics: K, timestamp: 0.2)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isPredictive)
    }

    func testDropsAfterPredictionTimeout() {
        var tracker = Tracker()
        let K = dummyIntrinsics()

        _ = tracker.step(detections: [det()], intrinsics: K, timestamp: 0.0)
        let out = tracker.step(detections: [], intrinsics: K, timestamp: 5.0)

        XCTAssertTrue(out.isEmpty)
    }

    func testPredictiveVelocityDecaysAcrossMissedFrames() {
        var tracker = Tracker()
        let K = dummyIntrinsics()

        _ = tracker.step(detections: [det(cx: 280)], intrinsics: K, timestamp: 0.00)
        _ = tracker.step(detections: [det(cx: 320)], intrinsics: K, timestamp: 0.10)
        let observed = tracker.step(detections: [det(cx: 360)], intrinsics: K, timestamp: 0.20)
        let v0 = observed.first?.speedSmoothed ?? 0

        let p1 = tracker.step(detections: [], intrinsics: K, timestamp: 0.30)
        let p2 = tracker.step(detections: [], intrinsics: K, timestamp: 0.40)
        let p3 = tracker.step(detections: [], intrinsics: K, timestamp: 0.50)

        let v1 = p1.first?.speedSmoothed ?? 0
        let v2 = p2.first?.speedSmoothed ?? 0
        let v3 = p3.first?.speedSmoothed ?? 0

        XCTAssertGreaterThan(v0, 0)
        XCTAssertLessThan(v1, v0)
        XCTAssertLessThan(v2, v1)
        XCTAssertLessThan(v3, v2)
    }
}
