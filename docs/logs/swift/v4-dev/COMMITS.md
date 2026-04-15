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
