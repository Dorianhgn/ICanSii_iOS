# Commits Log - swift/v4-dev

Purpose: Human-readable summary of commits and why they matter.

## Entry template
- Date:
- Commit:
- Scope:
- Why:
- Impact: (metrics, thresholds, behavior changes - omit if none)
- Datasets/targets impacted: (omit if not applicable)
- Follow-up:

---

## 2026-04-15T13:26:28Z
- Date: 2026-04-15
- Commit: 1543c43
- Scope: v4 iOS demo integration - synchronized Vision/AR frame output, 3D tracking pipeline, predictive tracking, vest mapping and preview UI, app tab routing, and initial unit test suite scaffold.
- Why: Execute the first implementation block of the v4 Swift/Metal port plan so on-device QA can begin with end-to-end behavior visible in Spatial and Vest tabs.
- Impact: Introduces predictive tracking timeout at 1.0 s with per-step velocity decay 0.85; introduces distance-threshold vest activation behavior at 1.25 m and watchdog off at 0.5 s; adds synchronized frame-coupled detection ingestion path to reduce 3D/depth mismatch risk.
- Datasets/targets impacted: iOS app target ICanSii_iOS; unit test source set Tests/SiiVisionTests (external to project target until Xcode target mapping).
- Follow-up: Run device QA checklist on iPhone 17 Pro, confirm geometry mapping under real camera motion, then split subsequent tasks into smaller reviewable commits.

## 2026-04-15
- Date: 2026-04-15
- Commit: (Pending) Fix 3D marker coordinate drift and double-rotation
- Scope: ICanSii_iOS / SpatialOverlayView
- Why: 3D positional distance markers for tracked objects were failing to align with 2D visual YOLO bounding boxes due to duplicated rotation mappings.
- Impact: 3D point markers accurately lock to semantic object centerings across iOS coordinate orientations without drifting.
- Follow-up: Need physical validations on iPhone 17 Pro to confirm final visual-haptic alignment matrices.

## 2026-04-20T09:40:00Z
- Date: 2026-04-20
- Commit: e580422
- Scope: Tracking ingestion backpressure and mask sampling hot path.
- Why: Producer/consumer imbalance caused frame backlog, latency growth, and memory pressure; scalar mask dot-product loop was too slow under large boxes.
- Impact: Mask dot-product path is vectorized with Accelerate; tracking now drops incoming frames while processing one frame to prevent unbounded queue growth.
- Datasets/targets impacted: ICanSii_iOS app target runtime behavior on live camera/depth streams.
- Follow-up: Confirm dropped-frame rate and latency trade-off on physical device with Instruments Allocations + Time Profiler.

## 2026-04-20T09:52:24Z
- Date: 2026-04-20
- Commit: 82a3aca
- Scope: Overlay reprojection alignment for tracked barycenters and shared Vision/screen transform utilities.
- Why: Tracked barycenter markers remained offset from YOLO boxes/segmentations because the final coordinate conversion path was not fully shared.
- Impact: 3D tracked markers now use the same Vision-to-screen conversion route as 2D overlays, reducing systematic offset and edge drift.
- Datasets/targets impacted: ICanSii_iOS app runtime overlay behavior in RGB mode.
- Follow-up: Validate on physical iPhone with camera motion and edge-of-frame objects.

## 2026-04-20T10:04:09Z
- Date: 2026-04-20
- Commit: (pending, next commit)
- Scope: Portrait logical-axis correction for vest haptic mapping and associated unit-test alignment.
- Why: The previous axis convention still produced an interpretation mismatch between handheld portrait motion and vest left/right + up/down feedback.
- Impact: Haptic side selection now follows the finalized portrait convention; right-bias test input updated to match runtime mapping semantics.
- Datasets/targets impacted: ICanSii_iOS app runtime haptic behavior (`VestMappingEngine`) and unit tests (`VestMappingEngineTests`).
- Follow-up: Validate on-device with left/right sweep and vertical sweep in portrait mode.
