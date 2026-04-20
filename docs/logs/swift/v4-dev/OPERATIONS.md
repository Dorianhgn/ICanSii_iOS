# Operations Log - swift/v4-dev

Purpose: Task execution journal. What was done, which files were touched, which commands ran.

## Format
- ISO datetime entry header
- Bullet list: action, files, commands/checks

---

## 2026-04-15T13:26:28Z
- Implemented the full v4 demo foundation slice: synchronized YOLO-to-3D tracking, predictive tracker, spatial overlay, vest mapping engine, and two-tab app root.
  Files: ICanSii_iOS/TrackingTypes.swift, ICanSii_iOS/Kalman3D.swift, ICanSii_iOS/MaskSampler.swift, ICanSii_iOS/DepthSampler.swift, ICanSii_iOS/Deprojection.swift, ICanSii_iOS/Tracker.swift, ICanSii_iOS/TrackingManager.swift, ICanSii_iOS/VestTypes.swift, ICanSii_iOS/VestMappingEngine.swift, ICanSii_iOS/VestPreviewView.swift, ICanSii_iOS/SpatialOverlayView.swift, ICanSii_iOS/AppTabView.swift, ICanSii_iOS/ARManager.swift, ICanSii_iOS/ContentView.swift, ICanSii_iOS/ICanSii_iOSApp.swift, ICanSii_iOS/VisionManager.swift.
  Commands/checks: repository baseline inspection via git branch/log/status; diagnostics via get_errors.
- Added test harness files for tracking, geometry, and vest logic and documented one-time test target setup.
  Files: Tests/SiiVisionTests/TrackingTypesTests.swift, Tests/SiiVisionTests/Kalman3DTests.swift, Tests/SiiVisionTests/MaskSamplerTests.swift, Tests/SiiVisionTests/DepthSamplerTests.swift, Tests/SiiVisionTests/DeprojectionTests.swift, Tests/SiiVisionTests/TrackerTests.swift, Tests/SiiVisionTests/VestMappingEngineTests.swift, Tests/SiiVisionTests/README.md.
  Commands/checks: static diagnostics check returned no errors across ICanSii_iOS and Tests/SiiVisionTests.
- Added manual QA execution checklist for physical iPhone validation.
  Files: docs/superpowers/plans/2026-04-14-v4-qa-checklist.md.
  Commands/checks: none (documentation addition only).
- Performed subagent-assisted review before finalizing and then applied remediation for high-risk issues.
  Files: ICanSii_iOS/VisionManager.swift, ICanSii_iOS/TrackingManager.swift, ICanSii_iOS/MaskSampler.swift, Tests/SiiVisionTests/TrackerTests.swift.
  Commands/checks: runSubagent(code-reviewer), get_errors after fixes.
- Finalized and committed the integrated slice.
  Files: 25 tracked files in commit.
  Commands/checks: git add (explicit file list), git commit, git rev-parse --short HEAD.

## 2026-04-15T17:00:00Z
- Debugged 3D marker reprojection drift compared to 2D YOLO boxes during device rotation.
  Files: `ICanSii_iOS/SpatialOverlayView.swift`, `ICanSii_iOS/ContentView.swift`, `ICanSii_iOS/VisionCoordinateMapper.swift`.
  Commands: Tested affine transforms/intrinsic projections via local swift simulator scripts, `xcodebuild` for iOS target validation.
- Fixed erroneous 90-degree sensor-to-view rotation from ARKit-derived 3D markers.
  Files: `ICanSii_iOS/SpatialOverlayView.swift`.
  Commands: `xcodebuild` clean compile verification.

## 2026-04-20T07:56:33Z
- Corrected depth/UV coordinate mapping for Vision mask centroids and ARKit overlay projection.
  Files: `ICanSii_iOS/VisionCoordinateMapper.swift`, `ICanSii_iOS/SpatialOverlayView.swift`.
  Commands: Verified mapping changes via code inspection, `git diff`, and `xcodebuild` build success.

## 2026-04-20T09:40:00Z
- Replaced scalar per-channel mask dot-product loop with Accelerate vector primitive for prototype mask assembly.
  Files: ICanSii_iOS/MaskSampler.swift.
  Commands/checks: get_errors on modified Swift files; xcodebuild build -project ICanSii_iOS.xcodeproj -scheme ICanSii_iOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro'.
- Removed unbounded Combine receive queueing in tracking ingestion and introduced single-inflight drop policy with explicit lock and autoreleasepool.
  Files: ICanSii_iOS/TrackingManager.swift.
  Commands/checks: xcodebuild test attempts with iPhone 16 and iPhone 17 Pro destinations; inspected scheme/destination availability with xcodebuild -list and xcodebuild -showdestinations.
- Committed performance and backpressure fix as a focused code commit.
  Files: ICanSii_iOS/MaskSampler.swift, ICanSii_iOS/TrackingManager.swift.
  Commands/checks: git add (explicit files), git commit, git show --name-only --oneline --no-patch HEAD.
