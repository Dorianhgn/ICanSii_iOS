# SiiVisionTests

Pure-Swift unit tests for v4 tracking and vest mapping modules.

## One-time setup in Xcode (on your Mac)

1. Open ICanSii_iOS.xcodeproj.
2. Create a new target: File -> New -> Target -> iOS -> Unit Testing Bundle.
3. Name it SiiVisionTests and set product target to ICanSii_iOS.
4. Delete the auto-generated test file from that target.
5. Add this folder (Tests/SiiVisionTests) to the test target only.
6. Run tests with Cmd+U.

These tests are intentionally outside the app target source roots, so they never compile into the app target.

## Covered modules

- TrackingTypes
- Kalman3D
- MaskSampler
- DepthSampler
- Deprojection
- Tracker
- VestMappingEngine
