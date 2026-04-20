# ICanSII iOS v4 Architecture

This document explains the current app structure in plain English. It is based on the v4 plan in [2026-04-14-v4-swift-metal-demo.md](superpowers/plans/2026-04-14-v4-swift-metal-demo.md) and the live source under [ICanSii_iOS](../ICanSii_iOS). The goal is to help someone who does not know Swift or Metal understand how camera frames become tracked 3D objects and vest feedback.

## The short version

The app does three jobs at once:

- It watches the iPhone camera and depth sensor.
- It finds objects, estimates where they are in 3D, and keeps their IDs stable over time.
- It shows the result in two places: a live spatial view and a vest preview.

A simple mental model is:

ARKit frame -> Vision detection -> 3D tracking -> screen overlay and vest preview

The Metal renderer is only the drawing surface. The tracking and vest logic stay in separate Swift files so they are easier to understand and test.

## Suggested reading order

If you are new to the code, read these files in this order:

1. [AppTabView.swift](../ICanSii_iOS/AppTabView.swift) - starts the pipeline and connects the pieces.
2. [ARManager.swift](../ICanSii_iOS/ARManager.swift) - captures ARKit frames and depth.
3. [VisionManager.swift](../ICanSii_iOS/VisionManager.swift) - runs YOLO segmentation.
4. [TrackingManager.swift](../ICanSii_iOS/TrackingManager.swift) - turns 2D detections into 3D objects.
5. [Tracker.swift](../ICanSii_iOS/Tracker.swift) and [Kalman3D.swift](../ICanSii_iOS/Kalman3D.swift) - keep object IDs stable and smooth motion.
6. [VestMappingEngine.swift](../ICanSii_iOS/VestMappingEngine.swift) - converts tracked objects into vest activation.
7. [SpatialOverlayView.swift](../ICanSii_iOS/SpatialOverlayView.swift) - draws labels over the camera view.
8. [VestPreviewView.swift](../ICanSii_iOS/VestPreviewView.swift) - shows the 20-cell vest preview.
9. [SpatialRenderer.swift](../ICanSii_iOS/SpatialRenderer.swift) and [SpatialShaders.metal](../ICanSii_iOS/SpatialShaders.metal) - render the live 3D view.

## What each part does

| File | Plain-English role |
|---|---|
| [ICanSii_iOSApp.swift](../ICanSii_iOS/ICanSii_iOSApp.swift) | App entry point. It opens the tab-based interface. |
| [AppTabView.swift](../ICanSii_iOS/AppTabView.swift) | Main coordinator. It starts ARKit, connects Vision to tracking, and updates the vest preview on a timer. |
| [ContentView.swift](../ICanSii_iOS/ContentView.swift) | Main spatial screen with the Metal view, object boxes, and floating controls. |
| [ARManager.swift](../ICanSii_iOS/ARManager.swift) | Starts the AR session and publishes each frame as a reusable bundle. |
| [SpatialFrame.swift](../ICanSii_iOS/SpatialFrame.swift) | Lightweight container for the camera image, depth map, intrinsics, and transforms. |
| [VisionManager.swift](../ICanSii_iOS/VisionManager.swift) | Runs the CoreML YOLO model and outputs 2D detections plus mask data. |
| [TrackingManager.swift](../ICanSii_iOS/TrackingManager.swift) | Combines detections with depth, converts them into 3D, and hands them to the tracker. |
| [TrackingTypes.swift](../ICanSii_iOS/TrackingTypes.swift) | Shared data objects passed between tracking, overlay, and vest logic. |
| [MaskSampler.swift](../ICanSii_iOS/MaskSampler.swift) | Builds a binary object mask from YOLO prototypes and mask coefficients. |
| [DepthSampler.swift](../ICanSii_iOS/DepthSampler.swift) | Reads a robust depth value from the ARKit depth map. |
| [Deprojection.swift](../ICanSii_iOS/Deprojection.swift) | Converts a 2D pixel plus depth into a 3D camera-space point. |
| [Tracker.swift](../ICanSii_iOS/Tracker.swift) | Matches objects across frames, keeps IDs stable, and predicts brief occlusions. |
| [Kalman3D.swift](../ICanSii_iOS/Kalman3D.swift) | Smooths 3D position and velocity with a simple constant-velocity filter. |
| [VisionCoordinateMapper.swift](../ICanSii_iOS/VisionCoordinateMapper.swift) | Converts between Vision coordinates, capture pixels, and depth pixels. |
| [VisionScreenTransform.swift](../ICanSii_iOS/VisionScreenTransform.swift) | Converts Vision coordinates into on-screen coordinates. |
| [SpatialOverlayView.swift](../ICanSii_iOS/SpatialOverlayView.swift) | Projects tracked 3D objects back onto the screen as labels. |
| [SpatialMetalView.swift](../ICanSii_iOS/SpatialMetalView.swift) | Hosts the Metal view that shows RGB, depth, and point cloud modes. |
| [SpatialRenderer.swift](../ICanSii_iOS/SpatialRenderer.swift) | The actual Metal renderer. It is isolated from the detection and tracking logic. |
| [VestTypes.swift](../ICanSii_iOS/VestTypes.swift) | Vest cell definitions and the transport abstraction used by the preview. |
| [VestMappingEngine.swift](../ICanSii_iOS/VestMappingEngine.swift) | Converts the nearest tracked object into a 20-cell haptic pattern. |
| [VestPreviewView.swift](../ICanSii_iOS/VestPreviewView.swift) | Displays the vest pattern in a SwiftUI grid. |

## How a frame moves through the app

1. ARManager receives an ARKit frame and packages the useful pieces into a SpatialFrame. That frame contains the camera image, the depth map, the camera intrinsics, the camera transform, and the screen transform.
2. VisionManager runs the YOLO segmentation model on the camera image. The model is requested with the `.right` orientation, which is why the coordinate conversion files exist.
3. TrackingManager takes the 2D detections and filters out objects that are not interesting for the app. For each surviving detection it rebuilds the object mask, samples depth from the mask, and back-projects the pixel into 3D.

   The key math is:

   $$
   d = P_{15}\bigl(\text{depth}(x, y) \;\text{over active mask pixels}\bigr)
   $$

   $$
   X = \frac{u - c_x}{f_x} \cdot d
   \qquad
   Y = -\frac{v - c_y}{f_y} \cdot d
   \qquad
   Z = -d
   $$

   where $(u, v)$ is the sampled pixel, $(f_x, f_y)$ are the camera focal lengths, and $(c_x, c_y)$ are the principal point coordinates.
4. Tracker compares the new 3D observation with the existing tracked objects. It uses box overlap and center distance to decide whether the new detection belongs to an existing object or should create a new one.

   In practice the match score is based on two simple distances:

   $$
   \operatorname{IoU}(A, B) = \frac{\operatorname{area}(A \cap B)}{\operatorname{area}(A \cup B)}
   $$

   $$
   d_{px} = \sqrt{(x_{track} - x_{det})^2 + (y_{track} - y_{det})^2}
   $$

   $$
   \operatorname{score} = \max\!\left(\operatorname{IoU}(A, B),\; 1 - \frac{d_{px}}{\text{threshold}}\right)
   $$

   Higher score means the detection is more likely to belong to that same tracked object.
5. Kalman3D smooths the 3D position and velocity. If an object disappears for a short time, the tracker predicts forward instead of dropping it immediately.

   The state is a constant-velocity model:

   $$
   \mathbf{x} = \begin{bmatrix} x & y & z & v_x & v_y & v_z \end{bmatrix}^{\mathsf T}
   $$

   $$
   \mathbf{x}_{t+\Delta t} = F(\Delta t)\,\mathbf{x}_t + \mathbf{w}
   $$

   with each axis behaving like:

   $$
   p(t+\Delta t) = p(t) + v(t)\,\Delta t
   $$

   $$
   v(t+\Delta t) = v(t)
   $$

   When a measurement arrives, the filter blends the observation and the prediction. When no measurement arrives, it keeps extrapolating briefly so the object does not disappear immediately.
6. SpatialOverlayView turns the tracked 3D positions back into screen labels so the user sees object IDs and distances on top of the camera view.
7. AppTabView also feeds the tracked objects into VestMappingEngine on a steady timer. VestMappingEngine picks the closest object that is still within range and turns it into a 20-cell vest state.
8. VestPreviewView displays that state as a simple color grid, so the haptic mapping can be understood without real hardware attached.

## Coordinate rules

The app uses several coordinate systems, and most bugs come from mixing them up.

| Coordinate system | What it means | Where it is used |
|---|---|---|
| ARKit camera space | The 3D space centered on the phone camera. Positive X is right, positive Y is up, and negative Z is forward. | Tracking, overlay projection, vest distance calculations. |
| Vision image space | The coordinate system returned by Vision for the YOLO model. In this app the model runs with `.right` orientation. | YOLO detections and mask math. |
| Capture image space | The raw camera image in pixel coordinates. | Depth sampling and deprojection. |
| Screen space | The final on-screen position seen by the user. | Bounding boxes and 3D labels. |
| Vest logical space | A portrait-friendly remap used before choosing left, right, front, or back cells. | VestMappingEngine and VestPreviewView. |

The important practical rule is this: if the overlay looks mirrored or the vest lights up on the wrong side, the bug is usually in a coordinate conversion file, not in the detector itself.

The current vest code intentionally rotates the sensor axes into a portrait-friendly logical frame before choosing the lit side. The tests encode that convention, so if the behavior changes, the tests should change with it.

## What to touch when something breaks

- If boxes are in the wrong place, start with VisionCoordinateMapper or VisionScreenTransform.
- If depth looks wrong or objects jump in 3D, check MaskSampler, DepthSampler, and Deprojection.
- If object IDs keep changing, look at Tracker and Kalman3D.
- If the vest preview is wrong, look at VestMappingEngine and VestTypes.
- If the live 3D canvas looks wrong, the issue is usually in SpatialRenderer or SpatialShaders.metal.

## Why the app is split this way

The structure is deliberate:

- ARManager handles sensor capture and timing.
- VisionManager handles object detection.
- TrackingManager handles the bridge from 2D detection to 3D tracking.
- Tracker and Kalman3D keep the motion stable.
- VestMappingEngine stays pure so it can be tested without the camera.
- SpatialRenderer stays isolated so the Metal code does not leak into the tracking logic.

That separation makes the app easier to reason about, easier to test, and easier to extend later if BLE haptic output is added.

## Validation

The repository includes pure Swift tests for tracking, depth, deprojection, and vest mapping under [Tests/SiiVisionTests](../Tests/SiiVisionTests). They are useful because they check the math without requiring a live AR session.

If you want the original implementation plan that led to this architecture, see [v4 Swift/Metal demo plan](superpowers/plans/2026-04-14-v4-swift-metal-demo.md).
