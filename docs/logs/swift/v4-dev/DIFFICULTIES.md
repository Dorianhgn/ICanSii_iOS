# Difficulties Log - swift/v4-dev

Purpose: Track blockers, root causes, and resolution paths.

## Entry template
- Date:
- Context:
- Symptom:
- Root cause (suspected/confirmed):
- Fix applied:
- Validation result:
- Open risk:

---

## 2026-04-15T13:26:28Z
- Date: 2026-04-15
- Context: First pass implementation of v4 tracking pipeline and app integration.
- Symptom: High risk of unstable 3D positions and ID jitter because detections and depth/intrinsics could be fused from different timestamps.
- Root cause (confirmed): TrackingManager originally consumed latest AR frame and latest detections independently; Vision inference is asynchronous and can complete after frame progression.
- Fix applied: Introduced VisionFrameOutput in VisionManager to publish detections + prototypes + source SpatialFrame as one payload; refactored TrackingManager to ingest only this synchronized payload.
- Validation result: Static diagnostics reported no errors after refactor; code-review subagent critical finding addressed in source.
- Open risk: On-device validation still required to confirm temporal behavior under high motion and dropped frames.

## 2026-04-15T13:26:28Z
- Date: 2026-04-15
- Context: Tracker orchestration under asynchronous Combine streams.
- Symptom: Potential race condition in tracker state updates from concurrent ingestion callbacks.
- Root cause (confirmed): Ingestion previously used a global queue with mutable tracker state and no strict serialization boundary.
- Fix applied: Added dedicated serial processing queue in TrackingManager and routed all ingest/tracker mutation through it.
- Validation result: No diagnostics errors; deterministic update path established in code.
- Open risk: Throughput under sustained 15-20 FPS needs runtime profiling on device.

## 2026-04-15T13:26:28Z
- Date: 2026-04-15
- Context: Coordinate conversion from Vision model output to capture-space deprojection.
- Symptom: Potentially biased 3D reconstruction when using normalized centroid directly as capture pixel.
- Root cause (suspected): Orientation/crop mismatch between Vision request orientation and camera-space conventions.
- Fix applied: Applied explicit normalized remap for .right-oriented processing before centroid-to-capture conversion in TrackingManager.
- Validation result: Build-time diagnostics clean; dedicated on-device spatial alignment verification still pending.
- Open risk: Additional explicit transform tests may be required if edge-of-frame projection drift appears.

## 2026-04-15
- Context: Projecting 3D object tracked coordinates (ARKit camera space) back to 2D UIKit/SwiftUI overlay points (`SpatialOverlayView`).
- Symptom: 3D distance marker dots were spatially misaligned and drifted completely out of 2D bounding boxes during device rotation/movement.
- Root cause (confirmed): Double rotation applied onto coordinates. Since projection maps 3D to 2D using ARKit intrinsics, the generated UV is inherently in native capture sensor coordinates. A hard-coded `1.0 - y, x` mapping flip was wrongly transforming it before `displayTransform.inverted()` was executed, effectively mirroring X/Y coordinates diagonally.
- Fix applied: Removed the hard-coded UV flip from `uvToScreen`. Now directly applying `displayTransform.inverted()` to the intrinsic-provided projection pixel.
- Validation result: Affine geometry transformations validated via Swift standalone test scripts; iOS simulator built cleanly (`** BUILD SUCCEEDED **`).
- Open risk: None confirmed, requires physical iPhone real-world QA run.

## 2026-04-20T07:56:33Z
- Date: 2026-04-20
- Context: Incorrect camera-space UV remapping between Vision segmentation/output and ARKit depth/capture coordinates.
- Symptom: Depth values assigned to tracked objects were inconsistent with physical depth; near objects appeared far and markers jumped during device movement.
- Root cause (confirmed): Vision UV remap function returned the wrong capture-space orientation, and the overlay projection used `displayTransform.inverted()` instead of the direct display transform for capture coordinates.
- Fix applied: Corrected `VisionCoordinateMapper.rightOrientedVisionUVToCaptureUV(_:)` to use `CGPoint(x: uv.y, y: 1.0 - uv.x)` and changed `uvToScreen(_:, displayTransform:)` to apply `displayTransform` directly.
- Validation result: Build passed cleanly with `xcodebuild`; coordinate mapping logic verified by code review and diff inspection.
- Open risk: Physical device QA still needed to confirm real-world AR marker alignment across camera motion.

## 2026-04-20T09:40:00Z
- Date: 2026-04-20
- Context: Post-fix verification for tracking backpressure and mask performance changes.
- Symptom: Automated tests could not run via xcodebuild despite available test sources.
- Root cause (confirmed): Scheme ICanSii_iOS is not configured for the Test action; initial destination request iPhone 16 was also unavailable in local simulator list.
- Fix applied: Switched build verification to available destination iPhone 17 Pro and executed xcodebuild build successfully; documented test-action configuration blocker instead of claiming test pass.
- Validation result: Build succeeded (xcodebuild); test run remained blocked with exit code 66 until scheme test action is configured.
- Open risk: Behavior regressions can still exist without executable automated tests from CLI until Xcode scheme test action is enabled.
