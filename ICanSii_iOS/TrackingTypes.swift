import Foundation
import CoreGraphics
import simd

/// A 3D-reconstructed, ID-stable tracked object produced by TrackingManager.
struct TrackedObject3D: Identifiable, Equatable {
    let id: Int
    let classId: Int
    let className: String
    let confidence: Float

    /// Position in ARKit camera space, meters. +X right, +Y up, -Z forward.
    var position: SIMD3<Float>
    /// Velocity in ARKit camera space, m/s.
    var velocity: SIMD3<Float>
    /// Smoothed scalar speed in m/s.
    var speedSmoothed: Float

    /// Bounding box in normalized 0..1 Vision coordinates.
    var boundingBox: CGRect

    /// True when directly observed in the current frame.
    var inFOV: Bool
    /// True when extrapolated with no direct detection this frame.
    var isPredictive: Bool
    /// Monotonic timestamp of last direct observation.
    var lastSeenTimestamp: TimeInterval
    /// Monotonic timestamp of latest state update (direct or predictive).
    var updatedTimestamp: TimeInterval

    var distance: Float { simd_length(position) }
}

/// Detection enriched with mask-derived centroid and metric depth.
struct Detection2DWithDepth {
    /// Normalized detection box (0..1) in Vision image coordinates.
    let boundingBox: CGRect
    /// Mask centroid in normalized 0..1 Vision coordinates.
    let centroidUV: CGPoint
    /// Centroid converted to capture-resolution pixel coordinates.
    let centroidPx: CGPoint

    let classId: Int
    let className: String
    let confidence: Float

    /// 15th-percentile depth over active mask pixels in meters.
    let depthMeters: Float
}

enum BoundingBoxIoU {
    static func of(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        if inter.isNull || inter.width <= 0 || inter.height <= 0 { return 0 }

        let interArea = Float(inter.width * inter.height)
        let unionArea = Float(a.width * a.height + b.width * b.height) - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}
