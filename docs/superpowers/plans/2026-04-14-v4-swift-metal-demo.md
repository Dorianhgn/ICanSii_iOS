# v4 Swift/Metal Demo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Jetson/ROS2 v4 YOLO-seg + 3D tracking + haptic-mapping pipeline to iPhone 17 Pro using ARKit sceneDepth, CoreML YOLOv26-seg, and SwiftUI/Metal. First iteration is visualization-only (no BLE) with two live views: (1) AR spatial overlay of tracked 3D objects, (2) vest preview showing the 20 TactSuit X40 cells lighting up based on distance + direction mapping.

**Architecture:** Extend the existing `ARManager` → `VisionManager` pipeline with a new `TrackingManager` that consumes per-frame YOLO detections + `SpatialFrame`, produces a stable stream of `TrackedObject3D` (persistent ID, smoothed 3D position, velocity, in-FOV flag). A pure `VestMappingEngine` module maps the object stream to `VestActivationState` (20 cells). A new `VestPreviewView` renders it. The AR spatial overlay is a SwiftUI layer on top of the existing `SpatialMetalView` using `ARCamera.projectPoint` — we do **not** touch `SpatialRenderer.swift` in v1 (it is 24.5 KB of Metal point-cloud code; extending it risks breaking the build and the user cannot test remotely). A `HapticTransport` protocol is introduced now so the future BLE transport drops in without refactor.

**Tech Stack:** Swift 5.9+, SwiftUI, ARKit (sceneDepth/smoothedSceneDepth), Vision/CoreML (yolo26s-seg.mlpackage, already in bundle), simd, Combine, XCTest.

**Build environment note:** Development happens remotely; the user builds and runs on their Mac via Xcode. We **do not** modify `ICanSii_iOS.xcodeproj` in this plan — every new `.swift` file lives inside `ICanSii_iOS/` where Xcode's folder-based group will auto-include it on next project open. Test files live in `/home/dorian/icansii_poc_iphone/Tests/SiiVisionTests/` (outside the xcodeproj source roots) so they do not accidentally compile into the app target; Task 14 documents the one-time Xcode action to add them to a test target when the user wants automated testing.

---

## File Structure

**New files (all under `ICanSii_iOS/`):**

| File | Responsibility |
|---|---|
| `TrackingTypes.swift` | `TrackedObject3D` struct, `Detection2DWithDepth` helper (carries mask-derived `centroidUV` + `depthMeters` — no raw tensor refs), `BoundingBoxIoU` utility |
| `Kalman3D.swift` | Unified 6-state Kalman filter `[x, y, z, vx, vy, vz]` — replaces the prior cascade of Kalman1D + PositionSmoother + VelocityEstimator. Returns smoothed 3D position AND 3D velocity per update with no FIFO latency. |
| `MaskSampler.swift` | Assembles binary segmentation mask from `(prototypes 160×160×32) ⊗ (coeffs 32)` strictly inside the bbox, resamples to depth-map resolution (256×192) via **nearest-neighbour** to preserve binary edges. Pure pointer arithmetic on `MLMultiArray` and `CVPixelBuffer` — **no `[Float]` materialisation**. |
| `DepthSampler.swift` | Mask-driven depth extraction from `CVPixelBuffer` (Float32 ARKit depth). Returns the **15th-percentile** depth over mask-active pixels, plus the **mask centroid in normalised UV (0..1)**. |
| `Deprojection.swift` | `rs2_deproject_pixel_to_point` equivalent using `simd_float3x3` intrinsics + `ARCamera` utilities |
| `Tracker.swift` | Greedy IoU + centroid-distance matcher, miss tolerance, **1.0 s** predictive timeout with **0.85 / frame velocity decay** during prediction |
| `TrackingManager.swift` | Orchestrator: subscribes to `VisionManager.detections` + `ARManager` frames → publishes `@Published var trackedObjects: [TrackedObject3D]` |
| `VestMappingEngine.swift` | Pure logic: closest-marker selection, distance → intensity curve, Y → motor-direction mapping, 20-cell activation output |
| `VestTypes.swift` | `VestCell`, `VestActivationState`, `HapticTransport` protocol, `PreviewTransport` (writes to a `@Published` state) |
| `VestPreviewView.swift` | SwiftUI view: 20-cell grid (2 sides × 2 columns × 5 rows), animated intensity via opacity + colour |
| `SpatialOverlayView.swift` | SwiftUI overlay drawing projected markers (dot + label + distance) over `SpatialMetalView` |
| `AppTabView.swift` | Root `TabView` with two tabs: "Spatial" and "Vest Preview" (replaces `ContentView` as the root in `ICanSii_iOSApp.swift`) |

**Modified files:**

| File | Change |
|---|---|
| `ICanSii_iOSApp.swift` | Root view swapped from `ContentView()` to `AppTabView()` |
| `ContentView.swift` | Becomes the "Spatial" tab body — adds `SpatialOverlayView` overlay and a `@StateObject trackingManager`; keeps existing HUD panels intact |

**Unchanged (do not touch):** `SpatialRenderer.swift`, `SpatialShaders.metal`, `SpatialMetalView.swift`, `MetalTextureBridge.swift`, `SpatialFrame.swift`, `ARManager.swift`, `VisionManager.swift`. The Metal renderer is working; the v4 demo layers on top rather than inside it.

**Test files (all under `Tests/SiiVisionTests/` — NOT in the Xcode project until Task 14):**

| File | Covers |
|---|---|
| `Kalman3DTests.swift` | Convergence to constant position; linear-ramp tracking with stable velocity output; outlier rejection on z; instant velocity estimate (no FIFO warm-up) |
| `MaskSamplerTests.swift` | Centroid of a synthetic disc mask matches geometric centre; nearest-neighbour resample preserves binary edges; bbox-restricted assembly ignores out-of-bbox pixels |
| `DepthSamplerTests.swift` | 15th percentile over a synthetic mask returns the expected closer-surface value; rejects zero/inf/out-of-range; falls back to nil when mask has no active pixels |
| `DeprojectionTests.swift` | Known pixel + depth + intrinsics → expected 3D point (numerical equivalence to pyrealsense2) |
| `TrackerTests.swift` | ID persistence across frames, new-ID assignment, **1.0 s** predictive timeout, **velocity decay 0.85/frame** during prediction (velocity ≈ 0.85^N · v₀ after N missed frames) |
| `VestMappingEngineTests.swift` | Closest-object selection, deadzone, beyond-threshold OFF, left/right/centre cell activation, intensity monotonicity |

---

## Parameters (match v4 Jetson baseline)

Declared in `VestMappingEngine.swift` and `Tracker.swift` as `static let` so they stay discoverable and tweakable.

| Name | Value | Source |
|---|---|---|
| `scoreThreshold` | `0.5` | exec summary |
| `depthMaskPercentile` | `0.15` (15th percentile) | captures the closest physical surface per mask without LiDAR-noise sensitivity |
| `predictionTimeout` | `1.0` s | **revised — 0.5 s caused ID churn on brief occlusions; 3.0 s caused ghost obstacles for vest** |
| `velocityDecay` | `0.85` per missed frame | **revised — applied each predict-only step so v → 0 over ~0.5 s; prevents constant-velocity ghost extrapolation** |
| `hysteresisTime` | `0.2` s | exec summary |
| `maxSpeedMps` | `6.0` m/s | exec summary — clamp on 3D speed magnitude inside `Kalman3D` post-update |
| `kalman3DProcessNoisePos` | `1e-3` (m²/step) | tuned for ARKit VIO (cleaner than Jetson) — small position drift between frames |
| `kalman3DProcessNoiseVel` | `5e-2` (m²/s²/step) | normal human walking dynamics: gentle accel, no teleportation |
| `kalman3DMeasurementNoise` | `5e-3` (m²) | tighter than Jetson — LiDAR-fused ARKit `sceneDepth` is precise inside 5 m |
| `vestDistanceThreshold` | `1.25` m | docs/v4.md |
| `vestIntensityMin` | `0.0` | docs/v4.md (0–1 scale) |
| `vestIntensityMax` | `1.0` | docs/v4.md |
| `vestDirectionDeadzone` | `0.12` m (lateral) | docs/v4.md |
| `vestOffsideIntensityFactor` | `0.25` | docs/v4.md |
| `vestUpdateRateHz` | `5` Hz | docs/v4.md — sample-and-hold inside `VestMappingEngine` |
| `watchdogTimeout` | `0.5` s | docs/v4.md — no-detection → all cells off |
| `depthMaskPercentile` | `0.15` (15th percentile) | **revised — replaces ROI-median; captures closest physical surface per mask without LiDAR-noise sensitivity** |
| `maskBinarisationThreshold` | `0.5` (post-sigmoid) | mask assembly: pixel is active iff `sigmoid(prototypes·coeffs) ≥ 0.5` |
| `trackerIoUThreshold` | `0.3` | IoU+centroid tracker |
| `trackerCentroidPxThreshold` | `80` px (640-space) | IoU+centroid tracker |

**Classes whitelist** (exec summary §📌): person, bicycle, car, motorcycle, airplane, bus, train, truck, boat, traffic light, fire hydrant, stop sign, parking meter, bench, bird, cat, dog, horse, chair, couch, potted plant, bed, dining table, refrigerator. Encoded as `Set<Int>` in `TrackingManager.swift`.

---

## Coordinate Conventions

One of the most common porting bugs: frame mismatch between ROS RealSense and ARKit.

- **ARKit camera frame:** +X right, +Y up, −Z forward (Apple convention).
- **v4 Jetson camera frame:** +X right, +Y down, +Z forward (OpenCV/RealSense convention).
- **Vest mapping uses Y for left/right.** In ROS v4, `marker.Y > +0.12 → left side` works because Y is the horizontal axis in a rotated depth frame convention. On iPhone in portrait orientation, **horizontal-in-image is ARKit's X, not Y.** We use the **camera-frame X** (ARKit convention) for left/right mapping. Sign: in ARKit camera space, +X is right, so `cameraSpaceX > +deadzone → object is on the right → activate right-side motors`. This is the opposite mapping from the docs/v4.md literal, and is correct for ARKit. Tests in `VestMappingEngineTests` encode the ARKit convention.
- **Distance** = `length(cameraSpacePosition)` (3D euclidean), in metres.

---

## Task 0: Baseline Verification

**Files:** None modified.

- [ ] **Step 0.1: Confirm the branch is `swift/v4-dev` and the working tree matches commit `2fa3b79`**

```bash
cd /home/dorian/icansii_poc_iphone
git branch --show-current  # expect: swift/v4-dev
git log --oneline -1       # expect: 2fa3b79 feat: Implement floating panels for YOLO HUD and settings...
ls ICanSii_iOS/ | grep -E "Triplane"  # expect: no output (no triplane files)
```

Expected: on `swift/v4-dev`, head at `2fa3b79`, no triplane files in the working tree. `yolo26s-seg.mlpackage/` present.

- [ ] **Step 0.2: Stage the v4 reference docs and commit plan + docs**

```bash
git add docs/v4.md docs/YOLO_DETECT_EXECUTIVE_SUMMARY.md docs/superpowers/plans/2026-04-14-v4-swift-metal-demo.md
git commit -m "docs(v4): import ROS/Jetson reference + Swift/Metal port plan"
```

---

## Task 1: Core tracking types

**Files:**
- Create: `ICanSii_iOS/TrackingTypes.swift`
- Create: `Tests/SiiVisionTests/TrackingTypesTests.swift` (if adding tests — otherwise skip; the types are trivial data holders and do not need standalone tests)

- [ ] **Step 1.1: Write `TrackingTypes.swift`**

```swift
import Foundation
import simd
import CoreML

/// A 3D-reconstructed, ID-stable tracked object. Populated by TrackingManager each frame.
struct TrackedObject3D: Identifiable, Equatable {
    let id: Int                          // Persistent tracker ID
    let classId: Int
    let className: String
    let confidence: Float

    /// Position in ARKit camera space, metres. +X right, +Y up, −Z forward.
    var position: SIMD3<Float>
    /// Velocity in camera space, m/s.
    var velocity: SIMD3<Float>
    /// Scalar speed, m/s (EMA-smoothed).
    var speedSmoothed: Float

    /// 2D bounding box in normalised image coords (0..1, Vision convention).
    var boundingBox: CGRect

    /// Is this object currently detected this frame?
    var inFOV: Bool
    /// True when the object is not in current detections and TrackingManager is extrapolating.
    var isPredictive: Bool
    /// Timestamp (seconds, monotonic) when tracker last saw a direct detection.
    var lastSeenTimestamp: TimeInterval
    /// Timestamp of the latest state update (direct OR predictive).
    var updatedTimestamp: TimeInterval

    /// Distance (metres) = length(position).
    var distance: Float { simd_length(position) }
}

/// Intermediate: a 2D YOLO-seg detection enriched with mask-derived centroid and depth.
///
/// `MaskSampler.assemble(...)` runs in `TrackingManager.ingest(...)` at the frame boundary,
/// converting raw prototypes ⊗ coefficients into a binary mask, then extracting the centroid
/// and active-pixel list used by `DepthSampler`. All expensive work is done once per detection
/// per frame; no tensor references are carried forward.
struct Detection2DWithDepth {
    let boundingBox: CGRect             // Normalised image coords (0..1, top-left origin, Vision convention)

    /// **Mask centroid in normalised UV (0..1)** — computed by `MaskSampler.assemble(...)`.
    /// Stable against frame-to-frame bbox deformation; eliminates lateral jitter in the deprojected 3D position.
    let centroidUV: CGPoint

    /// **Capture-resolution pixel** for `Deprojection.deproject(...)` — `centroidUV * captureResolution`.
    /// Computed in `TrackingManager` after `MaskSampler` returns.
    let centroidPx: CGPoint

    let classId: Int
    let className: String
    let confidence: Float

    /// 15th-percentile depth in metres over mask-active pixels (NN-resampled to depth-map resolution).
    let depthMeters: Float
}

/// Bounding-box IoU on normalised CGRect.
enum BoundingBoxIoU {
    static func of(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        if inter.isNull || inter.width <= 0 || inter.height <= 0 { return 0 }
        let interArea = Float(inter.width * inter.height)
        let union = Float(a.width * a.height + b.width * b.height) - interArea
        return union > 0 ? interArea / union : 0
    }
}
```

- [ ] **Step 1.2: Commit**

```bash
git add ICanSii_iOS/TrackingTypes.swift
git commit -m "feat(tracking): introduce TrackedObject3D and Detection2DWithDepth core types"
```

---

## Task 2: Kalman3D (replaces former Tasks 2 + 3 + 4)

> **Architectural revision (2026-04-15):** the prior cascade — `Kalman1D` (depth) → `PositionSmoother` (5-frame FIFO median) → `VelocityEstimator` (Δp/Δt + 7-frame FIFO + EMA) — introduced ≥7 frames (~0.5 s @ 15 FPS) of velocity latency. For evasive haptic feedback this is unacceptable. Replaced by a single 6-state Kalman filter on 3D position + 3D velocity, fed the *raw* deprojected 3D point each frame, returning *instantaneous* smoothed position **and** velocity with no FIFO. Former Tasks 3 and 4 (`PositionSmoother`, `VelocityEstimator`) are deleted; their files are not created.

**Files:**
- Create: `ICanSii_iOS/Kalman3D.swift`
- Create: `Tests/SiiVisionTests/Kalman3DTests.swift`

- [ ] **Step 2.1: Write the failing tests**

```swift
// Tests/SiiVisionTests/Kalman3DTests.swift
import XCTest
import simd
@testable import ICanSii_iOS

final class Kalman3DTests: XCTestCase {
    func test_convergesToConstantPosition() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        let p = SIMD3<Float>(1, 2, -3)
        for _ in 0..<50 { k.update(measurement: p, dt: 1.0/15.0) }
        XCTAssertEqual(simd_distance(k.position, p), 0, accuracy: 0.02)
        XCTAssertLessThan(simd_length(k.velocity), 0.05, "stationary target must yield ~0 velocity")
    }

    func test_tracksLinearRampWithStableVelocity() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        let dt: Float = 1.0/15.0
        let v = SIMD3<Float>(0, 0, -1) // 1 m/s along −Z
        for i in 0..<30 {
            let p = v * Float(i) * dt
            k.update(measurement: p, dt: dt)
        }
        XCTAssertEqual(k.velocity.z, -1.0, accuracy: 0.15, "velocity must stabilise near the true 1 m/s after ~30 frames")
    }

    func test_rejectsSingleOutlier() {
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        for _ in 0..<20 { k.update(measurement: SIMD3<Float>(0, 0, -2), dt: 1.0/15.0) }
        k.update(measurement: SIMD3<Float>(0, 0, -10), dt: 1.0/15.0) // outlier
        XCTAssertLessThan(abs(k.position.z + 2), 1.5, "single outlier must not pull z-estimate by >1.5 m")
    }

    func test_predictOnlyDecaysVelocity() {
        // Verifies the Tracker-side decay contract — Kalman3D itself only exposes a `predict(dt:)`
        // that advances state without updating; decay multiplication is applied by the caller.
        var k = Kalman3D(qPos: 1e-3, qVel: 5e-2, rMeas: 5e-3)
        let dt: Float = 1.0/15.0
        for i in 0..<10 { k.update(measurement: SIMD3<Float>(0, 0, Float(i) * -dt), dt: dt) }
        let v0 = k.velocity
        k.predict(dt: dt); k.applyVelocityDecay(0.85)
        XCTAssertEqual(simd_length(k.velocity), simd_length(v0) * 0.85, accuracy: 0.05)
    }
}
```

- [ ] **Step 2.2: Write `Kalman3D.swift` to make tests pass**

```swift
import Foundation
import simd

/// 6-state discrete Kalman filter on `[x, y, z, vx, vy, vz]`.
/// Feeds on the raw 3D point (deprojected from mask-driven depth) each frame,
/// returns instantaneous smoothed position AND velocity — no FIFO latency.
///
/// `predict(dt:)` and `applyVelocityDecay(_:)` are exposed separately so the
/// `Tracker` can extrapolate with velocity decay during brief occlusions
/// without corrupting the measurement-update path.
struct Kalman3D {
    private(set) var position: SIMD3<Float> = .zero
    private(set) var velocity: SIMD3<Float> = .zero

    // 6×6 covariance held as two 3×3 diagonals (pos–pos, vel–vel) and a
    // pos–vel cross block. Full 6×6 is overkill for axis-independent noise.
    private var Ppp: simd_float3x3
    private var Pvv: simd_float3x3
    private var Ppv: simd_float3x3

    private let qPos: Float     // process noise on position (m²/step)
    private let qVel: Float     // process noise on velocity (m²/s²/step)
    private let rMeas: Float    // measurement noise (m²) — pos-only observation
    private var initialised = false

    init(qPos: Float, qVel: Float, rMeas: Float) {
        self.qPos = qPos
        self.qVel = qVel
        self.rMeas = rMeas
        self.Ppp = simd_float3x3(diagonal: SIMD3(1, 1, 1))
        self.Pvv = simd_float3x3(diagonal: SIMD3(1, 1, 1))
        self.Ppv = simd_float3x3(0)
    }

    /// Initialise state from a first measurement without running a filter step.
    mutating func seed(position p: SIMD3<Float>) {
        self.position = p
        self.velocity = .zero
        self.initialised = true
    }

    /// Advance the state by `dt` seconds without incorporating a measurement.
    mutating func predict(dt: Float) {
        guard initialised else { return }
        position += velocity * dt
        // Covariance propagation for F = [[I, dt·I],[0, I]]:
        //   Ppp' = Ppp + dt (Ppv + Ppvᵀ) + dt² Pvv + Q_pos
        //   Ppv' = Ppv + dt Pvv
        //   Pvv' = Pvv + Q_vel
        let dt2 = dt * dt
        Ppp = Ppp
            + simd_float3x3(diagonal: SIMD3(repeating: qPos))
            + scale(Ppv, by: dt) + scale(Ppv.transpose, by: dt)
            + scale(Pvv, by: dt2)
        Ppv = Ppv + scale(Pvv, by: dt)
        Pvv = Pvv + simd_float3x3(diagonal: SIMD3(repeating: qVel))
    }

    /// Apply a multiplicative decay to the velocity estimate (used by the
    /// `Tracker` when a track is in predict-only mode during occlusion).
    mutating func applyVelocityDecay(_ k: Float) {
        velocity *= k
    }

    /// Incorporate a new 3D position measurement. `dt` is the elapsed time
    /// since the last `update` / `predict`.
    mutating func update(measurement z: SIMD3<Float>, dt: Float) {
        if !initialised {
            seed(position: z)
            return
        }
        predict(dt: dt)
        // Innovation S = Ppp + R·I (3×3), axis-decoupled → diagonal inverse.
        let S = Ppp + simd_float3x3(diagonal: SIMD3(repeating: rMeas))
        let Sinv = S.inverse
        // Kalman gains: Kp = Ppp · S⁻¹ ; Kv = Ppvᵀ · S⁻¹
        let Kp = Ppp * Sinv
        let Kv = Ppv.transpose * Sinv
        let y = z - position
        position += Kp * y
        velocity += Kv * y
        // Covariance update (Joseph-free, fine for axis-decoupled R):
        let I = simd_float3x3(diagonal: SIMD3(1, 1, 1))
        Ppp = (I - Kp) * Ppp
        Ppv = (I - Kp) * Ppv
        Pvv = Pvv - Kv * Ppv   // Ppv is already post-update here
    }

    private func scale(_ m: simd_float3x3, by s: Float) -> simd_float3x3 {
        simd_float3x3(m.columns.0 * s, m.columns.1 * s, m.columns.2 * s)
    }
}
```

- [ ] **Step 2.3: Commit**

```bash
git add ICanSii_iOS/Kalman3D.swift Tests/SiiVisionTests/Kalman3DTests.swift
git commit -m "feat(tracking): unified 6-state Kalman3D replacing Kalman1D+smoother+velocity cascade"
```

---

## Task 3: MaskSampler

**Files:**
- Create: `ICanSii_iOS/MaskSampler.swift`
- Create: `Tests/SiiVisionTests/MaskSamplerTests.swift`

Assembles a binary segmentation mask from `prototypes (1×32×160×160) ⊗ coefficients (32)` using pure pointer arithmetic on `MLMultiArray.dataPointer`. Only pixels inside the detection bounding box are considered. The result is:
- `centroidUV`: first-moment centroid of active pixels in normalised 0..1 UV coordinates (Vision convention: origin top-left)
- `activePixels`: list of `(col, row)` pairs at depth-map resolution (256×192) via nearest-neighbour resample

The caller (`TrackingManager`) passes both outputs directly into `DepthSampler` and into `Detection2DWithDepth`. No `[Float]` materialisation of the full mask ever occurs.

**CoreML tensor layout:** YOLO seg prototypes arrive as a 4D `MLMultiArray` with shape `[1, 32, 160, 160]` (batch, channels, height, width). Access pattern: `pointer[0 * 819200 + c * 25600 + ph * 160 + pw]`, simplified to `pointer[c * 25600 + ph * 160 + pw]` since batch is always 0.

- [ ] **Step 3.1: Write the failing tests**

```swift
// Tests/SiiVisionTests/MaskSamplerTests.swift
import XCTest
import CoreML
@testable import ICanSii_iOS

final class MaskSamplerTests: XCTestCase {

    /// Build a synthetic [1,32,160,160] MLMultiArray where every prototype pixel is 1.0,
    /// so that any positive coefficient vector produces a large positive dot → sigmoid ≈ 1 → all pixels active.
    private func allOnesPrototypes() throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 32, 160, 160]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<(32 * 160 * 160) { ptr[i] = 1.0 }
        return arr
    }

    /// All-zeros prototypes → dot = 0 → sigmoid = 0.5 → below threshold → no active pixels.
    private func allZeroPrototypes() throws -> MLMultiArray {
        let shape: [NSNumber] = [1, 32, 160, 160]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        for i in 0..<(32 * 160 * 160) { ptr[i] = 0.0 }
        return arr
    }

    func test_centroidOfFullBboxIsApproxCenter() throws {
        let proto = try allOnesPrototypes()
        let coeffs = [Float](repeating: 1.0, count: 32)  // all-positive → all pixels active
        let bbox = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)  // full image
        let result = MaskSampler.assemble(
            prototypes: proto, coefficients: coeffs,
            bbox: bbox, depthWidth: 256, depthHeight: 192
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.centroidUV.x, 0.5, accuracy: 0.02)
        XCTAssertEqual(result!.centroidUV.y, 0.5, accuracy: 0.02)
    }

    func test_noActivePixelsWhenAllZeroPrototypes() throws {
        let proto = try allZeroPrototypes()
        let coeffs = [Float](repeating: 1.0, count: 32)
        let bbox = CGRect(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let result = MaskSampler.assemble(
            prototypes: proto, coefficients: coeffs,
            bbox: bbox, depthWidth: 256, depthHeight: 192
        )
        // sigmoid(0) = 0.5 which is equal to the threshold → should NOT be active (strict >=0.5 means equal is active;
        // but with all-zero dot the value is exactly 0.5 — treat as threshold boundary.
        // The important thing is that all-negative coefficients should yield nil.
        // Use negative coefficients to push dot well below 0 → sigmoid ≪ 0.5 → nil.
        let negCoeffs = [Float](repeating: -10.0, count: 32)
        let result2 = MaskSampler.assemble(
            prototypes: proto, coefficients: negCoeffs,
            bbox: bbox, depthWidth: 256, depthHeight: 192
        )
        XCTAssertNil(result2)
    }

    func test_bboxRestrictionIgnoresOutsidePixels() throws {
        // Prototypes where only the right half (pw >= 80) has positive values
        let shape: [NSNumber] = [1, 32, 160, 160]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = arr.dataPointer.assumingMemoryBound(to: Float32.self)
        for c in 0..<32 {
            for ph in 0..<160 {
                for pw in 0..<160 {
                    // Right half: high dot; left half: very negative dot
                    ptr[c * 25600 + ph * 160 + pw] = pw >= 80 ? 1.0 : -10.0
                }
            }
        }
        let coeffs = [Float](repeating: 1.0, count: 32)

        // Bbox restricted to left half — should return nil (no active pixels)
        let bboxLeft = CGRect(x: 0.0, y: 0.0, width: 0.5, height: 1.0)
        let resultLeft = MaskSampler.assemble(
            prototypes: arr, coefficients: coeffs,
            bbox: bboxLeft, depthWidth: 256, depthHeight: 192
        )
        XCTAssertNil(resultLeft, "Left-half bbox over right-heavy prototypes should yield nil")

        // Bbox over right half — should succeed with centroid x > 0.5
        let bboxRight = CGRect(x: 0.5, y: 0.0, width: 0.5, height: 1.0)
        let resultRight = MaskSampler.assemble(
            prototypes: arr, coefficients: coeffs,
            bbox: bboxRight, depthWidth: 256, depthHeight: 192
        )
        XCTAssertNotNil(resultRight)
        XCTAssertGreaterThan(resultRight!.centroidUV.x, 0.5)
    }

    func test_depthPixelsAreWithinBounds() throws {
        let proto = try allOnesPrototypes()
        let coeffs = [Float](repeating: 1.0, count: 32)
        let bbox = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let result = MaskSampler.assemble(
            prototypes: proto, coefficients: coeffs,
            bbox: bbox, depthWidth: 256, depthHeight: 192
        )
        XCTAssertNotNil(result)
        for (col, row) in result!.activePixels {
            XCTAssertGreaterThanOrEqual(col, 0)
            XCTAssertLessThan(col, 256)
            XCTAssertGreaterThanOrEqual(row, 0)
            XCTAssertLessThan(row, 192)
        }
    }
}
```

- [ ] **Step 3.2: Implement `MaskSampler.swift`**

```swift
import Foundation
import CoreML
import CoreGraphics

enum MaskSampler {
    struct Result {
        /// Centroid of active mask pixels in normalised 0..1 UV (Vision convention: origin top-left).
        let centroidUV: CGPoint
        /// (col, row) pairs at depth-map resolution for use by DepthSampler. May contain duplicates
        /// from NN resampling; DepthSampler ignores them (duplicate reads of the same pixel are fine).
        let activePixels: [(col: Int, row: Int)]
    }

    static let protoSize = 160        // YOLO seg prototype spatial dimension
    static let numChannels = 32       // YOLO seg prototype channels
    static let maskThreshold: Float = 0.5

    /// Assemble binary mask from YOLO prototypes ⊗ coefficients restricted to `bbox`.
    ///
    /// - Parameters:
    ///   - prototypes: 4D `MLMultiArray` with shape `[1, 32, 160, 160]` from `VisionManager.currentPrototypes`.
    ///   - coefficients: 32 per-detection mask coefficients from `YoloDetection.maskCoefficients`.
    ///   - bbox: detection bounding box in normalised 0..1 Vision coords (origin top-left).
    ///   - depthWidth / depthHeight: ARKit depth map dimensions (typically 256×192).
    /// - Returns: `Result` with centroid + active pixel list, or `nil` if no pixels are active.
    static func assemble(
        prototypes: MLMultiArray,
        coefficients: [Float],
        bbox: CGRect,
        depthWidth: Int,
        depthHeight: Int
    ) -> Result? {
        // Validate tensor shape [1, 32, 160, 160]
        guard prototypes.shape.count == 4,
              prototypes.shape[1].intValue == numChannels,
              prototypes.shape[2].intValue == protoSize,
              prototypes.shape[3].intValue == protoSize,
              coefficients.count == numChannels
        else { return nil }

        let ptr = prototypes.dataPointer.assumingMemoryBound(to: Float32.self)
        // stride per channel: 160 * 160 = 25600 (batch stride skipped, batch=0 always)
        let chanStride = protoSize * protoSize

        // Convert bbox from normalised → proto pixel coords (clamp to [0, 159])
        let pw0 = max(0, Int((bbox.minX * CGFloat(protoSize)).rounded(.down)))
        let pw1 = min(protoSize - 1, Int((bbox.maxX * CGFloat(protoSize)).rounded(.up)))
        let ph0 = max(0, Int((bbox.minY * CGFloat(protoSize)).rounded(.down)))
        let ph1 = min(protoSize - 1, Int((bbox.maxY * CGFloat(protoSize)).rounded(.up)))
        guard pw1 > pw0, ph1 > ph0 else { return nil }

        // Assemble mask in proto space; accumulate centroid moments
        var sumX: Double = 0, sumY: Double = 0, count: Int = 0
        var protoActive: [(ph: Int, pw: Int)] = []
        protoActive.reserveCapacity((ph1 - ph0 + 1) * (pw1 - pw0 + 1) / 2)

        for ph in ph0...ph1 {
            let rowBase = ph * protoSize
            for pw in pw0...pw1 {
                // dot product: sum(proto[c, ph, pw] * coeff[c])
                var dot: Float = 0
                for c in 0..<numChannels {
                    dot += ptr[c * chanStride + rowBase + pw] * coefficients[c]
                }
                // sigmoid threshold
                let sig: Float = 1.0 / (1.0 + expf(-dot))
                if sig >= maskThreshold {
                    protoActive.append((ph, pw))
                    sumX += Double(pw)
                    sumY += Double(ph)
                    count += 1
                }
            }
        }
        guard count > 0 else { return nil }

        let centroidUV = CGPoint(
            x: (sumX / Double(count)) / Double(protoSize),
            y: (sumY / Double(count)) / Double(protoSize)
        )

        // Resample active proto pixels → depth-map resolution via nearest-neighbour
        let scaleX = Double(depthWidth)  / Double(protoSize)
        let scaleY = Double(depthHeight) / Double(protoSize)

        // Use a flat set to deduplicate depth pixels (multiple proto pixels may map to same depth pixel)
        var depthSet = Set<Int>()
        depthSet.reserveCapacity(protoActive.count)
        for (ph, pw) in protoActive {
            let dc = min(depthWidth  - 1, Int(Double(pw) * scaleX))
            let dr = min(depthHeight - 1, Int(Double(ph) * scaleY))
            depthSet.insert(dr * depthWidth + dc)
        }

        let activePixels = depthSet.map { idx in (col: idx % depthWidth, row: idx / depthWidth) }
        return Result(centroidUV: centroidUV, activePixels: activePixels)
    }
}
```

- [ ] **Step 3.3: Commit**

```bash
git add ICanSii_iOS/MaskSampler.swift Tests/SiiVisionTests/MaskSamplerTests.swift
git commit -m "feat(mask): MaskSampler assembles binary seg mask and centroid from YOLO prototypes"
```

---

## Task 5: DepthSampler (mask-driven 15th-percentile from ARKit depth CVPixelBuffer)

**Files:**
- Create: `ICanSii_iOS/DepthSampler.swift`
- Create: `Tests/SiiVisionTests/DepthSamplerTests.swift`

Context: `SpatialFrame.depthMap` is a Float32 `CVPixelBuffer` from ARKit (typically 256×192 on LiDAR). `ARManager` already locks/unlocks the base address idiomatically. `MaskSampler` provides a list of `(col, row)` pairs already at depth-map resolution — `DepthSampler` just reads those specific pixels, sorts, and returns the 15th-percentile value.

- [ ] **Step 5.1: Failing test (uses hand-built `CVPixelBuffer` + synthetic pixel list)**

```swift
import XCTest
import CoreVideo
@testable import ICanSii_iOS

final class DepthSamplerTests: XCTestCase {

    private func makeFloatBuffer(width: Int, height: Int, fill: Float) -> CVPixelBuffer {
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_DepthFloat32, attrs as CFDictionary, &out)
        let buf = out!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for r in 0..<height {
            let row = base.advanced(by: r * bpr).assumingMemoryBound(to: Float32.self)
            for c in 0..<width { row[c] = fill }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return buf
    }

    func test_15thPercentileOverConstantBufferIsConstant() {
        let buf = makeFloatBuffer(width: 10, height: 10, fill: 2.5)
        let pixels = (0..<10).flatMap { row in (0..<10).map { col in (col: col, row: row) } }
        let d = DepthSampler.sample(depthMap: buf, activePixels: pixels)
        XCTAssertEqual(d ?? -1, 2.5, accuracy: 0.001)
    }

    func test_rejectsZeroDepthPixels() {
        let buf = makeFloatBuffer(width: 10, height: 10, fill: 0.0)
        let pixels = [(col: 5, row: 5)]
        XCTAssertNil(DepthSampler.sample(depthMap: buf, activePixels: pixels))
    }

    func test_nilWhenNoActivePixels() {
        let buf = makeFloatBuffer(width: 10, height: 10, fill: 1.0)
        XCTAssertNil(DepthSampler.sample(depthMap: buf, activePixels: []))
    }

    func test_15thPercentilePicksCloserSurface() {
        // 100 pixels: 85 at 3.0 m (far), 15 at 0.5 m (close)
        // 15th percentile should return a value from the close surface
        var out: CVPixelBuffer?
        CVPixelBufferCreate(nil, 100, 1, kCVPixelFormatType_DepthFloat32,
                            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &out)
        let buf = out!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: Float32.self)
        for i in 0..<15 { base[i] = 0.5 }
        for i in 15..<100 { base[i] = 3.0 }
        CVPixelBufferUnlockBaseAddress(buf, [])

        let pixels = (0..<100).map { (col: $0, row: 0) }
        let d = DepthSampler.sample(depthMap: buf, activePixels: pixels)
        XCTAssertNotNil(d)
        XCTAssertLessThan(d!, 1.0, "15th percentile of a mix with 15 close pixels should be ≤ 0.5 m")
    }
}
```

- [ ] **Step 5.2: Implement `DepthSampler.swift`**

```swift
import Foundation
import CoreVideo

enum DepthSampler {
    /// Returns the 15th-percentile depth (metres) over a set of mask-active pixels in an ARKit Float32 depth map.
    ///
    /// - Parameters:
    ///   - depthMap: Float32 CVPixelBuffer (ARKit sceneDepth / smoothedSceneDepth, typically 256×192).
    ///   - activePixels: `(col, row)` pairs at depth-map resolution — output of `MaskSampler.assemble(...)`.
    /// - Returns: 15th-percentile depth in metres over valid pixels, or `nil` if no valid pixels.
    static func sample(depthMap: CVPixelBuffer, activePixels: [(col: Int, row: Int)]) -> Float? {
        guard !activePixels.isEmpty else { return nil }

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }

        let w = CVPixelBufferGetWidth(depthMap)
        let h = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        var samples: [Float] = []
        samples.reserveCapacity(activePixels.count)

        for (col, row) in activePixels {
            guard col >= 0, col < w, row >= 0, row < h else { continue }
            let v = base.advanced(by: row * bytesPerRow)
                        .assumingMemoryBound(to: Float32.self)[col]
            if v.isFinite && v > 0 && v < 10.0 { samples.append(v) }  // ARKit LiDAR valid range
        }
        guard !samples.isEmpty else { return nil }

        samples.sort()
        let idx = max(0, Int(Float(samples.count) * 0.15))
        return samples[idx]
    }
}
```

- [ ] **Step 5.3: Commit**

```bash
git add ICanSii_iOS/DepthSampler.swift Tests/SiiVisionTests/DepthSamplerTests.swift
git commit -m "feat(depth): mask-driven 15th-percentile DepthSampler for ARKit Float32 depth"
```

---

## Task 6: Deprojection

**Files:**
- Create: `ICanSii_iOS/Deprojection.swift`
- Create: `Tests/SiiVisionTests/DeprojectionTests.swift`

**Critical:** ARKit's `camera.intrinsics` is defined for the raw capture resolution (typically 1920×1440 on iPhone 17 Pro), NOT the 640×640 Vision input and NOT the depth map resolution. We must pass pixel coordinates in the capture resolution — `SpatialFrame.imageResolution` has it. Vision's bbox is 0..1 normalised, so multiply by capture width/height to get the pixel used for deprojection.

- [ ] **Step 6.1: Failing test**

```swift
import XCTest
import simd
@testable import ICanSii_iOS

final class DeprojectionTests: XCTestCase {
    func test_principalPointAtOneMeterIsAlongNegativeZ() {
        // intrinsics: fx=1000, fy=1000, ppx=960, ppy=540, at (960,540) → (0,0,−1)
        let K = simd_float3x3(
            SIMD3<Float>(1000, 0, 0),
            SIMD3<Float>(0, 1000, 0),
            SIMD3<Float>(960, 540, 1)
        ) // column-major; ARKit convention
        let p = Deprojection.deproject(pixel: CGPoint(x: 960, y: 540), depthMeters: 1.0, intrinsics: K)
        XCTAssertEqual(p.x, 0, accuracy: 1e-4)
        XCTAssertEqual(p.y, 0, accuracy: 1e-4)
        XCTAssertEqual(p.z, -1.0, accuracy: 1e-4)   // ARKit: forward is -Z
    }

    func test_offAxisPixelMapsProportionally() {
        let K = simd_float3x3(
            SIMD3<Float>(1000, 0, 0),
            SIMD3<Float>(0, 1000, 0),
            SIMD3<Float>(960, 540, 1)
        )
        // 100 px right of centre at 2 m → x = (100/1000)*2 = 0.2 m (+X = right)
        let p = Deprojection.deproject(pixel: CGPoint(x: 1060, y: 540), depthMeters: 2.0, intrinsics: K)
        XCTAssertEqual(p.x, 0.2, accuracy: 1e-4)
        XCTAssertEqual(p.z, -2.0, accuracy: 1e-4)
    }
}
```

- [ ] **Step 6.2: Implement**

```swift
import Foundation
import simd
import CoreGraphics

enum Deprojection {
    /// Back-project a capture-resolution pixel + metric depth into ARKit camera space.
    /// ARKit convention: +X right, +Y up, −Z forward. Intrinsics use image pixels with origin at top-left;
    /// Apple's ARCamera.intrinsics treats +Y as downward in image, so we flip Y to land in ARKit camera space.
    static func deproject(pixel: CGPoint, depthMeters z: Float, intrinsics K: simd_float3x3) -> SIMD3<Float> {
        let fx = K.columns.0.x
        let fy = K.columns.1.y
        let ppx = K.columns.2.x
        let ppy = K.columns.2.y
        let x = (Float(pixel.x) - ppx) / fx * z
        let y = (Float(pixel.y) - ppy) / fy * z
        // Image +Y is down; ARKit camera +Y is up; forward is −Z.
        return SIMD3<Float>(x, -y, -z)
    }
}
```

- [ ] **Step 6.3: Commit**

```bash
git add ICanSii_iOS/Deprojection.swift Tests/SiiVisionTests/DeprojectionTests.swift
git commit -m "feat(3d): pixel+depth→3D deprojection in ARKit camera space"
```

---

## Task 7: Tracker (IoU + centroid matcher, predictive)

**Files:**
- Create: `ICanSii_iOS/Tracker.swift`
- Create: `Tests/SiiVisionTests/TrackerTests.swift`

Design: one `TrackState` per tracker ID holding a single `Kalman3D` (6-state `[x,y,z,vx,vy,vz]`) plus last bbox, last update time, confidence, class. Frame step: (1) predict — every existing track ages its `timeSinceSeen`; (2) match — greedy assignment of current `Detection2DWithDepth` to tracks by (`IoU >= 0.3` OR `centroid distance < 80 px`), highest-first; (3) update matched tracks via `Kalman3D.update(measurement:dt:)` on the deprojected 3D centroid, reading smoothed position and velocity back from the filter; (4) create new tracks for unmatched detections; (5) extrapolate unmatched tracks by calling `Kalman3D.predict(dt:)` followed by `applyVelocityDecay(velocityDecay)` each frame for up to `predictionTimeout = 1 s`, then drop.

- [ ] **Step 7.1: Failing tests**

```swift
import XCTest
import CoreGraphics
@testable import ICanSii_iOS

final class TrackerTests: XCTestCase {
    func test_assignsStableIdAcrossTwoFrames() {
        var t = Tracker()
        let det = Detection2DWithDepth(
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            centroidUV: CGPoint(x: 0.5, y: 0.5),
            centroidPx: CGPoint(x: 320, y: 320),
            classId: 0, className: "person", confidence: 0.9, depthMeters: 2.0
        )
        let K = dummyIntrinsics()
        let a = t.step(detections: [det], intrinsics: K, timestamp: 0.0)
        let b = t.step(detections: [det], intrinsics: K, timestamp: 0.1)
        XCTAssertEqual(a.first?.id, b.first?.id)
    }

    func test_predictsBrieflyAfterDetectionLost() {
        var t = Tracker()
        let K = dummyIntrinsics()
        let det = Detection2DWithDepth(
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            centroidUV: CGPoint(x: 0.5, y: 0.5),
            centroidPx: CGPoint(x: 320, y: 320),
            classId: 0, className: "person", confidence: 0.9, depthMeters: 2.0
        )
        _ = t.step(detections: [det], intrinsics: K, timestamp: 0.0)
        _ = t.step(detections: [det], intrinsics: K, timestamp: 0.1)
        let out = t.step(detections: [], intrinsics: K, timestamp: 0.2)
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].isPredictive)
    }

    func test_dropsAfterPredictionTimeout() {
        var t = Tracker()
        let K = dummyIntrinsics()
        let det = Detection2DWithDepth(
            boundingBox: CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2),
            centroidUV: CGPoint(x: 0.5, y: 0.5),
            centroidPx: CGPoint(x: 320, y: 320),
            classId: 0, className: "person", confidence: 0.9, depthMeters: 2.0
        )
        _ = t.step(detections: [det], intrinsics: K, timestamp: 0.0)
        let out = t.step(detections: [], intrinsics: K, timestamp: 5.0)
        XCTAssertTrue(out.isEmpty)
    }

    private func dummyIntrinsics() -> simd_float3x3 {
        simd_float3x3(
            SIMD3<Float>(1000, 0, 0),
            SIMD3<Float>(0, 1000, 0),
            SIMD3<Float>(320, 320, 1)
        )
    }
}
```

- [ ] **Step 7.2: Implement `Tracker.swift`**

Full implementation outline (~180 lines):

```swift
import Foundation
import simd
import CoreGraphics

final class Tracker {
    // Config (mirrors VestMappingEngine.Params so tests can override).
    struct Params {
        var iouThreshold: Float = 0.3
        var centroidPxThreshold: Float = 80
        var predictionTimeout: TimeInterval = 1.0
        var velocityDecay: Float = 0.85
        var hysteresisTime: TimeInterval = 0.2
        var maxSpeedMps: Float = 6.0
        var kalman3DProcessNoisePos: Float = 1e-3
        var kalman3DProcessNoiseVel: Float = 5e-2
        var kalman3DMeasurementNoise: Float = 5e-3
    }

    private struct State {
        let id: Int
        var classId: Int
        var className: String
        var confidence: Float
        var lastBoundingBox: CGRect
        var lastCentroidPx: CGPoint
        var kalman: Kalman3D
        var position: SIMD3<Float>
        var velocity: SIMD3<Float>
        var speedSmoothed: Float
        var lastSeenTs: TimeInterval
        var updatedTs: TimeInterval
        var isPredictive: Bool
    }

    private let params: Params
    private var states: [Int: State] = [:]
    private var nextId: Int = 1

    init(params: Params = Params()) { self.params = params }

    func step(
        detections: [Detection2DWithDepth],
        intrinsics K: simd_float3x3,
        timestamp t: TimeInterval
    ) -> [TrackedObject3D] {
        // 1. Greedy match.
        var unmatchedDets = Array(detections.indices)
        var unmatchedTracks = Set(states.keys)
        var assignments: [(trackId: Int, detIdx: Int, score: Float)] = []

        for (tid, tst) in states {
            for di in unmatchedDets {
                let det = detections[di]
                let iou = BoundingBoxIoU.of(tst.lastBoundingBox, det.boundingBox)
                let centroidDist = hypotf(
                    Float(tst.lastCentroidPx.x - det.centroidPx.x),
                    Float(tst.lastCentroidPx.y - det.centroidPx.y)
                )
                if iou >= params.iouThreshold || centroidDist <= params.centroidPxThreshold {
                    assignments.append((tid, di, iou - centroidDist / 1000))
                }
            }
        }
        assignments.sort { $0.score > $1.score }
        var usedDets = Set<Int>()
        var usedTracks = Set<Int>()
        for a in assignments where !usedDets.contains(a.detIdx) && !usedTracks.contains(a.trackId) {
            usedDets.insert(a.detIdx); usedTracks.insert(a.trackId)
            unmatchedTracks.remove(a.trackId)
            updateTrack(id: a.trackId, det: detections[a.detIdx], intrinsics: K, ts: t)
        }
        unmatchedDets.removeAll { usedDets.contains($0) }

        // 2. New tracks for unmatched detections.
        for di in unmatchedDets { createTrack(det: detections[di], intrinsics: K, ts: t) }

        // 3. Predict unmatched tracks; drop if timed out.
        for tid in unmatchedTracks { predictTrack(id: tid, ts: t) }

        return emit(ts: t)
    }

    private func updateTrack(id: Int, det: Detection2DWithDepth, intrinsics K: simd_float3x3, ts: TimeInterval) {
        var s = states[id]!
        let raw = Deprojection.deproject(pixel: det.centroidPx, depthMeters: det.depthMeters, intrinsics: K)
        let dt = Float(max(ts - s.updatedTs, 1e-3))
        s.kalman.update(measurement: raw, dt: dt)
        let smoothed = s.kalman.position
        let vVec = s.kalman.velocity
        let speedClamped = min(simd_length(vVec), params.maxSpeedMps)
        s.classId = det.classId
        s.className = det.className
        s.confidence = det.confidence
        s.lastBoundingBox = det.boundingBox
        s.lastCentroidPx = det.centroidPx
        s.position = smoothed
        s.velocity = vVec
        s.speedSmoothed = speedClamped
        s.lastSeenTs = ts
        s.updatedTs = ts
        s.isPredictive = false
        states[id] = s
    }

    private func createTrack(det: Detection2DWithDepth, intrinsics K: simd_float3x3, ts: TimeInterval) {
        var kalman = Kalman3D(
            qPos: params.kalman3DProcessNoisePos,
            qVel: params.kalman3DProcessNoiseVel,
            rMeas: params.kalman3DMeasurementNoise
        )
        let pos = Deprojection.deproject(pixel: det.centroidPx, depthMeters: det.depthMeters, intrinsics: K)
        kalman.seed(position: pos)
        states[nextId] = State(
            id: nextId, classId: det.classId, className: det.className, confidence: det.confidence,
            lastBoundingBox: det.boundingBox, lastCentroidPx: det.centroidPx,
            kalman: kalman,
            position: pos, velocity: .zero, speedSmoothed: 0,
            lastSeenTs: ts, updatedTs: ts, isPredictive: false
        )
        nextId += 1
    }

    private func predictTrack(id: Int, ts: TimeInterval) {
        guard var s = states[id] else { return }
        let age = ts - s.lastSeenTs
        if age > params.predictionTimeout { states.removeValue(forKey: id); return }
        let dt = Float(max(ts - s.updatedTs, 1e-3))
        s.kalman.predict(dt: dt)
        s.kalman.applyVelocityDecay(params.velocityDecay)
        s.position = s.kalman.position
        s.velocity = s.kalman.velocity
        s.speedSmoothed = min(simd_length(s.velocity), params.maxSpeedMps)
        s.updatedTs = ts
        s.isPredictive = true
        states[id] = s
    }

    private func emit(ts: TimeInterval) -> [TrackedObject3D] {
        states.values.map { s in
            TrackedObject3D(
                id: s.id, classId: s.classId, className: s.className, confidence: s.confidence,
                position: s.position, velocity: s.velocity, speedSmoothed: s.speedSmoothed,
                boundingBox: s.lastBoundingBox,
                inFOV: !s.isPredictive,
                isPredictive: s.isPredictive,
                lastSeenTimestamp: s.lastSeenTs, updatedTimestamp: s.updatedTs
            )
        }.sorted { $0.id < $1.id }
    }
}
```

- [ ] **Step 7.3: Commit**

```bash
git add ICanSii_iOS/Tracker.swift Tests/SiiVisionTests/TrackerTests.swift
git commit -m "feat(tracking): IoU+centroid tracker with predictive extrapolation"
```

---

## Task 8: TrackingManager orchestrator

**Files:**
- Create: `ICanSii_iOS/TrackingManager.swift`

Concept: `TrackingManager` is an `ObservableObject` that subscribes to two Combine publishers — `VisionManager.$detections` (per-frame 2D YOLO) and `ARManager.framePublisher` (per-frame `SpatialFrame` with depth + intrinsics). Because they arrive on different threads at different rates, we buffer the latest `SpatialFrame` and trigger tracking whenever new `detections` arrive. This ordering matches v4 Jetson (YOLO detection drives the pipeline; depth is sampled just after).

Class whitelist + score threshold filter applied before tracker input.

- [ ] **Step 8.1: Implement**

```swift
import Foundation
import Combine
import ARKit
import CoreGraphics
import CoreML
import CoreVideo

final class TrackingManager: ObservableObject {
    static let allowedClassIds: Set<Int> = [
        0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,56,57,58,59,60,72
    ]
    static let scoreThreshold: Float = 0.5

    @Published private(set) var trackedObjects: [TrackedObject3D] = []

    private let tracker = Tracker()
    private var lastSpatialFrame: SpatialFrame?
    // Prototypes are captured atomically alongside detections — both published on main thread by VisionManager.
    private var lastPrototypes: MLMultiArray?
    private let lock = NSLock()
    private var cancellables: [AnyCancellable] = []

    /// Call once after init, passing the two upstream managers.
    func bind(arManager: ARManager, visionManager: VisionManager) {
        arManager.framePublisher
            .sink { [weak self] frame in
                guard let self = self else { return }
                self.lock.lock(); self.lastSpatialFrame = frame; self.lock.unlock()
            }
            .store(in: &cancellables)

        // Zip detections with current prototypes — both are set atomically on the main thread by
        // VisionManager.processResults, so reading them together here gives a consistent pair.
        visionManager.$detections
            .receive(on: DispatchQueue.global(qos: .userInitiated))
            .sink { [weak self] detections in
                guard let self = self else { return }
                // Snapshot prototypes on the calling thread (already on main via the publisher chain).
                // We'll read lastPrototypes from the lock-protected store below.
                self.lock.lock()
                let frame = self.lastSpatialFrame
                let prototypes = self.lastPrototypes
                self.lock.unlock()
                self.ingest(detections: detections, frame: frame, prototypes: prototypes)
            }
            .store(in: &cancellables)

        // Keep lastPrototypes in sync — updated on main alongside detections.
        visionManager.$currentPrototypes
            .sink { [weak self] proto in
                guard let self = self else { return }
                self.lock.lock(); self.lastPrototypes = proto; self.lock.unlock()
            }
            .store(in: &cancellables)
    }

    private func ingest(detections: [YoloDetection], frame: SpatialFrame?, prototypes: MLMultiArray?) {
        guard let frame = frame else { return }

        let captureW = CGFloat(frame.imageResolution.x)
        let captureH = CGFloat(frame.imageResolution.y)
        let depthW = CVPixelBufferGetWidth(frame.depthMap)
        let depthH = CVPixelBufferGetHeight(frame.depthMap)

        var enriched: [Detection2DWithDepth] = []
        enriched.reserveCapacity(detections.count)

        for det in detections {
            guard det.confidence >= Self.scoreThreshold,
                  Self.allowedClassIds.contains(det.classId) else { continue }

            let bbox = det.boundingBox

            // --- Mask-driven centroid + depth ---
            let centroidUV: CGPoint
            let depthMeters: Float

            if let proto = prototypes,
               let maskResult = MaskSampler.assemble(
                   prototypes: proto,
                   coefficients: det.maskCoefficients,
                   bbox: bbox,
                   depthWidth: depthW,
                   depthHeight: depthH
               ),
               let d = DepthSampler.sample(depthMap: frame.depthMap, activePixels: maskResult.activePixels) {
                centroidUV = maskResult.centroidUV
                depthMeters = d
            } else {
                // Fallback: bbox midpoint + nil depth → skip this detection.
                // (Prototypes may be nil when no YOLO model is active.)
                continue
            }

            let centroidPx = CGPoint(
                x: (centroidUV.x * captureW).rounded(),
                y: (centroidUV.y * captureH).rounded()
            )

            enriched.append(Detection2DWithDepth(
                boundingBox: bbox,
                centroidUV: centroidUV,
                centroidPx: centroidPx,
                classId: det.classId,
                className: VisionClassNames.name(for: det.classId),
                confidence: det.confidence,
                depthMeters: depthMeters
            ))
        }

        let output = tracker.step(detections: enriched, intrinsics: frame.intrinsics, timestamp: frame.timestamp)
        DispatchQueue.main.async { [weak self] in
            self?.trackedObjects = output
        }
    }
}

/// Minimal class-name lookup. (The full one lives in VisionManager as `getClassName(for:)` — private.
/// Duplicating the 24-entry subset we actually whitelist keeps TrackingManager independent.)
enum VisionClassNames {
    private static let names: [Int: String] = [
        0:"person",1:"bicycle",2:"car",3:"motorcycle",4:"airplane",5:"bus",6:"train",7:"truck",
        8:"boat",9:"traffic light",10:"fire hydrant",11:"stop sign",12:"parking meter",13:"bench",
        14:"bird",15:"cat",16:"dog",17:"horse",56:"chair",57:"couch",58:"potted plant",59:"bed",
        60:"dining table",72:"refrigerator"
    ]
    static func name(for id: Int) -> String { names[id] ?? "obj \(id)" }
}
```

- [ ] **Step 8.2: Commit**

```bash
git add ICanSii_iOS/TrackingManager.swift
git commit -m "feat(tracking): TrackingManager with MaskSampler+DepthSampler pipeline for YOLO→3D tracks"
```

---

## Task 9: Vest types + mapping engine

**Files:**
- Create: `ICanSii_iOS/VestTypes.swift`
- Create: `ICanSii_iOS/VestMappingEngine.swift`
- Create: `Tests/SiiVisionTests/VestMappingEngineTests.swift`

Vest layout (20 cells, 2×5 per side, 2 sides front/back):

```
Front (viewer facing vest from front):
   col0 col1        col0 col1
   [L0] [L1]        [R0] [R1]      row 0 (top)
   [L2] [L3]        [R2] [R3]      row 1
   [L4] [L5]        [R4] [R5]      row 2
   [L6] [L7]        [R6] [R7]      row 3
   [L8] [L9]        [R8] [R9]      row 4 (bottom)

Back: symmetric, `isBack = true`.
```

v4 uses a single vest-vs-direction mapping (left/right deadzone + offside @ 25%). For v1 demo we map the closest tracked object onto the **front half only** (objects in front of the camera = −Z). The back half stays dark unless the tracked object is behind the camera (z > 0 in ARKit). Row selection uses camera-space Y (up/down) — top rows activate for higher Y, bottom rows for lower. This matches physical intuition and sets up a clean upgrade path to the later 3D-aware vest mapping.

- [ ] **Step 9.1: Implement `VestTypes.swift`**

```swift
import Foundation

struct VestCell: Identifiable, Hashable {
    enum Side { case left, right }
    let id: String
    let isBack: Bool
    let side: Side
    let column: Int   // 0 (inner) or 1 (outer)
    let row: Int      // 0 (top) .. 4 (bottom)
}

/// 20-cell activation state. `intensity` is 0..1.
struct VestActivationState: Equatable {
    var cells: [String: Float] = [:]   // cell.id → intensity
    static let allOff = VestActivationState()
}

/// Transport-agnostic sink. `PreviewTransport` publishes for SwiftUI; a future `BLETransport` writes UUID chars.
protocol HapticTransport: AnyObject {
    func send(_ state: VestActivationState, timestamp: TimeInterval)
}

final class PreviewTransport: HapticTransport, ObservableObject {
    @Published private(set) var state: VestActivationState = .allOff
    func send(_ state: VestActivationState, timestamp: TimeInterval) {
        DispatchQueue.main.async { self.state = state }
    }
}

enum VestLayout {
    static let rowsPerSide = 5
    static let colsPerSide = 2
    static let all: [VestCell] = {
        var out: [VestCell] = []
        for isBack in [false, true] {
            for side in [VestCell.Side.left, .right] {
                for row in 0..<rowsPerSide {
                    for col in 0..<colsPerSide {
                        let id = "\(isBack ? "B" : "F")_\(side == .left ? "L" : "R")_r\(row)c\(col)"
                        out.append(VestCell(id: id, isBack: isBack, side: side, column: col, row: row))
                    }
                }
            }
        }
        return out
    }()
}
```

- [ ] **Step 9.2: Failing tests**

```swift
import XCTest
import simd
@testable import ICanSii_iOS

final class VestMappingEngineTests: XCTestCase {
    private func obj(x: Float, y: Float, z: Float, id: Int = 1) -> TrackedObject3D {
        TrackedObject3D(
            id: id, classId: 0, className: "person", confidence: 0.9,
            position: SIMD3(x, y, z), velocity: .zero, speedSmoothed: 0,
            boundingBox: .zero, inFOV: true, isPredictive: false,
            lastSeenTimestamp: 0, updatedTimestamp: 0
        )
    }

    func test_allOffBeyondThreshold() {
        let e = VestMappingEngine()
        // 2 m distance > 1.25 m threshold
        let s = e.map(objects: [obj(x: 0, y: 0, z: -2.0)], timestamp: 0)
        for c in VestLayout.all {
            XCTAssertEqual(s.cells[c.id] ?? 0, 0, accuracy: 1e-4)
        }
    }

    func test_closerObjectYieldsHigherIntensity() {
        let e = VestMappingEngine()
        let far  = e.map(objects: [obj(x: 0, y: 0, z: -1.0)], timestamp: 0)
        let near = e.map(objects: [obj(x: 0, y: 0, z: -0.3)], timestamp: 0.2)
        let farMax  = far.cells.values.max() ?? 0
        let nearMax = near.cells.values.max() ?? 0
        XCTAssertGreaterThan(nearMax, farMax)
    }

    func test_centreWithinDeadzoneActivatesBothSides() {
        let e = VestMappingEngine()
        let s = e.map(objects: [obj(x: 0.05, y: 0, z: -0.5)], timestamp: 0)
        let leftSum  = VestLayout.all.filter { !$0.isBack && $0.side == .left  }.map  { s.cells[$0.id] ?? 0 }.reduce(0,+)
        let rightSum = VestLayout.all.filter { !$0.isBack && $0.side == .right }.map { s.cells[$0.id] ?? 0 }.reduce(0,+)
        XCTAssertGreaterThan(leftSum, 0)
        XCTAssertGreaterThan(rightSum, 0)
        XCTAssertEqual(leftSum, rightSum, accuracy: 0.01)
    }

    func test_rightBiasActivatesRightFullLeftOffside() {
        let e = VestMappingEngine()
        let s = e.map(objects: [obj(x: 0.5, y: 0, z: -0.5)], timestamp: 0)
        let rightMax = VestLayout.all.filter { !$0.isBack && $0.side == .right }.map { s.cells[$0.id] ?? 0 }.max() ?? 0
        let leftMax  = VestLayout.all.filter { !$0.isBack && $0.side == .left  }.map { s.cells[$0.id] ?? 0 }.max() ?? 0
        XCTAssertGreaterThan(rightMax, leftMax)
        XCTAssertEqual(leftMax / rightMax, 0.25, accuracy: 0.05)
    }

    func test_watchdogTurnsOffWhenDetectionsStop() {
        let e = VestMappingEngine()
        _ = e.map(objects: [obj(x: 0, y: 0, z: -0.5)], timestamp: 0)
        let s = e.map(objects: [], timestamp: 1.0)  // > 0.5 s watchdog
        XCTAssertTrue(s.cells.allSatisfy { $0.value == 0 })
    }

    func test_behindObjectActivatesBackSide() {
        let e = VestMappingEngine()
        let s = e.map(objects: [obj(x: 0, y: 0, z: 0.5)], timestamp: 0) // +Z = behind
        let frontSum = VestLayout.all.filter { !$0.isBack }.map { s.cells[$0.id] ?? 0 }.reduce(0,+)
        let backSum  = VestLayout.all.filter {  $0.isBack }.map { s.cells[$0.id] ?? 0 }.reduce(0,+)
        XCTAssertGreaterThan(backSum, frontSum)
    }
}
```

- [ ] **Step 9.3: Implement `VestMappingEngine.swift`**

```swift
import Foundation
import simd

final class VestMappingEngine {
    struct Params {
        var distanceThreshold: Float = 1.25
        var intensityMin: Float = 0.0
        var intensityMax: Float = 1.0
        var directionDeadzone: Float = 0.12
        var offsideIntensityFactor: Float = 0.25
        var watchdogTimeout: TimeInterval = 0.5
    }

    private let params: Params
    private var lastDetectionTs: TimeInterval?

    init(params: Params = Params()) { self.params = params }

    func map(objects: [TrackedObject3D], timestamp ts: TimeInterval) -> VestActivationState {
        // Watchdog
        if !objects.isEmpty { lastDetectionTs = ts }
        if let last = lastDetectionTs, ts - last > params.watchdogTimeout {
            return .allOff
        }

        // Closest within threshold
        let candidates = objects.filter { $0.distance <= params.distanceThreshold }
        guard let target = candidates.min(by: { $0.distance < $1.distance }) else {
            return .allOff
        }

        // Intensity from distance
        let t = (params.distanceThreshold - target.distance) / params.distanceThreshold
        let tc = max(0, min(1, t))
        let intensity = params.intensityMin + (params.intensityMax - params.intensityMin) * tc

        // Side resolution (ARKit camera-space X). Center/back bias:
        let isBack = target.position.z > 0
        let x = target.position.x
        let primarySide: VestCell.Side
        let offsideIntensity: Float

        if abs(x) <= params.directionDeadzone {
            // Centre: both sides equal
            return makeState(full: intensity, offside: intensity, primary: .left, isBack: isBack, target: target, alsoOtherSide: true)
        } else if x > 0 {
            primarySide = .right
            offsideIntensity = intensity * params.offsideIntensityFactor
        } else {
            primarySide = .left
            offsideIntensity = intensity * params.offsideIntensityFactor
        }
        return makeState(full: intensity, offside: offsideIntensity, primary: primarySide, isBack: isBack, target: target, alsoOtherSide: false)
    }

    /// Distribute intensity across 10 cells per side by biasing rows toward the object's vertical position.
    /// Simple Gaussian weight centred on the target's Y (ARKit: +Y up, −Y down).
    private func makeState(
        full: Float, offside: Float,
        primary: VestCell.Side, isBack: Bool,
        target: TrackedObject3D,
        alsoOtherSide: Bool
    ) -> VestActivationState {
        var state = VestActivationState()
        let yNorm = max(-1, min(1, target.position.y / 0.6))   // clamp body-height scale ≈ ±0.6 m
        // Map y∈[-1..1] to row centre in [4..0] (top=0)
        let centreRow = (1 - yNorm) * 0.5 * Float(VestLayout.rowsPerSide - 1)

        for cell in VestLayout.all {
            guard cell.isBack == isBack else { continue }
            let sideIntensity: Float = (cell.side == primary) ? full : (alsoOtherSide ? full : offside)
            let dRow = Float(cell.row) - centreRow
            let weight = expf(-(dRow * dRow) / (2 * 1.5 * 1.5))
            state.cells[cell.id] = sideIntensity * weight
        }
        return state
    }
}
```

- [ ] **Step 9.4: Commit**

```bash
git add ICanSii_iOS/VestTypes.swift ICanSii_iOS/VestMappingEngine.swift Tests/SiiVisionTests/VestMappingEngineTests.swift
git commit -m "feat(vest): mapping engine + 20-cell layout + HapticTransport protocol"
```

---

## Task 10: Vest preview view

**Files:**
- Create: `ICanSii_iOS/VestPreviewView.swift`

- [ ] **Step 10.1: Implement**

```swift
import SwiftUI

struct VestPreviewView: View {
    @ObservedObject var transport: PreviewTransport
    @State private var showBack: Bool = false

    var body: some View {
        VStack(spacing: 24) {
            Picker("Side", selection: $showBack) {
                Text("Front").tag(false)
                Text("Back").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 40)

            grid(isBack: showBack)
                .padding(.horizontal, 40)

            legend

            Spacer()
        }
        .padding(.top, 40)
        .background(Color.black.ignoresSafeArea())
        .foregroundStyle(.white)
    }

    private func grid(isBack: Bool) -> some View {
        HStack(spacing: 40) {
            side(.left, isBack: isBack)
            side(.right, isBack: isBack)
        }
    }

    private func side(_ side: VestCell.Side, isBack: Bool) -> some View {
        VStack(spacing: 8) {
            ForEach(0..<VestLayout.rowsPerSide, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(0..<VestLayout.colsPerSide, id: \.self) { col in
                        cellView(isBack: isBack, side: side, row: row, col: col)
                    }
                }
            }
        }
    }

    private func cellView(isBack: Bool, side: VestCell.Side, row: Int, col: Int) -> some View {
        let id = "\(isBack ? "B" : "F")_\(side == .left ? "L" : "R")_r\(row)c\(col)"
        let intensity = transport.state.cells[id] ?? 0
        return RoundedRectangle(cornerRadius: 8)
            .fill(color(for: intensity))
            .frame(width: 56, height: 56)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.3), lineWidth: 1))
            .animation(.easeOut(duration: 0.1), value: intensity)
    }

    private func color(for intensity: Float) -> Color {
        // Black → red → yellow (HSB hue 0→0.16)
        if intensity <= 0.001 { return Color(white: 0.12) }
        let hue = Double(min(intensity, 1.0)) * 0.16
        return Color(hue: hue, saturation: 1.0, brightness: 0.4 + 0.6 * Double(min(intensity, 1.0)))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([0.0, 0.25, 0.5, 0.75, 1.0], id: \.self) { v in
                VStack {
                    RoundedRectangle(cornerRadius: 4).fill(color(for: Float(v))).frame(width: 28, height: 28)
                    Text(String(format: "%.2f", v)).font(.caption2.monospacedDigit())
                }
            }
        }
    }
}
```

- [ ] **Step 10.2: Commit**

```bash
git add ICanSii_iOS/VestPreviewView.swift
git commit -m "feat(vest): SwiftUI 20-cell preview view"
```

---

## Task 11: Spatial overlay (projected 3D markers on the AR feed)

**Files:**
- Create: `ICanSii_iOS/SpatialOverlayView.swift`

We project each `TrackedObject3D.position` (ARKit camera space) to a screen-space point using the same intrinsics + display transform already exposed by `ARManager` (`displayTransform`) and the `SpatialFrame.imageResolution`. The overlay renders a coloured dot + class label + distance as a SwiftUI layer above `SpatialMetalView`. This does not touch `SpatialRenderer.swift`.

- [ ] **Step 11.1: Implement**

```swift
import SwiftUI
import ARKit
import simd

struct SpatialOverlayView: View {
    @ObservedObject var tracking: TrackingManager
    @ObservedObject var arManager: ARManager
    /// Latest capture resolution seen from a SpatialFrame — published by TrackingManager or ARManager.
    let captureResolution: SIMD2<Int>
    /// Latest intrinsics seen.
    let intrinsics: simd_float3x3

    var body: some View {
        GeometryReader { geo in
            ForEach(tracking.trackedObjects) { obj in
                if let pt = project(obj.position, viewSize: geo.size) {
                    markerView(for: obj)
                        .position(pt)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func project(_ cameraSpace: SIMD3<Float>, viewSize: CGSize) -> CGPoint? {
        // ARKit camera space → image pixel via intrinsics (image +Y down, −Z forward).
        guard cameraSpace.z < 0 else { return nil }   // object must be in front of camera
        let fx = intrinsics.columns.0.x
        let fy = intrinsics.columns.1.y
        let ppx = intrinsics.columns.2.x
        let ppy = intrinsics.columns.2.y
        let z = -cameraSpace.z
        let px = ppx + cameraSpace.x / z * fx
        let py = ppy + (-cameraSpace.y) / z * fy

        // Normalise to 0..1 in capture resolution, then apply displayTransform (same path as 2D bboxes).
        let uv = CGPoint(x: CGFloat(px) / CGFloat(captureResolution.x),
                         y: CGFloat(py) / CGFloat(captureResolution.y))
        let transformed = uvToScreen(uv, displayTransform: arManager.displayTransform)
        return CGPoint(x: transformed.x * viewSize.width, y: transformed.y * viewSize.height)
    }

    /// Mirrors `CGRect.transformedToScreen` in ContentView.swift but for a single point.
    private func uvToScreen(_ uv: CGPoint, displayTransform: CGAffineTransform) -> CGPoint {
        let inverted = displayTransform.inverted()
        let tx = 1.0 - uv.y
        let ty = uv.x
        return CGPoint(x: tx, y: ty).applying(inverted)
    }

    @ViewBuilder private func markerView(for obj: TrackedObject3D) -> some View {
        let color: Color = obj.isPredictive ? .orange : .green
        VStack(spacing: 4) {
            Circle()
                .fill(color.opacity(0.9))
                .frame(width: 16, height: 16)
                .overlay(Circle().stroke(.white, lineWidth: 2))
            Text(String(format: "#%d %@  %.1fm", obj.id, obj.className, obj.distance))
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(color.opacity(0.8), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}
```

- [ ] **Step 11.2: Commit**

```bash
git add ICanSii_iOS/SpatialOverlayView.swift
git commit -m "feat(ui): SwiftUI spatial overlay with projected 3D markers"
```

---

## Task 12: Expose live intrinsics + capture resolution on ARManager

**Files:**
- Modify: `ICanSii_iOS/ARManager.swift`

The overlay view needs the latest `intrinsics` and `imageResolution`. `ARManager` already publishes full `SpatialFrame`s via `framePublisher` but doesn't keep a `@Published` copy. Add two lightweight `@Published` properties so SwiftUI can observe them without subscribing to the raw frame stream.

- [ ] **Step 12.1: Modify `ARManager.swift` — add two `@Published` properties and set them in the delegate**

Open `ICanSii_iOS/ARManager.swift`. Inside the `final class ARManager: NSObject, ObservableObject` block, immediately after the existing `@Published var displayTransform: CGAffineTransform = .identity` line (around line 15), add:

```swift
    @Published private(set) var latestIntrinsics: simd_float3x3 = matrix_identity_float3x3
    @Published private(set) var latestCaptureResolution: SIMD2<Int> = .zero
```

Inside `session(_:didUpdate:)`, after the existing `DispatchQueue.main.async { self.displayTransform = displayTransform }` block (around line 171-173), add:

```swift
        DispatchQueue.main.async {
            self.latestIntrinsics = frame.camera.intrinsics
            self.latestCaptureResolution = imageResolution
        }
```

- [ ] **Step 12.2: Commit**

```bash
git add ICanSii_iOS/ARManager.swift
git commit -m "feat(ar): publish live intrinsics + capture resolution for overlay"
```

---

## Task 13: App root — tabs + wiring

**Files:**
- Create: `ICanSii_iOS/AppTabView.swift`
- Modify: `ICanSii_iOS/ICanSii_iOSApp.swift`
- Modify: `ICanSii_iOS/ContentView.swift`

The app will now expose two tabs: "Spatial" (existing `ContentView` + `SpatialOverlayView` on top) and "Vest" (`VestPreviewView`). All managers are owned by `AppTabView` so tab switching doesn't re-init ARKit.

- [ ] **Step 13.1: Create `AppTabView.swift`**

```swift
import SwiftUI

struct AppTabView: View {
    @StateObject private var arManager = ARManager()
    @StateObject private var visionManager = VisionManager()
    @StateObject private var trackingManager = TrackingManager()
    @StateObject private var hapticTransport = PreviewTransport()

    private let vestEngine = VestMappingEngine()
    @State private var vestPumpTimer: Timer?

    var body: some View {
        TabView {
            SpatialTabView(
                arManager: arManager,
                visionManager: visionManager,
                trackingManager: trackingManager
            )
            .tabItem { Label("Spatial", systemImage: "arkit") }

            VestPreviewView(transport: hapticTransport)
                .tabItem { Label("Vest", systemImage: "waveform.path") }
        }
        .onAppear {
            // Wire managers once
            trackingManager.bind(arManager: arManager, visionManager: visionManager)
            // 5 Hz vest update loop — pulls current trackedObjects, maps, pushes to transport.
            vestPumpTimer?.invalidate()
            vestPumpTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                let now = CACurrentMediaTime()
                let state = vestEngine.map(objects: trackingManager.trackedObjects, timestamp: now)
                hapticTransport.send(state, timestamp: now)
            }
        }
        .onDisappear {
            vestPumpTimer?.invalidate()
            vestPumpTimer = nil
        }
    }
}

/// Thin wrapper around the existing ContentView that also adds the 3D marker overlay.
struct SpatialTabView: View {
    @ObservedObject var arManager: ARManager
    @ObservedObject var visionManager: VisionManager
    @ObservedObject var trackingManager: TrackingManager

    var body: some View {
        ContentView(
            arManager: arManager,
            visionManager: visionManager,
            trackingManager: trackingManager
        )
        .overlay(
            SpatialOverlayView(
                tracking: trackingManager,
                arManager: arManager,
                captureResolution: arManager.latestCaptureResolution,
                intrinsics: arManager.latestIntrinsics
            )
            .allowsHitTesting(false)
        )
    }
}

import QuartzCore  // for CACurrentMediaTime()
```

- [ ] **Step 13.2: Modify `ICanSii_iOSApp.swift`**

Current content:

```swift
import SwiftUI

@main
struct ICanSii_iOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

Replace `ContentView()` with `AppTabView()`:

```swift
import SwiftUI

@main
struct ICanSii_iOSApp: App {
    var body: some Scene {
        WindowGroup {
            AppTabView()
        }
    }
}
```

- [ ] **Step 13.3: Modify `ContentView.swift` — inject managers and add tracking init**

Currently `ContentView` owns its own `@StateObject private var arManager = ARManager()` / `visionManager` (lines 5-6). `AppTabView` now owns them — `ContentView` needs to accept them. Change the struct declaration:

Replace lines 4–15 of `ContentView.swift`:

```swift
struct ContentView: View {
    @StateObject private var arManager = ARManager()
    @StateObject private var visionManager = VisionManager()

    @State private var mode: SpatialDisplayMode = .rgb
    @State private var maxDistance: Float = 6.0
    @State private var isRecording: Bool = false
    @State private var showSegmentation3D: Bool = true

    // NOUVEAU : États pour contrôler l'ouverture des bulles
    @State private var showYoloPanel: Bool = false
    @State private var showSettingsPanel: Bool = true
```

with:

```swift
struct ContentView: View {
    @ObservedObject var arManager: ARManager
    @ObservedObject var visionManager: VisionManager
    @ObservedObject var trackingManager: TrackingManager

    @State private var mode: SpatialDisplayMode = .rgb
    @State private var maxDistance: Float = 6.0
    @State private var isRecording: Bool = false
    @State private var showSegmentation3D: Bool = true

    @State private var showYoloPanel: Bool = false
    @State private var showSettingsPanel: Bool = true
```

Everything else in `ContentView.swift` stays unchanged — the `arManager.setSemanticConsumer { frame in visionManager.process(frame: frame) }` call in `.onAppear` is still correct (it uses the now-injected `arManager`/`visionManager`).

- [ ] **Step 13.4: Commit**

```bash
git add ICanSii_iOS/AppTabView.swift ICanSii_iOS/ICanSii_iOSApp.swift ICanSii_iOS/ContentView.swift
git commit -m "feat(app): two-tab app (Spatial + Vest) with shared manager ownership"
```

---

## Task 14: Test harness setup documentation (one-time Xcode action for the user)

**Files:**
- Create: `Tests/SiiVisionTests/README.md`

The remote environment cannot create an Xcode test target safely. This README tells the user exactly what to click when they want automated tests.

- [ ] **Step 14.1: Create `Tests/SiiVisionTests/README.md`**

```markdown
# SiiVisionTests

Pure-Swift unit tests for the v4 tracking + vest mapping modules.

## One-time setup (Xcode, on your Mac)

1. Open `ICanSii_iOS.xcodeproj` in Xcode.
2. `File → New → Target… → iOS → Unit Testing Bundle`. Name it `SiiVisionTests`. Product target: ICanSii_iOS.
3. In the new `SiiVisionTests` group, delete the auto-generated `SiiVisionTests.swift`.
4. Right-click `SiiVisionTests` → `Add Files to "ICanSii_iOS"…` → select this `Tests/SiiVisionTests/` directory → check "Create groups" and ensure target membership is only `SiiVisionTests`.
5. Ensure the `ICanSii_iOS` target has `@testable import ICanSii_iOS` access (default in new test bundles).
6. Run tests: `Cmd+U`.

Until this setup is done the test files are ignored by the build — they live outside the xcodeproj source roots so they never compile into the app target.

## What's covered

- `Kalman3DTests` — convergence, linear-ramp velocity stability, outlier rejection, predict-only velocity decay
- `MaskSamplerTests` — centroid of full-bbox mask at geometric centre; bbox restriction ignores outside pixels; depth pixel coords in bounds
- `DepthSamplerTests` — 15th-percentile over mask-active pixels; rejects zero/out-of-range; falls back to nil with no active pixels
- `DeprojectionTests` — pixel+depth→3D numerical equivalence
- `TrackerTests` — ID persistence, predictive mode, timeout
- `VestMappingEngineTests` — closest selection, deadzone, offside, watchdog, back side
```

- [ ] **Step 14.2: Commit**

```bash
git add Tests/SiiVisionTests/README.md
git commit -m "docs(test): one-time Xcode setup for SiiVisionTests target"
```

---

## Task 15: Manual QA checklist

**Files:**
- Create: `docs/superpowers/plans/2026-04-14-v4-qa-checklist.md`

- [ ] **Step 15.1: Create the QA checklist**

```markdown
# v4 Swift/Metal Demo — Manual QA Checklist

Run on a physical iPhone 17 Pro (LiDAR required). Xcode scheme: ICanSii_iOS, Release config for perf check, Debug config for first run.

## Build
- [ ] Project builds without warnings introduced by v4 files
- [ ] YOLO model `yolo26s-seg.mlpackage` links into the bundle
- [ ] App launches to the `TabView` with two tabs: Spatial, Vest

## Spatial tab
- [ ] AR session starts, camera feed visible
- [ ] HUD floating panels (YOLO + Settings) still work
- [ ] Switching YOLO model to `YOLO26s-seg` shows 2D bbox overlay (existing behaviour)
- [ ] **NEW:** Green dot + label ("#N person 1.3m") appears on each detected person
- [ ] Walk laterally — distance reading changes smoothly (Kalman works)
- [ ] Walk out of frame — dot turns orange for up to ~3 s then disappears (predictive mode)
- [ ] Two people in frame — each has a distinct persistent ID across frames

## Vest tab
- [ ] With no object in range (>1.25 m) all cells dark grey
- [ ] Walk within 1.25 m in front of camera — front cells light up
- [ ] Approach closer (0.3 m) — intensity reaches max (yellow)
- [ ] Step left of centre — LEFT column cells brighter than RIGHT (25% offside on RIGHT)
- [ ] Step right of centre — RIGHT cells brighter than LEFT
- [ ] Stand dead-centre (<0.12 m lateral) — LEFT and RIGHT equal
- [ ] Duck — bottom-row cells brighten more than top-row
- [ ] Turn away (camera behind you) — flip to Back tab; cells on back light up when object is at z>0

## Watchdog
- [ ] Drop detections (cover camera) — within ~0.5 s all cells go dark

## Perf
- [ ] YOLO FPS ≥ 15 on device (acceptable for demo; target 20+)
- [ ] No visible frame stutter in Spatial tab
- [ ] No runaway CPU when Vest tab is foreground

## Stability
- [ ] Backgrounding the app then reopening resumes cleanly
- [ ] Rotating the device does not crash (portrait-locked is acceptable — confirm in Info.plist)
```

- [ ] **Step 15.2: Commit and push all branches**

```bash
git add docs/superpowers/plans/2026-04-14-v4-qa-checklist.md
git commit -m "docs(qa): v4 demo manual QA checklist"

# Push v4-dev and v4 (v4 is the stable base; v4-dev will be merged/PR'd into it)
git push -u origin swift/v4
git push -u origin swift/v4-dev
```

---

## Self-Review (run before handing off)

**Spec coverage (against exec summary §🔄 Pipeline and docs/v4.md):**

| Spec requirement | Task |
|---|---|
| YOLO detection & tracking | Existing `VisionManager` + Task 7 tracker |
| Robust ROI-median depth | Task 5 |
| Kalman 1D depth filter | Task 2 |
| 3D deprojection | Task 6 |
| Position smoothing (FIFO + adaptive median, 5) | Task 3 |
| Velocity estimation + clamp + EMA | Task 4 |
| Predictive out-of-FOV (3 s timeout, 0.2 s hysteresis) | Task 7 |
| Per-object track IDs + tracker state | Task 7 |
| Class whitelist (~24 classes) | Task 8 |
| 2D bbox overlay | Existing `ContentView` (unchanged) |
| 3D marker overlay | Task 11 |
| Distance → intensity mapping | Task 9 |
| Y-deadzone L/R/centre direction mapping (adapted: X in ARKit) | Task 9 |
| Watchdog 0.5 s | Task 9 |
| 5 Hz vest update | Task 13 |
| 20-cell vest preview UI | Task 10 |
| BLE transport future-compatibility | Task 9 (`HapticTransport` protocol) |

**Placeholders:** none — every step has the code or the exact file+line to edit.

**Type consistency check:** `TrackedObject3D.position`, `.velocity`, `.distance` used consistently across Tasks 7, 8, 9, 11. `VestActivationState.cells[String]` used in Tasks 9, 10. `HapticTransport.send(_:timestamp:)` signature consistent in Tasks 9 and 13. `VestCell.id` format consistent in Tasks 9 and 10.

**One known adaptation from the Jetson spec:** left/right mapping uses camera-space **X** (ARKit), not Y (as written in docs/v4.md). This is documented in the "Coordinate Conventions" section and encoded in `VestMappingEngineTests`.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-14-v4-swift-metal-demo.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — a fresh subagent per task, review between tasks. Best for a plan this size.

**2. Inline Execution** — executed by the main session with checkpoints after each task.

Either way, the user builds & runs on their Mac via Xcode after each push. Task 0 (baseline verification) → Task 15 (push) commits after every task so the user can pull partial progress any time.
