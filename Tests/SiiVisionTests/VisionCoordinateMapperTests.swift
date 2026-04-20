import CoreGraphics
import XCTest
@testable import ICanSii_iOS

final class VisionCoordinateMapperTests: XCTestCase {
    func testRightOrientedVisionRoundTripPreservesUV() {
        let samples: [CGPoint] = [
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 0.9, y: 0.8)
        ]

        for uv in samples {
            let captureUV = VisionCoordinateMapper.rightOrientedVisionUVToCaptureUV(uv)
            let roundTrip = VisionCoordinateMapper.captureUVToRightOrientedVisionUV(captureUV)
            XCTAssertEqual(roundTrip.x, uv.x, accuracy: 1e-6)
            XCTAssertEqual(roundTrip.y, uv.y, accuracy: 1e-6)
        }
    }
}
