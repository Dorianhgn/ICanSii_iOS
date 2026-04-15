# v4 Swift/Metal Demo - Manual QA Checklist

Run on a physical iPhone 17 Pro (LiDAR required).

## Build

- [ ] App builds with no warnings introduced by v4 files
- [ ] yolo26s-seg.mlpackage is in app bundle
- [ ] App launches with Spatial and Vest tabs

## Spatial Tab

- [ ] AR camera feed appears
- [ ] Existing floating HUD panels still work
- [ ] YOLO detections show 2D boxes as before
- [ ] New projected 3D markers appear with id, class, and distance
- [ ] Marker turns predictive color briefly after occlusion, then disappears

## Vest Tab

- [ ] Beyond 1.25 m all cells remain off
- [ ] Within 1.25 m front cells activate
- [ ] Closer objects increase intensity
- [ ] Right-side object biases right cells
- [ ] Left-side object biases left cells
- [ ] Center object activates both sides similarly
- [ ] Object behind camera activates back side map

## Watchdog

- [ ] With detections lost for >0.5 s, all cells turn off

## Stability

- [ ] Background/foreground transitions resume cleanly
- [ ] No crash on orientation change
