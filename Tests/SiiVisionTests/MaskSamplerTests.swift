import CoreGraphics
import CoreML
import XCTest
@testable import ICanSii_iOS

final class MaskSamplerTests: XCTestCase {
    private func makePrototypes(fill: Float) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 32, 160, 160]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<(32 * 160 * 160) {
            ptr[i] = fill
        }
        return arr
    }

    func testCentroidOfFullBboxIsApproxCenter() throws {
        let proto = try makePrototypes(fill: 1)
        let coeffs = [Float](repeating: 1, count: 32)

        let result = MaskSampler.assemble(
            prototypes: proto,
            coefficients: coeffs,
            bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
            depthWidth: 256,
            depthHeight: 192
        )

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.centroidUV.x ?? 0, 0.5, accuracy: 0.02)
        XCTAssertEqual(result?.centroidUV.y ?? 0, 0.5, accuracy: 0.02)
    }

    func testNoActivePixelsWhenNegative() throws {
        let proto = try makePrototypes(fill: 1)
        let coeffs = [Float](repeating: -10, count: 32)

        let result = MaskSampler.assemble(
            prototypes: proto,
            coefficients: coeffs,
            bbox: CGRect(x: 0, y: 0, width: 1, height: 1),
            depthWidth: 256,
            depthHeight: 192
        )

        XCTAssertNil(result)
    }

    func testBboxRestrictionIgnoresOutsidePixels() throws {
        let arr = try MLMultiArray(shape: [1, 32, 160, 160], dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)

        for c in 0..<32 {
            for ph in 0..<160 {
                for pw in 0..<160 {
                    let idx = c * 160 * 160 + ph * 160 + pw
                    ptr[idx] = (pw >= 80) ? 1.0 : -1.0
                }
            }
        }

        let coeffs = [Float](repeating: 1, count: 32)

        let leftResult = MaskSampler.assemble(
            prototypes: arr,
            coefficients: coeffs,
            bbox: CGRect(x: 0, y: 0, width: 0.5, height: 1),
            depthWidth: 256,
            depthHeight: 192
        )
        XCTAssertNil(leftResult)

        let rightResult = MaskSampler.assemble(
            prototypes: arr,
            coefficients: coeffs,
            bbox: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
            depthWidth: 256,
            depthHeight: 192
        )
        XCTAssertNotNil(rightResult)
        XCTAssertGreaterThan(rightResult?.centroidUV.x ?? 0, 0.5)
    }
}
