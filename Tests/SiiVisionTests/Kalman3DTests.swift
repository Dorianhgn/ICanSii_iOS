import XCTest
import simd
@testable import ICanSii_iOS

final class Kalman3DTests: XCTestCase {
    func testConvergesToConstantPosition() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        let p = SIMD3<Float>(1, 2, -3)

        for _ in 0..<50 {
            k.update(measurement: p, dt: 1.0 / 15.0)
        }

        XCTAssertEqual(simd_distance(k.position, p), 0, accuracy: 0.02)
        XCTAssertLessThan(simd_length(k.velocity), 0.05)
    }

    func testTracksLinearRampWithStableVelocity() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        let dt: Float = 1.0 / 15.0
        let v = SIMD3<Float>(0, 0, -1)

        for i in 0..<30 {
            let p = v * Float(i) * dt
            k.update(measurement: p, dt: dt)
        }

        XCTAssertEqual(k.velocity.z, -1.0, accuracy: 0.15)
    }

    func testRejectsSingleOutlier() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)

        for _ in 0..<20 {
            k.update(measurement: SIMD3<Float>(0, 0, -2), dt: 1.0 / 15.0)
        }
        k.update(measurement: SIMD3<Float>(0, 0, -10), dt: 1.0 / 15.0)

        XCTAssertLessThan(abs(k.position.z + 2), 1.5)
    }

    func testPredictOnlyDecaysVelocity() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        let dt: Float = 1.0 / 15.0

        for i in 0..<10 {
            let p = SIMD3<Float>(0, 0, Float(i) * -dt)
            k.update(measurement: p, dt: dt)
        }

        let v0 = k.velocity
        k.predict(dt: dt)
        k.applyVelocityDecay(0.85)

        XCTAssertEqual(simd_length(k.velocity), simd_length(v0) * 0.85, accuracy: 0.05)
    }
}
