import CoreGraphics
import Foundation

enum VisionScreenTransform {
    @inline(__always)
    static func rightOrientedVisionUVToScreenUV(_ uv: CGPoint, displayTransform: CGAffineTransform) -> CGPoint {
        let inverted = displayTransform.inverted()
        let captureUV = CGPoint(x: 1.0 - uv.y, y: uv.x)
        return captureUV.applying(inverted)
    }
}

extension CGRect {
    func transformedToScreen(using displayTransform: CGAffineTransform) -> CGRect {
        let corners = [
            CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
            CGPoint(x: minX, y: maxY), CGPoint(x: maxX, y: maxY)
        ]

        var minSx: CGFloat = 10_000
        var minSy: CGFloat = 10_000
        var maxSx: CGFloat = -10_000
        var maxSy: CGFloat = -10_000

        for corner in corners {
            let screenUV = VisionScreenTransform.rightOrientedVisionUVToScreenUV(
                corner,
                displayTransform: displayTransform
            )
            minSx = min(minSx, screenUV.x)
            minSy = min(minSy, screenUV.y)
            maxSx = max(maxSx, screenUV.x)
            maxSy = max(maxSy, screenUV.y)
        }

        return CGRect(x: minSx, y: minSy, width: maxSx - minSx, height: maxSy - minSy)
    }
}
