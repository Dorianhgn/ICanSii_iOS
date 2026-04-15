import CoreGraphics
import Foundation
import simd

enum Deprojection {
    /// Back-projects a capture-resolution pixel and metric depth into ARKit camera space.
    /// ARKit camera coordinates: +X right, +Y up, -Z forward.
    static func deproject(pixel: CGPoint, depthMeters z: Float, intrinsics K: simd_float3x3) -> SIMD3<Float> {
        let fx = K.columns.0.x
        let fy = K.columns.1.y
        let ppx = K.columns.2.x
        let ppy = K.columns.2.y

        guard fx != 0, fy != 0 else { return .zero }

        let x = (Float(pixel.x) - ppx) / fx * z
        let yImageDown = (Float(pixel.y) - ppy) / fy * z
        return SIMD3<Float>(x, -yImageDown, -z)
    }
}
