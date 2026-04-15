import Foundation
import CoreVideo

enum DepthSampler {
    static let defaultPercentile: Float = 0.15

    /// Samples the 15th-percentile depth over active mask pixels.
    static func sample(
        depthMap: CVPixelBuffer,
        activePixels: [(col: Int, row: Int)],
        percentile: Float = defaultPercentile
    ) -> Float? {
        guard !activePixels.isEmpty else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        var samples: [Float] = []
        samples.reserveCapacity(activePixels.count)

        for pixel in activePixels {
            let col = pixel.col
            let row = pixel.row
            guard row >= 0, row < height, col >= 0, col < width else { continue }

            let rowPtr = baseAddress.advanced(by: row * bytesPerRow).assumingMemoryBound(to: Float32.self)
            let value = rowPtr[col]

            if value.isFinite && value > 0 && value < 10.0 {
                samples.append(value)
            }
        }

        guard !samples.isEmpty else { return nil }
        samples.sort()

        let p = min(max(percentile, 0), 1)
        let index = min(samples.count - 1, max(0, Int(Float(samples.count - 1) * p)))
        return samples[index]
    }
}
