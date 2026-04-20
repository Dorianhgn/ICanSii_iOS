import CoreVideo
import XCTest
@testable import ICanSii_iOS

final class DepthSamplerTests: XCTestCase {
    private func makeFloatBuffer(width: Int, height: Int, fill: Float) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_DepthFloat32, attrs as CFDictionary, &out)

        let buf = out!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)

        for r in 0..<height {
            let row = base.advanced(by: r * bpr).assumingMemoryBound(to: Float32.self)
            for c in 0..<width {
                row[c] = fill
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    func test15thPercentileOverConstantBufferIsConstant() {
        let buf = makeFloatBuffer(width: 10, height: 10, fill: 2.5)
        let pixels = (0..<10).flatMap { row in
            (0..<10).map { col in (col: col, row: row) }
        }

        let d = DepthSampler.sample(depthMap: buf, activePixels: pixels)
        XCTAssertEqual(d ?? -1, 2.5, accuracy: 0.001)
    }

    func testRejectsZeroDepthPixels() {
        let buf = makeFloatBuffer(width: 10, height: 10, fill: 0)
        XCTAssertNil(DepthSampler.sample(depthMap: buf, activePixels: [(col: 5, row: 5)]))
    }

    func testNilWhenNoActivePixels() {
        let buf = makeFloatBuffer(width: 10, height: 10, fill: 1)
        XCTAssertNil(DepthSampler.sample(depthMap: buf, activePixels: []))
    }

    func test15thPercentilePicksCloserSurface() {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, 100, 1, kCVPixelFormatType_DepthFloat32, attrs as CFDictionary, &out)
        let buf = out!

        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: Float32.self)
        for i in 0..<15 { base[i] = 0.5 }
        for i in 15..<100 { base[i] = 3.0 }
        CVPixelBufferUnlockBaseAddress(buf, [])

        let pixels = (0..<100).map { (col: $0, row: 0) }
        let d = DepthSampler.sample(depthMap: buf, activePixels: pixels)
        XCTAssertNotNil(d)
        XCTAssertLessThan(d ?? 10, 1.0)
    }
}
