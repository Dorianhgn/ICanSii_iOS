import CoreGraphics
import XCTest
import simd
@testable import ICanSii_iOS

final class TrackingTypesTests: XCTestCase {
    func testIoUZeroWhenDisjoint() {
        let a = CGRect(x: 0, y: 0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)
        XCTAssertEqual(BoundingBoxIoU.of(a, b), 0, accuracy: 1e-6)
    }

    func testDistanceComputedFromPositionNorm() {
        let obj = TrackedObject3D(
            id: 1,
            classId: 0,
            className: "person",
            confidence: 1,
            position: SIMD3<Float>(3, 4, 0),
            velocity: .zero,
            speedSmoothed: 0,
            boundingBox: .zero,
            inFOV: true,
            isPredictive: false,
            lastSeenTimestamp: 0,
            updatedTimestamp: 0
        )

        XCTAssertEqual(obj.distance, 5, accuracy: 1e-6)
    }
}
