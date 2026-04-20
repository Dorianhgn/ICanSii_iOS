import Foundation
import simd

final class VestMappingEngine {
    struct Params {
        var distanceThreshold: Float = 4.0
        var intensityMin: Float = 0
        var intensityMax: Float = 1
        var directionDeadzone: Float = 0.12
        var offsideIntensityFactor: Float = 0.25
        var watchdogTimeout: TimeInterval = 0.5
    }

    private let params: Params
    private var lastDetectionTimestamp: TimeInterval?

    init(params: Params = Params()) {
        self.params = params
    }

    func map(objects: [TrackedObject3D], timestamp ts: TimeInterval) -> VestActivationState {
        if !objects.isEmpty {
            lastDetectionTimestamp = ts
        }

        if let last = lastDetectionTimestamp, ts - last > params.watchdogTimeout {
            return .allOff
        }

        let inRange = objects.filter { $0.distance <= params.distanceThreshold }
        guard let target = inRange.min(by: { $0.distance < $1.distance }) else {
            return .allOff
        }

        let dNorm = (params.distanceThreshold - target.distance) / params.distanceThreshold
        let dClamped = max(0, min(1, dNorm))
        let intensity = params.intensityMin + (params.intensityMax - params.intensityMin) * dClamped

        let isBack = target.position.z > 0
        // ARKit camera space is landscape-native; remap to portrait-logical axes.
        let logicalX = target.position.y
        let logicalY = -target.position.x

        if abs(logicalX) <= params.directionDeadzone {
            return makeState(
                primaryIntensity: intensity,
                offsideIntensity: intensity,
                primarySide: .left,
                alsoOtherSide: true,
                isBack: isBack,
                targetY: logicalY
            )
        }

        if logicalX > 0 {
            return makeState(
                primaryIntensity: intensity,
                offsideIntensity: intensity * params.offsideIntensityFactor,
                primarySide: .right,
                alsoOtherSide: false,
                isBack: isBack,
                targetY: logicalY
            )
        }

        return makeState(
            primaryIntensity: intensity,
            offsideIntensity: intensity * params.offsideIntensityFactor,
            primarySide: .left,
            alsoOtherSide: false,
            isBack: isBack,
            targetY: logicalY
        )
    }

    private func makeState(
        primaryIntensity: Float,
        offsideIntensity: Float,
        primarySide: VestCell.Side,
        alsoOtherSide: Bool,
        isBack: Bool,
        targetY: Float
    ) -> VestActivationState {
        var cells: [String: Float] = [:]

        let normalizedY = max(-1, min(1, targetY))
        let centerRowFloat = ((1 - normalizedY) * Float(VestLayout.rowsPerFace - 1)) / 2.0

        for cell in VestLayout.all where cell.isBack == isBack {
            let sideIntensity: Float
            if alsoOtherSide {
                sideIntensity = primaryIntensity
            } else if cell.side == primarySide {
                sideIntensity = primaryIntensity
            } else {
                sideIntensity = offsideIntensity
            }

            let dr = Float(cell.row) - centerRowFloat
            let sigma: Float = 1.1
            let gaussian = expf(-0.5 * (dr * dr) / (sigma * sigma))
            let value = max(0, min(1, sideIntensity * gaussian))

            if value > 1e-4 {
                cells[cell.id] = value
            }
        }

        return VestActivationState(cells: cells)
    }
}
