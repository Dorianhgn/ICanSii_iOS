import CoreGraphics
import Foundation

enum VisionCoordinateMapper {
    /// Vision inference runs with `.right` orientation.
    /// Convert normalized Vision UV back to capture-image normalized UV.
    @inline(__always)
    static func rightOrientedVisionUVToCaptureUV(_ uv: CGPoint) -> CGPoint {
        CGPoint(x: uv.y, y: 1.0 - uv.x)
    }

    @inline(__always)
    static func capturePixel(fromVisionUV uv: CGPoint, captureWidth: CGFloat, captureHeight: CGFloat) -> CGPoint {
        let captureUV = rightOrientedVisionUVToCaptureUV(uv)
        return CGPoint(x: captureUV.x * captureWidth, y: captureUV.y * captureHeight)
    }

    @inline(__always)
    static func depthPixel(fromVisionUV uv: CGPoint, depthWidth: Int, depthHeight: Int) -> (col: Int, row: Int) {
        let captureUV = rightOrientedVisionUVToCaptureUV(uv)
        let col = min(depthWidth - 1, max(0, Int(captureUV.x * CGFloat(depthWidth))))
        let row = min(depthHeight - 1, max(0, Int(captureUV.y * CGFloat(depthHeight))))
        return (col, row)
    }
}