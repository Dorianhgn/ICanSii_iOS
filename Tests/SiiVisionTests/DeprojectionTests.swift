import CoreGraphics
import XCTest
import simd
@testable import ICanSii_iOS

final class DeprojectionTests: XCTestCase {
    private let K = simd_float3x3(
        SIMD3<Float>(1000, 0, 0),
        SIMD3<Float>(0, 1000, 0),
        SIMD3<Float>(960, 540, 1)
    )

    func testPrincipalPointAtOneMeterIsAlongNegativeZ() {
        let p = Deprojection.deproject(pixel: CGPoint(x: 960, y: 540), depthMeters: 1.0, intrinsics: K)
        XCTAssertEqual(p.x, 0, accuracy: 1e-4)
        XCTAssertEqual(p.y, 0, accuracy: 1e-4)
        XCTAssertEqual(p.z, -1.0, accuracy: 1e-4)
    }

    func testOffAxisPixelMapsProportionally() {
        let p = Deprojection.deproject(pixel: CGPoint(x: 1060, y: 540), depthMeters: 2.0, intrinsics: K)
        XCTAssertEqual(p.x, 0.2, accuracy: 1e-4)
        XCTAssertEqual(p.z, -2.0, accuracy: 1e-4)
    }
}
