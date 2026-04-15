import ARKit
import Combine
import CoreGraphics
import CoreML
import CoreVideo
import Foundation

final class TrackingManager: ObservableObject {
    static let allowedClassIDs: Set<Int> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 56, 57, 58, 59, 60, 72
    ]
    static let scoreThreshold: Float = 0.5

    @Published private(set) var trackedObjects: [TrackedObject3D] = []

    private let tracker = Tracker()
    private let processingQueue = DispatchQueue(label: "sii.tracking.processing", qos: .userInitiated)
    private var cancellables: Set<AnyCancellable> = []

    func bind(arManager: ARManager, visionManager: VisionManager) {
        _ = arManager // retained as API symmetry for caller wiring

        visionManager.$latestFrameOutput
            .compactMap { $0 }
            .receive(on: processingQueue)
            .sink { [weak self] output in
                self?.ingest(
                    detections: output.detections,
                    frame: output.spatialFrame,
                    prototypes: output.prototypes
                )
            }
            .store(in: &cancellables)
    }

    private func ingest(detections: [YoloDetection], frame: SpatialFrame, prototypes: MLMultiArray) {
        let captureW = CGFloat(frame.imageResolution.x)
        let captureH = CGFloat(frame.imageResolution.y)
        let depthW = CVPixelBufferGetWidth(frame.depthMap)
        let depthH = CVPixelBufferGetHeight(frame.depthMap)

        var enriched: [Detection2DWithDepth] = []
        enriched.reserveCapacity(detections.count)

        for det in detections {
            guard det.confidence >= Self.scoreThreshold else { continue }
            guard Self.allowedClassIDs.contains(det.classId) else { continue }
            guard det.maskCoefficients.count == MaskSampler.numChannels else { continue }

            guard let mask = MaskSampler.assemble(
                prototypes: prototypes,
                coefficients: det.maskCoefficients,
                bbox: det.boundingBox,
                depthWidth: depthW,
                depthHeight: depthH
            ) else {
                continue
            }

            guard let depth = DepthSampler.sample(
                depthMap: frame.depthMap,
                activePixels: mask.activePixels,
                percentile: 0.15
            ) else {
                continue
            }

            let px = VisionCoordinateMapper.capturePixel(
                fromVisionUV: mask.centroidUV,
                captureWidth: captureW,
                captureHeight: captureH
            )
            let className = VisionClassNames.name(for: det.classId, fallback: det.label)

            enriched.append(
                Detection2DWithDepth(
                    boundingBox: det.boundingBox,
                    centroidUV: mask.centroidUV,
                    centroidPx: px,
                    classId: det.classId,
                    className: className,
                    confidence: det.confidence,
                    depthMeters: depth
                )
            )
        }

        let out = tracker.step(
            detections: enriched,
            intrinsics: frame.intrinsics,
            timestamp: frame.timestamp
        )

        DispatchQueue.main.async { [weak self] in
            self?.trackedObjects = out
        }
    }
}

enum VisionClassNames {
    private static let names: [Int: String] = [
        0: "person",
        1: "bicycle",
        2: "car",
        3: "motorcycle",
        4: "airplane",
        5: "bus",
        6: "train",
        7: "truck",
        8: "boat",
        9: "traffic light",
        10: "fire hydrant",
        11: "stop sign",
        12: "parking meter",
        13: "bench",
        14: "bird",
        15: "cat",
        16: "dog",
        17: "horse",
        56: "chair",
        57: "couch",
        58: "potted plant",
        59: "bed",
        60: "dining table",
        72: "refrigerator"
    ]

    static func name(for id: Int, fallback: String) -> String {
        names[id] ?? fallback
    }
}
