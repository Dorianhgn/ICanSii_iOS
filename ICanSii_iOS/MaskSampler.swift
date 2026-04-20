import Foundation
import CoreGraphics
import CoreML
import Accelerate

enum MaskSampler {
    struct Result {
        let centroidUV: CGPoint
        let activePixels: [(col: Int, row: Int)]
    }

    static let protoSize = 160
    static let numChannels = 32
    static let maskThreshold: Float = 0.5

    static func assemble(
        prototypes: MLMultiArray,
        coefficients: [Float],
        bbox: CGRect,
        depthWidth: Int,
        depthHeight: Int
    ) -> Result? {
        guard depthWidth > 0, depthHeight > 0 else { return nil }
        guard coefficients.count == numChannels else { return nil }
        guard prototypes.dataType == .float32 else { return nil }
        guard prototypes.shape.count == 4 else { return nil }

        let shape = prototypes.shape.map { $0.intValue }
        guard shape[0] == 1, shape[1] == numChannels, shape[2] == protoSize, shape[3] == protoSize else {
            print("MaskSampler: unsupported prototype shape \(shape), expected [1, 32, 160, 160]")
            return nil
        }

        let ptr = prototypes.dataPointer.assumingMemoryBound(to: Float32.self)
        let chanStride = protoSize * protoSize

        // Clamp bbox to [0, 1].
        let clampedX0 = max(0.0, min(1.0, bbox.minX))
        let clampedY0 = max(0.0, min(1.0, bbox.minY))
        let clampedX1 = max(0.0, min(1.0, bbox.maxX))
        let clampedY1 = max(0.0, min(1.0, bbox.maxY))
        guard clampedX1 > clampedX0, clampedY1 > clampedY0 else { return nil }

        let pw0 = max(0, Int((clampedX0 * CGFloat(protoSize)).rounded(.down)))
        let ph0 = max(0, Int((clampedY0 * CGFloat(protoSize)).rounded(.down)))
        let pw1 = min(protoSize - 1, Int((clampedX1 * CGFloat(protoSize)).rounded(.up)) - 1)
        let ph1 = min(protoSize - 1, Int((clampedY1 * CGFloat(protoSize)).rounded(.up)) - 1)
        guard pw1 >= pw0, ph1 >= ph0 else { return nil }

        var activeProtoPixels: [(pw: Int, ph: Int)] = []
        activeProtoPixels.reserveCapacity((pw1 - pw0 + 1) * (ph1 - ph0 + 1) / 2)

        var sumX: Double = 0
        var sumY: Double = 0
        var count = 0

        for ph in ph0...ph1 {
            let rowBase = ph * protoSize
            for pw in pw0...pw1 {
                var dot: Float = 0
                vDSP_dotpr(
                    ptr.advanced(by: rowBase + pw), vDSP_Stride(chanStride),
                    coefficients, 1,
                    &dot, vDSP_Length(numChannels)
                )

                let prob = 1.0 / (1.0 + exp(-Double(dot)))
                if Float(prob) >= maskThreshold {
                    activeProtoPixels.append((pw: pw, ph: ph))
                    sumX += Double(pw) + 0.5
                    sumY += Double(ph) + 0.5
                    count += 1
                }
            }
        }

        guard count > 0 else { return nil }

        let centroidUV = CGPoint(
            x: (sumX / Double(count)) / Double(protoSize),
            y: (sumY / Double(count)) / Double(protoSize)
        )

        // Nearest-neighbor resample to depth-map resolution.
        var depthSet = Set<Int>()
        depthSet.reserveCapacity(activeProtoPixels.count)

        for p in activeProtoPixels {
            let u = (Double(p.pw) + 0.5) / Double(protoSize)
            let v = (Double(p.ph) + 0.5) / Double(protoSize)

            let depthPx = VisionCoordinateMapper.depthPixel(
                fromVisionUV: CGPoint(x: u, y: v),
                depthWidth: depthWidth,
                depthHeight: depthHeight
            )
            let col = depthPx.col
            let row = depthPx.row
            depthSet.insert(row * depthWidth + col)
        }

        let activePixels = depthSet.map { idx in
            (col: idx % depthWidth, row: idx / depthWidth)
        }

        return Result(centroidUV: centroidUV, activePixels: activePixels)
    }
}
