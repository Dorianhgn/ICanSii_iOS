---
description: "Use when writing, reviewing, or generating Swift code for ICanSii iOS. Covers performance-critical iOS patterns: zero-copy CVPixelBuffer, Metal/Accelerate, ARKit, CoreML, CoreBluetooth. Apply for all sensor pipeline, AI inference, and BLE work."
applyTo: "**/*.swift"
---

# ICanSii iOS — Swift Code Generation Rules

## Project Architecture

**V4 (current baseline):**
```
RGB + Depth + Camera Intrinsics  →  YOLOv11s/26s (CoreML)  →  Distance Priority  →  BLE → Haptic Vest
```

**V5 (target):**
```
RGB + Depth + Camera Intrinsics + IMU  →  ┌ YOLO Branch (semantic)   ┐
                                           └ Geometric Branch (normals)┘  →  Distance / TTC Priority  →  BLE → Haptic Vest
```

All processing is 100% on-device. No network calls. No cloud.

---

## Mandatory Code Generation Rules

### Zero-Copy Memory
- Never copy pixel data unnecessarily. Access `CVPixelBuffer` via `CVPixelBufferLockBaseAddress` + `CVPixelBufferGetBaseAddress`, then unlock immediately after use.
- Pass `CVPixelBuffer` references between pipeline stages; never serialize to `Data` or `[UInt8]` in hot paths.
- Use `MTLStorageMode.shared` for buffers that both CPU and GPU must read.

### No Loops Over Image Data
- **Forbidden:** nested `for y in 0..<height { for x in 0..<width { ... } }` on depth maps or pixel buffers.
- **Required for GPU spatial ops** (unprojection, cross-products, normal estimation): Metal Compute Shaders (`MTLComputePipelineState`).
- **Required for CPU vector math** (reductions, percentile extraction, matrix ops): Accelerate framework — `vDSP`, `vImage`, `BNNS`.
- Use `simd` types (`simd_float3`, `simd_float4x4`) for per-element math outside of loops.

### Concurrency Model
- Keep `session(_:didUpdate:frame:)` (ARKit delegate) minimal — dispatch heavy work to a dedicated serial `DispatchQueue` or Swift actor immediately.
- Never block the main thread. No `DispatchQueue.main.sync` in sensor or inference callbacks.
- Use `async/await` for CoreML inference chains.

### Performance Idioms
- Declare performance-critical classes as `final` to eliminate dynamic dispatch.
- Use `@inline(__always)` on hot-path utility functions.
- Guard-unwrap `Optional`s early; avoid optional chaining inside tight loops.
- Reuse `MTLCommandBuffer` and `MTLBuffer` objects — allocate once, write repeatedly.

### Thermal Budget
- Semantic inference (YOLO): target **10–15 FPS** to stay within thermal budget.
- Geometric branch (depth/normals): can run at **30 FPS** (GPU, lightweight).
- Suppress full RGB screen rendering during active pipeline runs (headless mode in production).
- Batch all GPU work into a single `MTLCommandBuffer` per frame.

---

## Framework-to-Task Mapping

| Task | Use |
|------|-----|
| RGB frame, LiDAR depth, pose, camera intrinsics | `ARKit` — `ARFrame.sceneDepth`, `ARCamera` |
| Gravity vector, quaternions at 100 Hz | `CoreMotion` — `CMMotionManager` |
| GPU spatial compute (normals, unproject, cross-product) | `Metal` — compute shaders |
| CPU vector/matrix math (reductions, slicing) | `Accelerate` — `vDSP`, `vImage` |
| AI inference (YOLO, OOD heads) | `CoreML` + `Vision` — `VNCoreMLRequest` |
| BLE haptic vest communication | `CoreBluetooth` — `CBCentralManager` |

---

## CoreML / Neural Engine
- Always set `MLModelConfiguration.computeUnits = .all` to enable the Apple Neural Engine.
- Set `VNCoreMLRequest.usesCPUOnly = false`.
- Prefer `MLMultiArray` backed by a shared pixel buffer to eliminate input-copy overhead.

---

## Hard Prohibitions
- No non-native AI runtimes (no TensorFlow Lite, no PyTorch Mobile, no ONNX Runtime).
- No Python-style algorithms ported verbatim to Swift loops.
- No `UIViewRepresentable` wrappers or SwiftUI abstractions in the sensor pipeline layer.
- No synchronous network calls or cloud inference at any pipeline stage.
