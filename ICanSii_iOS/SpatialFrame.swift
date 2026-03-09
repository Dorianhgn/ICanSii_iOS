import ARKit
import simd

/// Zero-copy container shared across render and AI branches.
struct SpatialFrame {
    let timestamp: TimeInterval
    let capturedImage: CVPixelBuffer
    let depthMap: CVPixelBuffer
    let intrinsics: simd_float3x3
    let cameraTransform: simd_float4x4
    let imageResolution: SIMD2<Int>
    let displayTransform: CGAffineTransform
}

enum SpatialDisplayMode: String, CaseIterable, Identifiable {
    case rgb = "RGB"
    case depth = "Depth"
    case livePointCloud = "PC Direct"
    case accumulatedPointCloud = "PC Cumulé"

    var id: String { rawValue }
}