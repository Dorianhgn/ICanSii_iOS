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
- [ ] New projected 3D markers appear with id, class, and distance : *yes but they are misplaced. If I move the camera left or right, they move weirdly, and they aren't properly aligned with the 2D bounding boxes. Moreover, the distance changes, going from 1.0 m to 2.0 m even though I don't move, only rotate, and the object is stationary*
- [ ] Marker turns predictive color briefly after occlusion, then disappears : (not checked yet)

## Vest Tab

- [x] Beyond 1.25 m all cells remain off
- [x] Within 1.25 m front cells activate : *We should make this 1.25m threshold more like 4m actually. Tell me precisely where I can change it. Moreover, you have 2x5 cell for the front and 2x5 for the back. Actually, you have 2x5 for the left and 2x5 for the right for front and back. So fix this.*
- [x] Closer objects increase intensity
- [ ] Right-side object biases right cells
- [ ] Left-side object biases left cells
- [ ] Center object activates both sides similarly
- [ ] Object behind camera activates back side map

## Watchdog

- [ ] With detections lost for >0.5 s, all cells turn off

## Stability

- [ ] Background/foreground transitions resume cleanly
- [ ] No crash on orientation change
