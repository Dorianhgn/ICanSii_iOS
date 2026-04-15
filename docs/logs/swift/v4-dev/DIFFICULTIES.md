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
