# Difficulties Log

Purpose:
- Track blockers, root causes, and resolution paths.

## Entry template
- Date:
- Context:
- Symptom:
- Root cause (suspected/confirmed):
- Fix applied:
- Validation result:
- Open risk:

## 2026-03-25T08:18:21Z
- Date: 2026-03-25T08:18:21Z
- Context: Tri-plane scatter implementation on iOS Metal (real-time debug overlays in SpatialRenderer).
- Symptom: Shader build errors for `texture2d<atomic_uint>` and runtime abort at `setRenderPipelineState` during overlay rendering.
- Root cause (suspected/confirmed): Confirmed.
	1) iOS toolchain does not allow atomic texture channel usage as implemented.
	2) Debug overlay pipeline depth format mismatched with active MTKView render pass configuration.
- Fix applied:
	1) Replaced atomic textures with linear `device atomic_uint*` buffers (row-major indexing), preserving clear/scatter/resolve architecture.
	2) Created triplane debug pipeline with depth attachment format matching active pass.
	3) Replaced CPU dispatch timing with asynchronous command buffer GPU timestamp logging.
- Validation result: `get_errors` reports no issues in ICanSii_iOS/TriplaneScatter.metal, ICanSii_iOS/TriplaneEncoder.swift, and ICanSii_iOS/SpatialRenderer.swift.
- Open risk: Current timing uses full command-buffer GPU interval; isolated per-pass triplane timing may still be needed for profiling precision.
