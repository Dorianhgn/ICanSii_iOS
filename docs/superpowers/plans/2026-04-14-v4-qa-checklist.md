# v4 Swift/Metal Demo - Manual QA Checklist

Run on a physical iPhone 17 Pro (LiDAR required).

## Build

- [x] App builds with no warnings introduced by v4 files
- [x] yolo26s-seg.mlpackage is in app bundle
- [x] App launches with Spatial and Vest tabs

## Spatial Tab

- [x] AR camera feed appears
- [x] Existing floating HUD panels still work
- [x] YOLO detections show 2D boxes as before
- [x] New projected 3D markers appear with id, class, and distance
- [x] Marker turns predictive color briefly after occlusion, then disappears

## Vest Tab

- [x] Beyond 1.25 m all cells remain off
- [x] Within 1.25 m front cells activate 
- [x] Closer objects increase intensity
- [x] Right-side object biases right cells
- [x] Left-side object biases left cells
- [x] Center object activates both sides similarly
- [?] Object behind camera activates back side map

## Watchdog

- [x] With detections lost for >0.5 s, all cells turn off

## Stability

- [x] Background/foreground transitions resume cleanly
- [x] No crash on orientation change
