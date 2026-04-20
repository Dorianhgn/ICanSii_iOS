import CoreGraphics
import Foundation
import simd

final class Tracker {
    struct Params {
        var iouThreshold: Float = 0.3
        var centroidPxThreshold: Float = 80
        var predictionTimeout: TimeInterval = 1.0
        var velocityDecay: Float = 0.85
        var maxSpeedMps: Float = 6.0
        var kalman3DProcessNoisePos: Float = 1e-3
        var kalman3DProcessNoiseVel: Float = 5e-2
        var kalman3DMeasurementNoise: Float = 5e-3
    }

    private struct TrackState {
        let id: Int
        var classId: Int
        var className: String
        var confidence: Float

        var lastBoundingBox: CGRect
        var lastCentroidPx: CGPoint

        var kalman: Kalman3D
        var worldPosition: SIMD3<Float>
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var speedSmoothed: Float

        var lastSeenTs: TimeInterval
        var updatedTs: TimeInterval
        var isPredictive: Bool
    }

    private let params: Params
    private var states: [Int: TrackState] = [:]
    private var nextID = 1

    init(params: Params = Params()) {
        self.params = params
    }

    func step(
        detections: [Detection2DWithDepth],
        intrinsics K: simd_float3x3,
        cameraTransform: simd_float4x4,
        timestamp t: TimeInterval
    ) -> [TrackedObject3D] {
        // Build candidate matches.
        var candidates: [(trackID: Int, detIndex: Int, score: Float)] = []
        candidates.reserveCapacity(states.count * max(detections.count, 1))

        for (trackID, state) in states {
            for detIndex in detections.indices {
                let det = detections[detIndex]
                let iou = BoundingBoxIoU.of(state.lastBoundingBox, det.boundingBox)
                let dcx = Float(state.lastCentroidPx.x - det.centroidPx.x)
                let dcy = Float(state.lastCentroidPx.y - det.centroidPx.y)
                let dpx = hypotf(dcx, dcy)

                if iou >= params.iouThreshold || dpx <= params.centroidPxThreshold {
                    let centroidScore = max(0, 1 - (dpx / max(params.centroidPxThreshold, 1e-3)))
                    let score = max(iou, centroidScore)
                    candidates.append((trackID: trackID, detIndex: detIndex, score: score))
                }
            }
        }

        candidates.sort { $0.score > $1.score }

        var matchedTracks = Set<Int>()
        var matchedDetections = Set<Int>()

        for c in candidates {
            guard !matchedTracks.contains(c.trackID), !matchedDetections.contains(c.detIndex) else {
                continue
            }
            matchedTracks.insert(c.trackID)
            matchedDetections.insert(c.detIndex)
            updateTrack(id: c.trackID, with: detections[c.detIndex], intrinsics: K, cameraTransform: cameraTransform, timestamp: t)
        }

        // Create tracks for unmatched detections.
        for i in detections.indices where !matchedDetections.contains(i) {
            createTrack(from: detections[i], intrinsics: K, cameraTransform: cameraTransform, timestamp: t)
        }

        // Predict unmatched existing tracks, remove if stale.
        for trackID in Array(states.keys) where !matchedTracks.contains(trackID) {
            predictTrack(id: trackID, cameraTransform: cameraTransform, timestamp: t)
        }

        return states.values
            .map { state in
                TrackedObject3D(
                    id: state.id,
                    classId: state.classId,
                    className: state.className,
                    confidence: state.confidence,
                    position: state.position,
                    velocity: state.velocity,
                    speedSmoothed: state.speedSmoothed,
                    boundingBox: state.lastBoundingBox,
                    inFOV: !state.isPredictive,
                    isPredictive: state.isPredictive,
                    lastSeenTimestamp: state.lastSeenTs,
                    updatedTimestamp: state.updatedTs
                )
            }
            .sorted { $0.id < $1.id }
    }

    private func createTrack(from det: Detection2DWithDepth, intrinsics K: simd_float3x3, cameraTransform: simd_float4x4, timestamp t: TimeInterval) {
        var kalman = Kalman3D(
            qPos: params.kalman3DProcessNoisePos,
            qVel: params.kalman3DProcessNoiseVel,
            rMeas: params.kalman3DMeasurementNoise
        )

        let pLocal = Deprojection.deproject(pixel: det.centroidPx, depthMeters: det.depthMeters, intrinsics: K)
        
        // Convert Local to World
        let p4 = cameraTransform * SIMD4<Float>(pLocal.x, pLocal.y, pLocal.z, 1.0)
        let pWorld = SIMD3<Float>(p4.x, p4.y, p4.z)
        
        kalman.seed(position: pWorld)

        let state = TrackState(
            id: nextID,
            classId: det.classId,
            className: det.className,
            confidence: det.confidence,
            lastBoundingBox: det.boundingBox,
            lastCentroidPx: det.centroidPx,
            kalman: kalman,
            worldPosition: pWorld, 
            position: pLocal, // Output in camera space for SpatialOverlayView
            velocity: .zero,
            speedSmoothed: 0,
            lastSeenTs: t,
            updatedTs: t,
            isPredictive: false
        )

        states[nextID] = state
        nextID += 1
    }

    private func updateTrack(id: Int, with det: Detection2DWithDepth, intrinsics K: simd_float3x3, cameraTransform: simd_float4x4, timestamp t: TimeInterval) {
        guard var state = states[id] else { return }

        let dt = Float(max(t - state.updatedTs, 1e-3))
        let pLocal = Deprojection.deproject(pixel: det.centroidPx, depthMeters: det.depthMeters, intrinsics: K)
        
        // Local to World
        let p4 = cameraTransform * SIMD4<Float>(pLocal.x, pLocal.y, pLocal.z, 1.0)
        let pWorld = SIMD3<Float>(p4.x, p4.y, p4.z)

        // Filter runs strictly in stationary world space
        state.kalman.update(measurement: pWorld, dt: dt)

        let vWorld = state.kalman.velocity
        let speed = min(simd_length(vWorld), params.maxSpeedMps)

        state.classId = det.classId
        state.className = det.className
        state.confidence = det.confidence
        state.lastBoundingBox = det.boundingBox
        state.lastCentroidPx = det.centroidPx

        state.worldPosition = state.kalman.position
        
        // Convert smoothed world position back to Local camera space for the UI
        let invTransform = cameraTransform.inverse
        let pLocal4 = invTransform * SIMD4<Float>(state.worldPosition.x, state.worldPosition.y, state.worldPosition.z, 1.0)
        state.position = SIMD3<Float>(pLocal4.x, pLocal4.y, pLocal4.z)
        
        state.velocity = vWorld
        state.speedSmoothed = speed

        state.lastSeenTs = t
        state.updatedTs = t
        state.isPredictive = false

        states[id] = state
    }

    private func predictTrack(id: Int, cameraTransform: simd_float4x4, timestamp t: TimeInterval) {
        guard var state = states[id] else { return }

        let age = t - state.lastSeenTs
        if age > params.predictionTimeout {
            states.removeValue(forKey: id)
            return
        }

        let dt = Float(max(t - state.updatedTs, 1e-3))
        state.kalman.predict(dt: dt)
        state.kalman.applyVelocityDecay(params.velocityDecay)

        state.worldPosition = state.kalman.position
        
        // World to Local for UI
        let invTransform = cameraTransform.inverse
        let pLocal4 = invTransform * SIMD4<Float>(state.worldPosition.x, state.worldPosition.y, state.worldPosition.z, 1.0)
        state.position = SIMD3<Float>(pLocal4.x, pLocal4.y, pLocal4.z)
        
        state.velocity = state.kalman.velocity
        state.speedSmoothed = min(simd_length(state.velocity), params.maxSpeedMps)
        state.updatedTs = t
        state.isPredictive = true

        states[id] = state
    }
}
