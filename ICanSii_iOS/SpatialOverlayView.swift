import ARKit
import SwiftUI
import simd

struct SpatialOverlayView: View {
    @ObservedObject var tracking: TrackingManager
    @ObservedObject var arManager: ARManager

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(tracking.trackedObjects) { obj in
                    if let point = project(obj.position, viewSize: geo.size) {
                        markerView(for: obj)
                            .position(point)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(false)
    }

    private func project(_ cameraSpace: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        // Only project points in front of camera (-Z forward in ARKit).
        guard cameraSpace.z < -0.001 else { return nil }

        let K = arManager.latestIntrinsics
        let res = arManager.latestCaptureResolution
        guard res.x > 0, res.y > 0 else { return nil }

        let fx = K.columns.0.x
        let fy = K.columns.1.y
        let ppx = K.columns.2.x
        let ppy = K.columns.2.y

        let depth = -cameraSpace.z
        let u = fx * cameraSpace.x / depth + ppx
        let v = ppy - (fy * cameraSpace.y / depth)

        let captureUV = CGPoint(x: CGFloat(u) / CGFloat(res.x), y: CGFloat(v) / CGFloat(res.y))
        if captureUV.x < 0 || captureUV.x > 1 || captureUV.y < 0 || captureUV.y > 1 {
            return nil
        }

        let visionUV = VisionCoordinateMapper.captureUVToRightOrientedVisionUV(captureUV)
        let screen = VisionScreenTransform.rightOrientedVisionUVToScreenUV(
            visionUV,
            displayTransform: arManager.displayTransform
        )
        return CGPoint(x: screen.x * viewSize.width, y: screen.y * viewSize.height)
    }

    @ViewBuilder
    private func markerView(for obj: TrackedObject3D) -> some View {
        let color: Color = obj.isPredictive ? .orange : .green

        VStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
                .shadow(color: color.opacity(0.7), radius: 6)

            Text("#\(obj.id) \(obj.className) \(String(format: "%.1fm", obj.distance))")
                .font(.caption2.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}
