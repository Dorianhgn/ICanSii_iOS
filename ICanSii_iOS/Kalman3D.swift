import Foundation
import simd

/// Constant-velocity 3D Kalman filter with independent per-axis 2-state filters.
/// State per axis: [position, velocity].
struct Kalman3D {
    private struct AxisFilter {
        var xPos: Float = 0
        var xVel: Float = 0

        // Covariance matrix entries for [[p00, p01], [p10, p11]].
        var p00: Float = 1
        var p01: Float = 0
        var p10: Float = 0
        var p11: Float = 1

        mutating func predict(dt: Float, qPos: Float, qVel: Float) {
            xPos += xVel * dt

            let oldP00 = p00
            let oldP01 = p01
            let oldP10 = p10
            let oldP11 = p11

            // F = [[1, dt], [0, 1]], Q = diag(qPos, qVel)
            p00 = oldP00 + dt * (oldP01 + oldP10) + dt * dt * oldP11 + qPos
            p01 = oldP01 + dt * oldP11
            p10 = oldP10 + dt * oldP11
            p11 = oldP11 + qVel
        }

        mutating func update(z: Float, rMeas: Float) {
            let innovation = z - xPos
            let s = p00 + rMeas
            if s <= 1e-8 { return }

            let k0 = p00 / s
            let k1 = p10 / s

            xPos += k0 * innovation
            xVel += k1 * innovation

            // Keep covariance update simple/stable for scalar measurement H=[1,0].
            let newP00 = (1 - k0) * p00
            let newP01 = (1 - k0) * p01
            let newP10 = p10 - k1 * p00
            let newP11 = p11 - k1 * p01

            p00 = max(newP00, 1e-9)
            p01 = newP01
            p10 = newP10
            p11 = max(newP11, 1e-9)
        }
    }

    private var x = AxisFilter()
    private var y = AxisFilter()
    private var z = AxisFilter()

    private let qPos: Float
    private let qVel: Float
    private let rMeas: Float

    private var initialized = false

    private(set) var position: SIMD3<Float> = .zero
    private(set) var velocity: SIMD3<Float> = .zero

    init(qPos: Float, qVel: Float, rMeas: Float) {
        self.qPos = qPos
        self.qVel = qVel
        self.rMeas = rMeas
    }

    mutating func seed(position p: SIMD3<Float>) {
        x.xPos = p.x
        y.xPos = p.y
        z.xPos = p.z

        x.xVel = 0
        y.xVel = 0
        z.xVel = 0

        initialized = true
        syncOutput()
    }

    mutating func predict(dt: Float) {
        guard initialized else { return }
        let clampedDt = max(dt, 1e-3)

        x.predict(dt: clampedDt, qPos: qPos, qVel: qVel)
        y.predict(dt: clampedDt, qPos: qPos, qVel: qVel)
        z.predict(dt: clampedDt, qPos: qPos, qVel: qVel)

        syncOutput()
    }

    mutating func applyVelocityDecay(_ k: Float) {
        guard initialized else { return }
        let decay = max(0, min(k, 1))

        x.xVel *= decay
        y.xVel *= decay
        z.xVel *= decay

        syncOutput()
    }

    mutating func update(measurement m: SIMD3<Float>, dt: Float) {
        if !initialized {
            seed(position: m)
            return
        }

        predict(dt: dt)

        x.update(z: m.x, rMeas: rMeas)
        y.update(z: m.y, rMeas: rMeas)
        z.update(z: m.z, rMeas: rMeas)

        syncOutput()
    }

    private mutating func syncOutput() {
        position = SIMD3<Float>(x.xPos, y.xPos, z.xPos)
        velocity = SIMD3<Float>(x.xVel, y.xVel, z.xVel)
    }
}
